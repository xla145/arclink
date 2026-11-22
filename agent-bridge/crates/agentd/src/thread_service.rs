//! Managed catalog application boundary. Legacy byte-relay APIs remain independent.
use crate::{
    domain::{Project, Thread},
    types::{now, storage_error, validate_id, validate_name},
    BridgeError, Daemon, Result,
};
use serde::{Deserialize, Serialize};
use std::path::Path;
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SendThread {
    pub command_id: String,
    pub thread_id: String,
    pub client_message_id: String,
    pub text: String,
    pub expected_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InterruptThread {
    pub command_id: String,
    pub thread_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolveApproval {
    pub command_id: String,
    pub thread_id: String,
    pub approval_id: String,
    pub approved: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateProject {
    pub command_id: String,
    pub path: String,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateThread {
    pub command_id: String,
    pub project_id: String,
    pub provider_id: String,
    pub title: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetThreadModel {
    pub command_id: String,
    pub thread_id: String,
    pub model: Option<String>,
    pub expected_revision: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetThreadProvider {
    pub command_id: String,
    pub thread_id: String,
    pub provider_id: String,
    pub model: Option<String>,
    pub expected_revision: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct EnvironmentDescriptor {
    pub environment_id: String,
    pub service_instance: String,
    pub capabilities: Vec<&'static str>,
}

#[derive(Clone, Copy)]
enum Principal<'a> {
    Local,
    Remote(&'a str),
}
impl Principal<'_> {
    fn key(self) -> String {
        match self {
            Self::Local => "local-host".into(),
            Self::Remote(peer) => peer.into(),
        }
    }
}

impl Daemon {
    pub async fn set_managed_thread_provider(
        &self,
        peer: &str,
        request: SetThreadProvider,
    ) -> Result<Thread> {
        self.set_thread_provider_as(Principal::Remote(peer), request)
            .await
    }

    async fn set_thread_provider_as(
        &self,
        principal: Principal<'_>,
        request: SetThreadProvider,
    ) -> Result<Thread> {
        let _guard = self.mutation_gate.lock().await;
        self.authorize_managed_principal(principal, &["view", "session", "task"])?;
        self.ensure_catalog_writable()?;
        validate_id(&request.command_id)?;
        let thread = self.thread_for_principal(principal, &request.thread_id)?;
        let fingerprint =
            serde_json::json!({"method":"threads.provider.set","request":request}).to_string();
        let key = principal.key();
        if let Some(value) = self
            .store
            .command_receipt(&key, &request.command_id, &fingerprint)?
        {
            return serde_json::from_value(value).map_err(storage_error);
        }
        if !matches!(request.provider_id.as_str(), "codex" | "claude")
            || !matches!(thread.provider_id.as_str(), "codex" | "claude")
        {
            return Err(BridgeError::new(
                "unsupported",
                "Managed switching supports Codex and Claude.",
            ));
        }
        let revision = request
            .expected_revision
            .as_deref()
            .map(|raw| {
                raw.parse::<u64>()
                    .ok()
                    .filter(|v| v.to_string() == raw)
                    .ok_or_else(|| BridgeError::new("invalid_params", "Invalid thread revision."))
            })
            .transpose()?;
        self.store.check_provider_switch(&thread.id, revision)?;
        let spec = self
            .adapters
            .lock()
            .unwrap()
            .iter()
            .find(|s| s.id == request.provider_id)
            .cloned()
            .ok_or_else(|| BridgeError::new("agent_not_found", "Unknown Agent identifier."))?;
        let info = {
            let _probe = self.probe_gate.lock().await;
            agent_adapters::probe(&spec).await
        };
        if info.validation != "verified" {
            return Err(BridgeError::new(
                "agent_unavailable",
                "The selected provider does not have verified transport support.",
            ));
        }
        if let Some(model) = request.model.as_deref() {
            if model.is_empty() || model.len() > 256 || model.chars().any(char::is_control) {
                return Err(BridgeError::new(
                    "invalid_params",
                    "Model identifier is invalid.",
                ));
            }
            let catalog = crate::agent_models::list(
                &request.provider_id,
                &dirs::home_dir().unwrap_or_default(),
                Some(&spec),
            )
            .await;
            if !catalog.iter().any(|row| row.id == model) {
                return Err(BridgeError::new(
                    "model_unavailable",
                    "The selected model is not in this provider's current catalog.",
                ));
            }
        }
        self.authorize_managed_principal(principal, &["view", "session", "task"])?;
        self.thread_for_principal(principal, &request.thread_id)?;
        self.ensure_catalog_writable()?;
        self.retire_managed_session(&thread.id).await?;
        self.store.update_thread_provider(
            &key,
            &request.command_id,
            &fingerprint,
            &thread.id,
            &request.provider_id,
            request.model,
            revision,
        )
    }

    pub async fn set_managed_thread_model(
        &self,
        peer: &str,
        request: SetThreadModel,
    ) -> Result<Thread> {
        self.set_thread_model_as(Principal::Remote(peer), request)
            .await
    }

    async fn set_thread_model_as(
        &self,
        principal: Principal<'_>,
        request: SetThreadModel,
    ) -> Result<Thread> {
        let _guard = self.mutation_gate.lock().await;
        self.authorize_managed_principal(principal, &["view", "session", "task"])?;
        self.ensure_catalog_writable()?;
        validate_id(&request.command_id)?;
        let thread = self.thread_for_principal(principal, &request.thread_id)?;
        let fingerprint =
            serde_json::json!({"method":"threads.model.set","request":request}).to_string();
        let principal_key = principal.key();
        if let Some(result) =
            self.store
                .command_receipt(&principal_key, &request.command_id, &fingerprint)?
        {
            return serde_json::from_value(result).map_err(storage_error);
        }
        if !matches!(thread.provider_id.as_str(), "codex" | "claude") {
            return Err(BridgeError::new(
                "unsupported",
                "This provider does not support managed model selection.",
            ));
        }
        if request.model.as_ref().is_some_and(|value| {
            value.trim().is_empty() || value.len() > 256 || value.chars().any(char::is_control)
        }) {
            return Err(BridgeError::new(
                "invalid_params",
                "Model identifier is invalid.",
            ));
        }
        let revision = request
            .expected_revision
            .as_deref()
            .map(|raw| {
                let value = raw
                    .parse::<u64>()
                    .map_err(|_| BridgeError::new("invalid_params", "Invalid thread revision."))?;
                if value.to_string() != raw {
                    return Err(BridgeError::new(
                        "invalid_params",
                        "Invalid thread revision.",
                    ));
                }
                Ok(value)
            })
            .transpose()?;
        if thread.status != "idle" {
            return Err(BridgeError::new(
                "thread_busy",
                "Model selection can only change while the thread is idle.",
            ));
        }
        if let Some(model) = request.model.as_deref() {
            let spec = self
                .adapters
                .lock()
                .unwrap()
                .iter()
                .find(|s| s.id == thread.provider_id)
                .cloned();
            let catalog = crate::agent_models::list(
                &thread.provider_id,
                &dirs::home_dir().unwrap_or_default(),
                spec.as_ref(),
            )
            .await;
            if !catalog.iter().any(|row| row.id == model) {
                return Err(BridgeError::new("model_unavailable", "The selected model is not in this provider's current catalog. Refresh the model list or use the host default."));
            }
            self.authorize_managed_principal(principal, &["view", "session", "task"])?;
            self.thread_for_principal(principal, &request.thread_id)?;
            self.ensure_catalog_writable()?;
        }
        let default_model = if request.model.is_none()
            && thread.provider_id == "codex"
            && (thread.model.is_some() || self.store.provider_default_model(&thread.id)?.is_some())
        {
            let spec = self
                .adapters
                .lock()
                .unwrap()
                .iter()
                .find(|s| s.id == thread.provider_id)
                .cloned()
                .ok_or_else(|| BridgeError::new("agent_not_found", "Unknown Agent identifier."))?;
            Some(
                crate::agent_models::codex_default(&spec)
                    .await
                    .ok_or_else(|| {
                        BridgeError::new(
                            "model_unavailable",
                            "Could not resolve the host's default model. Refresh and retry.",
                        )
                    })?,
            )
        } else {
            None
        };
        self.authorize_managed_principal(principal, &["view", "session", "task"])?;
        self.thread_for_principal(principal, &request.thread_id)?;
        self.ensure_catalog_writable()?;
        self.store.update_thread_model(
            &principal_key,
            &request.command_id,
            &fingerprint,
            &request.thread_id,
            request.model,
            revision,
            default_model,
        )
    }

    fn authorize_managed_principal(
        &self,
        principal: Principal<'_>,
        permissions: &[&str],
    ) -> Result<()> {
        if let Principal::Remote(peer) = principal {
            self.authorize(peer, permissions)?;
        }
        Ok(())
    }
    fn thread_for_principal(&self, principal: Principal<'_>, id: &str) -> Result<Thread> {
        validate_id(id)?;
        let thread = self
            .store
            .thread(id)?
            .ok_or_else(|| BridgeError::new("not_found", "Thread not found."))?;
        if let Principal::Remote(peer) = principal {
            self.authorize_project(peer, &thread.project_id)?;
        }
        Ok(thread)
    }
    pub async fn send_managed_thread(
        self: &std::sync::Arc<Self>,
        peer: &str,
        request: SendThread,
    ) -> Result<crate::domain::Run> {
        self.send_thread_as(Principal::Remote(peer), request).await
    }
    async fn send_thread_as(
        self: &std::sync::Arc<Self>,
        principal: Principal<'_>,
        request: SendThread,
    ) -> Result<crate::domain::Run> {
        let _guard = self.mutation_gate.lock().await;
        self.authorize_managed_principal(principal, &["view", "session", "task"])?;
        self.ensure_catalog_writable()?;
        validate_id(&request.command_id)?;
        validate_id(&request.client_message_id)?;
        let thread = self.thread_for_principal(principal, &request.thread_id)?;
        let fingerprint =
            serde_json::json!({"method":"threads.send","request":request}).to_string();
        let peer = principal.key();
        if let Some(value) = self
            .store
            .command_receipt(&peer, &request.command_id, &fingerprint)?
        {
            let accepted: crate::store::AcceptedTurn =
                serde_json::from_value(value).map_err(storage_error)?;
            return Ok(accepted.run);
        }
        if thread.status == "attention" {
            return Err(BridgeError::new(
                "outcome_unknown",
                "The previous run needs reconciliation before sending another message.",
            ));
        }
        if thread.status == "active" {
            return Err(BridgeError::new(
                "thread_busy",
                "This thread already has an active run.",
            ));
        }
        if (request.text.trim().is_empty() && request.images.is_empty())
            || request.text.len() > crate::codex_session::MAX_INPUT_BYTES
        {
            return Err(BridgeError::new(
                "invalid_params",
                "Message text is empty or too large.",
            ));
        }
        if request.images.len() > 4 {
            return Err(BridgeError::new(
                "invalid_params",
                "At most 4 images may be attached per message.",
            ));
        }
        let mut total_image_bytes = 0usize;
        for encoded in &request.images {
            let decoded = crate::codex_session::base64_decode(encoded).ok_or_else(|| {
                BridgeError::new("invalid_params", "Attached image is not valid base64.")
            })?;
            if decoded.len() > 256 * 1024 || !decoded.starts_with(&[0xff, 0xd8]) {
                return Err(BridgeError::new(
                    "invalid_params",
                    "Attached image must be a JPEG up to 256 KB.",
                ));
            }
            total_image_bytes += decoded.len();
        }
        if total_image_bytes > 1024 * 1024 {
            return Err(BridgeError::new(
                "invalid_params",
                "Total attached image size exceeds 1 MB.",
            ));
        }
        let expected_revision = request
            .expected_revision
            .as_deref()
            .map(|v| {
                let number = v
                    .parse::<u64>()
                    .map_err(|_| BridgeError::new("invalid_params", "Invalid thread revision."))?;
                if number.to_string() != v {
                    return Err(BridgeError::new(
                        "invalid_params",
                        "Thread revision must be a canonical decimal string.",
                    ));
                }
                Ok(number)
            })
            .transpose()?;
        if expected_revision.is_some_and(|revision| revision != thread.revision) {
            return Err(BridgeError::new(
                "conflict",
                "Thread revision changed; refresh before sending.",
            ));
        }
        let content = if request.images.is_empty() {
            serde_json::json!({"text":request.text,"provider_id":thread.provider_id})
        } else {
            serde_json::json!({"text":request.text,"provider_id":thread.provider_id,"images":request.images})
        };
        let max_encoded = if request.images.is_empty() {
            crate::codex_session::MAX_INPUT_BYTES
        } else {
            crate::codex_session::MAX_INPUT_BYTES + 2 * 1024 * 1024
        };
        if serde_json::to_vec(&content).map_err(storage_error)?.len() > max_encoded {
            return Err(BridgeError::new(
                "invalid_params",
                "Encoded message content is too large.",
            ));
        }
        if !matches!(thread.provider_id.as_str(), "codex" | "claude") {
            return Err(BridgeError::new(
                "unsupported",
                "Managed execution supports Codex and Claude.",
            ));
        }
        if !Path::new(&thread.cwd).is_absolute() || !Path::new(&thread.cwd).is_dir() {
            return Err(BridgeError::new(
                "invalid_cwd",
                "Project directory is unavailable.",
            ));
        }
        let spec = self
            .adapters
            .lock()
            .unwrap()
            .iter()
            .find(|s| s.id == thread.provider_id)
            .cloned()
            .ok_or_else(|| BridgeError::new("agent_not_found", "Unknown Agent identifier."))?;
        let info = {
            let _probe = self.probe_gate.lock().await;
            agent_adapters::probe(&spec).await
        };
        if info.validation != "verified" {
            return Err(BridgeError::new(
                "agent_unavailable",
                "The selected provider does not have verified transport support.",
            ));
        }
        self.authorize_managed_principal(principal, &["view", "session", "task"])?;
        self.ensure_catalog_writable()?;
        self.ensure_managed_session(&thread).await?;
        let accepted = self.store.reserve_turn(
            &peer,
            &request.command_id,
            &fingerprint,
            &crate::store::NewTurn {
                thread_id: thread.id.clone(),
                client_message_id: request.client_message_id.clone(),
                content,
                expected_revision,
            },
        )?;
        if let Err(error) = self.dispatch_managed_turn(&accepted) {
            let _ = self.store.fail_turn(&accepted.effect_id);
            return Err(error);
        }
        Ok(accepted.run)
    }
    pub async fn interrupt_managed_thread(
        self: &std::sync::Arc<Self>,
        peer: &str,
        request: InterruptThread,
    ) -> Result<()> {
        self.interrupt_thread_as(Principal::Remote(peer), request)
            .await
    }
    async fn interrupt_thread_as(
        self: &std::sync::Arc<Self>,
        principal: Principal<'_>,
        request: InterruptThread,
    ) -> Result<()> {
        let _guard = self.mutation_gate.lock().await;
        self.authorize_managed_principal(principal, &["view", "session", "task"])?;
        self.ensure_catalog_writable()?;
        validate_id(&request.command_id)?;
        self.thread_for_principal(principal, &request.thread_id)?;
        let peer = principal.key();
        let fingerprint =
            serde_json::json!({"method":"threads.interrupt","request":request}).to_string();
        if !self.store.claim_control(
            &peer,
            &request.command_id,
            &fingerprint,
            &request.thread_id,
            None,
        )? {
            return self.control_result(&peer, &request.command_id, &fingerprint);
        }
        let result = self.interrupt_managed_session(&request.thread_id).await;
        self.finish_control_result(&peer, &request.command_id, &result)?;
        result
    }
    pub async fn resolve_managed_approval(
        self: &std::sync::Arc<Self>,
        peer: &str,
        request: ResolveApproval,
    ) -> Result<()> {
        self.approval_as(Principal::Remote(peer), request).await
    }
    async fn approval_as(
        self: &std::sync::Arc<Self>,
        principal: Principal<'_>,
        request: ResolveApproval,
    ) -> Result<()> {
        let _guard = self.mutation_gate.lock().await;
        self.authorize_managed_principal(principal, &["view", "approval"])?;
        self.ensure_catalog_writable()?;
        validate_id(&request.command_id)?;
        if request.approval_id.is_empty() || request.approval_id.len() > 1024 {
            return Err(BridgeError::new("invalid_params", "Invalid approval ID."));
        }
        self.thread_for_principal(principal, &request.thread_id)?;
        let peer = principal.key();
        let fingerprint =
            serde_json::json!({"method":"threads.approval","request":request}).to_string();
        if self
            .store
            .command_receipt(&peer, &request.command_id, &fingerprint)?
            .is_some()
        {
            return self.control_result(&peer, &request.command_id, &fingerprint);
        }
        let native_id = self
            .store
            .pending_approval(&request.thread_id, &request.approval_id)?;
        if !self.store.claim_control(
            &peer,
            &request.command_id,
            &fingerprint,
            &request.thread_id,
            Some(&request.approval_id),
        )? {
            return self.control_result(&peer, &request.command_id, &fingerprint);
        }
        let result = self
            .approve_managed_session(&request.thread_id, native_id, request.approved)
            .await;
        self.finish_control_result(&peer, &request.command_id, &result)?;
        result
    }
    fn finish_control_result(
        &self,
        peer: &str,
        command_id: &str,
        result: &Result<()>,
    ) -> Result<()> {
        let value = match result {
            Ok(()) => serde_json::json!({"ok":true}),
            Err(error) => serde_json::json!({"code":error.code,"message":error.message}),
        };
        self.store.finish_control(peer, command_id, value)
    }
    fn control_result(&self, peer: &str, command_id: &str, fingerprint: &str) -> Result<()> {
        let value = self
            .store
            .command_receipt(peer, command_id, fingerprint)?
            .ok_or_else(|| BridgeError::new("outcome_unknown", "Command result is unavailable."))?;
        if value.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
            Ok(())
        } else {
            Err(BridgeError::new(
                value
                    .get("code")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("outcome_unknown"),
                value
                    .get("message")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("Command delivery is uncertain."),
            ))
        }
    }
    /// Trusted local catalog, not callable through a remote principal selector.
    pub fn local_managed_projects(&self) -> Result<Vec<Project>> {
        self.store.projects_local()
    }
    /// Service-owned execution and bounded replay/wait capabilities.
    pub fn describe_environment(&self, peer: &str) -> Result<EnvironmentDescriptor> {
        self.authorize(peer, &["view"])?;
        Ok(EnvironmentDescriptor {
            environment_id: self.store.environment_id()?,
            service_instance: self.hub.instance.clone(),
            capabilities: vec![
                "managed_catalog_v1",
                "thread_sync_reads_v1",
                "managed_execution_v1",
                "managed_claude_v1",
                "managed_models_v1",
                "managed_provider_switch_v1",
                "thread_events_v1",
                "history_pages_v1",
                "approval_api_v1",
            ],
        })
    }

    pub async fn create_managed_project(
        &self,
        peer: &str,
        request: CreateProject,
    ) -> Result<Project> {
        self.create_project_as(Principal::Remote(peer), request)
            .await
    }
    async fn create_project_as(
        &self,
        principal: Principal<'_>,
        request: CreateProject,
    ) -> Result<Project> {
        let peer = principal.key();
        let peer = peer.as_str();
        let _guard = self.mutation_gate.lock().await;
        self.authorize_managed_principal(principal, &["view", "session"])?;
        self.ensure_catalog_writable()?;
        validate_id(&request.command_id)?;
        validate_name(&request.name)?;
        let fingerprint =
            serde_json::json!({"method":"projects.create", "request":request}).to_string();
        // A committed retry must succeed even if the directory has since disappeared.
        if let Some(value) = self
            .store
            .command_receipt(peer, &request.command_id, &fingerprint)?
        {
            let project: Project = serde_json::from_value(value).map_err(storage_error)?;
            if let Principal::Remote(peer) = principal {
                self.authorize_project(peer, &project.id)?;
            }
            return Ok(project);
        }
        if !Path::new(&request.path).is_absolute() {
            return Err(BridgeError::new(
                "invalid_cwd",
                "Project path must be absolute.",
            ));
        }
        let root = Path::new(&request.path)
            .canonicalize()
            .map_err(|_| BridgeError::new("invalid_cwd", "Project directory is unavailable."))?;
        if !root.is_dir() {
            return Err(BridgeError::new(
                "invalid_cwd",
                "Project path must be a directory.",
            ));
        }
        let canonical_root = root
            .to_str()
            .filter(|p| p.len() <= 4096)
            .ok_or_else(|| BridgeError::new("invalid_cwd", "Project path is not supported."))?
            .to_owned();
        // Project registration is keyed by canonical path. A new iOS task may
        // select a project that was already registered by an earlier task;
        // reuse that identity instead of surfacing SQLite's UNIQUE error as an
        // outcome_unknown result. A changed name remains an explicit conflict.
        if let Some(existing) = self.store.project_by_root(&canonical_root)? {
            if existing.name != request.name {
                return Err(BridgeError::new(
                    "conflict",
                    "This project path is already registered with another name.",
                ));
            }
            if let Principal::Remote(peer) = principal {
                // The caller already passed `view` + `session` device authorization above;
                // allow paired devices with session permission to attach to an existing project root.
                self.store.grant_project_access(&existing.id, peer)?;
            }
            return self.store.record_existing_project(
                peer,
                &request.command_id,
                &fingerprint,
                &existing,
            );
        }
        let timestamp = now();
        self.store.create_project(
            peer,
            &request.command_id,
            &fingerprint,
            &Project {
                id: Uuid::new_v4().to_string(),
                canonical_root,
                name: request.name,
                created_at: timestamp.clone(),
                updated_at: timestamp,
            },
        )
    }

    pub fn managed_projects(&self, peer: &str) -> Result<Vec<Project>> {
        self.authorize(peer, &["view"])?;
        self.store.projects(peer)
    }

    pub async fn create_managed_thread(&self, peer: &str, request: CreateThread) -> Result<Thread> {
        self.create_thread_as(Principal::Remote(peer), request)
            .await
    }
    async fn create_thread_as(
        &self,
        principal: Principal<'_>,
        request: CreateThread,
    ) -> Result<Thread> {
        let peer = principal.key();
        let peer = peer.as_str();
        let _guard = self.mutation_gate.lock().await;
        self.authorize_managed_principal(principal, &["view", "session"])?;
        self.ensure_catalog_writable()?;
        validate_id(&request.command_id)?;
        validate_id(&request.project_id)?;
        validate_name(&request.title)?;
        if let Principal::Remote(peer) = principal {
            self.authorize_project(peer, &request.project_id)?;
        }
        let fingerprint =
            serde_json::json!({"method":"threads.create", "request":request}).to_string();
        if let Some(value) = self
            .store
            .command_receipt(peer, &request.command_id, &fingerprint)?
        {
            return serde_json::from_value(value).map_err(storage_error);
        }
        // Register only known providers. Registration is not proof of executable capability.
        if !self
            .adapters
            .lock()
            .unwrap()
            .iter()
            .any(|a| a.id == request.provider_id)
        {
            return Err(BridgeError::new(
                "agent_not_found",
                "Unknown Agent identifier.",
            ));
        }
        let project = self
            .store
            .project(&request.project_id)?
            .ok_or_else(|| BridgeError::new("not_found", "Project not found."))?;
        let timestamp = now();
        self.store.create_thread(
            peer,
            &request.command_id,
            &fingerprint,
            &Thread {
                id: Uuid::new_v4().to_string(),
                project_id: project.id,
                provider_id: request.provider_id,
                model: None,
                title: request.title,
                cwd: project.canonical_root,
                status: "idle".into(),
                revision: 1,
                created_at: timestamp.clone(),
                updated_at: timestamp,
            },
        )
    }

    pub fn managed_threads(&self, peer: &str, project_id: &str) -> Result<Vec<Thread>> {
        self.authorize(peer, &["view"])?;
        validate_id(project_id)?;
        self.authorize_project(peer, project_id)?;
        self.store.threads(project_id)
    }

    pub fn managed_thread(&self, peer: &str, thread_id: &str) -> Result<Thread> {
        self.authorize(peer, &["view"])?;
        validate_id(thread_id)?;
        let thread = self
            .store
            .thread(thread_id)?
            .ok_or_else(|| BridgeError::new("not_found", "Thread not found."))?;
        self.authorize_project(peer, &thread.project_id)?;
        Ok(thread)
    }

    pub fn managed_thread_snapshot(
        &self,
        peer: &str,
        thread_id: &str,
    ) -> Result<crate::sync::ThreadSnapshot> {
        self.managed_thread(peer, thread_id)?;
        self.store.thread_snapshot(thread_id)
    }

    pub fn replay_managed_thread(
        &self,
        peer: &str,
        environment_id: &str,
        thread_id: &str,
        after_sequence: &str,
    ) -> Result<crate::sync::ThreadReplay> {
        self.managed_thread(peer, thread_id)?;
        self.store
            .replay_thread(environment_id, thread_id, after_sequence)
    }

    /// Trusted local administration only; deliberately absent from the remote RPC router.
    pub async fn grant_managed_project(&self, project_id: &str, device_id: &str) -> Result<()> {
        let _guard = self.mutation_gate.lock().await;
        self.ensure_catalog_writable()?;
        validate_id(project_id)?;
        self.authorize(device_id, &["view"])?;
        if self.store.project(project_id)?.is_none() {
            return Err(BridgeError::new("not_found", "Project not found."));
        }
        self.store.grant_project_access(project_id, device_id)
    }

    fn authorize_project(&self, peer: &str, project_id: &str) -> Result<()> {
        if !self.store.project_access(project_id, peer)? {
            return Err(BridgeError::new(
                "unauthorized",
                "This device has no access to the project.",
            ));
        }
        Ok(())
    }

    fn ensure_catalog_writable(&self) -> Result<()> {
        if self.stopping.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(BridgeError::new(
                "unavailable",
                "The host is shutting down.",
            ));
        }
        Ok(())
    }
}

impl Daemon {
    /// Trusted desktop entry point; remote RPCs never call this method.
    pub async fn local_thread_command(
        self: &std::sync::Arc<Self>,
        method: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value> {
        fn field<'a>(body: &'a serde_json::Value, name: &str) -> Result<&'a str> {
            body.get(name).and_then(|v| v.as_str()).ok_or_else(|| {
                BridgeError::new(
                    "invalid_params",
                    "Required managed command parameter is missing.",
                )
            })
        }
        let invalid = |_| BridgeError::new("invalid_params", "Invalid managed command parameters.");
        Ok(match method {
            "environment.describe" => {
                serde_json::json!({"environment_id":self.store.environment_id()?,"service_instance":self.hub.instance,"capabilities":["managed_catalog_v1","thread_sync_reads_v1","managed_execution_v1","managed_claude_v1","managed_models_v1","managed_provider_switch_v1","thread_events_v1","history_pages_v1","approval_api_v1"]})
            }
            "projects.list" => {
                serde_json::to_value(self.local_managed_projects()?).map_err(storage_error)?
            }
            "projects.create" => serde_json::to_value(
                self.create_project_as(
                    Principal::Local,
                    serde_json::from_value(body).map_err(invalid)?,
                )
                .await?,
            )
            .map_err(storage_error)?,
            "threads.list" => {
                serde_json::to_value(self.store.threads(field(&body, "project_id")?)?)
                    .map_err(storage_error)?
            }
            "threads.create" => serde_json::to_value(
                self.create_thread_as(
                    Principal::Local,
                    serde_json::from_value(body).map_err(invalid)?,
                )
                .await?,
            )
            .map_err(storage_error)?,
            "threads.get" => serde_json::to_value(
                self.thread_for_principal(Principal::Local, field(&body, "thread_id")?)?,
            )
            .map_err(storage_error)?,
            "threads.provider.set" => serde_json::to_value(
                self.set_thread_provider_as(
                    Principal::Local,
                    serde_json::from_value(body).map_err(invalid)?,
                )
                .await?,
            )
            .map_err(storage_error)?,
            "threads.model.set" => serde_json::to_value(
                self.set_thread_model_as(
                    Principal::Local,
                    serde_json::from_value(body).map_err(invalid)?,
                )
                .await?,
            )
            .map_err(storage_error)?,
            "threads.snapshot" => {
                serde_json::to_value(self.store.thread_snapshot(field(&body, "thread_id")?)?)
                    .map_err(storage_error)?
            }
            "threads.replay" => serde_json::to_value(self.store.replay_thread(
                field(&body, "environment_id")?,
                field(&body, "thread_id")?,
                field(&body, "after_sequence")?,
            )?)
            .map_err(storage_error)?,
            "threads.wait" => serde_json::to_value(
                self.wait_local_managed_thread(
                    field(&body, "environment_id")?,
                    field(&body, "thread_id")?,
                    field(&body, "after_sequence")?,
                )
                .await?,
            )
            .map_err(storage_error)?,
            "threads.history" => serde_json::to_value(self.store.thread_history(
                field(&body, "thread_id")?,
                body.get("before_id").and_then(|v| v.as_str()),
            )?)
            .map_err(storage_error)?,
            "threads.send" => serde_json::to_value(
                self.send_thread_as(
                    Principal::Local,
                    serde_json::from_value(body).map_err(invalid)?,
                )
                .await?,
            )
            .map_err(storage_error)?,
            "threads.interrupt" => {
                self.interrupt_thread_as(
                    Principal::Local,
                    serde_json::from_value(body).map_err(invalid)?,
                )
                .await?;
                serde_json::json!({"ok":true})
            }
            "threads.approval" => {
                self.approval_as(
                    Principal::Local,
                    serde_json::from_value(body).map_err(invalid)?,
                )
                .await?;
                serde_json::json!({"ok":true})
            }
            "projects.share" => {
                self.grant_managed_project(
                    field(&body, "project_id")?,
                    field(&body, "principal_id")?,
                )
                .await?;
                serde_json::json!({"ok":true})
            }
            _ => return Err(BridgeError::new("unsupported", "Unknown managed method.")),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(path: &Path) -> std::sync::Arc<Daemon> {
        let daemon = Daemon::open_with_adapters(
            path,
            vec![agent_adapters::AdapterSpec {
                id: "fixture".into(),
                name: "Fixture".into(),
                program: "/not-launched".into(),
                args: vec![],
                verified_version: None,
            }],
        )
        .unwrap();
        for peer in ["phone", "tablet"] {
            daemon
                .store
                .grant(peer, peer, vec!["view".into(), "session".into()])
                .unwrap();
        }
        daemon
    }

    #[tokio::test]
    async fn new_task_reuses_registered_project_without_widening_access() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("project");
        std::fs::create_dir(&root).unwrap();
        let daemon = host(&dir.path().join("host"));
        let request = CreateProject {
            command_id: "first".into(),
            path: root.to_str().unwrap().into(),
            name: "Project".into(),
        };
        let project = daemon
            .create_managed_project("phone", request.clone())
            .await
            .unwrap();
        let second = CreateProject {
            command_id: "second".into(),
            ..request.clone()
        };
        assert_eq!(
            daemon
                .create_managed_project("phone", second.clone())
                .await
                .unwrap(),
            project
        );
        assert_eq!(daemon.managed_projects("phone").unwrap().len(), 1);
        assert_eq!(
            daemon
                .create_managed_project(
                    "tablet",
                    CreateProject {
                        command_id: "tablet".into(),
                        ..request
                    }
                )
                .await
                .unwrap(),
            project
        );
        std::fs::remove_dir(root).unwrap();
        assert_eq!(
            daemon
                .create_managed_project("phone", second.clone())
                .await
                .unwrap(),
            project
        );
        assert_eq!(
            daemon
                .create_managed_project(
                    "phone",
                    CreateProject {
                        name: "Changed".into(),
                        ..second
                    }
                )
                .await
                .unwrap_err()
                .code,
            "conflict"
        );
    }

    #[tokio::test]
    async fn project_access_is_explicit_and_creation_retry_survives_missing_directory() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("project");
        std::fs::create_dir(&root).unwrap();
        let daemon = host(&dir.path().join("host"));
        let request = CreateProject {
            command_id: "create".into(),
            path: root.to_str().unwrap().into(),
            name: "Project".into(),
        };
        let project = daemon
            .create_managed_project("phone", request.clone())
            .await
            .unwrap();
        assert!(daemon.managed_projects("tablet").unwrap().is_empty());
        let create = CreateThread {
            command_id: "thread".into(),
            project_id: project.id.clone(),
            provider_id: "fixture".into(),
            title: "First".into(),
        };
        assert_eq!(
            daemon
                .create_managed_thread("tablet", create.clone())
                .await
                .unwrap_err()
                .code,
            "unauthorized"
        );
        let thread = daemon
            .create_managed_thread("phone", create.clone())
            .await
            .unwrap();
        assert_eq!(
            daemon.create_managed_thread("phone", create).await.unwrap(),
            thread
        );
        assert_eq!(
            daemon
                .managed_thread("tablet", &thread.id)
                .unwrap_err()
                .code,
            "unauthorized"
        );
        daemon
            .grant_managed_project(&project.id, "tablet")
            .await
            .unwrap();
        assert_eq!(daemon.managed_thread("tablet", &thread.id).unwrap(), thread);
        std::fs::remove_dir(root).unwrap();
        assert_eq!(
            daemon
                .create_managed_project("phone", request.clone())
                .await
                .unwrap(),
            project
        );
        let changed = CreateProject {
            name: "Changed".into(),
            ..request
        };
        assert_eq!(
            daemon
                .create_managed_project("phone", changed)
                .await
                .unwrap_err()
                .code,
            "conflict"
        );
        daemon.revoke_device("tablet").await.unwrap();
        assert_eq!(
            daemon
                .managed_thread("tablet", &thread.id)
                .unwrap_err()
                .code,
            "unauthorized"
        );
        assert!(
            daemon.list_processes().await.is_empty(),
            "catalog registration must not spawn a provider"
        );
    }

    #[tokio::test]
    async fn identity_and_thread_survive_restart_without_widening_legacy_capabilities() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("host");
        let daemon = host(&data);
        let identity = daemon.describe_environment("phone").unwrap().environment_id;
        let project = daemon
            .create_managed_project(
                "phone",
                CreateProject {
                    command_id: "p".into(),
                    path: dir.path().to_str().unwrap().into(),
                    name: "Project".into(),
                },
            )
            .await
            .unwrap();
        let thread = daemon
            .create_managed_thread(
                "phone",
                CreateThread {
                    command_id: "t".into(),
                    project_id: project.id,
                    provider_id: "fixture".into(),
                    title: "Thread".into(),
                },
            )
            .await
            .unwrap();
        drop(daemon);
        let daemon = host(&data);
        assert_eq!(
            daemon.describe_environment("phone").unwrap().environment_id,
            identity
        );
        assert_eq!(daemon.managed_thread("phone", &thread.id).unwrap(), thread);
        assert_eq!(
            daemon.describe_environment("phone").unwrap().capabilities,
            [
                "managed_catalog_v1",
                "thread_sync_reads_v1",
                "managed_execution_v1",
                "managed_claude_v1",
                "managed_models_v1",
                "managed_provider_switch_v1",
                "thread_events_v1",
                "history_pages_v1",
                "approval_api_v1"
            ]
        );
    }
}

#[cfg(all(test, unix))]
mod execution_tests {
    use super::*;
    use serde_json::json;
    use std::os::unix::fs::PermissionsExt;
    use tokio::time::{timeout, Duration};

    fn fixture(dir: &Path) -> agent_adapters::AdapterSpec {
        let program = dir.join("fake-codex");
        std::fs::write(&program, r#"#!/bin/sh
if [ "$1" = "--version" ]; then printf 'fixture 1\n'; exit 0; fi
while IFS= read -r line; do
 case "$line" in
  *'"method":"initialize"'*)
   case "$line" in
    *'arclink-1'*) printf '%s\n' '{"id":"arclink-1","result":{}}' ;;
    *) printf '%s\n' '{"id":1,"result":{}}' ;;
   esac ;;
  *'"method":"thread/start"'*|*'"method":"thread/resume"'*) printf '%s\n' '{"id":"arclink-2","result":{"thread":{"id":"native-thread"}}}' ;;
  *'"method":"turn/start"'*)
   turn=$((${turn:-0} + 1))
   req=$((turn + 2))
   printf '%s\n' 'turn' >> turns.txt
   if [ "$turn" -gt 1 ]; then printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"native-thread","turnId":"native-turn-1","itemId":"late","delta":"MUST NOT APPEAR"}}'; fi
   printf '{"id":"arclink-%s","result":{"turn":{"id":"native-turn-%s"}}}\n' "$req" "$turn"
   sleep 0.05
   printf '{"method":"item/agentMessage/delta","params":{"threadId":"native-thread","turnId":"native-turn-%s","itemId":"answer","delta":"hello"}}\n' "$turn"
   printf '{"method":"turn/completed","params":{"threadId":"native-thread","turn":{"id":"native-turn-%s","status":"completed"}}}\n' "$turn" ;;
 esac
done
"#).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        agent_adapters::AdapterSpec {
            id: "codex".into(),
            name: "Fake Codex".into(),
            program,
            args: vec![],
            verified_version: None,
        }
    }

    #[tokio::test]
    async fn invalid_send_does_not_start_or_persist_a_provider_session() {
        let dir = tempfile::tempdir().unwrap();
        let daemon =
            Daemon::open_with_adapters(dir.path().join("host"), vec![fixture(dir.path())]).unwrap();
        let project = daemon.local_thread_command("projects.create", json!({"command_id":"project","path":dir.path().to_str().unwrap(),"name":"Project"})).await.unwrap();
        let thread = daemon.local_thread_command("threads.create", json!({"command_id":"thread","project_id":project["id"],"provider_id":"codex","title":"Chat"})).await.unwrap();
        let thread_id = thread["id"].as_str().unwrap();
        for (command_id, text, expected_revision, expected_code) in [
            ("stale", "hello".into(), Some("0".into()), "conflict"),
            ("empty", " \n ".into(), None, "invalid_params"),
            (
                "escaped",
                format!("x{}", "\n".repeat(128 * 1024)),
                None,
                "invalid_params",
            ),
        ] {
            let result = daemon
                .send_thread_as(
                    Principal::Local,
                    SendThread {
                        command_id: command_id.into(),
                        thread_id: thread_id.into(),
                        client_message_id: command_id.into(),
                        text,
                        expected_revision,
                        images: vec![],
                    },
                )
                .await;
            assert_eq!(result.unwrap_err().code, expected_code);
            assert!(
                daemon.processes.list().is_empty(),
                "validation must precede process start"
            );
            assert!(daemon
                .store
                .provider_thread_id(thread_id)
                .unwrap()
                .is_none());
            assert!(daemon
                .store
                .thread_snapshot(thread_id)
                .unwrap()
                .messages
                .is_empty());
        }
        daemon.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn remote_send_is_durable_shared_and_idempotent_without_device_ownership() {
        let dir = tempfile::tempdir().unwrap();
        let daemon =
            Daemon::open_with_adapters(dir.path().join("host"), vec![fixture(dir.path())]).unwrap();
        for peer in ["phone", "tablet"] {
            daemon
                .store
                .grant(
                    peer,
                    peer,
                    vec![
                        "view".into(),
                        "session".into(),
                        "task".into(),
                        "approval".into(),
                    ],
                )
                .unwrap();
        }
        let project = daemon.local_thread_command("projects.create", json!({"command_id":"project","path":dir.path().to_str().unwrap(),"name":"Project"})).await.unwrap();
        let project_id = project["id"].as_str().unwrap();
        daemon
            .grant_managed_project(project_id, "phone")
            .await
            .unwrap();
        daemon
            .grant_managed_project(project_id, "tablet")
            .await
            .unwrap();
        let thread = daemon.local_thread_command("threads.create", json!({"command_id":"thread","project_id":project_id,"provider_id":"codex","title":"Chat"})).await.unwrap();
        let thread_id = thread["id"].as_str().unwrap();
        let request = SendThread {
            command_id: "send".into(),
            thread_id: thread_id.into(),
            client_message_id: "user-message".into(),
            text: "Hello".into(),
            expected_revision: None,
            images: vec![],
        };
        let run = daemon
            .send_managed_thread("phone", request.clone())
            .await
            .unwrap();
        assert_eq!(
            run,
            daemon
                .send_managed_thread("phone", request.clone())
                .await
                .unwrap()
        );
        let snapshot = timeout(Duration::from_secs(3), async {
            loop {
                let snapshot = daemon.managed_thread_snapshot("tablet", thread_id).unwrap();
                if snapshot.thread.status == "idle" && snapshot.messages.len() == 2 {
                    break snapshot;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(snapshot.messages[0].role, "user");
        assert_eq!(snapshot.messages[1].content["text"], "hello");
        assert_eq!(
            std::fs::read_to_string(dir.path().join("turns.txt")).unwrap(),
            "turn\n"
        );
        assert_eq!(
            daemon
                .store
                .provider_thread_id(thread_id)
                .unwrap()
                .as_deref(),
            Some("native-thread")
        );
        let changed = SendThread {
            text: "Changed".into(),
            ..request
        };
        assert_eq!(
            daemon
                .send_managed_thread("phone", changed)
                .await
                .unwrap_err()
                .code,
            "conflict"
        );
        daemon
            .send_managed_thread(
                "tablet",
                SendThread {
                    command_id: "second".into(),
                    thread_id: thread_id.into(),
                    client_message_id: "second-message".into(),
                    text: "Again".into(),
                    expected_revision: None,
                    images: vec![],
                },
            )
            .await
            .unwrap();
        let snapshot = timeout(Duration::from_secs(3), async {
            loop {
                let snapshot = daemon.managed_thread_snapshot("tablet", thread_id).unwrap();
                if snapshot.thread.status == "idle" && snapshot.messages.len() >= 4 {
                    break snapshot;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(
            snapshot.messages.len(),
            4,
            "late old-turn events must not enter the new run"
        );
        assert!(!serde_json::to_string(&snapshot.messages)
            .unwrap()
            .contains("MUST NOT APPEAR"));
        daemon.shutdown().await.unwrap();
        drop(daemon);
        let daemon =
            Daemon::open_with_adapters(dir.path().join("host"), vec![fixture(dir.path())]).unwrap();
        assert_eq!(
            daemon
                .managed_thread_snapshot("tablet", thread_id)
                .unwrap()
                .messages,
            snapshot.messages
        );
        daemon.shutdown().await.unwrap();
    }
}
