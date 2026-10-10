//! The OpenAPI front-end: an OpenAPI v3 document lowered to an `IrModel`.

use std::collections::{BTreeMap, BTreeSet};

use crate::ir::*;
use crate::json::{Json, JsonObject};
use crate::mojo_names::{escape_member, flatten, CollisionResolver};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct OpenApiLowering {
    pub model: IrModel,
    pub notes: Vec<String>,
}

pub fn lower_openapi(
    doc: &Json,
    doc_path: &str,
    package_prefix: &str,
) -> Result<OpenApiLowering, String> {
    let root = doc
        .as_object()
        .ok_or("OpenAPI document root is not a JSON object")?;

    // The `openapi:` version string — accept 3.x (3.0.x / 3.1.x).
    let version = root
        .get("openapi")
        .and_then(Json::as_str)
        .ok_or("OpenAPI document has no `openapi` version field")?;
    if !version.starts_with("3.") {
        return Err(format!(
            "unsupported OpenAPI version {version:?} — the front-end targets v3.x"
        ));
    }

    let mut lowerer = OpenApiLowerer {
        schema_names: BTreeMap::new(),
        enum_schemas: BTreeSet::new(),
        notes: Vec::new(),
    };

    // --- Pass 1: register every schema name, resolve a flat Mojo name. -
    // Mirrors `lower.rs` pass 1 — a `CollisionResolver` makes the flat
    // Mojo names unique within the generated file before any reference
    // is lowered. The pass also classifies each schema as enum vs message
    // (a `type: string` + `enum` schema is an enum) so a `$ref` to it
    // resolves to the right `IrType` variant — the emitter's `encode` /
    // `decode` paths are different for `IrType::Message` vs `IrType::Enum`.
    let schemas = root
        .get("components")
        .and_then(|c| c.get("schemas"))
        .and_then(Json::as_object);
    let mut resolver = CollisionResolver::new();
    if let Some(schemas) = schemas {
        for (name, schema) in schemas {
            let mojo = resolver.resolve(&flatten(&[name.clone()]));
            lowerer.schema_names.insert(name.clone(), mojo);
            if is_enum_schema(schema) {
                lowerer.enum_schemas.insert(name.clone());
            }
        }
    }

    // --- Pass 2: lower schemas to IR messages / enums. -----------------
    let mut messages = Vec::new();
    let mut enums = Vec::new();
    if let Some(schemas) = schemas {
        for (name, schema) in schemas {
            lowerer.lower_schema(name, schema, &mut messages, &mut enums)?;
        }
    }

    // --- Pass 3: lower paths to IR services. ---------------------------
    let services = lowerer.lower_paths(root.get("paths"))?;

    let file = IrFile {
        proto_path: doc_path.to_string(),
        // OpenAPI has no proto `package`; synthesize a stable label from
        // the document `info.title` so the IR-dump is informative.
        proto_package: openapi_package_label(root),
        mojo_package: package_prefix.to_string(),
        messages,
        enums,
        services,
        imports: Vec::new(),
    };

    Ok(OpenApiLowering {
        model: IrModel { files: vec![file] },
        notes: lowerer.notes,
    })
}

/// A synthetic proto-package label derived from `info.title` — purely for
/// the IR-dump / `# proto package:` header. `openapi.<slug-of-title>`.
fn openapi_package_label(root: &JsonObject) -> String {
    let title = root
        .get("info")
        .and_then(|i| i.get("title"))
        .and_then(Json::as_str)
        .unwrap_or("api");
    let slug: String = title
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
        .collect();
    format!("openapi.{slug}")
}

/// True if a schema is a string-enum (`type: string` carrying an `enum`
/// list) — the IR-enum shape.
fn is_enum_schema(schema: &Json) -> bool {
    schema.get("type").and_then(Json::as_str) == Some("string")
        && schema.get("enum").and_then(Json::as_array).is_some()
}

struct OpenApiLowerer {
    /// OpenAPI schema name -> resolved flat Mojo struct/enum name.
    schema_names: BTreeMap<String, String>,
    /// The subset of `schema_names` that are string-enums — a `$ref` to
    /// one of these resolves to `IrType::Enum`, not `IrType::Message`.
    enum_schemas: BTreeSet<String>,
    notes: Vec<String>,
}

impl OpenApiLowerer {
    /// Lower one `components/schemas` entry — either an object (an
    /// `IrMessage`) or a string-enum (an `IrEnum`).
    fn lower_schema(
        &mut self,
        name: &str,
        schema: &Json,
        messages: &mut Vec<IrMessage>,
        enums: &mut Vec<IrEnum>,
    ) -> Result<(), String> {
        let obj = schema
            .as_object()
            .ok_or_else(|| format!("schema {name:?} is not an object"))?;
        let mojo_name = self
            .schema_names
            .get(name)
            .cloned()
            .ok_or_else(|| format!("internal: schema {name:?} not registered"))?;

        // A `type: string` schema carrying an `enum` list is an IR enum.
        if is_enum_schema(schema) {
            let values = obj
                .get("enum")
                .and_then(Json::as_array)
                .expect("is_enum_schema guarantees an `enum` array");
            enums.push(self.lower_enum(name, &mojo_name, values)?);
            return Ok(());
        }

        // Otherwise it is an object schema -> an IR message. A schema
        // with no `type` and `properties` present is treated as an
        // object (the common OpenAPI shorthand).
        let properties = obj.get("properties").and_then(Json::as_object);
        let mut fields = Vec::new();
        if let Some(properties) = properties {
            // 1-based proto field numbers in the (sorted) property order.
            for (idx, (key, prop)) in properties.iter().enumerate() {
                let field_number = (idx + 1) as u32;
                fields.push(self.lower_property(name, key, prop, field_number)?);
            }
        }

        messages.push(IrMessage {
            name: name.to_string(),
            mojo_name,
            // OpenAPI's fully-qualified name is just the schema name; the
            // `#/components/schemas/<name>` ref form is normalised away
            // by `resolve_ref`.
            fq_name: format!("#/components/schemas/{name}"),
            // OpenAPI has no synthetic map-entry messages — a map is an
            // inline `additionalProperties` object, lowered to `IrType::
            // Map` directly. No message is ever a map-entry.
            is_map_entry: false,
            fields,
            // OpenAPI 3.0 has no native discriminated union at the
            // property level; an OpenAPI-sourced message carries no
            // oneofs (each `oneOf` arm, if present, would be a separate
            // optional property — out of scope for the reference corpus).
            oneofs: Vec::new(),
        });
        Ok(())
    }

    /// Lower a string-enum schema.
    fn lower_enum(
        &self,
        name: &str,
        mojo_name: &str,
        values: &[Json],
    ) -> Result<IrEnum, String> {
        let mut ir_values = Vec::new();
        for (idx, v) in values.iter().enumerate() {
            let val = v
                .as_str()
                .ok_or_else(|| format!("enum {name:?} has a non-string value"))?;
            ir_values.push(IrEnumValue {
                name: val.to_string(),
                mojo_name: escape_member(val),
                // OpenAPI string enums have no numbers — assign 0-based,
                // in declaration order (the proto3 convention: value 0 is
                // the default / first).
                number: idx as i32,
            });
        }
        Ok(IrEnum {
            name: name.to_string(),
            mojo_name: mojo_name.to_string(),
            fq_name: format!("#/components/schemas/{name}"),
            values: ir_values,
        })
    }

    fn lower_property(
        &mut self,
        msg_name: &str,
        key: &str,
        prop: &Json,
        field_number: u32,
    ) -> Result<IrField, String> {
        let (ty, label) = self.lower_property_type(msg_name, key, prop)?;
        Ok(IrField {
            // The proto field NAME — the property key, snake_cased-as-is
            // (OpenAPI keys are already the wire identifier) and reserved-
            // word-escaped so it is a valid Mojo struct field.
            name: escape_member(&to_snake_case(key)),
            ty,
            label,
            proto_field_number: field_number,
            json_name: key.to_string(),
            // OpenAPI 3.0 properties are never oneof arms here.
            oneof_index: None,
        })
    }

    /// Resolve a property's schema to an `(IrType, Label)` pair.
    fn lower_property_type(
        &mut self,
        msg_name: &str,
        key: &str,
        prop: &Json,
    ) -> Result<(IrType, Label), String> {
        // A `$ref` — a reference to another schema (message or enum).
        if let Some(reff) = prop.get("$ref").and_then(Json::as_str) {
            let tref = self.resolve_ref(reff)?;
            // A message ref is presence-tracked -> `Label::Optional`;
            // an enum ref is a plain scalar -> `Label::Single`.
            return match tref {
                ResolvedRef::Message(r) => Ok((IrType::Message(r), Label::Optional)),
                ResolvedRef::Enum(r) => Ok((IrType::Enum(r), Label::Single)),
            };
        }

        let obj = prop
            .as_object()
            .ok_or_else(|| format!("property {msg_name}.{key} is not an object"))?;
        let openapi_type = obj.get("type").and_then(Json::as_str);

        match openapi_type {
            Some("array") => {
                // `items` is the element schema — recurse, strip its
                // label (an array element is always `Repeated`).
                let items = obj
                    .get("items")
                    .ok_or_else(|| format!("array {msg_name}.{key} has no `items`"))?;
                let (elem_ty, _) =
                    self.lower_property_type(msg_name, key, items)?;
                Ok((elem_ty, Label::Repeated))
            }
            Some("object") | None if obj.contains_key("additionalProperties") => {
                // A free-form object with `additionalProperties` is a map.
                // proto3-JSON renders every map key as a string, so the
                // key type is `String`; the value type is the
                // `additionalProperties` schema.
                let ap = obj.get("additionalProperties").unwrap();
                let value_ty = if ap.as_bool() == Some(true) {
                    // `additionalProperties: true` — an untyped map; the
                    // value lowers to `String` (the proto3-JSON-safe
                    // catch-all). Recorded as a note.
                    self.notes.push(format!(
                        "{msg_name}.{key}: untyped map (`additionalProperties: \
                         true`) lowered to map<string,string>"
                    ));
                    IrType::Scalar(ScalarKind::String)
                } else {
                    let (vt, _) = self.lower_property_type(msg_name, key, ap)?;
                    vt
                };
                Ok((
                    IrType::Map(
                        Box::new(IrType::Scalar(ScalarKind::String)),
                        Box::new(value_ty),
                    ),
                    Label::Single,
                ))
            }
            Some("object") => {
                self.notes.push(format!(
                    "{msg_name}.{key}: inline anonymous object schema lowered \
                     to a string field (no named schema to reference)"
                ));
                Ok((IrType::Scalar(ScalarKind::String), Label::Single))
            }
            Some(prim) => {
                let scalar = self.openapi_scalar(msg_name, key, prim, obj)?;
                Ok((IrType::Scalar(scalar), Label::Single))
            }
            None => {
                // No `type`, no `$ref`, no `additionalProperties` — an
                // unconstrained schema. Lower to `String` and note it.
                self.notes.push(format!(
                    "{msg_name}.{key}: schema has no `type` / `$ref` — lowered \
                     to a string field"
                ));
                Ok((IrType::Scalar(ScalarKind::String), Label::Single))
            }
        }
    }

    /// Map an OpenAPI primitive `type` (+ optional `format`) to a proto
    /// `ScalarKind`. The `format` disambiguates integer width and the
    /// 64-bit-as-string convention.
    fn openapi_scalar(
        &mut self,
        msg_name: &str,
        key: &str,
        prim: &str,
        obj: &JsonObject,
    ) -> Result<ScalarKind, String> {
        let format = obj.get("format").and_then(Json::as_str);
        let scalar = match (prim, format) {
            ("boolean", _) => ScalarKind::Bool,
            ("integer", Some("int64")) => ScalarKind::Int64,
            ("integer", Some("uint64")) => ScalarKind::Uint64,
            ("integer", _) => ScalarKind::Int32,
            ("number", Some("float")) => ScalarKind::Float,
            ("number", _) => ScalarKind::Double,
            // proto3-JSON encodes 64-bit ints as strings — an OpenAPI
            // `type: string, format: int64` is exactly that.
            ("string", Some("int64")) => ScalarKind::Int64,
            ("string", Some("uint64")) => ScalarKind::Uint64,
            ("string", Some("byte")) => ScalarKind::Bytes,
            ("string", Some(fmt @ ("date-time" | "date" | "time" | "duration"))) => {
                self.notes.push(format!(
                    "{msg_name}.{key}: OpenAPI `format: {fmt}` mapped to \
                     `string` — the well-known-type runtime module \
                     (Timestamp / Duration) is deferred to PROTO-CODEGEN-M5; \
                     an RFC-3339 string is a lossless wire representation."
                ));
                ScalarKind::String
            }
            ("string", _) => ScalarKind::String,
            (other, _) => {
                return Err(format!(
                    "{msg_name}.{key}: unsupported OpenAPI type {other:?}"
                ))
            }
        };
        Ok(scalar)
    }

    /// Resolve a `$ref` string (`#/components/schemas/<Name>`) to a
    /// `TypeRef`, classified as message or enum.
    fn resolve_ref(&self, reff: &str) -> Result<ResolvedRef, String> {
        const PREFIX: &str = "#/components/schemas/";
        let name = reff.strip_prefix(PREFIX).ok_or_else(|| {
            format!("unsupported $ref {reff:?} — only {PREFIX}<Name> is supported")
        })?;
        let mojo_name = self
            .schema_names
            .get(name)
            .cloned()
            .ok_or_else(|| format!("$ref {reff:?} resolves to no known schema"))?;
        let tref = TypeRef {
            fq_name: format!("{PREFIX}{name}"),
            mojo_name,
        };
        // Classify by the pass-1 enum set so the emitter gets the right
        // `IrType` variant — a `$ref` to a string-enum schema is an
        // `IrType::Enum` (emitted as a varint `read_i32`), a `$ref` to an
        // object schema is an `IrType::Message` (emitted as
        // `read_message[T]`).
        if self.enum_schemas.contains(name) {
            Ok(ResolvedRef::Enum(tref))
        } else {
            Ok(ResolvedRef::Message(tref))
        }
    }
}

/// A resolved `$ref` — either a message or an enum target.
enum ResolvedRef {
    Message(TypeRef),
    Enum(TypeRef),
}

impl OpenApiLowerer {
    fn lower_paths(&mut self, paths: Option<&Json>) -> Result<Vec<IrService>, String> {
        let paths = match paths.and_then(Json::as_object) {
            Some(p) if !p.is_empty() => p,
            // No paths (a pure-schema document) — no services. The
            // emitter then emits only message structs.
            _ => return Ok(Vec::new()),
        };

        let mut methods = Vec::new();
        for (path, item) in paths {
            let item = item
                .as_object()
                .ok_or_else(|| format!("path item {path:?} is not an object"))?;
            for verb in ["get", "put", "post", "delete", "patch"] {
                if let Some(op) = item.get(verb) {
                    if let Some(method) = self.lower_operation(path, verb, op)? {
                        methods.push(method);
                    }
                }
            }
        }
        if methods.is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![IrService {
            name: "OpenApiService".to_string(),
            default_host: None,
            host_from_service_config: false,
            methods,
        }])
    }

    fn lower_operation(
        &mut self,
        path: &str,
        verb: &str,
        op: &Json,
    ) -> Result<Option<IrMethod>, String> {
        let method_name = op
            .get("operationId")
            .and_then(Json::as_str)
            .map(|s| s.to_string())
            .unwrap_or_else(|| synth_method_name(verb, path));

        let input = self.operation_body_ref(op);
        let output = self.operation_response_ref(op);

        let (input, output) = match (input, output) {
            (Some(i), Some(o)) => (i, o),
            _ => {
                self.notes.push(format!(
                    "operation {verb} {path}: request body or 200 response is \
                     not a $ref to a named schema — operation skipped (the IR \
                     models a method's I/O as named-type references)."
                ));
                return Ok(None);
            }
        };

        Ok(Some(IrMethod {
            name: method_name,
            input,
            output,
            // OpenAPI REST operations are unary — no streaming dimension.
            client_streaming: false,
            server_streaming: false,
            // A `GET` is idempotent; the IR's `idempotent` flag drives
            // retry-safety, and an OpenAPI `GET` is exactly that.
            idempotent: verb == "get",
            // The OpenAPI front-end does not feed the proto-`.proto`
            // REST-codegen path (it emits the default gRPC-shaped client);
            // the `(google.api.http)` overlay is a `.proto`-only concern.
            http_rule: None,
            // OpenAPI input carries no `(google.api.routing)` annotation —
            // that is a `.proto` gRPC concern.
            routing_rule: None,
        }))
    }

    /// The request-body schema `$ref` of an operation, if it is one.
    fn operation_body_ref(&self, op: &Json) -> Option<TypeRef> {
        let schema = op
            .get("requestBody")?
            .get("content")?
            // `application/json` is the proto3-JSON content type.
            .get("application/json")?
            .get("schema")?;
        self.ref_to_typeref(schema)
    }

    /// The `200`-response schema `$ref` of an operation, if it is one.
    fn operation_response_ref(&self, op: &Json) -> Option<TypeRef> {
        let schema = op
            .get("responses")?
            .get("200")?
            .get("content")?
            .get("application/json")?
            .get("schema")?;
        self.ref_to_typeref(schema)
    }

    /// Resolve a schema node that must be a `$ref` to a `TypeRef`.
    fn ref_to_typeref(&self, schema: &Json) -> Option<TypeRef> {
        let reff = schema.get("$ref").and_then(Json::as_str)?;
        match self.resolve_ref(reff).ok()? {
            ResolvedRef::Message(r) | ResolvedRef::Enum(r) => Some(r),
        }
    }
}

/// Synthesize a method name from a verb + path when no `operationId` is
/// present — `get` `/datasets/{id}` -> `get_datasets_id`.
fn synth_method_name(verb: &str, path: &str) -> String {
    let mut parts = vec![verb.to_string()];
    for seg in path.split('/') {
        let seg = seg.trim_matches(['{', '}'].as_ref());
        if !seg.is_empty() {
            parts.push(to_snake_case(seg));
        }
    }
    escape_member(&parts.join("_"))
}

/// Convert a `camelCase` / `PascalCase` identifier to `snake_case`. An
/// OpenAPI property key is the wire identifier verbatim; the Mojo struct
/// field name is its snake_case form (matching how `lower.rs` keeps proto
/// field names — proto fields are already snake_case, so `to_snake_case`
/// of a snake_case input is the identity).
fn to_snake_case(ident: &str) -> String {
    let mut out = String::with_capacity(ident.len() + 4);
    for (i, ch) in ident.chars().enumerate() {
        if ch.is_ascii_uppercase() {
            if i != 0 {
                out.push('_');
            }
            out.push(ch.to_ascii_lowercase());
        } else if ch == '-' || ch == ' ' {
            out.push('_');
        } else {
            out.push(ch);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snake_case_handles_camel_and_snake() {
        assert_eq!(to_snake_case("jobId"), "job_id");
        assert_eq!(to_snake_case("job_id"), "job_id");
        assert_eq!(to_snake_case("HTTPStatus"), "h_t_t_p_status");
    }

    #[test]
    fn synth_method_strips_path_params() {
        assert_eq!(synth_method_name("get", "/datasets/{id}"), "get_datasets_id");
    }
}
