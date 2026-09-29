//! Mojo name resolution: reserved-word escaping, nested-type flattening and
//! collision-free naming within one generated file.

use std::collections::HashSet;

const RESERVED: &[&str] = &[
    // Mojo keywords.
    "alias", "and", "as", "async", "await", "break", "comptime", "continue",
    "def", "del", "elif", "else", "except", "False", "fieldwise_init",
    "finally", "fn", "for", "from", "global", "if", "import", "in", "is",
    "lambda", "mut", "None", "nonlocal", "not", "or", "out", "owned", "pass",
    "raise", "raises", "read", "ref", "return", "self", "struct", "trait",
    "True", "try", "var", "while", "with", "yield",
    "imm", "deinit",
    // Builtin / runtime type names the generated module relies on.
    "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16",
    "UInt32", "UInt64", "Float16", "Float32", "Float64", "String",
    "StringSlice", "List", "Dict", "Optional", "Span", "InlineArray",
    "OwnedPointer", "ArcPointer", "Self",
    "Array", "Pointer",
    // `Error` is the Mojo builtin exception type the generated REST/gRPC
    // client raises (`raise Error("... failed: HTTP ...")`). A proto message
    // literally named `Error` (e.g. `google.cloud.compute.v1.Error`, the
    // Operation.error payload) would shadow the builtin at every raise site,
    // breaking the client. Escaping it to `Error_` keeps the builtin free.
    "Error",
    "range", "len", "chr", "swap", "print", "abort",
    // The `komira_serde` runtime surface the generated code imports.
    "Serializable", "WireEncoder", "WireDecoder", "FieldKey",
    "PbEncoder", "PbDecoder", "JsonEncoder", "JsonDecoder",
];

/// Escape a single identifier component if it is a reserved word.
/// Idempotent (an already-escaped `fn_` is left alone — it is not in the
/// reserved set).
fn escape_reserved(ident: &str) -> String {
    if RESERVED.contains(&ident) {
        format!("{ident}_")
    } else {
        ident.to_string()
    }
}

/// Flatten a proto nested-type path into one Mojo struct name.
///
/// `path` is the message/enum's path components from the file scope down,
/// e.g. `["DatasetEvent"]` for a top-level type or `["Outer", "Inner"]`
/// for a nested one. Each component is reserved-word-escaped, then joined
/// with `_`. The whole joined name is escaped once more so a flattened
/// name that itself lands on a reserved word (rare, but possible) is safe.
pub fn flatten(path: &[String]) -> String {
    let joined = path
        .iter()
        .map(|c| escape_reserved(c))
        .collect::<Vec<_>>()
        .join("_");
    escape_reserved(&joined)
}

#[derive(Default)]
pub struct CollisionResolver {
    used: HashSet<String>,
}

impl CollisionResolver {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn resolve(&mut self, candidate: &str) -> String {
        if self.used.insert(candidate.to_string()) {
            return candidate.to_string();
        }
        let mut n = 2u32;
        loop {
            let suffixed = format!("{candidate}_{n}");
            if self.used.insert(suffixed.clone()) {
                return suffixed;
            }
            n += 1;
        }
    }
}

/// Escape a field / method / enum-value identifier (snake_case for fields
/// and methods, SCREAMING for enum values). Used for struct field names,
/// method names, and enum-value alias names — anywhere a proto identifier
/// becomes a Mojo identifier that is NOT a type name.
pub fn escape_member(ident: &str) -> String {
    escape_reserved(ident)
}

#[allow(dead_code)]
pub fn rpc_method_name(proto_name: &str) -> String {
    let mut out = String::with_capacity(proto_name.len() + 4);
    for (i, ch) in proto_name.chars().enumerate() {
        if ch.is_ascii_uppercase() {
            if i != 0 {
                out.push('_');
            }
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }
    escape_member(&out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flatten_joins_nested_path() {
        assert_eq!(flatten(&["Outer".into(), "Inner".into()]), "Outer_Inner");
        assert_eq!(flatten(&["Dataset".into()]), "Dataset");
    }

    #[test]
    fn reserved_words_are_escaped() {
        assert_eq!(flatten(&["fn".into()]), "fn_");
        assert_eq!(escape_member("return"), "return_");
        assert_eq!(escape_member("job_id"), "job_id");
    }

    #[test]
    fn mojo_1_1_names_are_escaped_and_so_are_their_predecessors() {
        for n in ["Array", "Pointer", "imm", "deinit"] {
            assert_eq!(flatten(&[n.into()]), format!("{n}_"), "flatten({n})");
            assert_eq!(escape_member(n), format!("{n}_"), "escape_member({n})");
        }
        for n in ["InlineArray", "read", "del", "OwnedPointer"] {
            assert_eq!(flatten(&[n.into()]), format!("{n}_"), "flatten({n})");
        }
        // and a control: a name that merely CONTAINS one of them is untouched
        assert_eq!(flatten(&["ArrayOfThings".into()]), "ArrayOfThings");
        assert_eq!(escape_member("immediate"), "immediate");
    }

    #[test]
    fn collision_resolver_suffixes_deterministically() {
        let mut r = CollisionResolver::new();
        assert_eq!(r.resolve("Foo"), "Foo");
        assert_eq!(r.resolve("Foo"), "Foo_2");
        assert_eq!(r.resolve("Foo"), "Foo_3");
        assert_eq!(r.resolve("Bar"), "Bar");
    }

    #[test]
    fn rpc_method_is_snake_cased() {
        assert_eq!(rpc_method_name("GetDataset"), "get_dataset");
        assert_eq!(rpc_method_name("WatchDatasets"), "watch_datasets");
        assert_eq!(rpc_method_name("HTTPGet"), "h_t_t_p_get");
    }
}
