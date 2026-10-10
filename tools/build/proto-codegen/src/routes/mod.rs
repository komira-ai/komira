//! The route-table and handler-trait emitter behind `protoc-gen-mojo-routes`.
//!
//! For each `.proto` to generate that declares a service, it writes
//! `<stem>_routes.mojo`: per service, a handler trait (one method per RPC), a
//! function building komira_http_server's `Router` from the RPCs'
//! `(google.api.http)` rules, and a dispatcher (a komira_http_server
//! `RoutedDispatcher`, so `ComposedRoutes` can serve several services from one
//! server) that matches a request through that router, binds the
//! request message from the path, the query and the body, calls the handler
//! and writes the response message as proto3 JSON.
//!
//! Refused at generation, each with a message naming the RPC: a streaming
//! RPC, an RPC without an HTTP rule, a rule whose `body` names one field, a
//! path variable the router cannot capture (a dotted field path, a
//! `{field=a/*}` pattern, a variable followed by a custom verb), a path
//! variable whose field is not a singular string, integer or bool, and two
//! bindings the router could not tell apart.

use std::collections::BTreeSet;
use std::fmt::Write as _;

use komira_proto_codegen::ir::{
    IrField, IrFile, IrHttpRule, IrMessage, IrMethod, IrModel, IrService, IrType, Label,
    ScalarKind, TypeRef,
};
use komira_proto_codegen::lower::{module_stem, ModuleNames};
use komira_proto_codegen::mojo_names::rpc_method_name;
use komira_proto_codegen::path_template::{PathSegment, PathTemplate, VarPattern};

#[cfg(test)]
mod tests;

/// The file a `.proto` with services is generated as: `<stem>_routes.mojo`.
pub fn routes_file_name(proto_path: &str) -> String {
    format!("{}_routes.mojo", module_stem(proto_path, &ModuleNames::new()))
}

/// One `<stem>_routes.mojo` per file of `generate` that declares a service,
/// in `model`'s file order. `model` is lowered with the HTTP rules from
/// `generate` and the files declaring its RPCs' request messages, and its
/// `mojo_package` is the package the message modules are generated in.
pub fn emit_routes(model: &IrModel, generate: &[String]) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    for file in &model.files {
        if file.services.is_empty() || !generate.contains(&file.proto_path) {
            continue;
        }
        out.push((routes_file_name(&file.proto_path), emit_file(model, file)?));
    }
    Ok(out)
}

/// How the request message's fields arrive for one binding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Body {
    /// `body: "*"`: every field not in the path is in the JSON body; the
    /// query must be empty.
    Whole,
    /// No `body`: the request has no body; every field not in the path may
    /// come from the query.
    None,
}

/// One route: an (RPC, HTTP binding) pair, as the router registers it.
struct Route<'a> {
    method: &'a IrMethod,
    verb: &'static str,
    template: String,
    /// The router pattern: `{field}` becomes `:field`.
    pattern: String,
    /// The segments with each variable as `None`: the order and ambiguity key.
    shape: Vec<Option<String>>,
    /// The path variables' fields, in template order.
    path_fields: Vec<&'a IrField>,
    body: Body,
    /// The fields a query parameter may set (empty unless `body` is `None`).
    query_fields: Vec<&'a IrField>,
}

fn emit_file(model: &IrModel, file: &IrFile) -> Result<String, String> {
    let own_module = format!(
        "{}.{}",
        file.mojo_package,
        module_stem(&file.proto_path, &ModuleNames::new())
    );
    let mut services = Vec::new();
    let mut imports: BTreeSet<(String, String)> = BTreeSet::new();
    for svc in &file.services {
        check_generated_names(file, svc)?;
        let routes = service_routes(model, svc)?;
        for m in &svc.methods {
            imports.insert(type_import(file, &own_module, &m.input)?);
            imports.insert(type_import(file, &own_module, &m.output)?);
        }
        services.push((svc, routes));
    }

    let mut s = String::new();
    header(&mut s, file);
    for (module, symbol) in &imports {
        let _ = writeln!(s, "from {module} import {symbol}");
    }
    s.push_str("\n\n");
    s.push_str(HELPERS);
    for (svc, routes) in &services {
        emit_service(&mut s, file, svc, routes);
    }
    Ok(s)
}

/// Refuse a service whose generated trait or dispatcher name is a message
/// name of the same file (the routes module imports both).
fn check_generated_names(file: &IrFile, svc: &IrService) -> Result<(), String> {
    for name in [format!("{}Handler", svc.name), format!("{}Routes", svc.name)] {
        if file.messages.iter().any(|m| m.mojo_name == name) {
            return Err(format!(
                "service `{}`: the generated name `{name}` is also a message of {}",
                svc.name, file.proto_path
            ));
        }
    }
    Ok(())
}

/// `(module, symbol)` to import a method's input or output type from.
fn type_import(file: &IrFile, own_module: &str, t: &TypeRef) -> Result<(String, String), String> {
    if file.messages.iter().any(|m| m.fq_name == t.fq_name) {
        return Ok((own_module.to_string(), t.mojo_name.clone()));
    }
    file.imports
        .iter()
        .find(|i| i.symbol == t.mojo_name)
        .map(|i| (i.module.clone(), i.symbol.clone()))
        .ok_or_else(|| format!("type `{}` is declared in no file of the request", t.fq_name))
}

/// The service's routes in registration order: static segments before
/// variables at the first position two shapes differ (the router takes the
/// first match), then declaration order.
fn service_routes<'a>(model: &'a IrModel, svc: &'a IrService) -> Result<Vec<Route<'a>>, String> {
    let mut routes = Vec::new();
    for m in &svc.methods {
        let ctx = format!("rpc {}.{}", svc.name, m.name);
        if m.client_streaming || m.server_streaming {
            return Err(format!("{ctx}: a streaming RPC has no HTTP route"));
        }
        let Some(rule) = &m.http_rule else {
            return Err(format!(
                "{ctx} has no (google.api.http) rule; every RPC of a routed service needs one"
            ));
        };
        let input = find_message(model, &m.input.fq_name);
        routes.push(route(&ctx, m, rule, input)?);
        for b in &rule.additional_bindings {
            routes.push(route(&ctx, m, b, input)?);
        }
    }
    routes.sort_by(|a, b| shape_key(&a.shape).cmp(&shape_key(&b.shape)));
    for (i, a) in routes.iter().enumerate() {
        for b in &routes[i + 1..] {
            if a.verb == b.verb && a.shape == b.shape {
                return Err(format!(
                    "service {}: {} {} ({}) and {} {} ({}) match the same requests",
                    svc.name,
                    a.verb.to_uppercase(),
                    a.template,
                    a.method.name,
                    b.verb.to_uppercase(),
                    b.template,
                    b.method.name
                ));
            }
        }
    }
    Ok(routes)
}

fn shape_key(shape: &[Option<String>]) -> Vec<u8> {
    shape.iter().map(|s| u8::from(s.is_none())).collect()
}

fn find_message<'a>(model: &'a IrModel, fq_name: &str) -> Option<&'a IrMessage> {
    model
        .files
        .iter()
        .flat_map(|f| f.messages.iter())
        .find(|m| m.fq_name == fq_name)
}

fn route<'a>(
    ctx: &str,
    m: &'a IrMethod,
    rule: &IrHttpRule,
    input: Option<&'a IrMessage>,
) -> Result<Route<'a>, String> {
    let verb = match rule.verb.as_str() {
        "get" => "get",
        "put" => "put",
        "post" => "post",
        "delete" => "delete",
        "patch" => "patch",
        other => return Err(format!("{ctx}: unknown HTTP verb `{other}`")),
    };
    let ctx = format!("{ctx} ({} {})", verb.to_uppercase(), rule.path_template);
    let body = match rule.body.as_str() {
        "*" => Body::Whole,
        "" => Body::None,
        field => {
            return Err(format!(
                "{ctx}: `body: \"{field}\"` (one field as the body) is not supported; use `*`"
            ))
        }
    };
    let tmpl = PathTemplate::parse(&rule.path_template).map_err(|e| format!("{ctx}: {e}"))?;
    let message = || {
        input.ok_or_else(|| {
            format!(
                "{ctx}: the request message `{}` is not declared in a file being generated",
                m.input.fq_name
            )
        })
    };
    let mut pattern = String::new();
    let mut shape = Vec::new();
    let mut path_fields = Vec::new();
    for seg in &tmpl.segments {
        match seg {
            PathSegment::Literal(l) => {
                if l.starts_with(':') {
                    return Err(format!("{ctx}: literal segment `{l}` reads as a router variable"));
                }
                let _ = write!(pattern, "/{l}");
                shape.push(Some(l.clone()));
            }
            PathSegment::Var(v) => {
                if v.field.contains('.') {
                    return Err(format!(
                        "{ctx}: path variable `{}` names a nested field; the router binds top-level fields only",
                        v.field
                    ));
                }
                if let VarPattern::Segments(p) = &v.pattern {
                    return Err(format!(
                        "{ctx}: path variable `{{{}={p}}}` spans segments; the router captures one segment",
                        v.field
                    ));
                }
                let field = message()?
                    .fields
                    .iter()
                    .find(|f| f.name == v.field)
                    .ok_or_else(|| format!("{ctx}: path variable `{}` names no field", v.field))?;
                if !bindable(field) {
                    return Err(format!(
                        "{ctx}: path variable `{}` is not a singular string, integer or bool field",
                        v.field
                    ));
                }
                let _ = write!(pattern, "/:{}", v.field);
                shape.push(None);
                path_fields.push(field);
            }
        }
    }
    if let Some(custom) = &tmpl.verb {
        let Some(Some(last)) = shape.last_mut() else {
            return Err(format!(
                "{ctx}: the custom verb `:{custom}` follows a variable or the root; the router matches whole segments"
            ));
        };
        let _ = write!(last, ":{custom}");
        let _ = write!(pattern, ":{custom}");
    }
    if pattern.is_empty() {
        pattern.push('/');
    }
    let query_fields = match body {
        Body::Whole => Vec::new(),
        Body::None => message()?
            .fields
            .iter()
            .filter(|f| bindable(f) && !path_fields.iter().any(|p| p.name == f.name))
            .collect(),
    };
    Ok(Route {
        method: m,
        verb,
        template: rule.path_template.clone(),
        pattern,
        shape,
        path_fields,
        body,
        query_fields,
    })
}

/// A field a path segment or a query parameter can set: singular, outside
/// every oneof, a string, integer or bool.
fn bindable(f: &IrField) -> bool {
    f.oneof_index.is_none() && f.label != Label::Repeated && conversion(f).is_some()
}

/// The Mojo expression converting the `String` expression `v` to the
/// field's storage type, or `None` when the field cannot be bound from text.
fn conversion(f: &IrField) -> Option<String> {
    let IrType::Scalar(k) = f.ty else { return None };
    let (ty, expr) = match k {
        ScalarKind::String => ("String", "{v}".to_string()),
        ScalarKind::Int64 | ScalarKind::Sint64 | ScalarKind::Sfixed64 => {
            ("Int64", "_route_int64({v})".to_string())
        }
        ScalarKind::Int32 | ScalarKind::Sint32 | ScalarKind::Sfixed32 => {
            ("Int32", "_route_int32({v})".to_string())
        }
        ScalarKind::Uint64 | ScalarKind::Fixed64 => ("UInt64", "_route_uint64({v})".to_string()),
        ScalarKind::Uint32 | ScalarKind::Fixed32 => ("UInt32", "_route_uint32({v})".to_string()),
        ScalarKind::Bool => ("Bool", "_route_bool({v})".to_string()),
        _ => return None,
    };
    Some(match f.label {
        Label::Optional => format!("Optional[{ty}]({expr})"),
        _ => expr,
    })
}

fn assign(f: &IrField, value: &str) -> String {
    let expr = conversion(f).expect("only bindable fields are assigned");
    format!("msg.{} = {}", f.name, expr.replace("{v}", value))
}

fn header(s: &mut String, file: &IrFile) {
    let _ = write!(
        s,
        "\
# GENERATED by protoc-gen-mojo-routes — do not hand-edit.
# Source: {src}
# Messages: the Mojo package {pkg}
#
# For each service: a handler trait with one method per RPC, `<service>_router()`
# (komira_http_server's `Router`, one entry per HTTP binding of each RPC's
# `(google.api.http)` rule), and `<Service>Routes[H]`, a `RoutedDispatcher`
# (`ComposedRoutes` serves several from one server) that answers:
#   no route matches the path                     404
#   a route matches the path, not the method      405, `Allow` naming the path's
#                                                      methods
#   the body, path or query does not bind         400 (an unknown JSON field or
#                                                      query parameter included)
#   the handler raises                            the handler's `error_response`
#   otherwise                                     200, the response as proto3 JSON
# A path variable overrides the same field in the body.

from std.collections.dict import Dict

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.routing.compose import RoutedDispatcher
from komira_http_server.routing.router import Router
from komira_proto_codec import decode_json, encode_json
",
        src = file.proto_path,
        pkg = file.mojo_package
    );
}

fn emit_service(s: &mut String, file: &IrFile, svc: &IrService, routes: &[Route<'_>]) {
    let fq = if file.proto_package.is_empty() {
        svc.name.clone()
    } else {
        format!("{}.{}", file.proto_package, svc.name)
    };
    let snake = rpc_method_name(&svc.name);
    let _ = write!(s, "\n\n# ---- service {fq} ----\n\n\n");

    // The handler trait.
    let _ = writeln!(s, "trait {}Handler(Movable, Deinitable):", svc.name);
    let _ = writeln!(s, "    \"\"\"The RPCs of `{fq}`: a server implements each.\"\"\"");
    for m in &svc.methods {
        let _ = write!(
            s,
            "\n    def {}[\n        RT: Runtime,\n    ](\n        mut self, mut reactor: Reactor[RT.Sink], var request: {}\n    ) raises -> {}:\n",
            rpc_method_name(&m.name),
            m.input.mojo_name,
            m.output.mojo_name
        );
        let _ = writeln!(s, "        \"\"\"{}.\"\"\"", rule_summary(m));
        s.push_str("        ...\n");
    }
    s.push_str(
        "\n    def error_response(mut self, rpc: String, error: Error) -> HttpResponse:\n\
         \x20       \"\"\"The response for RPC `rpc` (its proto name) when its handler raised `error`.\"\"\"\n\
         \x20       ...\n",
    );

    // The route table.
    let _ = write!(
        s,
        "\n\ndef {snake}_router() raises -> Router:\n    \"\"\"The routes of `{fq}`, one per HTTP binding, as the dispatcher numbers them.\"\"\"\n    var r = Router()\n"
    );
    for (id, r) in routes.iter().enumerate() {
        let _ = writeln!(
            s,
            "    r.add(HttpMethod.{}(), \"{}\", {id})  # {}",
            r.verb, r.pattern, r.method.name
        );
    }
    s.push_str("    return r^\n");

    // One bind function per route.
    for (id, r) in routes.iter().enumerate() {
        emit_bind(s, &snake, id, r);
    }

    // The dispatcher.
    let _ = write!(
        s,
        "\n\nstruct {name}Routes[H: {name}Handler](Movable, RoutedDispatcher):\n\
         \x20   \"\"\"`{fq}` over HTTP: the routes of `{snake}_router()`, each bound and passed to `handler`.\"\"\"\n\n\
         \x20   var handler: Self.H\n\
         \x20   var _router: Router\n\n\
         \x20   def __init__(out self, var handler: Self.H) raises:\n\
         \x20       self.handler = handler^\n\
         \x20       self._router = {snake}_router()\n\n\
         \x20   def has_route(self, method: HttpMethod, path: String) -> Bool:\n\
         \x20       var params = Dict[String, String]()\n\
         \x20       return Bool(self._router.match_route(method, path, params))\n\n\
         \x20   def allowed_methods(self, path: String, mut methods: List[HttpMethod]):\n\
         \x20       methods.extend(self._router.allowed_methods(path))\n\n\
         \x20   def dispatch[\n\
         \x20       RT: Runtime,\n\
         \x20   ](\n\
         \x20       mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest\n\
         \x20   ) raises -> HttpResponse:\n\
         \x20       var params = Dict[String, String]()\n\
         \x20       var hit = self._router.match_route(req.method, req.path, params)\n\
         \x20       if not hit:\n\
         \x20           var allowed = self._router.allowed_methods(req.path)\n\
         \x20           if len(allowed) != 0:\n\
         \x20               return HttpResponse.method_not_allowed(allowed)\n\
         \x20           return HttpResponse.not_found()\n\
         \x20       var route = hit.value()\n",
        name = svc.name
    );
    for (id, r) in routes.iter().enumerate() {
        let m = r.method;
        let _ = write!(
            s,
            "        if route == {id}:\n\
             \x20           var request = Optional[{input}]()\n\
             \x20           try:\n\
             \x20               request = Optional[{input}](_{snake}_bind_{id}(req, params))\n\
             \x20           except:\n\
             \x20               return _route_bad_request(String(\"the request does not bind to {in_fq}\"))\n\
             \x20           var response = Optional[{output}]()\n\
             \x20           try:\n\
             \x20               response = Optional[{output}](\n\
             \x20                   self.handler.{method}[RT](reactor, request.take())\n\
             \x20               )\n\
             \x20           except e:\n\
             \x20               return self.handler.error_response(String(\"{rpc}\"), e)\n\
             \x20           return _route_json(encode_json(response.value()))\n",
            input = m.input.mojo_name,
            output = m.output.mojo_name,
            in_fq = m.input.fq_name.trim_start_matches('.'),
            method = rpc_method_name(&m.name),
            rpc = m.name,
        );
    }
    s.push_str("        return HttpResponse.not_found()\n");
}

fn rule_summary(m: &IrMethod) -> String {
    let mut parts = Vec::new();
    if let Some(rule) = &m.http_rule {
        for r in std::iter::once(rule).chain(rule.additional_bindings.iter()) {
            parts.push(format!("{} {}", r.verb.to_uppercase(), r.path_template));
        }
    }
    format!("{}: {}", m.name, parts.join(", "))
}

fn emit_bind(s: &mut String, snake: &str, id: usize, r: &Route<'_>) {
    let input = &r.method.input.mojo_name;
    let _ = write!(
        s,
        "\n\ndef _{snake}_bind_{id}(\n    req: HttpRequest, params: Dict[String, String]\n) raises -> {input}:\n    \"\"\"{} {}{}: {}.\"\"\"\n",
        r.verb.to_uppercase(),
        r.template,
        if r.body == Body::Whole { ", body *" } else { "" },
        r.method.name
    );
    match r.body {
        Body::Whole => {
            s.push_str("    if len(_route_query(req.query_string)) != 0:\n");
            s.push_str("        raise Error(\"a route with a body takes no query parameters\")\n");
            let _ = writeln!(s, "    var msg = decode_json[{input}](_route_body_text(req))");
        }
        Body::None => {
            s.push_str("    if len(req.body) != 0:\n");
            s.push_str("        raise Error(\"this route takes no body\")\n");
            let _ = writeln!(s, "    var msg = decode_json[{input}](String(\"{{}}\"))");
        }
    }
    for f in &r.path_fields {
        let value = format!("_route_unescape(params[String(\"{}\")], False)", f.name);
        let _ = writeln!(s, "    {}", assign(f, &value));
    }
    if r.body == Body::None && r.query_fields.is_empty() {
        s.push_str("    if len(_route_query(req.query_string)) != 0:\n");
        s.push_str("        raise Error(\"unknown query parameter\")\n");
    } else if r.body == Body::None {
        s.push_str("    var q = _route_query(req.query_string)\n");
        s.push_str("    for i in range(len(q)):\n");
        s.push_str("        ref k = q[i].key\n");
        for (n, f) in r.query_fields.iter().enumerate() {
            let kw = if n == 0 { "if" } else { "elif" };
            let cond = if f.json_name == f.name {
                format!("k == \"{}\"", f.name)
            } else {
                format!("k == \"{}\" or k == \"{}\"", f.json_name, f.name)
            };
            let _ = writeln!(s, "        {kw} {cond}:");
            let _ = writeln!(s, "            {}", assign(f, "String(q[i].value)"));
        }
        s.push_str("        else:\n            raise Error(\"unknown query parameter\")\n");
    }
    s.push_str("    return msg^\n");
}

/// The private helpers every routes module carries.
const HELPERS: &str = r#"@fieldwise_init
struct _RouteQueryParam(Copyable, Movable):
    var key: String
    var value: String


def _route_hex(b: UInt8) raises -> UInt8:
    if b >= UInt8(0x30) and b <= UInt8(0x39):
        return b - UInt8(0x30)
    if b >= UInt8(0x41) and b <= UInt8(0x46):
        return b - UInt8(0x41) + UInt8(10)
    if b >= UInt8(0x61) and b <= UInt8(0x66):
        return b - UInt8(0x61) + UInt8(10)
    raise Error("a percent-escape is not two hex digits")


def _route_unescape(s: String, plus_is_space: Bool) raises -> String:
    """`s` with each `%XX` decoded (and `+` as a space in a query); the result
    must be UTF-8."""
    var bs = s.as_bytes()
    var n = len(bs)
    var out = List[UInt8]()
    var i = 0
    while i < n:
        var c = bs[i]
        if c == UInt8(0x25):
            if i + 2 >= n:
                raise Error("a percent-escape is cut short")
            out.append(_route_hex(bs[i + 1]) * UInt8(16) + _route_hex(bs[i + 2]))
            i += 3
        elif c == UInt8(0x2B) and plus_is_space:
            out.append(UInt8(0x20))
            i += 1
        else:
            out.append(c)
            i += 1
    return String(StringSlice(from_utf8=Span(out)))


def _route_query(qs: String) raises -> List[_RouteQueryParam]:
    """The decoded `key=value` pairs of a query string, in order."""
    var out = List[_RouteQueryParam]()
    if qs.byte_length() == 0:
        return out^
    for part in qs.split("&"):
        var p = String(part)
        if p.byte_length() == 0:
            continue
        var eq = p.find("=")
        if eq < 0:
            out.append(_RouteQueryParam(_route_unescape(p, True), String("")))
        else:
            out.append(
                _RouteQueryParam(
                    _route_unescape(String(p[byte=0:eq]), True),
                    _route_unescape(String(p[byte = eq + 1 : p.byte_length()]), True),
                )
            )
    return out^


def _route_uint64(s: String) raises -> UInt64:
    var bs = s.as_bytes()
    if len(bs) == 0:
        raise Error("an empty number")
    var v = UInt64(0)
    for i in range(len(bs)):
        var c = bs[i]
        if c < UInt8(0x30) or c > UInt8(0x39):
            raise Error("not a decimal number")
        var d = UInt64(c - UInt8(0x30))
        if v > (UInt64(18446744073709551615) - d) // UInt64(10):
            raise Error("a number out of range")
        v = v * UInt64(10) + d
    return v


def _route_int64(s: String) raises -> Int64:
    if s.startswith("-"):
        var m = _route_uint64(String(s[byte=1 : s.byte_length()]))
        if m > UInt64(9223372036854775808):
            raise Error("a number out of range")
        if m == UInt64(9223372036854775808):
            return Int64(-9223372036854775807) - Int64(1)
        return -Int64(m)
    var v = _route_uint64(s)
    if v > UInt64(9223372036854775807):
        raise Error("a number out of range")
    return Int64(v)


def _route_int32(s: String) raises -> Int32:
    var v = _route_int64(s)
    if v < Int64(-2147483648) or v > Int64(2147483647):
        raise Error("a number out of range")
    return Int32(v)


def _route_uint32(s: String) raises -> UInt32:
    var v = _route_uint64(s)
    if v > UInt64(4294967295):
        raise Error("a number out of range")
    return UInt32(v)


def _route_bool(s: String) raises -> Bool:
    if s == "true":
        return True
    if s == "false":
        return False
    raise Error("not true or false")


def _route_body_text(req: HttpRequest) raises -> String:
    """The request body as text; an empty body is `{}`."""
    if len(req.body) == 0:
        return String("{}")
    return String(StringSlice(from_utf8=Span(req.body)))


def _route_text_response(status: Int, content_type: String, text: String) -> HttpResponse:
    var r = HttpResponse(status=Int32(status))
    r.headers[String("content-type")] = String(content_type)
    var b = text.as_bytes()
    for i in range(len(b)):
        r.body.append(b[i])
    r.headers[String("content-length")] = String(len(r.body))
    return r^


def _route_bad_request(reason: String) -> HttpResponse:
    return _route_text_response(400, String("text/plain"), reason)


def _route_json(text: String) -> HttpResponse:
    return _route_text_response(200, String("application/json"), text)
"#;
