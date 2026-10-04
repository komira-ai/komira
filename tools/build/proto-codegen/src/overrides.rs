//! The hand-override manifest: how hand-written code replaces a generated
//! operation so that regenerating never overwrites it.

use std::collections::BTreeMap;

use crate::aws_in::AwsLowering;
use crate::json::{parse, Json};

/// One hand-written override of a generated operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AwsOverride {
    pub operation: String,
    /// The Mojo module that owns the plain verb name.
    pub hand_module: String,
    /// The symbol in that module — a function or a method.
    pub hand_symbol: String,
    pub reason: String,
}

/// The parsed overrides manifest for one service.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AwsOverrides {
    service: String,
    by_operation: BTreeMap<String, AwsOverride>,
}

const MIN_REASON_LEN: usize = 40;

impl AwsOverrides {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.by_operation.is_empty()
    }

    pub fn len(&self) -> usize {
        self.by_operation.len()
    }

    pub fn get(&self, operation: &str) -> Option<&AwsOverride> {
        self.by_operation.get(operation)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &AwsOverride)> {
        self.by_operation.iter()
    }

    pub fn service(&self) -> &str {
        &self.service
    }

    pub fn parse_manifest(text: &str) -> Result<Self, String> {
        let doc = parse(text).map_err(|e| format!("overrides: not JSON: {e}"))?;
        let obj = doc
            .as_object()
            .ok_or_else(|| "overrides: the manifest must be a JSON object".to_string())?;
        let service = obj
            .get("service")
            .and_then(Json::as_str)
            .ok_or_else(|| {
                "overrides: the manifest must carry a `service` string — an override \
                 file that does not say which service it is for can be pointed at the \
                 wrong one and every entry silently becomes an unknown operation."
                    .to_string()
            })?
            .to_string();
        let mut by_operation = BTreeMap::new();
        let list = match obj.get("overrides") {
            None => return Ok(AwsOverrides { service, by_operation }),
            Some(v) => v
                .as_array()
                .ok_or_else(|| "overrides: `overrides` must be an array".to_string())?,
        };
        for (i, entry) in list.iter().enumerate() {
            let e = entry
                .as_object()
                .ok_or_else(|| format!("overrides: entry {i} is not an object"))?;
            let field = |k: &str| -> Result<String, String> {
                e.get(k)
                    .and_then(Json::as_str)
                    .map(str::to_string)
                    .ok_or_else(|| format!("overrides: entry {i} has no `{k}` string"))
            };
            let operation = field("operation")?;
            let hand_module = field("hand_module")?;
            let hand_symbol = field("hand_symbol")?;
            let reason = field("reason")?;
            if reason.trim().len() < MIN_REASON_LEN {
                return Err(format!(
                    "overrides: `{operation}` has a {}-character reason, and the floor is \
                     {MIN_REASON_LEN}. The reason is the ONLY part of an override a future \
                     reader cannot re-derive — the operation name, the module and the symbol \
                     are all visible in the code, and the AWS behaviour that forced the \
                     override is visible NOWHERE. State what the service does that the model \
                     does not say.",
                    reason.trim().len()
                ));
            }
            if by_operation.contains_key(&operation) {
                return Err(format!(
                    "overrides: `{operation}` is declared twice. Two overrides of one \
                     operation cannot both own the plain verb name."
                ));
            }
            by_operation.insert(
                operation.clone(),
                AwsOverride {
                    operation,
                    hand_module,
                    hand_symbol,
                    reason,
                },
            );
        }
        Ok(AwsOverrides { service, by_operation })
    }

    pub fn check_against(&self, lowering: &AwsLowering) -> Result<(), String> {
        if !self.is_empty() && self.service != lowering.service.service {
            return Err(format!(
                "overrides: this manifest is for service `{}` but was applied to `{}`. \
                 Every entry would name an unknown operation and every plain verb would \
                 be generated un-overridden.",
                self.service, lowering.service.service
            ));
        }
        for op in self.by_operation.keys() {
            if lowering.facts.operation(op).is_err() {
                let known: Vec<&str> = lowering
                    .facts
                    .operations()
                    .map(|(n, _)| n.as_str())
                    .collect();
                return Err(format!(
                    "overrides: `{op}` is not an operation this client generates. The \
                     generated operations are: {}. An override that matches nothing does \
                     not fail closed — it silently emits the UN-OVERRIDDEN verb under the \
                     plain name, which is the case the seam exists to prevent.",
                    known.join(", ")
                ));
            }
        }
        Ok(())
    }

    pub fn check_symbols(&self, sources: &[(String, String)]) -> Result<(), String> {
        for (op, ov) in &self.by_operation {
            let module_tail = ov
                .hand_module
                .rsplit('.')
                .next()
                .unwrap_or(&ov.hand_module);
            let found = sources.iter().find(|(path, _)| {
                let stem = std::path::Path::new(path)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("");
                stem == module_tail
            });
            let (path, text) = match found {
                Some(p) => p,
                None => {
                    return Err(format!(
                        "overrides: `{op}` names owner module `{}`, and no source file \
                         `{module_tail}.mojo` is declared in this target's `hand_srcs`. The \
                         generated client emits only `{}_raw`, so nothing supplies the plain \
                         verb — the build must fail HERE, naming the manifest, rather than at \
                         every call site with a cause three files away.",
                        ov.hand_module,
                        snake(&ov.operation)
                    ))
                }
            };
            // A parametric owner (`def f[C: Connector, ...](`), as one taking
            // the generated client is, opens its parameter list with `[`.
            let def_fn = format!("def {}(", ov.hand_symbol);
            let def_param_fn = format!("def {}[", ov.hand_symbol);
            let def_struct = format!("struct {}", ov.hand_symbol);
            if !text.contains(&def_fn)
                && !text.contains(&def_param_fn)
                && !text.contains(&def_struct)
            {
                return Err(format!(
                    "overrides: `{op}` names owner symbol `{}` in `{path}`, and that file \
                     defines none of `{def_fn}…`, `{def_param_fn}…` and `{def_struct}`. An \
                     override whose owner does not exist is a claim the build believed and \
                     nothing checked.",
                    ov.hand_symbol
                ));
            }
        }
        Ok(())
    }
}

fn snake(s: &str) -> String {
    crate::aws_in::snake_case(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    const REASON: &str = "DeleteSecret is a SOFT delete: the secret enters a 7-30 day \
                          recovery window during which its NAME stays taken.";

    fn manifest(body: &str) -> String {
        format!(
            r#"{{"service":"secretsmanager","overrides":[{body}]}}"#
        )
    }

    #[test]
    fn parses_a_well_formed_manifest() {
        let m = AwsOverrides::parse_manifest(&manifest(&format!(
            r#"{{"operation":"DeleteSecret","hand_module":"komira_aws_secretsmanager_ext.sm_overrides",
                 "hand_symbol":"delete_secret","reason":"{REASON}"}}"#
        )))
        .expect("parses");
        assert_eq!(m.len(), 1);
        assert_eq!(m.get("DeleteSecret").unwrap().hand_symbol, "delete_secret");
        assert!(m.get("CreateSecret").is_none());
    }

    #[test]
    fn refuses_a_thin_reason() {
        let err = AwsOverrides::parse_manifest(&manifest(
            r#"{"operation":"DeleteSecret","hand_module":"m","hand_symbol":"s","reason":"custom"}"#,
        ))
        .unwrap_err();
        assert!(err.contains("reason"), "{err}");
    }

    #[test]
    fn refuses_a_duplicate_operation() {
        let one = format!(
            r#"{{"operation":"DeleteSecret","hand_module":"m","hand_symbol":"s","reason":"{REASON}"}}"#
        );
        let err = AwsOverrides::parse_manifest(&manifest(&format!("{one},{one}"))).unwrap_err();
        assert!(err.contains("twice"), "{err}");
    }

    #[test]
    fn refuses_a_manifest_with_no_service() {
        let err = AwsOverrides::parse_manifest(r#"{"overrides":[]}"#).unwrap_err();
        assert!(err.contains("service"), "{err}");
    }

    #[test]
    fn check_symbols_refuses_a_missing_owner_module() {
        let m = AwsOverrides::parse_manifest(&manifest(&format!(
            r#"{{"operation":"DeleteSecret","hand_module":"komira_aws_secretsmanager_ext.sm_overrides",
                 "hand_symbol":"delete_secret","reason":"{REASON}"}}"#
        )))
        .unwrap();
        let err = m.check_symbols(&[]).unwrap_err();
        assert!(err.contains("sm_overrides"), "{err}");
    }

    #[test]
    fn check_symbols_refuses_a_missing_owner_symbol() {
        let m = AwsOverrides::parse_manifest(&manifest(&format!(
            r#"{{"operation":"DeleteSecret","hand_module":"komira_aws_secretsmanager_ext.sm_overrides",
                 "hand_symbol":"delete_secret","reason":"{REASON}"}}"#
        )))
        .unwrap();
        let err = m
            .check_symbols(&[(
                "src/komira_aws_secretsmanager_ext/sm_overrides.mojo".into(),
                "def something_else(x: Int):\n    pass\n".into(),
            )])
            .unwrap_err();
        assert!(err.contains("delete_secret"), "{err}");
    }

    #[test]
    fn check_symbols_accepts_a_present_owner() {
        let m = AwsOverrides::parse_manifest(&manifest(&format!(
            r#"{{"operation":"DeleteSecret","hand_module":"komira_aws_secretsmanager_ext.sm_overrides",
                 "hand_symbol":"delete_secret","reason":"{REASON}"}}"#
        )))
        .unwrap();
        m.check_symbols(&[(
            "src/komira_aws_secretsmanager_ext/sm_overrides.mojo".into(),
            "def delete_secret(mut c: X) raises -> Y:\n    pass\n".into(),
        )])
        .expect("accepts");
    }

    #[test]
    fn check_symbols_accepts_a_parametric_owner() {
        let m = AwsOverrides::parse_manifest(&manifest(&format!(
            r#"{{"operation":"DeleteSecret","hand_module":"komira_aws_secretsmanager_ext.sm_overrides",
                 "hand_symbol":"delete_secret","reason":"{REASON}"}}"#
        )))
        .unwrap();
        let sm = "src/komira_aws_secretsmanager_ext/sm_overrides.mojo";
        m.check_symbols(&[(
            sm.into(),
            "def delete_secret[C: Connector](mut c: X[C]) raises -> Y:\n    pass\n".into(),
        )])
        .expect("accepts");
        // A longer name sharing the prefix is not the owner.
        let err = m
            .check_symbols(&[(
                sm.into(),
                "def delete_secret_raw[C: Connector](mut c: X[C]):\n    pass\n".into(),
            )])
            .unwrap_err();
        assert!(err.contains("delete_secret"), "{err}");
    }
}
