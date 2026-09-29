//! Parsing `(google.api.http)` path templates, and partitioning a request's
//! fields into path, query and body for one HTTP rule.

/// One segment of a parsed path template.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PathSegment {
    /// A literal path segment, e.g. `v1` or `shelves`.
    Literal(String),
    /// A `{var}` capture — the named scalar request field substituted here.
    Var(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PathTemplate {
    pub segments: Vec<PathSegment>,
    /// The `{var}` names, in template order — the path-field set.
    pub vars: Vec<String>,
}

impl PathTemplate {
    pub fn parse(template: &str) -> Result<Self, String> {
        if !template.starts_with('/') {
            return Err(format!(
                "path template {template:?} must be absolute (start with `/`)"
            ));
        }
        let mut segments = Vec::new();
        let mut vars = Vec::new();
        // `split('/')` on a leading-slash string yields a leading empty
        // component; skip it. A trailing slash similarly yields a trailing
        // empty component — also skipped (no empty literal segments).
        for raw in template.split('/') {
            if raw.is_empty() {
                continue;
            }
            if let Some(inner) = raw.strip_prefix('{').and_then(|s| s.strip_suffix('}')) {
                // A `{var}` capture. Reject the richer `{var=...}` form and
                // any non-identifier var name.
                if inner.contains('=') {
                    return Err(format!(
                        "path template {template:?}: nested capture `{{{inner}}}` is \
                         unsupported (Phase 1 handles only simple `{{var}}`)"
                    ));
                }
                if !is_simple_ident(inner) {
                    return Err(format!(
                        "path template {template:?}: `{{{inner}}}` is not a simple \
                         field identifier"
                    ));
                }
                vars.push(inner.to_string());
                segments.push(PathSegment::Var(inner.to_string()));
            } else {
                if raw.contains(['{', '}', '*', ':']) {
                    return Err(format!(
                        "path template {template:?}: literal segment {raw:?} carries \
                         an unsupported template metacharacter (Phase 1 handles only \
                         literals and simple `{{var}}`)"
                    ));
                }
                segments.push(PathSegment::Literal(raw.to_string()));
            }
        }
        Ok(PathTemplate { segments, vars })
    }
}

fn is_simple_ident(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

pub fn percent_encode_simple(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        if is_unreserved(b) {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(hex_upper(b >> 4));
            out.push(hex_upper(b & 0x0F));
        }
    }
    out
}

fn is_unreserved(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~')
}

fn hex_upper(nibble: u8) -> char {
    match nibble {
        0..=9 => (b'0' + nibble) as char,
        10..=15 => (b'A' + (nibble - 10)) as char,
        _ => unreachable!("nibble is 4 bits"),
    }
}

/// How a request's leaf fields partition for one HTTP rule. Field NAMES
/// only — the emitter joins these against the IR to find each field's type.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldPartition {
    /// `{var}` names, in template order → URL path substitution.
    pub path_fields: Vec<String>,
    /// The body designator. `Whole` = the entire request message is the JSON
    /// body (`body: "*"`); `None` = no body (`body: ""`); `Field(name)` = a
    /// single named field is the body.
    pub body: BodyDesignator,
    /// Every remaining leaf field → URL query params, in declaration order.
    pub query_fields: Vec<String>,
}

/// The body designator of an HTTP rule.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BodyDesignator {
    /// `body: "*"` — the whole request message serializes to the JSON body.
    Whole,
    /// `body: ""` — no request body; every non-path field is a query param.
    None,
    /// `body: "<field>"` — one named field serializes to the JSON body.
    Field(String),
}

pub fn partition_fields(
    all_fields: &[String],
    template: &PathTemplate,
    body: &str,
) -> Result<FieldPartition, String> {
    // Every `{var}` must name a real request field.
    for v in &template.vars {
        if !all_fields.iter().any(|f| f == v) {
            return Err(format!(
                "path template var `{{{v}}}` does not match any request field \
                 (have: {all_fields:?})"
            ));
        }
    }

    let body_des = match body {
        "*" => BodyDesignator::Whole,
        "" => BodyDesignator::None,
        field => {
            if !all_fields.iter().any(|f| f == field) {
                return Err(format!(
                    "body designator `{field}` does not match any request field \
                     (have: {all_fields:?})"
                ));
            }
            BodyDesignator::Field(field.to_string())
        }
    };

    // Query fields = every leaf field that is NOT a path var and NOT the
    // body. With `body: "*"` there are no query fields (the whole message is
    // the body); with `body: ""` every non-path field is a query field; with
    // a named body field, every non-path non-body field is a query field.
    let query_fields = match &body_des {
        BodyDesignator::Whole => Vec::new(),
        BodyDesignator::None => all_fields
            .iter()
            .filter(|f| !template.vars.contains(f))
            .cloned()
            .collect(),
        BodyDesignator::Field(b) => all_fields
            .iter()
            .filter(|f| !template.vars.contains(f) && *f != b)
            .cloned()
            .collect(),
    };

    Ok(FieldPartition {
        path_fields: template.vars.clone(),
        body: body_des,
        query_fields,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_template() {
        let t = PathTemplate::parse("/v1/shelves/{shelf}/books/{book}").unwrap();
        assert_eq!(
            t.segments,
            vec![
                PathSegment::Literal("v1".into()),
                PathSegment::Literal("shelves".into()),
                PathSegment::Var("shelf".into()),
                PathSegment::Literal("books".into()),
                PathSegment::Var("book".into()),
            ]
        );
        assert_eq!(t.vars, vec!["shelf".to_string(), "book".to_string()]);
    }

    #[test]
    fn parse_no_vars() {
        let t = PathTemplate::parse("/v1/shelves").unwrap();
        assert_eq!(t.vars, Vec::<String>::new());
        assert_eq!(t.segments.len(), 2);
    }

    #[test]
    fn parse_rejects_relative() {
        assert!(PathTemplate::parse("v1/x").is_err());
    }

    #[test]
    fn parse_rejects_nested_capture() {
        assert!(PathTemplate::parse("/v1/{name=shelves/*}").is_err());
    }

    #[test]
    fn parse_rejects_wildcard() {
        assert!(PathTemplate::parse("/v1/**").is_err());
    }

    #[test]
    fn percent_encode_leaves_unreserved() {
        assert_eq!(percent_encode_simple("abcXYZ-._~09"), "abcXYZ-._~09");
    }

    #[test]
    fn percent_encode_escapes_reserved() {
        assert_eq!(percent_encode_simple("a/b c"), "a%2Fb%20c");
        assert_eq!(percent_encode_simple("hello world"), "hello%20world");
    }

    #[test]
    fn partition_get_path_and_query() {
        // GET /v1/shelves/{shelf}/books/{book} with no body — `page_size` and
        // `page_token` become query params.
        let t = PathTemplate::parse("/v1/shelves/{shelf}/books/{book}").unwrap();
        let fields = vec![
            "shelf".to_string(),
            "book".to_string(),
            "page_size".to_string(),
            "page_token".to_string(),
        ];
        let p = partition_fields(&fields, &t, "").unwrap();
        assert_eq!(p.path_fields, vec!["shelf", "book"]);
        assert_eq!(p.body, BodyDesignator::None);
        assert_eq!(p.query_fields, vec!["page_size", "page_token"]);
    }

    #[test]
    fn partition_post_whole_body() {
        // POST /v1/shelves with body:"*" — every non-path field is the body,
        // no query params.
        let t = PathTemplate::parse("/v1/shelves").unwrap();
        let fields = vec!["name".to_string(), "theme".to_string()];
        let p = partition_fields(&fields, &t, "*").unwrap();
        assert_eq!(p.path_fields, Vec::<String>::new());
        assert_eq!(p.body, BodyDesignator::Whole);
        assert_eq!(p.query_fields, Vec::<String>::new());
    }

    #[test]
    fn partition_named_body_field() {
        // POST /v1/shelves/{shelf}/books with body:"book" — `book` is the
        // body, `shelf` is the path, `dry_run` is a query param.
        let t = PathTemplate::parse("/v1/shelves/{shelf}/books").unwrap();
        let fields = vec![
            "shelf".to_string(),
            "book".to_string(),
            "dry_run".to_string(),
        ];
        let p = partition_fields(&fields, &t, "book").unwrap();
        assert_eq!(p.path_fields, vec!["shelf"]);
        assert_eq!(p.body, BodyDesignator::Field("book".to_string()));
        assert_eq!(p.query_fields, vec!["dry_run"]);
    }

    #[test]
    fn partition_rejects_unknown_path_var() {
        let t = PathTemplate::parse("/v1/{missing}").unwrap();
        let fields = vec!["other".to_string()];
        assert!(partition_fields(&fields, &t, "").is_err());
    }

    #[test]
    fn partition_rejects_unknown_body_field() {
        let t = PathTemplate::parse("/v1/x").unwrap();
        let fields = vec!["a".to_string()];
        assert!(partition_fields(&fields, &t, "nonexistent").is_err());
    }
}
