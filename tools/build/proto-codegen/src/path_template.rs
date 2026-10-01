//! Parsing `(google.api.http)` path templates, and partitioning a request's
//! fields into path, query and body for one HTTP rule.
//!
//! The grammar is the one `google/api/http.proto` states:
//!
//! ```text
//! Template = "/" Segments [ Verb ] ;
//! Segments = Segment { "/" Segment } ;
//! Segment  = "*" | "**" | LITERAL | Variable ;
//! Variable = "{" FieldPath [ "=" Segments ] "}" ;
//! FieldPath = IDENT { "." IDENT } ;
//! Verb     = ":" LITERAL ;
//! ```
//!
//! A client fills every variable from a request field, so two parts of the
//! grammar are refused rather than half-supported: a bare `*`/`**` segment
//! outside a variable (no field fills it) and a dotted field path (the
//! generated code reads top-level request fields only).

/// One segment of a parsed path template.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PathSegment {
    /// A literal path segment, e.g. `v1` or `entries`.
    Literal(String),
    /// A `{field}` or `{field=pattern}` capture, filled from the named
    /// scalar request field.
    Var(PathVar),
}

/// A variable of a path template.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PathVar {
    /// The request field the variable is filled from.
    pub field: String,
    pub pattern: VarPattern,
    /// The variable was written `{field=...}`, `{field=*}` included. Its
    /// expansion is decided by `pattern`; this records only the spelling,
    /// which an OpenAPI path cannot state (see [`PathTemplate::has_patterns`]).
    pub explicit_pattern: bool,
}

/// What a variable's value may look like, which decides how it is expanded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VarPattern {
    /// `{field}` or `{field=*}`: one segment. Every byte outside the
    /// unreserved set is percent-encoded, `/` included.
    Segment,
    /// `{field=<segments>}` with more than one segment, a literal or `**`,
    /// e.g. `projects/*/logs/*` or `operations/**`. The value is checked
    /// against the pattern and each of its segments percent-encoded, with
    /// the `/` between them kept (the multi-segment expansion of
    /// `http.proto`). Held in its canonical text form: segments joined by
    /// `/`, each `*`, `**` (last only) or an unreserved-only literal.
    Segments(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PathTemplate {
    pub segments: Vec<PathSegment>,
    /// The variables' field names, in template order: the path-field set.
    pub vars: Vec<String>,
    /// The custom verb, e.g. `list` for `/v2/entries:list`.
    pub verb: Option<String>,
}

impl PathTemplate {
    pub fn parse(template: &str) -> Result<Self, String> {
        let Some(rest) = template.strip_prefix('/') else {
            return Err(format!(
                "path template {template:?} must be absolute (start with `/`)"
            ));
        };
        let (body, verb) = split_verb(template, rest)?;
        let mut segments = Vec::new();
        let mut vars: Vec<String> = Vec::new();
        let raws = split_top_level(template, body)?;
        let last = raws.len().saturating_sub(1);
        for (i, raw) in raws.into_iter().enumerate() {
            // An empty component (a trailing or doubled `/`) is skipped: no
            // empty literal segments.
            if raw.is_empty() {
                continue;
            }
            if let Some(inner) = raw.strip_prefix('{') {
                let inner = inner.strip_suffix('}').ok_or_else(|| {
                    format!("path template {template:?}: segment {raw:?} is not a whole `{{...}}` variable")
                })?;
                let var = parse_var(template, inner)?;
                if vars.contains(&var.field) {
                    return Err(format!(
                        "path template {template:?}: field `{}` is captured twice",
                        var.field
                    ));
                }
                if let VarPattern::Segments(p) = &var.pattern {
                    if p.ends_with("**") && i != last {
                        return Err(format!(
                            "path template {template:?}: `**` matches the rest of the \
                             path, so its variable `{}` must be the last segment",
                            var.field
                        ));
                    }
                }
                vars.push(var.field.clone());
                segments.push(PathSegment::Var(var));
            } else if raw == "*" || raw == "**" {
                return Err(format!(
                    "path template {template:?}: a bare `{raw}` segment has no request \
                     field to fill it; a client can only send a template whose \
                     wildcards sit inside a `{{field=...}}` variable"
                ));
            } else {
                if raw.contains(['{', '}', '*', '=']) {
                    return Err(format!(
                        "path template {template:?}: literal segment {raw:?} carries \
                         a template metacharacter"
                    ));
                }
                segments.push(PathSegment::Literal(raw.to_string()));
            }
        }
        Ok(PathTemplate { segments, vars, verb })
    }

    /// True when some variable was written `{field=...}`, i.e. the template
    /// text is not the plain `{field}` form an OpenAPI path can state as it
    /// is. Decided by the spelling, not by the pattern: `{field=*}` expands
    /// like `{field}`, but its text still carries the `=*`, so an OpenAPI
    /// path key made from it would name no `{field}` parameter.
    pub fn has_patterns(&self) -> bool {
        self.segments
            .iter()
            .any(|s| matches!(s, PathSegment::Var(PathVar { explicit_pattern: true, .. })))
    }
}

/// Split the custom verb off the template body (`rest`, after the leading
/// `/`). The verb is the text after a `:` outside every `{...}`; it is a
/// non-empty unreserved literal, because it is emitted into the URL as it is.
fn split_verb<'a>(template: &str, rest: &'a str) -> Result<(&'a str, Option<String>), String> {
    let mut depth = 0usize;
    for (i, c) in rest.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => depth = depth.saturating_sub(1),
            ':' if depth == 0 => {
                let verb = &rest[i + 1..];
                if verb.is_empty() || !verb.bytes().all(is_unreserved) {
                    return Err(format!(
                        "path template {template:?}: custom verb {verb:?} must be a \
                         non-empty literal of [A-Za-z0-9-._~]"
                    ));
                }
                return Ok((&rest[..i], Some(verb.to_string())));
            }
            _ => {}
        }
    }
    Ok((rest, None))
}

/// Split at every `/` outside a `{...}`, refusing unbalanced or nested braces.
fn split_top_level<'a>(template: &str, body: &'a str) -> Result<Vec<&'a str>, String> {
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut start = 0;
    for (i, c) in body.char_indices() {
        match c {
            '{' => {
                if depth > 0 {
                    return Err(format!("path template {template:?}: nested `{{` in a variable"));
                }
                depth = 1;
            }
            '}' => {
                if depth == 0 {
                    return Err(format!("path template {template:?}: unbalanced `}}`"));
                }
                depth = 0;
            }
            '/' if depth == 0 => {
                out.push(&body[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    if depth != 0 {
        return Err(format!("path template {template:?}: unclosed `{{`"));
    }
    out.push(&body[start..]);
    Ok(out)
}

/// Parse the inside of `{...}`: `field` or `field=pattern`.
fn parse_var(template: &str, inner: &str) -> Result<PathVar, String> {
    let (field, pattern) = match inner.split_once('=') {
        Some((f, p)) => (f, Some(p)),
        None => (inner, None),
    };
    if field.contains('.') {
        return Err(format!(
            "path template {template:?}: `{{{inner}}}` names a nested field path; \
             only a top-level request field can be captured"
        ));
    }
    if !is_simple_ident(field) {
        return Err(format!(
            "path template {template:?}: `{{{inner}}}` does not name a field identifier"
        ));
    }
    let pattern = match pattern {
        None | Some("*") => VarPattern::Segment,
        Some(p) => {
            let segs: Vec<&str> = p.split('/').collect();
            for (i, s) in segs.iter().enumerate() {
                let ok = match *s {
                    "*" => true,
                    "**" => i + 1 == segs.len(),
                    lit => !lit.is_empty() && lit.bytes().all(is_unreserved),
                };
                if !ok {
                    return Err(format!(
                        "path template {template:?}: pattern {p:?} of `{field}` must be \
                         `/`-separated segments, each `*`, a literal of [A-Za-z0-9-._~], \
                         or `**` as the last one"
                    ));
                }
            }
            VarPattern::Segments(p.to_string())
        }
    };
    Ok(PathVar { field: field.to_string(), explicit_pattern: inner.contains('='), pattern })
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

    fn seg_var(field: &str) -> PathSegment {
        PathSegment::Var(PathVar { field: field.into(), pattern: VarPattern::Segment, explicit_pattern: false })
    }

    #[test]
    fn parse_simple_template() {
        let t = PathTemplate::parse("/v1/shelves/{shelf}/books/{book}").unwrap();
        assert_eq!(
            t.segments,
            vec![
                PathSegment::Literal("v1".into()),
                PathSegment::Literal("shelves".into()),
                seg_var("shelf"),
                PathSegment::Literal("books".into()),
                seg_var("book"),
            ]
        );
        assert_eq!(t.vars, vec!["shelf".to_string(), "book".to_string()]);
        assert_eq!(t.verb, None);
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
    fn parse_custom_verb_on_a_literal() {
        let t = PathTemplate::parse("/v2/entries:list").unwrap();
        assert_eq!(
            t.segments,
            vec![PathSegment::Literal("v2".into()), PathSegment::Literal("entries".into())]
        );
        assert_eq!(t.verb.as_deref(), Some("list"));
    }

    #[test]
    fn parse_pattern_capture_keeps_its_slashes_inside_the_braces() {
        let t = PathTemplate::parse("/v2/{parent=projects/*}/logs").unwrap();
        assert_eq!(
            t.segments,
            vec![
                PathSegment::Literal("v2".into()),
                PathSegment::Var(PathVar {
                    field: "parent".into(),
                    pattern: VarPattern::Segments("projects/*".into()),
                    explicit_pattern: true,
                }),
                PathSegment::Literal("logs".into()),
            ]
        );
        assert!(t.has_patterns());
    }

    #[test]
    fn parse_double_star_capture_then_verb() {
        let t = PathTemplate::parse("/v1/{name=operations/**}:cancel").unwrap();
        assert_eq!(t.vars, vec!["name".to_string()]);
        assert_eq!(t.verb.as_deref(), Some("cancel"));
    }

    #[test]
    fn parse_star_pattern_is_one_segment_but_still_a_written_pattern() {
        // `{name=*}` expands like `{name}` (one segment, `/` encoded), but
        // its text carries `=*`: an OpenAPI path key made from it would name
        // no `{name}` parameter, so has_patterns() must say so.
        let t = PathTemplate::parse("/v1/{name=*}/things").unwrap();
        let PathSegment::Var(v) = &t.segments[1] else { panic!("not a variable") };
        assert_eq!(v.pattern, VarPattern::Segment);
        assert!(v.explicit_pattern);
        assert!(t.has_patterns());
        assert!(!PathTemplate::parse("/v1/{name}/things").unwrap().has_patterns());
    }

    #[test]
    fn parse_refusals() {
        for bad in [
            "/v1/**",                       // bare wildcard: no field fills it
            "/v1/*/x",                      // the same, one segment
            "/v1/{a=**/x}",                 // `**` not last in its pattern
            "/v1/{a=x/**}/y",               // `**` variable not last in the path
            "/v1/{a.b}",                    // nested field path
            "/v1/{a={b}}",                  // nested braces
            "/v1/{a",                       // unclosed
            "/v1/a}",                       // unbalanced
            "/v1/x:",                       // empty verb
            "/v1/x:a/b",                    // verb with a `/`
            "/v1/{a=x y}",                  // pattern literal outside the unreserved set
            "/v1/{a}/{a}",                  // captured twice
            "/v1/{a=x//y}",                 // empty pattern segment
        ] {
            assert!(PathTemplate::parse(bad).is_err(), "{bad} was accepted");
        }
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
