//! What every generator in this crate writes, taken together: each emitted
//! Mojo file starts with the `@generated` header, the same inputs give the
//! same bytes, and no text names the host or the build root.
//!
//! The emitters run over small inputs built here. The goldens in
//! `tools/build/tests/functional` hold the text of the large ones.

use prost::Message;
use prost_types::field_descriptor_proto::{Label, Type};
use prost_types::{
    DescriptorProto, FieldDescriptorProto, FileDescriptorProto, MethodDescriptorProto,
    ServiceDescriptorProto,
};

use crate::emit_aws::{
    emit_aws_module, emit_layout_probe, AwsEmitOptions, AwsProvenance, AWS_GENERATOR_VERSION,
};
use crate::header::{GENERATED_TOKEN, PLUGIN_GENERATOR_VERSION};
use crate::overrides::AwsOverrides;
use crate::plugin::CodeGeneratorRequest;

/// `(label, text)` of every file a generator wrote.
type Emitted = Vec<(String, String)>;

fn field(name: &str, number: i32, ty: Type) -> FieldDescriptorProto {
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        label: Some(Label::Optional as i32),
        r#type: Some(ty as i32),
        json_name: Some(name.to_string()),
        ..FieldDescriptorProto::default()
    }
}

/// `example/v1/thing.proto`: a message with two fields, and a service with
/// one unary method over it. `extra_field` adds a third field to the message,
/// so a test can change the input.
fn thing_proto(extra_field: bool) -> FileDescriptorProto {
    let mut fields = vec![field("name", 1, Type::String), field("count", 2, Type::Int32)];
    if extra_field {
        fields.push(field("note", 3, Type::String));
    }
    FileDescriptorProto {
        name: Some("example/v1/thing.proto".to_string()),
        package: Some("example.v1".to_string()),
        syntax: Some("proto3".to_string()),
        message_type: vec![DescriptorProto {
            name: Some("Thing".to_string()),
            field: fields,
            ..DescriptorProto::default()
        }],
        service: vec![ServiceDescriptorProto {
            name: Some("ThingService".to_string()),
            method: vec![MethodDescriptorProto {
                name: Some("GetThing".to_string()),
                input_type: Some(".example.v1.Thing".to_string()),
                output_type: Some(".example.v1.Thing".to_string()),
                ..MethodDescriptorProto::default()
            }],
            ..ServiceDescriptorProto::default()
        }],
        ..FileDescriptorProto::default()
    }
}

fn proto_request(extra_field: bool) -> CodeGeneratorRequest {
    CodeGeneratorRequest {
        file_to_generate: vec!["example/v1/thing.proto".to_string()],
        parameter: Some("package_prefix=example_pkg,default_protocol=grpc,layout_probe=true".into()),
        proto_file: vec![thing_proto(extra_field)],
        compiler_version: None,
    }
}

/// The files `protoc-gen-mojo` writes for [`proto_request`]: the module and
/// the layout probe.
fn proto_files(extra_field: bool) -> Emitted {
    proto_files_for(thing_proto(extra_field))
}

fn proto_files_for(file: FileDescriptorProto) -> Emitted {
    let mut request = proto_request(false);
    request.proto_file = vec![file];
    let response = crate::respond_with_bytes(&request, &request.encode_to_vec());
    assert_eq!(response.error, None, "protoc-gen-mojo refused the fixture");
    response
        .file
        .into_iter()
        .map(|f| (format!("proto/{}", f.name()), f.content().to_string()))
        .collect()
}

/// The awsJson model of one operation, as a botocore `service-2.json`: its
/// input holds five structures, so a module declares enough structs for an
/// emitter that iterates a hash set to put them in another order.
const TINY_MODEL: &str = r#"{"version": "2.0",
    "metadata": {"apiVersion": "2026-10-02", "endpointPrefix": "tiny",
        "jsonVersion": "1.1", "protocol": "json", "serviceFullName": "Tiny",
        "serviceId": "Tiny", "signatureVersion": "v4",
        "targetPrefix": "Tiny", "uid": "tiny-2026-10-02"},
    "operations": {"Op": {"name": "Op",
        "http": {"method": "POST", "requestUri": "/"},
        "input": {"shape": "In"}, "output": {"shape": "Out"}}},
    "shapes": {"In": {"type": "structure", "members": {"Name": {"shape": "S"},
                   "A": {"shape": "A"}, "B": {"shape": "B"}, "C": {"shape": "C"},
                   "D": {"shape": "D"}, "E": {"shape": "E"}}},
               "Out": {"type": "structure", "members": {}},
               "A": {"type": "structure", "members": {"X": {"shape": "S"}}},
               "B": {"type": "structure", "members": {"X": {"shape": "S"}}},
               "C": {"type": "structure", "members": {"X": {"shape": "S"}}},
               "D": {"type": "structure", "members": {"X": {"shape": "S"}}},
               "E": {"type": "structure", "members": {"X": {"shape": "S"}}},
               "S": {"type": "string"}}}"#;

/// The files `aws-client-gen` writes for [`TINY_MODEL`] in each mode, and the
/// layout probe of each.
fn aws_files(model_sha256: &str) -> Emitted {
    let model = crate::json::parse(TINY_MODEL).unwrap();
    let lowering = crate::aws_in::lower_aws_service(
        &model,
        "tiny",
        &["Op".to_string()],
        "tiny.json",
        "aws.tiny",
    )
    .unwrap();
    let mut out = Vec::new();
    for (mode, pure_only) in [("client", false), ("pure", true)] {
        let options = AwsEmitOptions { pure_only, ..AwsEmitOptions::default() };
        let provenance = AwsProvenance { model_key: "tiny/2026-10-02", model_sha256 };
        let emitted = emit_aws_module(
            &lowering,
            &AwsOverrides::empty(),
            "tiny",
            options,
            Some(provenance),
        )
        .unwrap();
        let probe = emit_layout_probe(&emitted, "tiny.tiny").unwrap();
        out.push((format!("aws-{mode}/{}", emitted.path), emitted.source));
        out.push((format!("aws-{mode}/_layout_probe.mojo"), probe));
    }
    out
}

const TINY_OPENAPI: &str = r##"{"openapi": "3.0.0",
    "info": {"title": "Tiny", "version": "1"},
    "paths": {"/things": {"get": {"operationId": "listThings",
        "responses": {"200": {"description": "ok", "content": {"application/json":
            {"schema": {"$ref": "#/components/schemas/Thing"}}}}}}}},
    "components": {"schemas": {"Thing": {"type": "object",
        "properties": {"name": {"type": "string"}}}}}}"##;

/// The files the OpenAPI front-end writes for [`TINY_OPENAPI`], read from
/// `dir`/`tiny.json`.
fn openapi_files(dir: &str) -> Emitted {
    let (files, _notes) =
        crate::generate_from_openapi(TINY_OPENAPI, &format!("{dir}/tiny.json"), "tiny_pkg")
            .unwrap();
    files
        .into_iter()
        .map(|(name, text)| (format!("openapi/{name}"), text))
        .collect()
}

/// A file `path` in `package` with one message `msg` and one service over it.
fn simple_proto(path: &str, package: &str, msg: &str) -> FileDescriptorProto {
    let ty = format!(".{package}.{msg}");
    FileDescriptorProto {
        name: Some(path.to_string()),
        package: Some(package.to_string()),
        syntax: Some("proto3".to_string()),
        message_type: vec![DescriptorProto {
            name: Some(msg.to_string()),
            field: vec![field("name", 1, Type::String), field("count", 2, Type::Int32)],
            ..DescriptorProto::default()
        }],
        service: vec![ServiceDescriptorProto {
            name: Some(format!("{msg}Service")),
            method: vec![MethodDescriptorProto {
                name: Some(format!("Get{msg}")),
                input_type: Some(ty.clone()),
                output_type: Some(ty),
                ..MethodDescriptorProto::default()
            }],
            ..ServiceDescriptorProto::default()
        }],
        ..FileDescriptorProto::default()
    }
}

/// Three independent files, `protoc-gen-mojo` run over the request whose
/// `proto_file` holds them in `proto_order` and whose `file_to_generate`
/// names them in `generate_order` (indices into a, b, c).
fn three_files(proto_order: [usize; 3], generate_order: [usize; 3]) -> Emitted {
    let files = [
        simple_proto("a/a.proto", "a.v1", "Alpha"),
        simple_proto("b/b.proto", "b.v1", "Beta"),
        simple_proto("c/c.proto", "c.v1", "Gamma"),
    ];
    let request = CodeGeneratorRequest {
        file_to_generate: generate_order.iter().map(|&i| files[i].name().to_string()).collect(),
        parameter: Some("package_prefix=example_pkg,default_protocol=grpc,layout_probe=true".into()),
        proto_file: proto_order.iter().map(|&i| files[i].clone()).collect(),
        compiler_version: None,
    };
    let response = crate::respond_with_bytes(&request, &request.encode_to_vec());
    assert_eq!(response.error, None, "protoc-gen-mojo refused the fixture");
    response
        .file
        .into_iter()
        .map(|f| (format!("three/{}", f.name()), f.content().to_string()))
        .collect()
}

fn everything() -> Emitted {
    let mut all = proto_files(false);
    all.extend(three_files([0, 1, 2], [0, 1, 2]));
    all.extend(aws_files(&crate::sha256::hex(TINY_MODEL.as_bytes())));
    all.extend(openapi_files("docs"));
    all
}

#[test]
fn the_same_inputs_give_the_same_bytes() {
    let first = everything();
    let second = everything();
    let labels = |e: &Emitted| e.iter().map(|(l, _)| l.clone()).collect::<Vec<_>>();
    assert_eq!(labels(&first), labels(&second), "the files, in their order");
    for ((label, a), (_, b)) in first.iter().zip(&second) {
        assert_eq!(a, b, "{label} differs between two runs on the same input");
    }
    // The set is what the test claims to cover: a generator that emitted
    // nothing would be equal to itself.
    assert!(first.len() >= 11, "{:?}", labels(&first));
    assert!(first.iter().all(|(_, text)| !text.is_empty()));
}

#[test]
fn every_emitted_file_starts_with_the_generated_token() {
    for (label, text) in everything() {
        let first = text.lines().next().unwrap_or("");
        assert!(
            first.starts_with(&format!("# {GENERATED_TOKEN} ")),
            "{label}: the first line is `{first}`"
        );
        assert!(
            text.lines().take(12).any(|l| l.starts_with(
                "# DO NOT EDIT. Regenerate with `./buck2 run komira//tools/build/gen:regen -- <library target>`. Generated by "
            )),
            "{label}: no do-not-edit line in its header"
        );
    }
}

#[test]
fn the_first_line_names_the_generator() {
    let all = everything();
    let first_of = |label: &str| -> String {
        let (_, text) = all.iter().find(|(l, _)| l == label).unwrap();
        text.lines().next().unwrap().to_string()
    };
    let plugin = |name: &str| format!("# @generated by {name} version {PLUGIN_GENERATOR_VERSION}");
    assert_eq!(first_of("proto/thing.mojo"), plugin("protoc-gen-mojo"));
    assert_eq!(first_of("proto/_layout_probe.mojo"), plugin("protoc-gen-mojo"));
    assert_eq!(first_of("openapi/tiny.mojo"), plugin("protoc-gen-mojo"));
}

#[test]
fn no_emitted_text_names_the_host_or_the_build_root() {
    // The directories this process runs in, when they say anything.
    let here: Vec<String> = [std::env::current_dir().unwrap(), std::env::temp_dir()]
        .iter()
        .map(|p| p.display().to_string())
        .filter(|p| p.len() > 1)
        .collect();
    // The OpenAPI document is read from an absolute directory: the header
    // names its file, not where it was.
    let mut all = everything();
    all.extend(openapi_files("/home/someone/work/buck-out/v2/gen"));
    for (label, text) in &all {
        let fixed = ["/home/", "/Users/", "/root/", "/tmp/", "buck-out", "C:\\"];
        for marker in fixed.iter().copied().chain(here.iter().map(String::as_str)) {
            assert!(!text.contains(marker), "{label} contains `{marker}`");
        }
    }
}

#[test]
fn the_openapi_pin_is_the_file_name_and_the_document_digest() {
    let a = openapi_files("docs");
    let b = openapi_files("/elsewhere/in/the/tree");
    assert_eq!(a, b, "the directory of the document is not an input");
    let text = &a.iter().find(|(l, _)| l == "openapi/tiny.mojo").unwrap().1;
    let want = format!(
        "# input tiny.json sha256:{}\n",
        crate::sha256::hex(TINY_OPENAPI.as_bytes())
    );
    assert!(text.contains(&want), "{text}");
}

#[test]
fn the_proto_header_pins_the_file_and_moves_only_with_it() {
    let pin_line = |files: &Emitted| -> String {
        let (_, text) = files.iter().find(|(l, _)| l == "proto/thing.mojo").unwrap();
        text.lines().nth(1).unwrap().to_string()
    };
    let probe_pin = |files: &Emitted| -> String {
        let (_, text) = files.iter().find(|(l, _)| l == "proto/_layout_probe.mojo").unwrap();
        text.lines().nth(1).unwrap().to_string()
    };
    let base = proto_files(false);
    let changed = proto_files(true);
    assert!(pin_line(&base).starts_with("# input example/v1/thing.proto sha256:"));
    let digest = pin_line(&base).rsplit(':').next().unwrap().to_string();
    assert_eq!(digest.len(), 64);
    assert!(digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    assert_eq!(pin_line(&base), pin_line(&proto_files(false)));
    assert_ne!(pin_line(&base), pin_line(&changed), "a new field is a new input");
    // The probe pins the same input.
    assert_eq!(pin_line(&base), probe_pin(&base));
}

#[test]
fn the_aws_header_pins_the_model_and_the_generator_version() {
    let sha = crate::sha256::hex(TINY_MODEL.as_bytes());
    let files = aws_files(&sha);
    let want_first = format!("# @generated by aws-client-gen version {AWS_GENERATOR_VERSION}");
    let want_pin = format!("# input tiny/2026-10-02 sha256:{sha}");
    for (label, text) in &files {
        let mut lines = text.lines();
        assert_eq!(lines.next(), Some(want_first.as_str()), "{label}");
        assert_eq!(lines.next(), Some(want_pin.as_str()), "{label}");
    }
}

fn by_name(files: Emitted) -> std::collections::BTreeMap<String, String> {
    files.into_iter().collect()
}

#[test]
fn inputs_given_in_another_order_give_the_same_modules() {
    let base = by_name(three_files([0, 1, 2], [0, 1, 2]));
    assert_eq!(base.len(), 4, "three modules and the probe: {:?}", base.keys());
    for proto_order in [[0, 1, 2], [2, 0, 1], [1, 2, 0], [2, 1, 0]] {
        for generate_order in [[0, 1, 2], [2, 1, 0], [1, 0, 2]] {
            let got = by_name(three_files(proto_order, generate_order));
            for module in ["three/a.mojo", "three/b.mojo", "three/c.mojo"] {
                assert_eq!(
                    got[module], base[module],
                    "{module} with proto_file {proto_order:?} and file_to_generate {generate_order:?}"
                );
            }
        }
        // The probe lists its inputs in the order generated: the same request
        // twice is the same probe, whatever order protoc listed the files in.
        assert_eq!(
            by_name(three_files(proto_order, [0, 1, 2]))["three/_layout_probe.mojo"],
            base["three/_layout_probe.mojo"],
            "probe with proto_file {proto_order:?}"
        );
    }
}

#[test]
fn each_module_pins_its_own_file_and_the_probe_pins_all_three() {
    let got = by_name(three_files([0, 1, 2], [0, 1, 2]));
    let pin = |text: &str, n: usize| text.lines().nth(n).unwrap().to_string();
    let a = pin(&got["three/a.mojo"], 1);
    let b = pin(&got["three/b.mojo"], 1);
    let c = pin(&got["three/c.mojo"], 1);
    assert!(a.starts_with("# input a/a.proto sha256:"), "{a}");
    assert!(b.starts_with("# input b/b.proto sha256:"), "{b}");
    assert!(c.starts_with("# input c/c.proto sha256:"), "{c}");
    let digests: std::collections::BTreeSet<&str> =
        [&a, &b, &c].iter().map(|l| l.rsplit(':').next().unwrap()).collect();
    assert_eq!(digests.len(), 3, "three different files, three digests");
    let probe = &got["three/_layout_probe.mojo"];
    assert_eq!([pin(probe, 1), pin(probe, 2), pin(probe, 3)], [a, b, c]);
}

#[test]
fn no_emitted_code_depends_on_source_code_info() {
    use prost_types::source_code_info::Location;
    use prost_types::SourceCodeInfo;
    // Comments on the message (path 4, 0) and on the service (6, 0), as
    // protoc sends them. A generator that turned them into doc comments
    // would change the text and trip this test: it must then also decide
    // whether a comment is an input of the pin (`plugin::InputPins`).
    let plain = thing_proto(false);
    let mut commented = plain.clone();
    commented.source_code_info = Some(SourceCodeInfo {
        location: vec![
            Location {
                path: vec![4, 0],
                span: vec![3, 0, 5, 1],
                leading_comments: Some(" A thing, with a comment.\n".into()),
                ..Location::default()
            },
            Location {
                path: vec![6, 0],
                span: vec![7, 0, 9, 1],
                leading_comments: Some(" The service.\n".into()),
                trailing_comments: Some(" and a trailing one\n".into()),
                ..Location::default()
            },
        ],
    });
    assert_ne!(plain.encode_to_vec(), commented.encode_to_vec());
    assert_eq!(proto_files_for(plain), proto_files_for(commented));
}

#[test]
fn the_openapi_package_init_is_a_header_and_nothing_else() {
    let text = crate::openapi_package_init_text();
    assert_eq!(
        text,
        "# @generated by mojo-gen-openapi version 1\n\
         # DO NOT EDIT. Regenerate with `./buck2 run komira//tools/build/gen:regen -- <library target>`. Generated by mojo-gen-openapi.\n"
    );
}
