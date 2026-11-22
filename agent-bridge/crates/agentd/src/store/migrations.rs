use crate::types::{storage_error, BridgeError, Result};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior};

const LEGACY_SCHEMA: &str = "
CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, paired_at TEXT NOT NULL, last_seen TEXT, permissions TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
CREATE TABLE operations(peer TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, state TEXT NOT NULL, result TEXT, created_at TEXT NOT NULL, PRIMARY KEY(peer,id));
CREATE TABLE processes(id TEXT PRIMARY KEY, info TEXT NOT NULL);
CREATE INDEX processes_started ON processes(json_extract(info,'$.started_at'));
CREATE INDEX processes_state ON processes(json_extract(info,'$.state'));
CREATE TABLE discovery(id TEXT PRIMARY KEY, info TEXT NOT NULL, expires_at INTEGER NOT NULL);
";

const DOMAIN_SCHEMA: &str = "
CREATE TABLE projects(id TEXT PRIMARY KEY, canonical_root TEXT NOT NULL UNIQUE, payload TEXT NOT NULL CHECK(json_valid(payload)));
CREATE TABLE project_access(project_id TEXT NOT NULL REFERENCES projects(id), principal_id TEXT NOT NULL, PRIMARY KEY(project_id,principal_id));
CREATE TABLE threads(id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), provider_id TEXT NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)), revision INTEGER NOT NULL CHECK(revision >= 0));
CREATE INDEX threads_project ON threads(project_id, id);
CREATE TABLE provider_sessions(id TEXT PRIMARY KEY, thread_id TEXT NOT NULL UNIQUE REFERENCES threads(id), provider_thread_id TEXT, payload TEXT NOT NULL CHECK(json_valid(payload)));
CREATE TABLE runs(id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id), status TEXT NOT NULL CHECK(status IN ('queued','starting','running','waiting_approval','completed','failed','interrupted','outcome_unknown')), payload TEXT NOT NULL CHECK(json_valid(payload)), revision INTEGER NOT NULL CHECK(revision >= 0));
CREATE UNIQUE INDEX runs_active_thread ON runs(thread_id) WHERE status IN ('queued','starting','running','waiting_approval','outcome_unknown');
CREATE TABLE messages(id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id), run_id TEXT REFERENCES runs(id), client_message_id TEXT, payload TEXT NOT NULL CHECK(json_valid(payload)), revision INTEGER NOT NULL CHECK(revision >= 0), UNIQUE(thread_id,client_message_id));
CREATE INDEX messages_thread ON messages(thread_id,id);
CREATE TABLE approvals(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), state TEXT NOT NULL CHECK(state IN ('pending','resolved','expired')), payload TEXT NOT NULL CHECK(json_valid(payload)));
CREATE TABLE external_thread_refs(provider_id TEXT NOT NULL, external_thread_id TEXT NOT NULL, thread_id TEXT NOT NULL REFERENCES threads(id), source TEXT NOT NULL, PRIMARY KEY(provider_id,external_thread_id));
CREATE TABLE domain_events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_id TEXT NOT NULL, thread_id TEXT REFERENCES threads(id), event_type TEXT NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)), created_at TEXT NOT NULL);
CREATE INDEX domain_events_thread ON domain_events(thread_id,sequence);
CREATE TABLE command_receipts(principal_id TEXT NOT NULL, command_id TEXT NOT NULL, fingerprint TEXT NOT NULL, result TEXT NOT NULL CHECK(json_valid(result)), created_at TEXT NOT NULL, PRIMARY KEY(principal_id,command_id));
CREATE TABLE effect_outbox(id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id), state TEXT NOT NULL CHECK(state IN ('pending','executing','completed','outcome_unknown')), payload TEXT NOT NULL CHECK(json_valid(payload)), created_at TEXT NOT NULL);
CREATE TABLE sync_watermarks(scope TEXT PRIMARY KEY, pruned_through INTEGER NOT NULL CHECK(pruned_through >= 0));
INSERT INTO sync_watermarks VALUES('environment',0);
";

/// All DDL and the version marker commit together. Unknown schemas are untouched.
pub(super) fn migrate(conn: &mut Connection) -> Result<()> {
    conn.execute_batch("PRAGMA foreign_keys=ON;")
        .map_err(storage_error)?;
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(storage_error)?;
    let has_metadata: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata')",
            [],
            |row| row.get(0),
        )
        .map_err(storage_error)?;
    let version: Option<String> = if has_metadata {
        tx.query_row(
            "SELECT value FROM metadata WHERE key='schema_version'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(storage_error)?
    } else {
        None
    };
    match version.as_deref() {
        None if !has_metadata => tx.execute_batch(LEGACY_SCHEMA).map_err(storage_error)?,
        Some("1" | "2") => (),
        _ => {
            return Err(BridgeError::new(
                "unsupported",
                "The local database was created by an incompatible application version.",
            ))
        }
    }
    if version.as_deref() != Some("2") {
        tx.execute_batch(DOMAIN_SCHEMA).map_err(storage_error)?;
        tx.execute("INSERT INTO metadata(key,value) VALUES('schema_version','2') ON CONFLICT(key) DO UPDATE SET value=excluded.value", []).map_err(storage_error)?;
        tx.execute(
            "INSERT INTO metadata(key,value) VALUES('environment_id',?1)",
            [uuid::Uuid::new_v4().to_string()],
        )
        .map_err(storage_error)?;
    }
    tx.commit().map_err(storage_error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upgrades_legacy_rows_and_keeps_stable_identity() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(LEGACY_SCHEMA).unwrap();
        conn.execute_batch("INSERT INTO metadata VALUES('schema_version','1'); INSERT INTO devices(id,name,paired_at,permissions) VALUES('phone','Phone','now','[\"view\"]');").unwrap();
        migrate(&mut conn).unwrap();
        let identity: String = conn
            .query_row(
                "SELECT value FROM metadata WHERE key='environment_id'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        migrate(&mut conn).unwrap();
        assert_eq!(
            identity,
            conn.query_row::<String, _, _>(
                "SELECT value FROM metadata WHERE key='environment_id'",
                [],
                |r| r.get(0)
            )
            .unwrap()
        );
        assert_eq!(
            1,
            conn.query_row::<i64, _, _>("SELECT COUNT(*) FROM devices WHERE id='phone'", [], |r| r
                .get(0))
                .unwrap()
        );
    }

    #[test]
    fn rejects_future_schema_without_creating_tables() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); INSERT INTO metadata VALUES('schema_version','99');").unwrap();
        assert_eq!(migrate(&mut conn).unwrap_err().code, "unsupported");
        assert_eq!(
            1,
            conn.query_row::<i64, _, _>(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table'",
                [],
                |r| r.get(0)
            )
            .unwrap()
        );
    }

    #[test]
    fn failed_migration_rolls_back_ddl_and_version() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(LEGACY_SCHEMA).unwrap();
        conn.execute_batch(
            "INSERT INTO metadata VALUES('schema_version','1'); CREATE TABLE runs(sentinel TEXT);",
        )
        .unwrap();
        assert!(migrate(&mut conn).is_err());
        assert_eq!(
            "1",
            conn.query_row::<String, _, _>(
                "SELECT value FROM metadata WHERE key='schema_version'",
                [],
                |r| r.get(0)
            )
            .unwrap()
        );
        assert_eq!(
            0,
            conn.query_row::<i64, _, _>(
                "SELECT COUNT(*) FROM sqlite_master WHERE name='projects'",
                [],
                |r| r.get(0)
            )
            .unwrap()
        );
    }

    #[test]
    fn active_run_and_message_ids_are_unique() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate(&mut conn).unwrap();
        conn.execute_batch("INSERT INTO projects VALUES('p','/project','{}'); INSERT INTO threads VALUES('t','p','codex','{}',0); INSERT INTO runs VALUES('r','t','outcome_unknown','{}',0);").unwrap();
        assert!(conn
            .execute("INSERT INTO runs VALUES('r2','t','running','{}',0)", [])
            .is_err());
        conn.execute("UPDATE runs SET status='completed' WHERE id='r'", [])
            .unwrap();
        conn.execute("INSERT INTO runs VALUES('r2','t','running','{}',0)", [])
            .unwrap();
        conn.execute(
            "INSERT INTO messages VALUES('m','t','r2','client','{}',0)",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "INSERT INTO messages VALUES('m2','t','r2','client','{}',0)",
                []
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO threads VALUES('bad','missing','codex','{}',0)",
                []
            )
            .is_err());
    }
}
