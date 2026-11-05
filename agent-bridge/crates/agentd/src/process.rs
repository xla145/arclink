use crate::{store::Store, types::*};
use agent_adapters::AdapterSpec;
use std::{
    collections::{HashMap, VecDeque},
    process::Stdio,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    sync::{mpsc, oneshot, Notify},
};
use uuid::Uuid;

pub(crate) const OUTPUT_BUDGET: usize = 4 * 1024 * 1024;
pub(crate) const RECORD_LIMIT: usize = 2 * 1024 * 1024;
const INPUT_LIMIT: usize = 64 * 1024;
type Changed = Arc<dyn Fn(ProcessInfo) + Send + Sync>;
struct Chunk {
    sequence: u64,
    channel: String,
    offset: u64,
    data: Vec<u8>,
}
struct Ring {
    chunks: VecDeque<Chunk>,
    bytes: usize,
    sequence: u64,
    stdout_offset: u64,
    stderr_offset: u64,
    open_readers: u8,
}
impl Ring {
    fn push(&mut self, channel: &str, data: Vec<u8>) {
        let offset = if channel == "stdout" {
            let p = self.stdout_offset;
            self.stdout_offset += data.len() as u64;
            p
        } else {
            let p = self.stderr_offset;
            self.stderr_offset += data.len() as u64;
            p
        };
        self.sequence += 1;
        self.bytes += data.len();
        self.chunks.push_back(Chunk {
            sequence: self.sequence,
            channel: channel.into(),
            offset,
            data,
        });
        while self.bytes > OUTPUT_BUDGET {
            if let Some(old) = self.chunks.pop_front() {
                self.bytes -= old.data.len();
            }
        }
    }
}
struct WriteRequest {
    peer: String,
    lease: String,
    bytes: Vec<u8>,
    done: oneshot::Sender<Result<()>>,
}
struct Managed {
    info: Mutex<ProcessInfo>,
    ring: Mutex<Ring>,
    changed: Notify,
    writer: mpsc::Sender<WriteRequest>,
    stop: Mutex<Option<oneshot::Sender<()>>>,
    lease: Mutex<Option<String>>,
    store: Arc<Store>,
}
pub(crate) struct ProcessManager {
    entries: Mutex<HashMap<String, Arc<Managed>>>,
    store: Arc<Store>,
    changed: Changed,
    snapshot_gate: Arc<Mutex<()>>,
}
impl ProcessManager {
    pub fn new(store: Arc<Store>, snapshot_gate: Arc<Mutex<()>>, changed: Changed) -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            store,
            changed,
            snapshot_gate,
        }
    }
    pub fn list(&self) -> Vec<ProcessInfo> {
        self.entries
            .lock()
            .unwrap()
            .values()
            .map(|p| p.info.lock().unwrap().clone())
            .collect()
    }
    pub fn get(&self, id: &str, generation: &str) -> Result<ProcessInfo> {
        let managed = self.managed(id, generation)?;
        let info = managed.info.lock().unwrap().clone();
        Ok(info)
    }
    fn managed(&self, id: &str, generation: &str) -> Result<Arc<Managed>> {
        let entry = self
            .entries
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or_else(|| {
                BridgeError::new(
                    "process_gone",
                    "Process is no longer owned by this service.",
                )
            })?;
        if entry.info.lock().unwrap().generation != generation {
            return Err(BridgeError::new(
                "process_gone",
                "Process generation is stale.",
            ));
        }
        Ok(entry)
    }
    pub async fn start(&self, peer: &str, spec: &AdapterSpec, cwd: &str) -> Result<ProcessInfo> {
        if self
            .list()
            .iter()
            .filter(|p| matches!(p.state.as_str(), "starting" | "running" | "stopping"))
            .count()
            >= 8
        {
            return Err(BridgeError::new(
                "resource_limit",
                "At most 8 Agent processes may run.",
            ));
        }
        // Retain at most 64 terminal in-memory rings; durable operation results remain.
        {
            let mut entries = self.entries.lock().unwrap();
            let mut terminal: Vec<_> = entries
                .iter()
                .filter_map(|(id, p)| {
                    let info = p.info.lock().unwrap();
                    matches!(info.state.as_str(), "exited" | "failed")
                        .then_some((info.started_at.clone(), id.clone()))
                })
                .collect();
            terminal.sort();
            let remove = terminal.len().saturating_sub(63);
            for (_, id) in terminal.into_iter().take(remove) {
                entries.remove(&id);
            }
        }
        let mut child=agent_adapters::command(spec).args(&spec.args).current_dir(cwd).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|_|BridgeError::new("process_failed","Could not start the selected Agent. Check its installation and working directory."))?;
        let info = ProcessInfo {
            process_id: Uuid::new_v4().to_string(),
            generation: Uuid::new_v4().to_string(),
            agent_id: spec.id.clone(),
            owner_device_id: peer.into(),
            pid: child.id(),
            state: "running".into(),
            started_at: now(),
            exit_code: None,
        };
        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let (writer, mut input) = mpsc::channel::<WriteRequest>(8);
        let (stop, mut stopped) = oneshot::channel();
        let process = Arc::new(Managed {
            info: Mutex::new(info.clone()),
            ring: Mutex::new(Ring {
                chunks: VecDeque::new(),
                bytes: 0,
                sequence: 0,
                stdout_offset: 0,
                stderr_offset: 0,
                open_readers: 2,
            }),
            changed: Notify::new(),
            writer,
            stop: Mutex::new(Some(stop)),
            lease: Mutex::new(None),
            store: self.store.clone(),
        });
        let saved = {
            let _snapshot = self.snapshot_gate.lock().unwrap();
            self.entries
                .lock()
                .unwrap()
                .insert(info.process_id.clone(), process.clone());
            let saved = self.store.save_process(&info);
            if saved.is_ok() {
                (self.changed)(info.clone());
            }
            saved
        };
        if saved.is_err() {
            agent_adapters::terminate_group(child.id());
            let _ = child.kill().await;
            let _ = child.wait().await;
            let _snapshot = self.snapshot_gate.lock().unwrap();
            self.entries.lock().unwrap().remove(&info.process_id);
            (self.changed)(ProcessInfo {
                state: "failed".into(),
                ..info.clone()
            });
            return Err(BridgeError::new(
                "outcome_unknown",
                "Agent was spawned but metadata failed; the owned process was stopped.",
            ));
        }
        let p = process.clone();
        let writer_task = tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(request) = input.recv().await {
                if p.lease.lock().unwrap().as_deref() != Some(&request.lease) {
                    let _ = request.done.send(Err(BridgeError::new(
                        "unauthorized",
                        "The input lease is no longer active.",
                    )));
                    continue;
                }
                if let Err(error) = p.store.authorize(&request.peer, &["task", "approval"]) {
                    let _ = request.done.send(Err(error));
                    continue;
                }
                let result = match tokio::time::timeout(
                    Duration::from_secs(5),
                    stdin.write_all(&request.bytes),
                )
                .await
                {
                    Ok(Ok(())) => Ok(()),
                    _ => Err(BridgeError::new(
                        "outcome_unknown",
                        "Agent input was not fully acknowledged. Do not replay automatically.",
                    )),
                };
                let failed = result.is_err();
                let _ = request.done.send(result);
                if failed {
                    break;
                }
            }
        });
        let mut out = tokio::spawn(drain(stdout, process.clone(), "stdout"));
        let mut err = tokio::spawn(drain(stderr, process.clone(), "stderr"));
        let changed = self.changed.clone();
        let snapshot_gate = self.snapshot_gate.clone();
        tokio::spawn(async move {
            let pid = child.id();
            let result = tokio::select! {
                result=child.wait()=>result,
                _=&mut stopped=>{
                    #[cfg(unix)] if let Some(pid)=pid { unsafe{libc::kill(-(pid as i32),libc::SIGTERM);} }
                    match tokio::time::timeout(Duration::from_secs(2),child.wait()).await {Ok(result)=>result,Err(_)=>{agent_adapters::terminate_group(pid);let _=child.start_kill();child.wait().await}}
                }
            };
            // Descendants are part of our process group even after the leader exits.
            agent_adapters::terminate_group(pid);
            writer_task.abort();
            let _ = writer_task.await;
            if tokio::time::timeout(Duration::from_secs(2), &mut out)
                .await
                .is_err()
            {
                out.abort();
                let _ = out.await;
            }
            if tokio::time::timeout(Duration::from_secs(2), &mut err)
                .await
                .is_err()
            {
                err.abort();
                let _ = err.await;
            }
            let _snapshot = snapshot_gate.lock().unwrap();
            let info = {
                let mut info = process.info.lock().unwrap();
                info.state = if result.is_ok() { "exited" } else { "failed" }.into();
                info.exit_code = result.ok().and_then(|s| s.code());
                info.clone()
            };
            process.ring.lock().unwrap().open_readers = 0;
            let _ = process.store.save_process(&info);
            changed(info);
            process.changed.notify_waiters();
        });
        Ok(info)
    }
    pub async fn stop(&self, id: &str, generation: &str) -> Result<ProcessInfo> {
        let p = self.managed(id, generation)?;
        {
            let _snapshot = self.snapshot_gate.lock().unwrap();
            let mut info = p.info.lock().unwrap();
            if matches!(info.state.as_str(), "running" | "starting") {
                info.state = "stopping".into();
                (self.changed)(info.clone());
            }
        }
        if let Some(stop) = p.stop.lock().unwrap().take() {
            let _ = stop.send(());
        }
        tokio::time::timeout(Duration::from_secs(7), async {
            loop {
                let notified = p.changed.notified();
                let info = p.info.lock().unwrap().clone();
                if matches!(info.state.as_str(), "exited" | "failed") {
                    return info;
                }
                notified.await;
            }
        })
        .await
        .map_err(|_| {
            BridgeError::new(
                "outcome_unknown",
                "Process termination is still pending. Query its current state.",
            )
        })
    }
    pub fn attach(&self, peer: &str, id: &str, generation: &str) -> Result<IoSession> {
        self.attach_options(peer, id, generation, None, false)
    }
    pub fn attach_options(
        &self,
        peer: &str,
        id: &str,
        generation: &str,
        resume: Option<&abp_protocol::IoResume>,
        record_framed: bool,
    ) -> Result<IoSession> {
        self.store.authorize(peer, &["task", "approval"])?;
        let p = self.managed(id, generation)?;
        {
            let info = p.info.lock().unwrap();
            if info.owner_device_id != peer {
                return Err(BridgeError::new(
                    "unauthorized",
                    "The process belongs to another device.",
                ));
            }
            if info.state != "running"
                && !(resume.is_some() && matches!(info.state.as_str(), "exited" | "failed"))
            {
                return Err(BridgeError::new(
                    "process_gone",
                    "The process is not running.",
                ));
            }
        }
        if let Some(resume) = resume {
            if resume.previous_lease_id.is_empty() || resume.previous_lease_id.len() > 128 {
                return Err(BridgeError::new(
                    "invalid_params",
                    "A valid prior input lease is required.",
                ));
            }
            let ring = p.ring.lock().unwrap();
            if resume.stdout_offset > ring.stdout_offset
                || resume.stderr_offset > ring.stderr_offset
            {
                return Err(BridgeError::new(
                    "invalid_params",
                    "Output checkpoint is ahead of the process.",
                ));
            }
        }
        let lease = Uuid::new_v4().to_string();
        {
            let mut current = p.lease.lock().unwrap();
            if let Some(prior) = current.as_deref() {
                if resume.map(|r| r.previous_lease_id.as_str()) != Some(prior) {
                    return Err(BridgeError::new(
                        "conflict",
                        "This process already has another I/O writer.",
                    ));
                }
            }
            *current = Some(lease.clone());
        }
        p.changed.notify_waiters();
        Ok(IoSession {
            process: p,
            peer: peer.into(),
            lease,
            cursor: 1,
            resume_offsets: if record_framed || resume.is_some() {
                Some(
                    resume
                        .map(|r| (r.stdout_offset, r.stderr_offset))
                        .unwrap_or((0, 0)),
                )
            } else {
                None
            },
        })
    }
    pub fn notify_revocation(&self) {
        for p in self.entries.lock().unwrap().values() {
            let owner = p.info.lock().unwrap().owner_device_id.clone();
            if p.store.authorize(&owner, &["task", "approval"]).is_err() {
                *p.lease.lock().unwrap() = None;
            }
            p.changed.notify_waiters();
        }
    }
    pub async fn shutdown(&self) -> Result<()> {
        let list = self.list();
        let mut failure = None;
        for p in list {
            if matches!(p.state.as_str(), "running" | "starting" | "stopping") {
                if let Err(error) = self.stop(&p.process_id, &p.generation).await {
                    failure.get_or_insert(error);
                }
            }
        }
        failure.map_or(Ok(()), Err)
    }
}
async fn drain<R: AsyncRead + Unpin>(mut reader: R, p: Arc<Managed>, channel: &str) {
    let mut buffer = [0; 8192];
    loop {
        match reader.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                p.ring.lock().unwrap().push(channel, buffer[..n].to_vec());
                p.changed.notify_waiters();
            }
        }
    }
    let mut ring = p.ring.lock().unwrap();
    ring.open_readers = ring.open_readers.saturating_sub(1);
    drop(ring);
    p.changed.notify_waiters();
}

pub struct IoSession {
    process: Arc<Managed>,
    peer: String,
    lease: String,
    cursor: u64,
    resume_offsets: Option<(u64, u64)>,
}
impl IoSession {
    pub fn lease_id(&self) -> &str {
        &self.lease
    }
    fn check_lease(&self) -> Result<()> {
        if self.process.lease.lock().unwrap().as_deref() != Some(&self.lease) {
            Err(BridgeError::new(
                "unauthorized",
                "The I/O lease has been revoked.",
            ))
        } else {
            Ok(())
        }
    }
    pub async fn write(&self, bytes: Vec<u8>) -> Result<()> {
        self.write_bounded(bytes, INPUT_LIMIT).await
    }
    pub async fn write_record(&self, bytes: Vec<u8>) -> Result<()> {
        if bytes.last() != Some(&b'\n') {
            return Err(BridgeError::new(
                "invalid_params",
                "Agent record is incomplete.",
            ));
        }
        self.write_bounded(bytes, RECORD_LIMIT).await
    }
    async fn write_bounded(&self, bytes: Vec<u8>, limit: usize) -> Result<()> {
        if bytes.len() > limit {
            return Err(BridgeError::new(
                "resource_limit",
                "Agent input exceeds its bounded limit.",
            ));
        }
        self.check_lease()?;
        self.process
            .store
            .authorize(&self.peer, &["task", "approval"])?;
        if self.process.info.lock().unwrap().state != "running" {
            return Err(BridgeError::new(
                "process_gone",
                "Agent process has exited.",
            ));
        }
        let (done, wait) = oneshot::channel();
        self.process
            .writer
            .try_send(WriteRequest {
                peer: self.peer.clone(),
                lease: self.lease.clone(),
                bytes,
                done,
            })
            .map_err(|_| {
                BridgeError::new("resource_limit", "Agent input queue is full or closed.")
            })?;
        wait.await
            .map_err(|_| BridgeError::new("process_gone", "Agent input writer closed."))?
    }
    pub async fn next(&mut self) -> Result<Option<OutputFrame>> {
        loop {
            let notified = self.process.changed.notified();
            self.check_lease()?;
            self.process
                .store
                .authorize(&self.peer, &["task", "approval"])?;
            {
                let ring = self.process.ring.lock().unwrap();
                if let Some((stdout, stderr)) = self.resume_offsets.as_mut() {
                    // Report each channel independently, including a channel whose
                    // retained chunks have all been evicted by the other channel.
                    for (channel, next, end) in [
                        ("stdout", &mut *stdout, ring.stdout_offset),
                        ("stderr", &mut *stderr, ring.stderr_offset),
                    ] {
                        let oldest = ring
                            .chunks
                            .iter()
                            .find(|c| c.channel == channel)
                            .map(|c| c.offset)
                            .unwrap_or(end);
                        if *next < oldest {
                            *next = oldest;
                            return Ok(Some(OutputFrame {
                                channel: channel.into(),
                                offset: oldest.to_string(),
                                data: vec![],
                                gap: true,
                            }));
                        }
                    }
                    if let Some(chunk) = ring.chunks.iter().find(|c| {
                        c.offset + c.data.len() as u64
                            > if c.channel == "stdout" {
                                *stdout
                            } else {
                                *stderr
                            }
                    }) {
                        let next = if chunk.channel == "stdout" {
                            stdout
                        } else {
                            stderr
                        };
                        let skip = next.saturating_sub(chunk.offset) as usize;
                        let offset = chunk.offset + skip as u64;
                        let data = chunk.data[skip..].to_vec();
                        *next = offset + data.len() as u64;
                        return Ok(Some(OutputFrame {
                            channel: chunk.channel.clone(),
                            offset: offset.to_string(),
                            data,
                            gap: false,
                        }));
                    }
                } else if let Some(chunk) = ring.chunks.iter().find(|c| c.sequence >= self.cursor) {
                    let gap = chunk.sequence > self.cursor;
                    self.cursor = chunk.sequence + 1;
                    return Ok(Some(OutputFrame {
                        channel: chunk.channel.clone(),
                        offset: chunk.offset.to_string(),
                        data: chunk.data.clone(),
                        gap,
                    }));
                }
                if ring.open_readers == 0
                    && matches!(
                        self.process.info.lock().unwrap().state.as_str(),
                        "exited" | "failed"
                    )
                {
                    return Ok(None);
                }
            }
            notified.await;
        }
    }
}
impl Drop for IoSession {
    fn drop(&mut self) {
        let mut lease = self.process.lease.lock().unwrap();
        if lease.as_deref() == Some(&self.lease) {
            *lease = None;
        }
    }
}

impl Drop for ProcessManager {
    fn drop(&mut self) {
        for process in self.entries.lock().unwrap().values() {
            let info = process.info.lock().unwrap();
            if matches!(info.state.as_str(), "starting" | "running" | "stopping") {
                agent_adapters::terminate_group(info.pid);
                if let Some(stop) = process.stop.lock().unwrap().take() {
                    let _ = stop.send(());
                }
            }
        }
    }
}

#[cfg(test)]
mod resume_tests {
    use super::*;

    #[test]
    fn ring_retains_image_sized_echo_and_bounds_memory() {
        let mut ring = Ring {
            chunks: VecDeque::new(),
            bytes: 0,
            sequence: 0,
            stdout_offset: 0,
            stderr_offset: 0,
            open_readers: 2,
        };
        for _ in 0..180 {
            ring.push("stdout", vec![b'x'; 8192]);
        }
        assert_eq!(
            ring.chunks.front().unwrap().offset,
            0,
            "normal image echo must not be evicted"
        );
        for _ in 0..540 {
            ring.push("stderr", vec![b'e'; 8192]);
        }
        assert!(ring.bytes <= OUTPUT_BUDGET);
        assert!(ring.stdout_offset > 0 && ring.stderr_offset > 0);
    }
}
