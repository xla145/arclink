mod execution;
mod managed_projection;
pub(crate) use execution::{AcceptedTurn, NewTurn, TurnOutcome};
mod migrations;
mod sync;

use crate::{
    domain::{Project, Thread},
    types::*,
};
use rusqlite::{params, Connection, OptionalExtension};
use std::{
    path::Path,
    sync::{Mutex, MutexGuard},
};

pub(crate) struct Store {
    conn: Mutex<Connection>,
}

impl Store {
    pub(crate) fn project(&self, id: &str) -> Result<Option<Project>> {
        self.conn()?
            .query_row("SELECT payload FROM projects WHERE id=?1", [id], |row| {
                row.get::<_, String>(0)
            })
            .optional()
            .map_err(storage_error)?
            .map(|payload| serde_json::from_str(&payload).map_err(storage_error))
            .transpose()
    }

    pub(crate) fn project_access(&self, project_id: &str, principal: &str) -> Result<bool> {
        self.conn()?.query_row("SELECT EXISTS(SELECT 1 FROM project_access WHERE project_id=?1 AND principal_id=?2)", params![project_id, principal], |row| row.get(0)).map_err(storage_error)
    }

    pub(crate) fn project_by_root(&self, root: &str) -> Result<Option<Project>> {
        self.conn()?
            .query_row(
                "SELECT payload FROM projects WHERE canonical_root=?1",
                [root],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(storage_error)?
            .map(|payload| serde_json::from_str(&payload).map_err(storage_error))
            .transpose()
    }

    pub(crate) fn record_existing_project(
        &self,
        principal: &str,
        command_id: &str,
        fingerprint: &str,
        project: &Project,
    ) -> Result<Project> {
        let mut conn = self.conn()?;
        let tx = conn.transaction().map_err(storage_error)?;
        if let Some(result) = command_result(&tx, principal, command_id, fingerprint)? {
            return serde_json::from_str(&result).map_err(storage_error);
        }
        tx.execute("INSERT INTO command_receipts(principal_id,command_id,fingerprint,result,created_at) VALUES(?1,?2,?3,?4,?5)", params![principal, command_id, fingerprint, serde_json::to_string(project).map_err(storage_error)?, now()]).map_err(storage_error)?;
        tx.commit().map_err(storage_error)?;
        Ok(project.clone())
    }

    pub(crate) fn grant_project_access(&self, project_id: &str, principal: &str) -> Result<()> {
        self.conn()?
            .execute(
                "INSERT OR IGNORE INTO project_access VALUES(?1,?2)",
                params![project_id, principal],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub(crate) fn command_receipt(
        &self,
        principal: &str,
        command_id: &str,
        fingerprint: &str,
    ) -> Result<Option<serde_json::Value>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction().map_err(storage_error)?;
        command_result(&tx, principal, command_id, fingerprint)?
            .map(|result| serde_json::from_str(&result).map_err(storage_error))
            .transpose()
    }

    pub(crate) fn environment_id(&self) -> Result<String> {
        self.conn()?
            .query_row(
                "SELECT value FROM metadata WHERE key='environment_id'",
                [],
                |row| row.get(0),
            )
            .map_err(storage_error)
    }

    pub(crate) fn create_project(
        &self,
        principal: &str,
        command_id: &str,
        fingerprint: &str,
        project: &Project,
    ) -> Result<Project> {
        let payload = serde_json::to_string(project).map_err(storage_error)?;
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        if let Some(result) = command_result(&tx, principal, command_id, fingerprint)? {
            return serde_json::from_str(&result).map_err(storage_error);
        }
        tx.execute(
            "INSERT INTO projects(id,canonical_root,payload) VALUES(?1,?2,?3)",
            rusqlite::params![project.id, project.canonical_root, payload],
        )
        .map_err(storage_error)?;
        tx.execute(
            "INSERT INTO project_access VALUES(?1,?2)",
            params![project.id, principal],
        )
        .map_err(storage_error)?;
        record_command_and_event(
            &tx,
            principal,
            command_id,
            fingerprint,
            "project.created",
            &project.id,
            &serde_json::to_value(project).map_err(storage_error)?,
        )?;
        tx.commit().map_err(storage_error)?;
        Ok(project.clone())
    }

    pub(crate) fn create_thread(
        &self,
        principal: &str,
        command_id: &str,
        fingerprint: &str,
        thread: &Thread,
    ) -> Result<Thread> {
        let payload = serde_json::to_string(thread).map_err(storage_error)?;
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        if let Some(result) = command_result(&tx, principal, command_id, fingerprint)? {
            return serde_json::from_str(&result).map_err(storage_error);
        }
        tx.execute("INSERT INTO threads(id,project_id,provider_id,payload,revision) VALUES(?1,?2,?3,?4,?5)", rusqlite::params![thread.id, thread.project_id, thread.provider_id, payload, thread.revision]).map_err(storage_error)?;
        record_command_and_event(
            &tx,
            principal,
            command_id,
            fingerprint,
            "thread.created",
            &thread.id,
            &serde_json::to_value(thread).map_err(storage_error)?,
        )?;
        tx.commit().map_err(storage_error)?;
        Ok(thread.clone())
    }

    pub(crate) fn projects(&self, principal: &str) -> Result<Vec<Project>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT p.payload FROM projects p JOIN project_access a ON a.project_id=p.id WHERE a.principal_id=?1 ORDER BY p.canonical_root LIMIT 101").map_err(storage_error)?;
        let rows: Result<Vec<Project>> = stmt
            .query_map([principal], |row| row.get::<_, String>(0))
            .map_err(storage_error)?
            .map(|row| serde_json::from_str(&row.map_err(storage_error)?).map_err(storage_error))
            .collect();
        bounded_catalog(rows?)
    }

    pub(crate) fn projects_local(&self) -> Result<Vec<Project>> {
        let conn = self.conn()?;
        let mut stmt = conn
            .prepare("SELECT payload FROM projects ORDER BY canonical_root LIMIT 101")
            .map_err(storage_error)?;
        let rows: Result<Vec<Project>> = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(storage_error)?
            .map(|row| serde_json::from_str(&row.map_err(storage_error)?).map_err(storage_error))
            .collect();
        bounded_catalog(rows?)
    }

    pub(crate) fn threads(&self, project_id: &str) -> Result<Vec<Thread>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT payload FROM threads WHERE project_id=?1 ORDER BY json_extract(payload,'$.updated_at') DESC, id LIMIT 101").map_err(storage_error)?;
        let rows: Result<Vec<Thread>> = stmt
            .query_map([project_id], |row| row.get::<_, String>(0))
            .map_err(storage_error)?
            .map(|row| serde_json::from_str(&row.map_err(storage_error)?).map_err(storage_error))
            .collect();
        bounded_catalog(rows?)
    }

    pub(crate) fn thread(&self, id: &str) -> Result<Option<Thread>> {
        let conn = self.conn()?;
        conn.query_row("SELECT payload FROM threads WHERE id=?1", [id], |row| {
            row.get::<_, String>(0)
        })
        .optional()
        .map_err(storage_error)?
        .map(|payload| serde_json::from_str(&payload).map_err(storage_error))
        .transpose()
    }

    pub(crate) fn check_provider_switch(
        &self,
        thread_id: &str,
        revision: Option<u64>,
    ) -> Result<()> {
        let thread = self
            .thread(thread_id)?
            .ok_or_else(|| BridgeError::new("not_found", "Thread not found."))?;
        let active: bool = self.conn()?.query_row("SELECT EXISTS(SELECT 1 FROM runs WHERE thread_id=?1 AND status IN ('queued','starting','running','waiting_approval','outcome_unknown'))", [thread_id], |r| r.get(0)).map_err(storage_error)?;
        if thread.status != "idle" || active {
            return Err(BridgeError::new(
                "thread_busy",
                "Agent selection can only change while the thread is idle.",
            ));
        }
        if revision.is_some_and(|v| v != thread.revision) {
            return Err(BridgeError::new(
                "conflict",
                "Thread revision changed; refresh before switching Agent.",
            ));
        }
        Ok(())
    }

    pub(crate) fn update_thread_provider(
        &self,
        principal: &str,
        command_id: &str,
        fingerprint: &str,
        thread_id: &str,
        provider: &str,
        model: Option<String>,
        revision: Option<u64>,
    ) -> Result<Thread> {
        if let Some(value) = self.command_receipt(principal, command_id, fingerprint)? {
            return serde_json::from_value(value).map_err(storage_error);
        }
        self.check_provider_switch(thread_id, revision)?;
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        if let Some(result) = command_result(&tx, principal, command_id, fingerprint)? {
            return serde_json::from_str(&result).map_err(storage_error);
        }
        let payload: String = tx
            .query_row(
                "SELECT payload FROM threads WHERE id=?1",
                [thread_id],
                |r| r.get(0),
            )
            .map_err(storage_error)?;
        let mut thread: Thread = serde_json::from_str(&payload).map_err(storage_error)?;
        let previous = thread.provider_id.clone();
        thread.provider_id = provider.into();
        thread.model = model.clone();
        thread.revision = thread
            .revision
            .checked_add(1)
            .filter(|v| *v <= i64::MAX as u64)
            .ok_or_else(|| storage_error("Thread revision exhausted"))?;
        thread.updated_at = now();
        tx.execute(
            "UPDATE threads SET payload=?2,revision=?3 WHERE id=?1",
            params![
                thread_id,
                serde_json::to_string(&thread).map_err(storage_error)?,
                thread.revision
            ],
        )
        .map_err(storage_error)?;
        if previous != provider {
            // A native ID is meaningful only to its original provider. A -> B -> A also starts fresh.
            tx.execute("INSERT INTO provider_sessions(id,thread_id,provider_thread_id,payload) VALUES(?1,?1,NULL,'{\"handoff_pending\":true}') ON CONFLICT(thread_id) DO UPDATE SET provider_thread_id=NULL,payload=excluded.payload", [thread_id]).map_err(storage_error)?;
            let marker = crate::domain::Message {
                id: uuid::Uuid::new_v4().to_string(),
                thread_id: thread_id.into(),
                run_id: None,
                client_message_id: None,
                role: "system".into(),
                content: serde_json::json!({"type":"provider_switch","from_provider_id":previous,"to_provider_id":provider,"model":model}),
                revision: 0,
            };
            let payload = serde_json::to_string(&marker).map_err(storage_error)?;
            tx.execute(
                "INSERT INTO messages(id,thread_id,payload,revision) VALUES(?1,?2,?3,0)",
                params![marker.id, thread_id, payload],
            )
            .map_err(storage_error)?;
            tx.execute("INSERT INTO domain_events(aggregate_id,thread_id,event_type,payload,created_at) VALUES(?1,?2,'message.created',?3,?4)",params![marker.id,thread_id,payload,now()]).map_err(storage_error)?;
        }
        record_command_and_event(
            &tx,
            principal,
            command_id,
            fingerprint,
            "thread.updated",
            thread_id,
            &serde_json::to_value(&thread).map_err(storage_error)?,
        )?;
        tx.commit().map_err(storage_error)?;
        Ok(thread)
    }

    pub(crate) fn update_thread_model(
        &self,
        principal: &str,
        command_id: &str,
        fingerprint: &str,
        thread_id: &str,
        model: Option<String>,
        expected_revision: Option<u64>,
        default_model: Option<String>,
    ) -> Result<Thread> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        if let Some(result) = command_result(&tx, principal, command_id, fingerprint)? {
            return serde_json::from_str(&result).map_err(storage_error);
        }
        let payload: String = tx
            .query_row(
                "SELECT payload FROM threads WHERE id=?1",
                [thread_id],
                |r| r.get(0),
            )
            .map_err(storage_error)?;
        let mut thread: Thread = serde_json::from_str(&payload).map_err(storage_error)?;
        let active: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM runs WHERE thread_id=?1 AND status IN ('queued','starting','running','waiting_approval','outcome_unknown'))", [thread_id], |r| r.get(0)).map_err(storage_error)?;
        if thread.status != "idle" || active {
            return Err(BridgeError::new(
                "thread_busy",
                "Model selection can only change while the thread is idle.",
            ));
        }
        if expected_revision.is_some_and(|revision| revision != thread.revision) {
            return Err(BridgeError::new(
                "conflict",
                "Thread revision changed; refresh before updating the model.",
            ));
        }
        thread.model = model;
        thread.revision = thread
            .revision
            .checked_add(1)
            .filter(|v| *v <= i64::MAX as u64)
            .ok_or_else(|| storage_error("Thread revision exhausted"))?;
        thread.updated_at = now();
        let serialized = serde_json::to_string(&thread).map_err(storage_error)?;
        tx.execute(
            "UPDATE threads SET payload=?2, revision=?3 WHERE id=?1",
            params![thread.id, serialized, thread.revision],
        )
        .map_err(storage_error)?;
        // Codex resume otherwise inherits its previous native model. Preserve
        // the host default resolved at an explicit reset, separate from the UI
        // selection (`model: null`), including across daemon restarts.
        tx.execute("INSERT INTO provider_sessions(id,thread_id,provider_thread_id,payload) VALUES(?1,?1,NULL,?2) ON CONFLICT(thread_id) DO UPDATE SET payload=json_set(provider_sessions.payload,'$.default_model',json_extract(excluded.payload,'$.default_model'))", params![thread.id, serde_json::json!({"default_model":default_model}).to_string()]).map_err(storage_error)?;
        record_command_and_event(
            &tx,
            principal,
            command_id,
            fingerprint,
            "thread.updated",
            &thread.id,
            &serde_json::to_value(&thread).map_err(storage_error)?,
        )?;
        tx.commit().map_err(storage_error)?;
        Ok(thread)
    }
}

fn bounded_catalog<T>(rows: Vec<T>) -> Result<Vec<T>> {
    if rows.len() > 100 {
        return Err(BridgeError::new(
            "resource_limit",
            "This catalog requires pagination; no partial result was returned.",
        ));
    }
    Ok(rows)
}

fn command_result(
    tx: &rusqlite::Transaction<'_>,
    principal: &str,
    command_id: &str,
    fingerprint: &str,
) -> Result<Option<String>> {
    let prior: Option<(String, String)> = tx.query_row("SELECT fingerprint,result FROM command_receipts WHERE principal_id=?1 AND command_id=?2", rusqlite::params![principal, command_id], |row| Ok((row.get(0)?, row.get(1)?))).optional().map_err(storage_error)?;
    match prior {
        None => Ok(None),
        Some((old, result)) if old == fingerprint => Ok(Some(result)),
        Some(_) => Err(BridgeError::new(
            "conflict",
            "Command ID was already used for a different request.",
        )),
    }
}

fn record_command_and_event(
    tx: &rusqlite::Transaction<'_>,
    principal: &str,
    command_id: &str,
    fingerprint: &str,
    event_type: &str,
    aggregate_id: &str,
    payload: &serde_json::Value,
) -> Result<()> {
    let result = serde_json::to_string(payload).map_err(storage_error)?;
    tx.execute("INSERT INTO command_receipts(principal_id,command_id,fingerprint,result,created_at) VALUES(?1,?2,?3,?4,?5)", rusqlite::params![principal, command_id, fingerprint, result, now()]).map_err(storage_error)?;
    tx.execute("INSERT INTO domain_events(aggregate_id,thread_id,event_type,payload,created_at) VALUES(?1,?2,?3,?4,?5)", rusqlite::params![aggregate_id, event_type.starts_with("thread.").then_some(aggregate_id), event_type, payload.to_string(), now()]).map_err(storage_error)?;
    Ok(())
}
pub(crate) enum Reservation {
    New,
    Finished(ProcessInfo),
}
impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let mut conn = Connection::open(path).map_err(storage_error)?;
        conn.busy_timeout(std::time::Duration::from_secs(2))
            .map_err(storage_error)?;
        migrations::migrate(&mut conn)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
            .map_err(storage_error)?;
        conn.execute(
            "UPDATE operations SET state='unknown' WHERE state='reserved'",
            [],
        )
        .map_err(storage_error)?;
        let store = Self {
            conn: Mutex::new(conn),
        };
        store.reconcile_effects()?;
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
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        if tx
            .execute("UPDATE devices SET revoked=1 WHERE id=?1", [peer])
            .map_err(storage_error)?
            == 0
        {
            return Err(BridgeError::new("not_found", "Device is not paired."));
        }
        tx.execute("DELETE FROM project_access WHERE principal_id=?1", [peer])
            .map_err(storage_error)?;
        tx.commit().map_err(storage_error)?;
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
mod domain_tests {
    use super::*;

    fn project() -> Project {
        Project {
            id: "project".into(),
            canonical_root: "/project".into(),
            name: "Project".into(),
            created_at: now(),
            updated_at: now(),
        }
    }

    #[test]
    fn revoke_then_regrant_does_not_restore_project_access() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("host.sqlite3")).unwrap();
        store.grant("phone", "Phone", vec!["view".into()]).unwrap();
        store
            .create_project("phone", "command", "fingerprint", &project())
            .unwrap();
        assert!(store.project_access("project", "phone").unwrap());
        store.revoke("phone").unwrap();
        assert!(!store.project_access("project", "phone").unwrap());
        store.grant("phone", "Phone", vec!["view".into()]).unwrap();
        assert!(!store.project_access("project", "phone").unwrap());
        assert!(store.projects("phone").unwrap().is_empty());
    }

    #[test]
    fn revoke_access_failure_preserves_device_authorization() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("host.sqlite3")).unwrap();
        store.grant("phone", "Phone", vec!["view".into()]).unwrap();
        store
            .create_project("phone", "command", "fingerprint", &project())
            .unwrap();
        store.conn().unwrap().execute_batch("CREATE TRIGGER fail_revoke BEFORE DELETE ON project_access BEGIN SELECT RAISE(ABORT,'test failure'); END;").unwrap();
        assert!(store.revoke("phone").is_err());
        assert!(store.authorize("phone", &["view"]).is_ok());
        assert!(store.project_access("project", "phone").unwrap());
    }

    #[test]
    fn committed_command_retries_do_not_duplicate_events_and_survive_reopen() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("host.sqlite3");
        let store = Store::open(&path).unwrap();
        let value = project();
        let created = store
            .create_project("phone", "command", "fingerprint", &value)
            .unwrap();
        assert_eq!(
            created,
            store
                .create_project(
                    "phone",
                    "command",
                    "fingerprint",
                    &Project {
                        id: "different-generated-id".into(),
                        ..value.clone()
                    }
                )
                .unwrap()
        );
        assert_eq!(
            store
                .create_project("phone", "command", "changed", &value)
                .unwrap_err()
                .code,
            "conflict"
        );
        assert_eq!(
            1,
            store
                .conn()
                .unwrap()
                .query_row::<i64, _, _>("SELECT COUNT(*) FROM domain_events", [], |row| row.get(0))
                .unwrap()
        );
        assert!(store.projects("other").unwrap().is_empty());
        assert!(store.project_access("project", "phone").unwrap());
        store.grant_project_access("project", "other").unwrap();
        assert_eq!(store.projects("other").unwrap(), vec![value.clone()]);
        let environment = store.environment_id().unwrap();
        drop(store);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.environment_id().unwrap(), environment);
        assert_eq!(
            store
                .command_receipt("phone", "command", "fingerprint")
                .unwrap(),
            Some(serde_json::to_value(value).unwrap())
        );
    }

    #[test]
    fn event_failure_rolls_back_project_and_receipt() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("host.sqlite3")).unwrap();
        store.conn().unwrap().execute_batch("CREATE TRIGGER fail_event BEFORE INSERT ON domain_events BEGIN SELECT RAISE(ABORT,'test failure'); END;").unwrap();
        assert!(store
            .create_project("phone", "command", "fp", &project())
            .is_err());
        assert!(store.projects_local().unwrap().is_empty());
        assert!(store
            .command_receipt("phone", "command", "fp")
            .unwrap()
            .is_none());
        assert!(!store.project_access("project", "phone").unwrap());
    }

    #[test]
    fn thread_creation_is_durable_and_events_have_valid_thread_reference() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("host.sqlite3");
        let store = Store::open(&path).unwrap();
        store
            .create_project("phone", "project-command", "project-fp", &project())
            .unwrap();
        let thread = Thread {
            id: "thread".into(),
            project_id: "project".into(),
            provider_id: "codex".into(),
            model: None,
            title: "Work".into(),
            cwd: "/project".into(),
            status: "idle".into(),
            revision: 0,
            created_at: now(),
            updated_at: now(),
        };
        store
            .create_thread("phone", "thread-command", "thread-fp", &thread)
            .unwrap();
        drop(store);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.thread("thread").unwrap(), Some(thread.clone()));
        assert_eq!(store.threads("project").unwrap(), vec![thread.clone()]);
        let chosen = store
            .update_thread_model(
                "phone",
                "choose",
                "choose-fp",
                "thread",
                Some("model-one".into()),
                Some(0),
                None,
            )
            .unwrap();
        assert_eq!(chosen.model.as_deref(), Some("model-one"));
        assert_eq!(chosen.revision, 1);
        // Receipt check precedes revision validation, so a timed-out model
        // selection can be checked with the same command safely.
        assert_eq!(
            store
                .update_thread_model(
                    "phone",
                    "choose",
                    "choose-fp",
                    "thread",
                    Some("model-one".into()),
                    Some(0),
                    None
                )
                .unwrap(),
            chosen
        );
        assert_eq!(
            store
                .update_thread_model("phone", "choose", "changed", "thread", None, None, None)
                .unwrap_err()
                .code,
            "conflict"
        );
        assert_eq!(
            store
                .update_thread_model("phone", "stale", "stale", "thread", None, Some(0), None)
                .unwrap_err()
                .code,
            "conflict"
        );
        let reset = store
            .update_thread_model(
                "phone",
                "reset",
                "reset",
                "thread",
                None,
                Some(1),
                Some("host-default".into()),
            )
            .unwrap();
        assert_eq!(reset.model, None);
        assert_eq!(
            store.provider_default_model("thread").unwrap().as_deref(),
            Some("host-default")
        );
        store
            .conn()
            .unwrap()
            .execute(
                "INSERT INTO runs VALUES('busy','thread','outcome_unknown','{}',0)",
                [],
            )
            .unwrap();
        assert_eq!(
            store
                .update_thread_model(
                    "phone",
                    "busy",
                    "busy",
                    "thread",
                    Some("model-two".into()),
                    None,
                    None
                )
                .unwrap_err()
                .code,
            "thread_busy"
        );
        drop(store);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.thread("thread").unwrap().unwrap().model, None);
        assert_eq!(
            store.provider_default_model("thread").unwrap().as_deref(),
            Some("host-default")
        );
        assert_eq!(
            4,
            store
                .conn()
                .unwrap()
                .query_row::<i64, _, _>("SELECT MAX(sequence) FROM domain_events", [], |row| row
                    .get(0))
                .unwrap()
        );
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
