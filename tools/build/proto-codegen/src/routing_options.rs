//! Decoding the `(google.api.routing)` method annotation, which drives the
//! `x-goog-request-params` header of the generated gRPC clients.

use std::collections::BTreeMap;

use prost::Message;

// ===========================================================================
// The prost mirror — only the descriptor fields the `routing` annotation
// rides on. Structural tags mirror `descriptor.proto`; the extension tag +
// the RoutingRule / RoutingParameter tags mirror `routing.proto`.
// ===========================================================================

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorSetMirror {
    #[prost(message, repeated, tag = "1")]
    file: Vec<FileDescriptorProtoMirror>,
}

/// The `CodeGeneratorRequest` wire shape, mirrored just enough to recover the
/// `proto_file` set (tag 15) — the descriptors carry the `MethodOptions`
/// extension prost strips on its typed decode. Lets the plugin recover
/// routing rules from the SAME stdin bytes it already read (no separate
/// `--descriptor_set_out`).
#[derive(Clone, PartialEq, Message)]
struct CodeGeneratorRequestMirror {
    // CodeGeneratorRequest.proto_file = 15.
    #[prost(message, repeated, tag = "15")]
    proto_file: Vec<FileDescriptorProtoMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    #[prost(string, optional, tag = "2")]
    package: Option<String>,
    // FileDescriptorProto.service = 6.
    #[prost(message, repeated, tag = "6")]
    service: Vec<ServiceDescriptorProtoMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct ServiceDescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    // ServiceDescriptorProto.method = 2.
    #[prost(message, repeated, tag = "2")]
    method: Vec<MethodDescriptorProtoMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct MethodDescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    // MethodDescriptorProto.options = 4.
    #[prost(message, optional, tag = "4")]
    options: Option<MethodOptionsExt>,
}

#[derive(Clone, PartialEq, Message)]
struct MethodOptionsExt {
    #[prost(message, optional, tag = "72295729")]
    routing: Option<RoutingRuleMirror>,
}

/// The `google.api.RoutingRule` mirror (`google/api/routing.proto`):
/// `repeated RoutingParameter routing_parameters = 2`.
#[derive(Clone, PartialEq, Message)]
struct RoutingRuleMirror {
    #[prost(message, repeated, tag = "2")]
    routing_parameters: Vec<RoutingParameterMirror>,
}

/// The `google.api.RoutingParameter` mirror: `string field = 1`,
/// `string path_template = 2`.
#[derive(Clone, PartialEq, Message)]
struct RoutingParameterMirror {
    #[prost(string, optional, tag = "1")]
    field: Option<String>,
    #[prost(string, optional, tag = "2")]
    path_template: Option<String>,
}

// ===========================================================================
// The public model the lowerer / emitter consume.
// ===========================================================================

/// One recovered `routing_parameter` — the (request field, path template)
/// pair. The `field` may be DOTTED (`service.name`, `bucket.project`) — a
/// path into nested message fields. An EMPTY `path_template` means the whole
/// field is the value and the key is the `field` name (the spec's fallback).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveredRoutingParameter {
    /// The request field to extract from, e.g. `name`, `parent`,
    /// `service.name`, `write_object_spec.resource.bucket`. May be dotted.
    pub field: String,
    /// The path template applied to the field's string value, e.g.
    /// `{bucket=**}`, `projects/*/locations/{location=*}`. Empty when the
    /// annotation omits it (the whole-field fallback).
    pub path_template: String,
}

/// One recovered `(google.api.routing)` rule attached to a method — the
/// ordered set of routing parameters.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveredRoutingRule {
    pub parameters: Vec<RecoveredRoutingParameter>,
}

/// The decoded routing-annotation side-table for one request, keyed by
/// `(service_name, method_name)` — the same identity the IR exposes
/// (`IrService.name`, `IrMethod.name`), so the lowerer joins its method
/// model against this overlay with no re-parse.
#[derive(Clone, Debug, Default)]
pub struct RoutingRuleTable {
    rules: BTreeMap<(String, String), RecoveredRoutingRule>,
}

impl RoutingRuleTable {
    /// Decode the `(google.api.routing)` annotations out of a
    /// `FileDescriptorSet`'s raw bytes (the `protoc --descriptor_set_out`
    /// output). Returns an empty table if the bytes carry no `routing`
    /// annotation at all.
    pub fn from_descriptor_set_bytes(bytes: &[u8]) -> Result<Self, String> {
        let fds = FileDescriptorSetMirror::decode(bytes)
            .map_err(|e| format!("routing_options: decode FileDescriptorSet: {e}"))?;
        Self::from_files(&fds.file)
    }

    /// Decode the `(google.api.routing)` annotations directly out of a
    /// `CodeGeneratorRequest`'s raw bytes (the plugin's stdin). The request
    /// embeds the same `FileDescriptorProto` set (tag 15) carrying the
    /// `MethodOptions` extension, so the plugin needs no separate
    /// `--descriptor_set_out`.
    pub fn from_request_bytes(bytes: &[u8]) -> Result<Self, String> {
        let req = CodeGeneratorRequestMirror::decode(bytes)
            .map_err(|e| format!("routing_options: decode CodeGeneratorRequest: {e}"))?;
        Self::from_files(&req.proto_file)
    }

    /// Walk the recovered file mirror, collecting one rule per annotated
    /// `(service, method)`.
    fn from_files(files: &[FileDescriptorProtoMirror]) -> Result<Self, String> {
        let mut table = RoutingRuleTable::default();
        for file in files {
            for svc in &file.service {
                let Some(svc_name) = &svc.name else { continue };
                for m in &svc.method {
                    let Some(m_name) = &m.name else { continue };
                    let Some(opts) = &m.options else { continue };
                    let Some(rule) = &opts.routing else { continue };
                    if let Some(recovered) = flatten_rule(rule) {
                        table
                            .rules
                            .insert((svc_name.clone(), m_name.clone()), recovered);
                    }
                }
            }
        }
        Ok(table)
    }

    /// The recovered rule for `(service_name, method_name)` — `Some` iff the
    /// method carries a `(google.api.routing)` annotation with at least one
    /// usable routing parameter.
    pub fn rule_for(&self, service: &str, method: &str) -> Option<&RecoveredRoutingRule> {
        self.rules.get(&(service.to_string(), method.to_string()))
    }
}

/// Flatten a wire `RoutingRuleMirror` to the public `RecoveredRoutingRule`.
/// A parameter with an empty / missing `field` is dropped (a field is
/// required to read a value). Returns `None` if NO usable parameter remains
/// (an empty rule) — the lowerer treats that as "no routing rule".
fn flatten_rule(r: &RoutingRuleMirror) -> Option<RecoveredRoutingRule> {
    let mut parameters = Vec::new();
    for p in &r.routing_parameters {
        let Some(field) = &p.field else { continue };
        if field.is_empty() {
            continue;
        }
        parameters.push(RecoveredRoutingParameter {
            field: field.clone(),
            path_template: p.path_template.clone().unwrap_or_default(),
        });
    }
    if parameters.is_empty() {
        return None;
    }
    Some(RecoveredRoutingRule { parameters })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_bytes_is_empty_table() {
        let t = RoutingRuleTable::from_descriptor_set_bytes(&[]).unwrap();
        assert!(t.rule_for("Svc", "Method").is_none());
    }

    #[test]
    fn flatten_collects_parameters_in_order() {
        let r = RoutingRuleMirror {
            routing_parameters: vec![
                RoutingParameterMirror {
                    field: Some("parent".into()),
                    path_template: Some("{project=**}".into()),
                },
                RoutingParameterMirror {
                    field: Some("bucket.project".into()),
                    path_template: Some("{project=projects/*}/**".into()),
                },
            ],
        };
        let flat = flatten_rule(&r).unwrap();
        assert_eq!(flat.parameters.len(), 2);
        assert_eq!(flat.parameters[0].field, "parent");
        assert_eq!(flat.parameters[0].path_template, "{project=**}");
        assert_eq!(flat.parameters[1].field, "bucket.project");
    }

    #[test]
    fn flatten_empty_path_template_is_whole_field_fallback() {
        let r = RoutingRuleMirror {
            routing_parameters: vec![RoutingParameterMirror {
                field: Some("source_bucket".into()),
                path_template: None,
            }],
        };
        let flat = flatten_rule(&r).unwrap();
        assert_eq!(flat.parameters[0].field, "source_bucket");
        assert_eq!(flat.parameters[0].path_template, "");
    }

    #[test]
    fn flatten_drops_empty_field_params() {
        let r = RoutingRuleMirror {
            routing_parameters: vec![
                RoutingParameterMirror {
                    field: Some("".into()),
                    path_template: Some("{x=*}".into()),
                },
                RoutingParameterMirror {
                    field: None,
                    path_template: Some("{y=*}".into()),
                },
            ],
        };
        assert!(flatten_rule(&r).is_none());
    }
}
