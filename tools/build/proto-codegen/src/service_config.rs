//! A Google API service configuration (`google.api.Service`, the
//! `<api>_<version>.yaml` beside an API's protos in googleapis), read for
//! what a REST client generated from those protos needs and no `.proto`
//! states: the `http.rules` binding a mixin (google.longrunning.Operations,
//! google.iam.v1.IAMPolicy, google.cloud.location.Locations) to the API's
//! own paths, and the API's host, `name`.
//!
//! [`ServiceConfig::apply`] overlays both on a lowered model:
//!
//!   * a method whose fully-qualified name (`package.Service.Method`) is the
//!     `selector` of a rule takes that rule as its HTTP binding (verb and
//!     path, `body`, `additional_bindings`) in place of its own
//!     `(google.api.http)` annotation, if it has one;
//!   * a service starts at the configuration's `name` in place of its
//!     `(google.api.default_host)` when the configuration's `apis` lists it
//!     or a rule binds one of its generated methods: every `http.rules`
//!     binding is served at the API's host, whether or not `apis` lists the
//!     mixin (googleapis' API Gateway configuration binds
//!     google.longrunning.Operations without listing it). When that replaces
//!     a different host, the service is marked
//!     (`IrService::host_from_service_config`) so the client names the
//!     configuration as its host's source.
//!
//! A rule naming no method of the model is not used: the configuration
//! describes the whole API, a target generates part of it.
//!
//! Refused (each naming the configuration and the line): a `type` other than
//! `google.api.Service`, no `name`, a rule with no selector, a wildcard or
//! malformed selector, a selector bound twice, a rule with no verb or two,
//! the `custom` verb, a key `http` or a rule does not define here, an
//! additional binding with a `selector` or bindings of its own, and
//! `fully_decode_reserved_expansion: true`. A rule applied to a generated
//! method is refused when it, or one of its additional bindings, sets
//! `response_body` (the emitter decodes the whole response as the method's
//! output). Refused naming the configuration and the method: a generated
//! method with no rule whose service moves from its own declared host to
//! `name` (a mixin): its proto binding is the mixin's generic path, which
//! the API's host does not serve.

use std::collections::BTreeMap;

use crate::http_options::HttpVerb;
use crate::ir::{IrHttpRule, IrModel};
use crate::yaml_subset::{self, Node, Yaml};

/// One `http.rules` entry, or one of its `additional_bindings`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigHttpRule {
    pub verb: HttpVerb,
    pub path_template: String,
    /// `"*"`, a field name, or empty (no body).
    pub body: String,
    pub response_body: String,
    pub additional_bindings: Vec<ConfigHttpRule>,
    /// The line the rule starts on.
    pub line: usize,
}

impl ConfigHttpRule {
    fn to_ir(&self) -> IrHttpRule {
        IrHttpRule {
            verb: self.verb.ir_token().to_string(),
            path_template: self.path_template.clone(),
            body: self.body.clone(),
            additional_bindings: self.additional_bindings.iter().map(Self::to_ir).collect(),
        }
    }

    fn response_body_line(&self) -> Option<usize> {
        if !self.response_body.is_empty() {
            return Some(self.line);
        }
        self.additional_bindings.iter().find_map(Self::response_body_line)
    }
}

/// What the generator reads of a service configuration.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServiceConfig {
    /// Where the configuration was read from, for messages.
    pub origin: String,
    /// `name`: the API's service name, the host its clients start at.
    pub name: String,
    /// `apis[].name`: the fully-qualified services the API serves.
    pub apis: Vec<String>,
    /// `http.rules`, by selector.
    pub rules: BTreeMap<String, ConfigHttpRule>,
}

const VERBS: [(&str, HttpVerb); 5] = [
    ("get", HttpVerb::Get),
    ("put", HttpVerb::Put),
    ("post", HttpVerb::Post),
    ("delete", HttpVerb::Delete),
    ("patch", HttpVerb::Patch),
];

fn scalar<'a>(n: &'a Node, what: &str) -> Result<&'a str, String> {
    match &n.value {
        Yaml::Scalar(s) => Ok(s),
        _ => Err(format!("line {}: `{what}` is not a scalar", n.line)),
    }
}

fn entries<'a>(n: &'a Node, what: &str) -> Result<&'a [(String, Node)], String> {
    match &n.value {
        Yaml::Map(e) => Ok(e),
        _ => Err(format!("line {}: `{what}` is not a mapping", n.line)),
    }
}

fn items<'a>(n: &'a Node, what: &str) -> Result<&'a [Node], String> {
    match &n.value {
        Yaml::Seq(v) => Ok(v),
        // `key:` with nothing under it: an empty list.
        Yaml::Scalar(s) if s.is_empty() => Ok(&[]),
        _ => Err(format!("line {}: `{what}` is not a sequence", n.line)),
    }
}

fn is_ident(s: &str) -> bool {
    s.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A selector names one method: `package.Service.Method`, at least two
/// dot-separated identifiers.
fn check_selector(sel: &str, line: usize) -> Result<(), String> {
    if sel.contains('*') {
        return Err(format!(
            "line {line}: http rule selector `{sel}` is a wildcard; a rule here binds one \
             method, named in full"
        ));
    }
    let parts: Vec<&str> = sel.split('.').collect();
    if parts.len() < 2 || !parts.iter().all(|p| is_ident(p)) {
        return Err(format!(
            "line {line}: http rule selector `{sel}` is not a fully-qualified method name"
        ));
    }
    Ok(())
}

fn parse_rule(n: &Node, top: bool) -> Result<ConfigHttpRule, String> {
    let what = if top { "http.rules" } else { "additional_bindings" };
    let mut verb: Option<(HttpVerb, String)> = None;
    let mut body = String::new();
    let mut response_body = String::new();
    let mut additional_bindings = Vec::new();
    for (k, v) in entries(n, what)? {
        if let Some((_, vb)) = VERBS.iter().find(|(name, _)| name == k) {
            let path = scalar(v, k)?;
            if path.is_empty() {
                return Err(format!("line {}: `{k}` has no path", v.line));
            }
            if verb.is_some() {
                return Err(format!(
                    "line {}: an http rule states a second verb, `{k}`",
                    v.line
                ));
            }
            verb = Some((*vb, path.to_string()));
            continue;
        }
        match k.as_str() {
            "selector" if top => {}
            "body" => body = scalar(v, k)?.to_string(),
            "response_body" => response_body = scalar(v, k)?.to_string(),
            "additional_bindings" if top => {
                for b in items(v, k)? {
                    additional_bindings.push(parse_rule(b, false)?);
                }
            }
            "custom" => {
                return Err(format!(
                    "line {}: the `custom` verb is not generated",
                    v.line
                ))
            }
            other => {
                return Err(format!(
                    "line {}: `{other}` is not a key of an http rule{}",
                    v.line,
                    if top { "" } else { "'s additional binding" }
                ))
            }
        }
    }
    let (verb, path_template) = verb.ok_or_else(|| {
        format!(
            "line {}: an http rule names no verb (get, put, post, delete, patch)",
            n.line
        )
    })?;
    Ok(ConfigHttpRule {
        verb,
        path_template,
        body,
        response_body,
        additional_bindings,
        line: n.line,
    })
}

impl ServiceConfig {
    /// Read a service configuration's text; `origin` names it in messages.
    pub fn parse(text: &str, origin: &str) -> Result<Self, String> {
        Self::parse_inner(text, origin).map_err(|e| format!("service config `{origin}`: {e}"))
    }

    fn parse_inner(text: &str, origin: &str) -> Result<Self, String> {
        let top = yaml_subset::parse_top_level(text, &["type", "name", "apis", "http"])?;
        let ty = top.get("type").map(|n| scalar(n, "type")).transpose()?;
        if ty != Some("google.api.Service") {
            return Err(format!(
                "`type` is {}, not `google.api.Service`",
                ty.map_or("absent".to_string(), |t| format!("`{t}`"))
            ));
        }
        let name = match top.get("name") {
            Some(n) => scalar(n, "name")?.to_string(),
            None => String::new(),
        };
        if name.is_empty() {
            return Err("no `name`: the API's service name".to_string());
        }
        let mut apis = Vec::new();
        if let Some(a) = top.get("apis") {
            for api in items(a, "apis")? {
                let n = api
                    .get("name")
                    .ok_or_else(|| format!("line {}: an `apis` entry has no `name`", api.line))?;
                apis.push(scalar(n, "name")?.to_string());
            }
        }
        let mut rules = BTreeMap::new();
        if let Some(http) = top.get("http") {
            for (k, v) in entries(http, "http")? {
                match k.as_str() {
                    "rules" => {
                        for r in items(v, "rules")? {
                            let sel_node = r.get("selector").ok_or_else(|| {
                                format!("line {}: an http rule has no selector", r.line)
                            })?;
                            let sel = scalar(sel_node, "selector")?;
                            check_selector(sel, sel_node.line)?;
                            let rule = parse_rule(r, true)?;
                            if rules.insert(sel.to_string(), rule).is_some() {
                                return Err(format!(
                                    "line {}: http rule selector `{sel}` is bound twice",
                                    sel_node.line
                                ));
                            }
                        }
                    }
                    "fully_decode_reserved_expansion" => {
                        if scalar(v, k)? != "false" {
                            return Err(format!(
                                "line {}: `http.fully_decode_reserved_expansion` is not \
                                 generated",
                                v.line
                            ));
                        }
                    }
                    other => {
                        return Err(format!("line {}: `http.{other}` is not read", v.line))
                    }
                }
            }
        }
        Ok(ServiceConfig { origin: origin.to_string(), name, apis, rules })
    }

    /// Overlay the rules and the host on `model` (module docstring).
    pub fn apply(&self, model: &mut IrModel) -> Result<(), String> {
        for file in &mut model.files {
            for svc in &mut file.services {
                let fq_svc = if file.proto_package.is_empty() {
                    svc.name.clone()
                } else {
                    format!("{}.{}", file.proto_package, svc.name)
                };
                let mut bound = false;
                for m in &svc.methods {
                    let sel = format!("{fq_svc}.{}", m.name);
                    let Some(rule) = self.rules.get(&sel) else { continue };
                    if let Some(line) = rule.response_body_line() {
                        return Err(format!(
                            "service config `{}`: line {line}: the http rule for `{sel}` sets \
                             `response_body`, which is not generated",
                            self.origin
                        ));
                    }
                    bound = true;
                }
                if !bound && !self.apis.contains(&fq_svc) {
                    continue;
                }
                if let Some(own) = svc.default_host.as_deref().filter(|h| *h != self.name) {
                    let unbound = svc
                        .methods
                        .iter()
                        .map(|m| format!("{fq_svc}.{}", m.name))
                        .find(|sel| !self.rules.contains_key(sel));
                    if let Some(sel) = unbound {
                        return Err(format!(
                            "service config `{}`: `{sel}` is generated with no http rule in \
                             it, but its service starts at the configuration's `name`, `{}`, \
                             not its own `{own}`: the proto's binding is not served there; bind \
                             the method in `http.rules` or leave it out of the target",
                            self.origin, self.name
                        ));
                    }
                }
                if svc.default_host.as_deref() != Some(self.name.as_str()) {
                    svc.default_host = Some(self.name.clone());
                    svc.host_from_service_config = true;
                }
                for m in &mut svc.methods {
                    if let Some(rule) = self.rules.get(&format!("{fq_svc}.{}", m.name)) {
                        m.http_rule = Some(rule.to_ir());
                    }
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{IrFile, IrMethod, IrService, TypeRef};

    const CONFIG: &str = "\
type: google.api.Service
config_version: 3
name: fixture.googleapis.com

apis:
- name: example.ops.v1.Operations

documentation:
  summary: |-
    Not read.

http:
  rules:
  - selector: example.ops.v1.Operations.GetOperation
    get: '/v9/{name=projects/*/operations/*}'
    additional_bindings:
    - get: '/v9/{name=folders/*/operations/*}'
  - selector: example.ops.v1.Operations.WaitOperation
    post: '/v9/{name=projects/*/operations/*}:wait'
    body: '*'
  - selector: example.other.v1.Absent.Method
    delete: '/v9/{name=absent/*}'
";

    fn parse(text: &str) -> Result<ServiceConfig, String> {
        ServiceConfig::parse(text, "fixture_v1.yaml")
    }

    fn method(name: &str, rule: Option<IrHttpRule>) -> IrMethod {
        IrMethod {
            name: name.into(),
            input: TypeRef { fq_name: ".example.ops.v1.Req".into(), mojo_name: "Req".into() },
            output: TypeRef { fq_name: ".example.ops.v1.Op".into(), mojo_name: "Op".into() },
            client_streaming: false,
            server_streaming: false,
            idempotent: false,
            http_rule: rule,
            routing_rule: None,
        }
    }

    fn model(package: &str, service: &str, methods: Vec<IrMethod>) -> IrModel {
        IrModel {
            files: vec![IrFile {
                proto_path: "example/ops/v1/ops.proto".into(),
                proto_package: package.into(),
                mojo_package: "komira_test".into(),
                messages: vec![],
                enums: vec![],
                services: vec![IrService {
                    name: service.into(),
                    methods,
                    default_host: Some("ops.example.com".into()),
                    host_from_service_config: false,
                }],
                imports: vec![],
            }],
        }
    }

    fn rule(verb: &str, path: &str, body: &str) -> IrHttpRule {
        IrHttpRule {
            verb: verb.into(),
            path_template: path.into(),
            body: body.into(),
            additional_bindings: vec![],
        }
    }

    #[test]
    fn reads_name_apis_and_rules() {
        let c = parse(CONFIG).unwrap();
        assert_eq!(c.name, "fixture.googleapis.com");
        assert_eq!(c.apis, ["example.ops.v1.Operations"]);
        let get = &c.rules["example.ops.v1.Operations.GetOperation"];
        assert_eq!(get.verb, HttpVerb::Get);
        assert_eq!(get.path_template, "/v9/{name=projects/*/operations/*}");
        assert_eq!(get.additional_bindings[0].path_template, "/v9/{name=folders/*/operations/*}");
        assert_eq!(c.rules["example.ops.v1.Operations.WaitOperation"].body, "*");
        assert_eq!(c.rules.len(), 3);
    }

    #[test]
    fn apply_replaces_the_protos_binding_and_host() {
        let c = parse(CONFIG).unwrap();
        let mut m = model(
            "example.ops.v1",
            "Operations",
            vec![
                method("GetOperation", Some(rule("get", "/v1/{name=operations/**}", ""))),
                method("WaitOperation", None),
            ],
        );
        c.apply(&mut m).unwrap();
        let svc = &m.files[0].services[0];
        assert_eq!(svc.default_host.as_deref(), Some("fixture.googleapis.com"));
        assert!(svc.host_from_service_config);
        let mut want_get = rule("get", "/v9/{name=projects/*/operations/*}", "");
        want_get.additional_bindings = vec![rule("get", "/v9/{name=folders/*/operations/*}", "")];
        assert_eq!(svc.methods[0].http_rule, Some(want_get));
        assert_eq!(
            svc.methods[1].http_rule,
            Some(rule("post", "/v9/{name=projects/*/operations/*}:wait", "*"))
        );
    }

    #[test]
    fn a_service_not_in_apis_keeps_its_host_and_takes_no_rule() {
        let c = parse(CONFIG).unwrap();
        let mut m = model("example.ops.v2", "Operations", vec![method("GetOperation", None)]);
        c.apply(&mut m).unwrap();
        assert_eq!(m.files[0].services[0].default_host.as_deref(), Some("ops.example.com"));
        assert!(!m.files[0].services[0].host_from_service_config);
        assert_eq!(m.files[0].services[0].methods[0].http_rule, None);
    }

    #[test]
    fn a_service_apis_does_not_list_starts_at_name_when_a_rule_binds_it() {
        // googleapis' apigateway_v1.yaml: http.rules bind
        // google.longrunning.Operations, `apis` does not list it. Every rule
        // is served at the API's host.
        let text = CONFIG.replace("- name: example.ops.v1.Operations\n", "- name: example.Other\n");
        let c = parse(&text).unwrap();
        let mut m = model("example.ops.v1", "Operations", vec![method("WaitOperation", None)]);
        c.apply(&mut m).unwrap();
        let svc = &m.files[0].services[0];
        assert_eq!(svc.default_host.as_deref(), Some("fixture.googleapis.com"));
        assert!(svc.host_from_service_config);
        assert_eq!(
            svc.methods[0].http_rule,
            Some(rule("post", "/v9/{name=projects/*/operations/*}:wait", "*"))
        );
    }

    #[test]
    fn a_mixin_method_with_no_rule_is_refused() {
        // Listed or not, a service moved off its own host needs a rule for
        // every generated method: the proto's generic path is the mixin's.
        for text in [
            CONFIG.to_string(),
            CONFIG.replace("- name: example.ops.v1.Operations\n", "- name: example.Other\n"),
        ] {
            let c = parse(&text).unwrap();
            let mut m = model(
                "example.ops.v1",
                "Operations",
                vec![
                    method("GetOperation", None),
                    method("ListOperations", Some(rule("get", "/v1/{name=operations}", ""))),
                ],
            );
            assert_eq!(
                c.apply(&mut m).unwrap_err(),
                "service config `fixture_v1.yaml`: `example.ops.v1.Operations.ListOperations` \
                 is generated with no http rule in it, but its service starts at the \
                 configuration's `name`, `fixture.googleapis.com`, not its own \
                 `ops.example.com`: the proto's binding is not served there; bind the method \
                 in `http.rules` or leave it out of the target"
            );
        }
    }

    #[test]
    fn a_listed_service_with_no_rule_keeps_its_bindings() {
        let text = CONFIG.replace(
            "- name: example.ops.v1.Operations\n",
            "- name: example.ops.v1.Operations\n- name: example.api.v1.Things\n",
        );
        let c = parse(&text).unwrap();
        // The API's own service, declaring the configuration's host: nothing
        // moves, and the client says the host is its own annotation's.
        let mut same = model(
            "example.api.v1",
            "Things",
            vec![method("ListThings", Some(rule("get", "/v1/things", "")))],
        );
        same.files[0].services[0].default_host = Some("fixture.googleapis.com".into());
        c.apply(&mut same).unwrap();
        let svc = &same.files[0].services[0];
        assert_eq!(svc.default_host.as_deref(), Some("fixture.googleapis.com"));
        assert!(!svc.host_from_service_config);
        assert_eq!(svc.methods[0].http_rule, Some(rule("get", "/v1/things", "")));
        // Declaring no host: listing it gives it `name`, its bindings stay.
        let mut none = model(
            "example.api.v1",
            "Things",
            vec![method("ListThings", Some(rule("get", "/v1/things", "")))],
        );
        none.files[0].services[0].default_host = None;
        c.apply(&mut none).unwrap();
        let svc = &none.files[0].services[0];
        assert_eq!(svc.default_host.as_deref(), Some("fixture.googleapis.com"));
        assert!(svc.host_from_service_config);
        assert_eq!(svc.methods[0].http_rule, Some(rule("get", "/v1/things", "")));
    }

    #[test]
    fn a_response_body_on_a_generated_method_is_refused() {
        let text = CONFIG.replace("    body: '*'\n", "    body: '*'\n    response_body: done\n");
        let c = parse(&text).unwrap();
        let mut unused = model("example.ops.v1", "Operations", vec![method("GetOperation", None)]);
        c.apply(&mut unused).unwrap();
        let mut m = model("example.ops.v1", "Operations", vec![method("WaitOperation", None)]);
        assert_eq!(
            c.apply(&mut m).unwrap_err(),
            "service config `fixture_v1.yaml`: line 18: the http rule for \
             `example.ops.v1.Operations.WaitOperation` sets `response_body`, which is not \
             generated"
        );
    }

    #[test]
    fn a_response_body_on_an_additional_binding_is_refused() {
        let text = CONFIG.replace(
            "    - get: '/v9/{name=folders/*/operations/*}'\n",
            "    - get: '/v9/{name=folders/*/operations/*}'\n      response_body: done\n",
        );
        let c = parse(&text).unwrap();
        let mut m = model("example.ops.v1", "Operations", vec![method("GetOperation", None)]);
        assert_eq!(
            c.apply(&mut m).unwrap_err(),
            "service config `fixture_v1.yaml`: line 17: the http rule for \
             `example.ops.v1.Operations.GetOperation` sets `response_body`, which is not \
             generated"
        );
    }

    #[test]
    fn refusals_name_the_configuration_and_the_line() {
        let head = "type: google.api.Service\nname: x.googleapis.com\nhttp:\n  rules:\n";
        for (rules, want) in [
            ("  - get: /a\n", "line 5: an http rule has no selector"),
            ("  - selector: 'a.B.*'\n    get: /a\n", "line 5: http rule selector `a.B.*` is a wildcard"),
            ("  - selector: Method\n    get: /a\n", "line 5: http rule selector `Method` is not a fully-qualified"),
            (
                "  - selector: a.B.M\n    get: /a\n  - selector: a.B.M\n    get: /b\n",
                "line 7: http rule selector `a.B.M` is bound twice",
            ),
            ("  - selector: a.B.M\n    body: '*'\n", "line 5: an http rule names no verb"),
            ("  - selector: a.B.M\n    get: /a\n    post: /b\n", "line 7: an http rule states a second verb, `post`"),
            ("  - selector: a.B.M\n    custom:\n      kind: HEAD\n      path: /a\n", "line 7: the `custom` verb is not generated"),
            ("  - selector: a.B.M\n    get: /a\n    gett: /b\n", "line 7: `gett` is not a key of an http rule"),
            (
                "  - selector: a.B.M\n    get: /a\n    additional_bindings:\n    - get: /b\n      selector: a.B.N\n",
                "line 9: `selector` is not a key of an http rule's additional binding",
            ),
            (
                "  - selector: a.B.M\n    get: /a\n    additional_bindings:\n    - get: /b\n      additional_bindings:\n      - get: /c\n",
                "line 10: `additional_bindings` is not a key of an http rule's additional binding",
            ),
            ("  - selector: a.B.M\n    get: ''\n", "line 6: `get` has no path"),
        ] {
            let err = parse(&format!("{head}{rules}")).unwrap_err();
            let want = format!("service config `fixture_v1.yaml`: {want}");
            assert!(err.starts_with(&want), "{rules:?}: {err}");
        }
        for (doc, want) in [
            ("name: x\n", "`type` is absent, not `google.api.Service`"),
            ("type: google.api.Other\nname: x\n", "`type` is `google.api.Other`, not"),
            ("type: google.api.Service\n", "no `name`"),
            ("type: google.api.Service\nname: x\napis:\n- version: v1\n", "line 4: an `apis` entry has no `name`"),
            ("type: google.api.Service\nname: x\nhttp:\n  fully_decode_reserved_expansion: true\n", "line 4: `http.fully_decode_reserved_expansion` is not generated"),
            ("type: google.api.Service\nname: x\nhttp:\n  rulez: []\n", "line 4: `[` starts a flow collection"),
            ("type: google.api.Service\nname: x\nhttp:\n  rulez:\n", "line 4: `http.rulez` is not read"),
        ] {
            let err = parse(doc).unwrap_err();
            let want = format!("service config `fixture_v1.yaml`: {want}");
            assert!(err.starts_with(&want), "{doc:?}: {err}");
        }
        // `fully_decode_reserved_expansion: false` is the default, read as such.
        parse("type: google.api.Service\nname: x\nhttp:\n  fully_decode_reserved_expansion: false\n").unwrap();
    }
}
