//! Unit tests of the routes emitter over hand-built IR. What the generated
//! Mojo does is tested by running it: the welded tests of the fixture library
//! in `tools/build/proto-codegen/routes`.

use super::*;
use komira_proto_codegen::ir::{IrFile, IrImport};

fn tref(name: &str) -> TypeRef {
    TypeRef {
        fq_name: format!(".example.v1.{name}"),
        mojo_name: name.to_string(),
    }
}

fn field(name: &str, json: &str, ty: IrType, label: Label) -> IrField {
    IrField {
        name: name.into(),
        ty,
        label,
        proto_field_number: 1,
        json_name: json.into(),
        oneof_index: None,
    }
}

fn s(name: &str) -> IrField {
    field(name, name, IrType::Scalar(ScalarKind::String), Label::Single)
}

fn message(name: &str, fields: Vec<IrField>) -> IrMessage {
    IrMessage {
        name: name.into(),
        mojo_name: name.into(),
        fq_name: format!(".example.v1.{name}"),
        is_map_entry: false,
        fields,
        oneofs: Vec::new(),
    }
}

fn rule(verb: &str, path: &str, body: &str) -> IrHttpRule {
    IrHttpRule {
        verb: verb.into(),
        path_template: path.into(),
        body: body.into(),
        additional_bindings: Vec::new(),
    }
}

fn rpc(name: &str, input: &str, http: Option<IrHttpRule>) -> IrMethod {
    IrMethod {
        name: name.into(),
        input: tref(input),
        output: tref("Thing"),
        client_streaming: false,
        server_streaming: false,
        idempotent: false,
        http_rule: http,
        routing_rule: None,
    }
}

fn service(name: &str, methods: Vec<IrMethod>) -> IrService {
    IrService {
        name: name.into(),
        methods,
        default_host: None,
        host_from_service_config: false,
    }
}

/// `Req` has `name` (string), `id` (int64), `pageSize` (int32), `tags`
/// (repeated string), `score` (double) and `flag` (optional bool).
fn file(services: Vec<IrService>) -> IrFile {
    IrFile {
        proto_path: "example/v1/things.proto".into(),
        proto_package: "example.v1".into(),
        mojo_package: "komira_things".into(),
        messages: vec![
            message(
                "Req",
                vec![
                    s("name"),
                    field("id", "id", IrType::Scalar(ScalarKind::Int64), Label::Single),
                    field("page_size", "pageSize", IrType::Scalar(ScalarKind::Int32), Label::Single),
                    field("tags", "tags", IrType::Scalar(ScalarKind::String), Label::Repeated),
                    field("score", "score", IrType::Scalar(ScalarKind::Double), Label::Single),
                    field("flag", "flag", IrType::Scalar(ScalarKind::Bool), Label::Optional),
                ],
            ),
            message("Thing", vec![s("name")]),
        ],
        enums: Vec::new(),
        services,
        imports: Vec::new(),
    }
}

fn all(model: &IrModel) -> Vec<String> {
    model.files.iter().map(|f| f.proto_path.clone()).collect()
}

fn emit_model(files: Vec<IrFile>) -> Result<Vec<(String, String)>, String> {
    let model = IrModel { files };
    emit_routes(&model, &all(&model))
}

fn emit_one(services: Vec<IrService>) -> Result<String, String> {
    let model = IrModel {
        files: vec![file(services)],
    };
    let mut files = emit_routes(&model, &all(&model))?;
    assert_eq!(files.len(), 1);
    let (name, text) = files.remove(0);
    assert_eq!(name, "things_routes.mojo");
    Ok(text)
}

fn refusal(services: Vec<IrService>) -> String {
    emit_one(services).expect_err("the emitter must refuse this service")
}

fn get(name: &str, path: &str) -> IrMethod {
    rpc(name, "Req", Some(rule("get", path, "")))
}

#[test]
fn a_file_without_services_writes_nothing() {
    let model = IrModel {
        files: vec![file(Vec::new())],
    };
    assert!(emit_routes(&model, &all(&model)).unwrap().is_empty());
}

#[test]
fn every_rpc_of_every_service_is_registered_the_last_included() {
    let text = emit_one(vec![
        service(
            "Alpha",
            vec![
                get("First", "/v1/a"),
                rpc("Second", "Req", Some(rule("post", "/v1/a", "*"))),
                get("Third", "/v1/c/{name}"),
            ],
        ),
        service("Beta", vec![get("Only", "/v1/b"), get("Last", "/v1/b/{id}")]),
    ])
    .unwrap();
    for line in [
        "r.add(HttpMethod.get(), \"/v1/a\", 0)  # First",
        "r.add(HttpMethod.post(), \"/v1/a\", 1)  # Second",
        "r.add(HttpMethod.get(), \"/v1/c/:name\", 2)  # Third",
        "r.add(HttpMethod.get(), \"/v1/b\", 0)  # Only",
        "r.add(HttpMethod.get(), \"/v1/b/:id\", 1)  # Last",
    ] {
        assert!(text.contains(line), "missing `{line}` in:\n{text}");
    }
    for call in ["self.handler.third[RT]", "self.handler.last[RT]", "def last[", "def third["] {
        assert!(text.contains(call), "missing `{call}`");
    }
    assert!(text.contains("trait AlphaHandler(Movable, Deinitable):"));
    assert!(text.contains("struct BetaRoutes[H: BetaHandler](Movable, RoutedDispatcher):"));
}

#[test]
fn static_segments_are_registered_before_variables() {
    let text = emit_one(vec![service(
        "S",
        vec![get("ByName", "/v1/x/{name}"), get("Special", "/v1/x/special")],
    )])
    .unwrap();
    assert!(text.contains("\"/v1/x/special\", 0)  # Special"), "{text}");
    assert!(text.contains("\"/v1/x/:name\", 1)  # ByName"), "{text}");
}

#[test]
fn additional_bindings_are_routes_of_the_same_rpc() {
    let mut r = rule("get", "/v1/things/{name}", "");
    r.additional_bindings.push(rule("post", "/v2/things/{name}", "*"));
    let text = emit_one(vec![service("S", vec![rpc("Get", "Req", Some(r))])]).unwrap();
    assert!(text.contains("get(), \"/v1/things/:name\", 0)  # Get"), "{text}");
    assert!(text.contains("post(), \"/v2/things/:name\", 1)  # Get"), "{text}");
    assert_eq!(text.matches("self.handler.get[RT]").count(), 2);
}

#[test]
fn a_custom_verb_joins_the_last_literal() {
    let text =
        emit_one(vec![service("S", vec![rpc("Search", "Req", Some(rule("post", "/v1/things:search", "*")))])])
            .unwrap();
    assert!(text.contains("r.add(HttpMethod.post(), \"/v1/things:search\", 0)"), "{text}");
}

#[test]
fn path_variables_are_converted_by_field_type() {
    let text = emit_one(vec![service("S", vec![get("Get", "/v1/{name=*}/n/{id}")])]).unwrap();
    assert!(text.contains("\"/v1/:name/n/:id\""), "{text}");
    assert!(text.contains("msg.name = _route_unescape(params[String(\"name\")], False)"), "{text}");
    assert!(
        text.contains("msg.id = _route_int64(_route_unescape(params[String(\"id\")], False))"),
        "{text}"
    );
}

#[test]
fn query_parameters_bind_singular_fields_by_either_name() {
    let text = emit_one(vec![service("S", vec![get("List", "/v1/things/{name}")])]).unwrap();
    assert!(text.contains("if k == \"id\":"), "{text}");
    assert!(text.contains("elif k == \"pageSize\" or k == \"page_size\":"), "{text}");
    assert!(text.contains("msg.page_size = _route_int32(String(q[i].value))"), "{text}");
    assert!(text.contains("msg.flag = Optional[Bool](_route_bool(String(q[i].value)))"), "{text}");
    // The path field, the repeated field and the double are not query fields.
    for absent in ["k == \"name\"", "k == \"tags\"", "k == \"score\""] {
        assert!(!text.contains(absent), "`{absent}` in:\n{text}");
    }
    assert!(text.contains("            raise Error(\"unknown query parameter\")"));
}

#[test]
fn a_body_route_takes_the_whole_body_strictly_and_no_query() {
    let text = emit_one(vec![service("S", vec![rpc("Make", "Req", Some(rule("post", "/v1/things", "*")))])])
        .unwrap();
    assert!(text.contains("var msg = decode_json[Req](_route_body_text(req))"), "{text}");
    assert!(text.contains("raise Error(\"a route with a body takes no query parameters\")"));
    assert!(!text.contains("decode_json_lenient"));
}

#[test]
fn a_wrong_method_on_a_known_path_is_405() {
    let text = emit_one(vec![service("S", vec![get("Get", "/v1/a")])]).unwrap();
    assert!(
        text.contains(
            "var allowed = self._router.allowed_methods(req.path)\n            if len(allowed) != 0:\n                return HttpResponse.method_not_allowed(allowed)"
        ),
        "{text}"
    );
}

#[test]
fn a_dispatcher_says_which_routes_it_has() {
    // What ComposedRoutes asks a service before dispatching to it.
    let text = emit_one(vec![service("S", vec![get("Get", "/v1/a")])]).unwrap();
    assert!(text.contains("from komira_http_server.routing.compose import RoutedDispatcher\n"), "{text}");
    for line in [
        "    def has_route(self, method: HttpMethod, path: String) -> Bool:\n        var params = Dict[String, String]()\n        return Bool(self._router.match_route(method, path, params))\n",
        "    def allowed_methods(self, path: String, mut methods: List[HttpMethod]):\n        methods.extend(self._router.allowed_methods(path))\n",
    ] {
        assert!(text.contains(line), "missing `{line}` in:\n{text}");
    }
}

#[test]
fn types_are_imported_from_their_modules() {
    let mut f = file(vec![service(
        "S",
        vec![IrMethod {
            output: TypeRef {
                fq_name: ".google.protobuf.Empty".into(),
                mojo_name: "Empty".into(),
            },
            ..get("Get", "/v1/a")
        }],
    )]);
    f.imports.push(IrImport {
        module: "komira_wkt".into(),
        symbol: "Empty".into(),
    });
    let text = emit_model(vec![f]).unwrap().remove(0).1;
    assert!(text.contains("from komira_things.things import Req\n"), "{text}");
    assert!(text.contains("from komira_wkt import Empty\n"), "{text}");
}

#[test]
fn refusals_name_the_rpc_and_the_reason() {
    let cases: Vec<(IrMethod, &str)> = vec![
        (rpc("NoRule", "Req", None), "rpc S.NoRule has no (google.api.http) rule"),
        (
            IrMethod {
                server_streaming: true,
                ..get("Watch", "/v1/a")
            },
            "rpc S.Watch: a streaming RPC has no HTTP route",
        ),
        (
            rpc("One", "Req", Some(rule("post", "/v1/a", "name"))),
            "`body: \"name\"` (one field as the body) is not supported",
        ),
        (get("Dotted", "/v1/{name.x}"), "names a nested field"),
        (get("Spans", "/v1/{name=things/*}"), "spans segments"),
        (get("VerbOnVar", "/v1/{name}:go"), "follows a variable or the root"),
        (get("Repeated", "/v1/{tags}"), "`tags` is not a singular string, integer or bool"),
        (get("Double", "/v1/{score}"), "`score` is not a singular string, integer or bool"),
        (get("Missing", "/v1/{nope}"), "path variable `nope` names no field"),
        (get("Elsewhere", "/v1/{x}"), "is not declared in a file being generated"),
    ];
    for (m, want) in cases {
        let m = if m.name == "Elsewhere" {
            IrMethod {
                input: TypeRef {
                    fq_name: ".other.Req".into(),
                    mojo_name: "Req".into(),
                },
                ..m
            }
        } else {
            m
        };
        let err = refusal(vec![service("S", vec![m])]);
        assert!(err.contains(want), "want `{want}`, got `{err}`");
    }
}

#[test]
fn two_routes_the_router_cannot_tell_apart_are_refused() {
    let err = refusal(vec![service("S", vec![get("A", "/v1/x/{name}"), get("B", "/v1/x/{id}")])]);
    assert!(err.contains("GET /v1/x/{name} (A) and GET /v1/x/{id} (B) match the same requests"), "{err}");
    // The same shape under another verb is a different route.
    emit_one(vec![service(
        "S",
        vec![get("A", "/v1/x/{name}"), rpc("B", "Req", Some(rule("delete", "/v1/x/{id}", "")))],
    )])
    .unwrap();
}

#[test]
fn a_generated_name_that_is_a_message_is_refused() {
    let mut f = file(vec![service("Thing", vec![get("Get", "/v1/a")])]);
    f.messages.push(message("ThingRoutes", vec![]));
    let err = emit_model(vec![f]).unwrap_err();
    assert!(err.contains("the generated name `ThingRoutes` is also a message"), "{err}");
}
