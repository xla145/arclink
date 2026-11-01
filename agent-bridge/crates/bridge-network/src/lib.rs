//! Shared, bounded peer address hints. Credentials never implement Serialize or Debug.
mod dns;
pub use dns::dns_resolver;
use iroh::{EndpointAddr, EndpointId, RelayConfig, RelayUrl};
use serde::{Deserialize, Serialize};
use std::{fmt, net::SocketAddr, str::FromStr};

pub const DEFAULT_PRIVATE_RELAY: &str = "https://iroh.classktv.com";
pub const MAX_INVITATION_BYTES: usize = 4096;

#[derive(Debug, thiserror::Error)]
#[error("Invalid relay or address configuration.")]
pub struct InvalidNetwork;

#[derive(Clone, Default, Deserialize, Serialize, PartialEq, Eq, Debug)]
pub struct AddressHints {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay_url: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub direct_addresses: Vec<String>,
}

/// Input-only secret-bearing boundary. Only non-secret hints are serializable.
#[derive(Clone, Default, Deserialize)]
pub struct PeerNetwork {
    #[serde(flatten)]
    pub hints: AddressHints,
    #[serde(default)]
    pub relay_access_key: Option<String>,
}
impl fmt::Debug for PeerNetwork {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PeerNetwork")
            .field("hints", &self.hints)
            .field("has_access_key", &self.relay_access_key.is_some())
            .finish()
    }
}

impl PeerNetwork {
    pub fn validate(mut self) -> Result<Self, InvalidNetwork> {
        if let Some(url) = &self.hints.relay_url {
            self.hints.relay_url = Some(canonical_relay_url(url)?);
        }
        if let Some(key) = &self.relay_access_key {
            if key.is_empty() || key.len() > 256 || key.bytes().any(|b| b.is_ascii_control()) {
                return Err(InvalidNetwork);
            }
            if self.hints.relay_url.is_none() {
                return Err(InvalidNetwork);
            }
        }
        if self.hints.direct_addresses.len() > 8 {
            return Err(InvalidNetwork);
        }
        let mut addresses = Vec::new();
        for text in &self.hints.direct_addresses {
            let addr: SocketAddr = text.parse().map_err(|_| InvalidNetwork)?;
            if addr.port() == 0 || addr.ip().is_unspecified() || addr.ip().is_multicast() {
                return Err(InvalidNetwork);
            }
            let text = addr.to_string();
            if !addresses.contains(&text) {
                addresses.push(text);
            }
        }
        self.hints.direct_addresses = addresses;
        Ok(self)
    }

    pub fn from_json(input: &str) -> Result<Self, InvalidNetwork> {
        if input.len() > MAX_INVITATION_BYTES {
            return Err(InvalidNetwork);
        }
        serde_json::from_str::<Self>(input)
            .map_err(|_| InvalidNetwork)?
            .validate()
    }

    pub fn relay_config(&self) -> Option<RelayConfig> {
        let url: RelayUrl = self.hints.relay_url.as_ref()?.parse().ok()?;
        let mut config = RelayConfig::new(url, None);
        if let Some(key) = &self.relay_access_key {
            config = config.with_auth_token(key.clone());
        }
        Some(config)
    }

    pub fn peer_addr(&self, id: &str) -> Result<EndpointAddr, InvalidNetwork> {
        let id = EndpointId::from_str(id).map_err(|_| InvalidNetwork)?;
        let mut addr = EndpointAddr::new(id);
        if let Some(url) = &self.hints.relay_url {
            addr = addr.with_relay_url(url.parse().map_err(|_| InvalidNetwork)?);
        }
        for candidate in &self.hints.direct_addresses {
            addr = addr.with_ip_addr(candidate.parse().map_err(|_| InvalidNetwork)?);
        }
        Ok(addr)
    }

    /// Explicit transient invitation serialization; callers must not persist/log this value.
    pub fn invitation_value(&self) -> serde_json::Value {
        let mut value = serde_json::to_value(&self.hints).expect("address hints serialize");
        if let Some(key) = &self.relay_access_key {
            value["relay_access_key"] = serde_json::Value::String(key.clone());
        }
        value
    }
}

pub fn canonical_relay_url(text: &str) -> Result<String, InvalidNetwork> {
    if text.len() > 512 || text.trim() != text {
        return Err(InvalidNetwork);
    }
    let relay: RelayUrl = text.parse().map_err(|_| InvalidNetwork)?;
    let url: url::Url = relay.to_string().parse().map_err(|_| InvalidNetwork)?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err(InvalidNetwork);
    }
    Ok(relay.to_string())
}

/// Observe the selected route, not merely whether a relay is configured.
pub fn selected_path(connection: &iroh::endpoint::Connection) -> &'static str {
    let paths = connection.paths();
    for path in paths.iter() {
        if path.is_selected() {
            return if path.is_relay() {
                "relay"
            } else if path.is_ip() {
                "direct"
            } else {
                "unknown"
            };
        }
    }
    "unknown"
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_credential_urls_and_unbounded_inputs() {
        for url in [
            "http://example.com",
            "https://u:p@example.com",
            "https://example.com/?key=x",
            "https://example.com/#x",
            "https://example.com/path",
        ] {
            assert!(canonical_relay_url(url).is_err(), "{url}");
        }
        assert!(PeerNetwork::from_json(&"x".repeat(MAX_INVITATION_BYTES + 1)).is_err());
        assert!(PeerNetwork::from_json(r#"{"direct_addresses":["0.0.0.0:1"]}"#).is_err());
    }
    #[test]
    fn hints_serialize_without_access_key_and_debug_redacts() {
        let config = PeerNetwork::from_json(r#"{"relay_url":"https://example.com","relay_access_key":"private-test-key","direct_addresses":["127.0.0.1:1234"]}"#).unwrap();
        assert!(!format!("{config:?}").contains("private-test-key"));
        assert!(!serde_json::to_string(&config.hints)
            .unwrap()
            .contains("private-test-key"));
        assert!(config.relay_config().unwrap().quic.is_none());
        assert_eq!(
            config.invitation_value()["relay_access_key"],
            "private-test-key"
        );
    }
}
