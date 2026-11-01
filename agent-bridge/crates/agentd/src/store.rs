use crate::types::*;
use rusqlite::{params, Connection, OptionalExtension};
use std::{
    path::Path,
    sync::{Mutex, MutexGuard},
};

pub(crate) struct Store {
    conn: Mutex<Connection>,
}
pub(crate) enum Reservation {
    New,
    Finished(ProcessInfo),
}
impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path).map_err(storage_error)?;
        conn.busy_timeout(std::time::Duration::from_secs(2))
            .map_err(storage_error)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, paired_at TEXT NOT NULL, last_seen TEXT, permissions TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS operations(peer TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, state TEXT NOT NULL, result TEXT, created_at TEXT NOT NULL, PRIMARY KEY(peer,id));
            CREATE TABLE IF NOT EXISTS processes(id TEXT PRIMARY KEY, info TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS processes_started ON processes(json_extract(info,'$.started_at'));
            CREATE INDEX IF NOT EXISTS processes_state ON processes(json_extract(info,'$.state'));
            CREATE TABLE IF NOT EXISTS discovery(id TEXT PRIMARY KEY, info TEXT NOT NULL, expires_at INTEGER NOT NULL);").map_err(storage_error)?;
        let version: Option<String> = conn
            .query_row(
                "SELECT value FROM metadata WHERE key='schema_version'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(storage_error)?;
        if version.as_deref().is_some_and(|v| v != "1") {
            return Err(BridgeError::new(
                "unsupported",
                "The local database was created by an incompatible application version.",
            ));
        }
        conn.execute(
            "INSERT OR IGNORE INTO metadata(key,value) VALUES('schema_version','1')",
            [],
        )
        .map_err(storage_error)?;
        conn.execute(
            "UPDATE operations SET state='unknown' WHERE state='reserved'",
            [],
        )
        .map_err(storage_error)?;
        let store = Self {
            conn: Mutex::new(conn),
        };
        for mut info in store.recoverable_processes()? {
            if matches!(info.state.as_str(), "starting" | "running" | "stopping") {
                info.state = "lost".into();
                info.pid = None;
                store.save_process(&info)?;
            }
        }
        Ok(store)
    }
    fn conn(&self) -> Result<MutexGuard<'_, Connection>> {
        self.conn.lock().map_err(|_| storage_error("poisoned"))
    }
    pub fn settings(&self) -> Result<AppSettings> {
        let value: Option<String> = self
            .conn()?
            .query_row("SELECT value FROM metadata WHERE key='settings'", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(storage_error)?;
        let mut settings: AppSettings = value
            .map(|v| serde_json::from_str(&v).map_err(storage_error))
            .unwrap_or_else(|| Ok(AppSettings::default()))?;
        // Preserve custom names while upgrading the former product default.
        if settings.device_name == "Agent Bridge" {
            settings.device_name = AppSettings::default().device_name;
        }
        Ok(settings)
    }
    pub fn save_settings(&self, settings: &AppSettings) -> Result<()> {
        self.conn()?.execute("INSERT INTO metadata(key,value) VALUES('settings',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [serde_json::to_string(settings).map_err(storage_error)?]).map_err(storage_error)?;
        Ok(())
    }
    /// The QR stores direct IP/port hints. Keep the host sockets stable across
    /// process restarts so those hints still work without public DNS lookup.
    pub fn network_bind_addrs(&self) -> Result<Option<Vec<std::net::SocketAddr>>> {
        let value: Option<String> = self
            .conn()?
            .query_row(
                "SELECT value FROM metadata WHERE key='network_bind_addrs_v1'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(storage_error)?;
        let addresses = value
            .map(|value| {
                serde_json::from_str::<Vec<std::net::SocketAddr>>(&value).map_err(storage_error)
            })
            .transpose()?;
        if let Some(addresses) = &addresses {
            if addresses.is_empty()
                || addresses.len() > 2
                || addresses
                    .iter()
                    .any(|address| !address.ip().is_unspecified() || address.port() == 0)
                || addresses.iter().filter(|address| address.is_ipv4()).count() > 1
                || addresses.iter().filter(|address| address.is_ipv6()).count() > 1
            {
                return Err(storage_error("Invalid saved network bind addresses."));
            }
        }
        Ok(addresses)
    }

    pub fn save_network_bind_addrs(&self, addresses: &[std::net::SocketAddr]) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO metadata(key,value) VALUES('network_bind_addrs_v1',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [serde_json::to_string(addresses).map_err(storage_error)?],
        ).map_err(storage_error)?;
        Ok(())
    }

    pub fn devices(&self) -> Result<Vec<PairedDevice>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT id,name,paired_at,last_seen,permissions FROM devices WHERE revoked=0 ORDER BY paired_at").map_err(storage_error)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, String>(4)?,
                ))
            })
            .map_err(storage_error)?;
        rows.map(|row| {
            let (device_id, name, paired_at, last_seen, perms) = row.map_err(storage_error)?;
            Ok(PairedDevice {
                device_id,
                name,
                paired_at,
                last_seen,
                connection: "offline".into(),
                path_kind: None,
                permissions: serde_json::from_str(&perms).map_err(storage_error)?,
            })
        })
        .collect()
    }
    pub fn grant(&self, peer: &str, name: &str, permissions: Vec<String>) -> Result<PairedDevice> {
        let device = PairedDevice {
            device_id: peer.into(),
            name: name.into(),
            paired_at: now(),
            last_seen: None,
            connection: "offline".into(),
            path_kind: None,
            permissions,
        };
        self.conn()?.execute("INSERT INTO devices(id,name,paired_at,permissions,revoked) VALUES(?1,?2,?3,?4,0) ON CONFLICT(id) DO UPDATE SET name=excluded.name,paired_at=excluded.paired_at,permissions=excluded.permissions,revoked=0",params![peer,name,device.paired_at,serde_json::to_string(&device.permissions).map_err(storage_error)?]).map_err(storage_error)?;
        Ok(device)
    }
    pub fn revoke(&self, peer: &str) -> Result<()> {
        if self
            .conn()?
            .execute("UPDATE devices SET revoked=1 WHERE id=?1", [peer])
            .map_err(storage_error)?
            == 0
        {
            return Err(BridgeError::new("not_found", "Device is not paired."));
        }
        Ok(())
    }
    pub fn seen(&self, peer: &str) -> Result<()> {
        self.conn()?
            .execute(
                "UPDATE devices SET last_seen=?2 WHERE id=?1 AND revoked=0",
                params![peer, now()],
            )
            .map_err(storage_error)?;
        Ok(())
    }
    pub fn authorize(&self, peer: &str, permissions: &[&str]) -> Result<()> {
        let stored: Option<String> = self
            .conn()?
            .query_row(
                "SELECT permissions FROM devices WHERE id=?1 AND revoked=0",
                [peer],
                |r| r.get(0),
            )
            .optional()
            .map_err(storage_error)?;
        let grant: Vec<String> = match stored {
            Some(s) => serde_json::from_str(&s).map_err(storage_error)?,
            None => {
                return Err(BridgeError::new(
                    "unauthorized",
                    "Device is not authorized.",
                ));
            }
        };
        if grant.is_empty() || permissions.iter().any(|p| !grant.iter().any(|g| g == p)) {
            Err(BridgeError::new(
                "unauthorized",
                "The device lacks the required permission.",
            ))
        } else {
            Ok(())
        }
    }
    pub fn existing_operation(
        &self,
        peer: &str,
        id: &str,
        fingerprint: &str,
    ) -> Result<Option<ProcessInfo>> {
        let prior: Option<(String, String, Option<String>)> = self
            .conn()?
            .query_row(
                "SELECT fingerprint,state,result FROM operations WHERE peer=?1 AND id=?2",
                params![peer, id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()
            .map_err(storage_error)?;
        match prior {
            None => Ok(None),
            Some((old, _, _)) if old != fingerprint => Err(BridgeError::new(
                "conflict",
                "Operation ID was already used for a different request.",
            )),
            Some((_, state, result)) if state == "finished" => Ok(Some(
                serde_json::from_str(&result.ok_or_else(|| storage_error("missing result"))?)
                    .map_err(storage_error)?,
            )),
            Some(_) => Err(BridgeError::new(
                "outcome_unknown",
                "A previous attempt may have executed. Query process state; do not replay automatically.",
            )),
        }
    }
    pub fn reserve(&self, peer: &str, id: &str, fingerprint: &str) -> Result<Reservation> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        let prior: Option<(String, String, Option<String>)> = tx
            .query_row(
                "SELECT fingerprint,state,result FROM operations WHERE peer=?1 AND id=?2",
                params![peer, id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()
            .map_err(storage_error)?;
        if let Some((old, state, result)) = prior {
            if old != fingerprint {
                return Err(BridgeError::new(
                    "conflict",
                    "Operation ID was already used for a different request.",
                ));
            }
            if state == "finished" {
                return Ok(Reservation::Finished(
                    serde_json::from_str(&result.ok_or_else(|| storage_error("missing result"))?)
                        .map_err(storage_error)?,
                ));
            }
            return Err(BridgeError::new(
                "outcome_unknown",
                "A previous attempt may have executed. Query process state; do not repeat with a new operation ID.",
            ));
        }
        tx.execute("INSERT INTO operations(peer,id,fingerprint,state,created_at) VALUES(?1,?2,?3,'reserved',?4)",params![peer,id,fingerprint,now()]).map_err(storage_error)?;
        tx.commit().map_err(storage_error)?;
        Ok(Reservation::New)
    }
    pub fn finish(&self, peer: &str, id: &str, info: &ProcessInfo) -> Result<()> {
        self.conn()?
            .execute(
                "UPDATE operations SET state='finished',result=?3 WHERE peer=?1 AND id=?2",
                params![
                    peer,
                    id,
                    serde_json::to_string(info).map_err(storage_error)?
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }
    pub fn save_process(&self, info: &ProcessInfo) -> Result<()> {
        self.conn()?.execute("INSERT INTO processes(id,info) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET info=excluded.info",params![info.process_id,serde_json::to_string(info).map_err(storage_error)?]).map_err(storage_error)?;
        Ok(())
    }
    pub fn processes(&self) -> Result<Vec<ProcessInfo>> {
        self.query_processes("SELECT info FROM processes ORDER BY json_extract(info,'$.started_at') DESC, id DESC LIMIT 64")
    }
    fn recoverable_processes(&self) -> Result<Vec<ProcessInfo>> {
        self.query_processes("SELECT info FROM processes WHERE json_extract(info,'$.state') IN ('starting','running','stopping')")
    }
    fn query_processes(&self, sql: &str) -> Result<Vec<ProcessInfo>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(sql).map_err(storage_error)?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(storage_error)?;
        rows.map(|r| serde_json::from_str(&r.map_err(storage_error)?).map_err(storage_error))
            .collect()
    }
    pub fn process(&self, id: &str) -> Result<Option<ProcessInfo>> {
        let json: Option<String> = self
            .conn()?
            .query_row("SELECT info FROM processes WHERE id=?1", [id], |r| r.get(0))
            .optional()
            .map_err(storage_error)?;
        json.map(|json| serde_json::from_str(&json).map_err(storage_error))
            .transpose()
    }
    pub fn cached_agents(&self) -> Result<Option<Vec<AgentInfo>>> {
        let conn = self.conn()?;
        let mut stmt = conn
            .prepare("SELECT info,expires_at FROM discovery ORDER BY id")
            .map_err(storage_error)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            .map_err(storage_error)?;
        let mut result = Vec::new();
        for row in rows {
            let (text, expiry) = row.map_err(storage_error)?;
            if expiry <= chrono::Utc::now().timestamp() {
                return Ok(None);
            }
            result.push(serde_json::from_str(&text).map_err(storage_error)?);
        }
        Ok((!result.is_empty()).then_some(result))
    }
    pub fn cache_agents(&self, infos: &[AgentInfo]) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn.transaction().map_err(storage_error)?;
        tx.execute("DELETE FROM discovery", [])
            .map_err(storage_error)?;
        for info in infos {
            tx.execute(
                "INSERT INTO discovery(id,info,expires_at) VALUES(?1,?2,?3)",
                params![
                    info.id,
                    serde_json::to_string(info).map_err(storage_error)?,
                    chrono::Utc::now().timestamp() + 300
                ],
            )
            .map_err(storage_error)?;
        }
        tx.commit().map_err(storage_error)
    }
}

#[cfg(test)]
mod network_bind_tests {
    use super::*;

    #[test]
    fn bind_addresses_survive_store_reopen_without_changing_settings() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("host.sqlite3");
        let store = Store::open(&path).unwrap();
        assert!(store.network_bind_addrs().unwrap().is_none());
        let addresses = [
            "0.0.0.0:55555".parse().unwrap(),
            "[::]:55556".parse().unwrap(),
        ];
        store.save_network_bind_addrs(&addresses).unwrap();
        drop(store);
        let store = Store::open(&path).unwrap();
        assert_eq!(
            store.network_bind_addrs().unwrap(),
            Some(addresses.to_vec())
        );
        assert_eq!(
            store.settings().unwrap().device_name,
            AppSettings::default().device_name
        );
    }

    #[test]
    fn invalid_saved_bindings_fail_without_overwriting_them() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("host.sqlite3")).unwrap();
        for invalid in [
            "not-json",
            "[]",
            r#"["0.0.0.0:0"]"#,
            r#"["127.0.0.1:55555"]"#,
            r#"["192.0.2.1:55555"]"#,
            r#"["0.0.0.0:55555","0.0.0.0:55556"]"#,
            r#"["[::]:55555","[::]:55556"]"#,
            r#"["0.0.0.0:55555","[::]:55556","[::]:55557"]"#,
        ] {
            store
                .conn()
                .unwrap()
                .execute(
                    "INSERT OR REPLACE INTO metadata(key,value) VALUES('network_bind_addrs_v1',?1)",
                    [invalid],
                )
                .unwrap();
            assert!(store.network_bind_addrs().is_err(), "accepted {invalid}");
            let retained: String = store
                .conn()
                .unwrap()
                .query_row(
                    "SELECT value FROM metadata WHERE key='network_bind_addrs_v1'",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(retained, invalid);
        }
    }
}
