//! One network endpoint per phone identity, shared by pairing and all Macs.
use crate::load_or_create_key;
use iroh::{endpoint::presets, Endpoint};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, Weak},
};
use tokio::sync::OnceCell;

pub(crate) struct SharedEndpoint {
    key_path: PathBuf,
    endpoint: OnceCell<Endpoint>,
}

impl SharedEndpoint {
    pub(crate) fn for_key(path: &str) -> Arc<Self> {
        static OWNERS: OnceLock<Mutex<HashMap<PathBuf, Weak<SharedEndpoint>>>> = OnceLock::new();
        let path = Path::new(path);
        // Swift passes an absolute application-support path. Canonicalize its
        // parent when possible so equivalent existing directory aliases share.
        let key_path = path
            .parent()
            .and_then(|p| p.canonicalize().ok())
            .and_then(|p| path.file_name().map(|n| p.join(n)))
            .unwrap_or_else(|| {
                if path.is_absolute() {
                    path.to_owned()
                } else {
                    std::env::current_dir().unwrap_or_default().join(path)
                }
            });
        let mut owners = OWNERS
            .get_or_init(Default::default)
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        owners.retain(|_, owner| owner.strong_count() > 0);
        if let Some(owner) = owners.get(&key_path).and_then(Weak::upgrade) {
            return owner;
        }
        let owner = Arc::new(Self {
            key_path: key_path.clone(),
            endpoint: OnceCell::new(),
        });
        owners.insert(key_path, Arc::downgrade(&owner));
        owner
    }

    pub(crate) async fn get(&self) -> Result<Endpoint, (&'static str, String)> {
        self.endpoint
            .get_or_try_init(|| async {
                let secret =
                    load_or_create_key(&self.key_path).map_err(|e| ("identity_error", e))?;
                Endpoint::builder(presets::N0)
                    .secret_key(secret)
                    .alpns(vec![abp_protocol::ALPN.to_vec()])
                    .bind()
                    .await
                    .map_err(|_| {
                        (
                            "network_error",
                            "Could not start the phone endpoint.".into(),
                        )
                    })
            })
            .await
            .cloned()
    }
}
