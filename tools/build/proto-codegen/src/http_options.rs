//! Decoding the `(google.api.http)` method annotation out of the raw
//! descriptor bytes, for the REST emitter and the OpenAPI document.

use std::collections::BTreeMap;

use prost::Message;

// ===========================================================================
// The prost mirror — only the descriptor fields the `http` annotation rides
// on. Structural tags mirror `descriptor.proto`; the extension tag + the
// HttpRule tags mirror `annotations.proto` / `http.proto`.
// ===========================================================================

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorSetMirror {
    #[prost(message, repeated, tag = "1")]
    file: Vec<FileDescriptorProtoMirror>,
}

/// The `CodeGeneratorRequest` wire shape, mirrored just enough to recover the
/// `proto_file` set (tag 15) — the descriptors carry the `MethodOptions`
/// extension prost strips on its typed decode. Lets the plugin recover http
/// rules from the SAME stdin bytes it already read (no separate
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
    #[prost(message, optional, tag = "72295728")]
    http: Option<HttpRuleMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct HttpRuleMirror {
    // The verb oneof — proto2/proto3 oneof arms decode as plain optional
    // fields off the wire, so the mirror declares them flat (exactly one is
    // present for a well-formed rule).
    #[prost(string, optional, tag = "2")]
    get: Option<String>,
    #[prost(string, optional, tag = "3")]
    put: Option<String>,
    #[prost(string, optional, tag = "4")]
    post: Option<String>,
    #[prost(string, optional, tag = "5")]
    delete: Option<String>,
    #[prost(string, optional, tag = "6")]
    patch: Option<String>,
    // HttpRule.body = 7 — the body designator ("*", "", or a field name).
    #[prost(string, optional, tag = "7")]
    body: Option<String>,
    #[prost(message, repeated, tag = "11")]
    additional_bindings: Vec<HttpRuleMirror>,
}

// ===========================================================================
// The public model the lowerer / emitter consume.
// ===========================================================================

/// The HTTP verb of a recovered `HttpRule` — the `oneof pattern` arm.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpVerb {
    Get,
    Put,
    Post,
    Delete,
    Patch,
}

impl HttpVerb {
    pub fn ir_token(self) -> &'static str {
        match self {
            HttpVerb::Get => "get",
            HttpVerb::Put => "put",
            HttpVerb::Post => "post",
            HttpVerb::Delete => "delete",
            HttpVerb::Patch => "patch",
        }
    }
}

/// One recovered `(google.api.http)` rule, flattened to the (verb, path
/// template, body designator) the REST emitter needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveredHttpRule {
    pub verb: HttpVerb,
    /// The path template, e.g. `/v1/shelves/{shelf}/books/{book}`.
    pub path_template: String,
    /// The `body` designator: `"*"` (whole request is the body), `""` (no
    /// body — all leaf fields are path/query), or a field name (that one
    /// field is the body). Empty string when the annotation omits `body`.
    pub body: String,
    /// The rule's `additional_bindings`, in declaration order: further
    /// (verb, path, body) forms of the same method, each flattened as this
    /// one is. A binding never carries bindings of its own (`http.proto`:
    /// "Nested bindings must not contain an `additional_bindings` field
    /// themselves"), so each entry's own list is empty.
    pub additional_bindings: Vec<RecoveredHttpRule>,
}

/// The decoded HTTP-annotation side-table for one request, keyed by
/// `(service_name, method_name)` — the same identity the IR exposes
/// (`IrService.name`, `IrMethod.name`), so the lowerer joins its method
/// model against this overlay with no re-parse.
#[derive(Clone, Debug, Default)]
pub struct HttpRuleTable {
    rules: BTreeMap<(String, String), RecoveredHttpRule>,
}

impl HttpRuleTable {
    /// Decode the `(google.api.http)` annotations out of a
    /// `FileDescriptorSet`'s raw bytes (the `protoc --descriptor_set_out`
    /// output). Returns an empty table if the bytes carry no `http`
    /// annotation at all.
    pub fn from_descriptor_set_bytes(bytes: &[u8]) -> Result<Self, String> {
        let fds = FileDescriptorSetMirror::decode(bytes)
            .map_err(|e| format!("http_options: decode FileDescriptorSet: {e}"))?;
        Self::from_files(&fds.file)
    }

    /// Decode the `(google.api.http)` annotations directly out of a
    /// `CodeGeneratorRequest`'s raw bytes (the plugin's stdin). The request
    /// embeds the same `FileDescriptorProto` set (tag 15) carrying the
    /// `MethodOptions` extension, so the plugin needs no separate
    /// `--descriptor_set_out`.
    pub fn from_request_bytes(bytes: &[u8]) -> Result<Self, String> {
        let req = CodeGeneratorRequestMirror::decode(bytes)
            .map_err(|e| format!("http_options: decode CodeGeneratorRequest: {e}"))?;
        Self::from_files(&req.proto_file)
    }

    /// Walk the recovered file mirror, collecting one rule per annotated
    /// `(service, method)`.
    fn from_files(files: &[FileDescriptorProtoMirror]) -> Result<Self, String> {
        let mut table = HttpRuleTable::default();
        for file in files {
            for svc in &file.service {
                let Some(svc_name) = &svc.name else { continue };
                for m in &svc.method {
                    let Some(m_name) = &m.name else { continue };
                    let Some(opts) = &m.options else { continue };
                    let Some(rule) = &opts.http else { continue };
                    if let Some(recovered) = flatten_rule(rule)? {
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
    /// method carries a `(google.api.http)` annotation with a verb.
    pub fn rule_for(&self, service: &str, method: &str) -> Option<&RecoveredHttpRule> {
        self.rules
            .get(&(service.to_string(), method.to_string()))
    }
}

fn flatten_rule(r: &HttpRuleMirror) -> Result<Option<RecoveredHttpRule>, String> {
    let mut found: Option<(HttpVerb, String)> = None;
    let mut set = |verb: HttpVerb, path: &str| -> Result<(), String> {
        if found.is_some() {
            return Err(format!(
                "http_options: HttpRule has more than one verb set (oneof pattern \
                 must have exactly one); second was `{}`",
                verb.ir_token()
            ));
        }
        found = Some((verb, path.to_string()));
        Ok(())
    };
    if let Some(p) = &r.get {
        set(HttpVerb::Get, p)?;
    }
    if let Some(p) = &r.put {
        set(HttpVerb::Put, p)?;
    }
    if let Some(p) = &r.post {
        set(HttpVerb::Post, p)?;
    }
    if let Some(p) = &r.delete {
        set(HttpVerb::Delete, p)?;
    }
    if let Some(p) = &r.patch {
        set(HttpVerb::Patch, p)?;
    }
    let Some((verb, path_template)) = found else {
        return Ok(None);
    };
    let mut additional_bindings = Vec::new();
    for (i, b) in r.additional_bindings.iter().enumerate() {
        if !b.additional_bindings.is_empty() {
            return Err(format!(
                "http_options: additional binding {i} (`{}`) carries additional_bindings \
                 of its own, which `google.api.HttpRule` forbids",
                path_template
            ));
        }
        match flatten_rule(b)? {
            Some(flat) => additional_bindings.push(flat),
            None => {
                return Err(format!(
                    "http_options: additional binding {i} of `{path_template}` names no verb"
                ))
            }
        }
    }
    Ok(Some(RecoveredHttpRule {
        verb,
        path_template,
        body: r.body.clone().unwrap_or_default(),
        additional_bindings,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_bytes_is_empty_table() {
        let t = HttpRuleTable::from_descriptor_set_bytes(&[]).unwrap();
        assert!(t.rule_for("Svc", "Method").is_none());
    }

    #[test]
    fn flatten_picks_the_single_verb_arm() {
        let r = HttpRuleMirror {
            get: Some("/v1/x/{id}".to_string()),
            body: None,
            ..Default::default()
        };
        let flat = flatten_rule(&r).unwrap().unwrap();
        assert_eq!(flat.verb, HttpVerb::Get);
        assert_eq!(flat.path_template, "/v1/x/{id}");
        assert_eq!(flat.body, "");
    }

    #[test]
    fn flatten_carries_body_designator() {
        let r = HttpRuleMirror {
            post: Some("/v1/x".to_string()),
            body: Some("*".to_string()),
            ..Default::default()
        };
        let flat = flatten_rule(&r).unwrap().unwrap();
        assert_eq!(flat.verb, HttpVerb::Post);
        assert_eq!(flat.body, "*");
    }

    #[test]
    fn flatten_two_verbs_is_an_error() {
        let r = HttpRuleMirror {
            get: Some("/a".to_string()),
            post: Some("/b".to_string()),
            ..Default::default()
        };
        assert!(flatten_rule(&r).is_err());
    }

    #[test]
    fn flatten_no_verb_is_none() {
        let r = HttpRuleMirror {
            body: Some("*".to_string()),
            ..Default::default()
        };
        assert!(flatten_rule(&r).unwrap().is_none());
    }

    #[test]
    fn flatten_carries_additional_bindings_in_order() {
        let r = HttpRuleMirror {
            get: Some("/v1/{name=roles/*}".to_string()),
            additional_bindings: vec![
                HttpRuleMirror {
                    get: Some("/v1/{name=organizations/*/roles/*}".to_string()),
                    ..Default::default()
                },
                HttpRuleMirror {
                    get: Some("/v1/{name=projects/*/roles/*}".to_string()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let flat = flatten_rule(&r).unwrap().unwrap();
        let paths: Vec<&str> = flat
            .additional_bindings
            .iter()
            .map(|b| b.path_template.as_str())
            .collect();
        assert_eq!(
            paths,
            ["/v1/{name=organizations/*/roles/*}", "/v1/{name=projects/*/roles/*}"]
        );
        assert!(flat.additional_bindings.iter().all(|b| b.additional_bindings.is_empty()));
    }

    #[test]
    fn a_nested_additional_binding_is_an_error() {
        let inner = HttpRuleMirror {
            get: Some("/v1/c".to_string()),
            ..Default::default()
        };
        let r = HttpRuleMirror {
            get: Some("/v1/a".to_string()),
            additional_bindings: vec![HttpRuleMirror {
                get: Some("/v1/b".to_string()),
                additional_bindings: vec![inner],
                ..Default::default()
            }],
            ..Default::default()
        };
        let err = flatten_rule(&r).unwrap_err();
        assert!(err.contains("carries additional_bindings"), "{err}");
    }

    #[test]
    fn an_additional_binding_with_no_verb_is_an_error() {
        let r = HttpRuleMirror {
            get: Some("/v1/a".to_string()),
            additional_bindings: vec![HttpRuleMirror::default()],
            ..Default::default()
        };
        let err = flatten_rule(&r).unwrap_err();
        assert!(err.contains("names no verb"), "{err}");
    }
}
