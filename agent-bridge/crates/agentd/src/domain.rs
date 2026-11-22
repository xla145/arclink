use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Project {
    pub id: String,
    pub canonical_root: String,
    pub name: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Thread {
    pub id: String,
    pub project_id: String,
    pub provider_id: String,
    /// Optional provider selection; absent means the configured host default.
    #[serde(default)]
    pub model: Option<String>,
    pub title: String,
    pub cwd: String,
    pub status: String,
    #[serde(with = "decimal_revision")]
    pub revision: u64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Run {
    pub id: String,
    pub thread_id: String,
    pub status: String,
    #[serde(with = "decimal_revision")]
    pub revision: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Message {
    pub id: String,
    pub thread_id: String,
    pub run_id: Option<String>,
    pub client_message_id: Option<String>,
    pub role: String,
    pub content: serde_json::Value,
    #[serde(with = "decimal_revision")]
    pub revision: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Approval {
    pub id: String,
    pub run_id: String,
    pub state: String,
    pub kind: String,
    pub target: String,
    pub detail: String,
}

mod decimal_revision {
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(value: &u64, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_string())
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
        let value = String::deserialize(deserializer)?;
        let number = value.parse::<u64>().map_err(serde::de::Error::custom)?;
        if number.to_string() != value {
            return Err(serde::de::Error::custom(
                "revision must be a canonical decimal string",
            ));
        }
        Ok(number)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn revision_round_trips_above_javascript_integer_range() {
        let run = Run {
            id: "r".into(),
            thread_id: "t".into(),
            status: "completed".into(),
            revision: u64::MAX,
        };
        let json = serde_json::to_value(&run).unwrap();
        assert_eq!(json["revision"], u64::MAX.to_string());
        assert_eq!(serde_json::from_value::<Run>(json).unwrap(), run);
    }
    #[test]
    fn numeric_and_noncanonical_revisions_are_rejected() {
        for revision in [
            serde_json::json!(42),
            serde_json::json!("01"),
            serde_json::json!("-1"),
        ] {
            assert!(serde_json::from_value::<Run>(serde_json::json!({"id":"r","thread_id":"t","status":"completed","revision":revision})).is_err());
        }
    }
}
