//! `protoc-gen-mojo-index`: a protoc plugin that emits the composite-index
//! Terraform file and per-file index manifests.

use std::io::{Read, Write};

use prost::Message;
use komira_proto_codegen::plugin::{
    code_generator_response, CodeGeneratorRequest, CodeGeneratorResponse,
};
use komira_proto_codegen::{generate_index, FEATURE_PROTO3_OPTIONAL};

fn main() -> std::io::Result<()> {
    let mut buf = Vec::new();
    std::io::stdin().read_to_end(&mut buf)?;

    let response = match CodeGeneratorRequest::from_stdin_bytes(&buf) {
        Ok(request) => respond(&request, &buf),
        Err(e) => CodeGeneratorResponse::with_error(format!(
            "protoc-gen-mojo-index: failed to decode CodeGeneratorRequest: {e}"
        )),
    };

    std::io::stdout().write_all(&response.to_stdout_bytes())?;
    Ok(())
}

/// Run the DECODE -> LOWER -> INDEX-EMIT pipeline and build the response.
fn respond(request: &CodeGeneratorRequest, request_bytes: &[u8]) -> CodeGeneratorResponse {
    let fds_bytes = recover_descriptor_set_bytes(request_bytes);
    match generate_index(request, &fds_bytes) {
        Ok(files) => CodeGeneratorResponse {
            error: None,
            supported_features: Some(FEATURE_PROTO3_OPTIONAL),
            file: files
                .into_iter()
                .map(|(name, content)| code_generator_response::File {
                    name: Some(name),
                    content: Some(content),
                })
                .collect(),
        },
        Err(e) => CodeGeneratorResponse::with_error(format!("protoc-gen-mojo-index: {e}")),
    }
}

// The FDS-bytes recovery — byte-identical to `main_db.rs`'s (the
// `(komira.db.*)` options ride the same MessageOptions extension path). See
// `main_db.rs::recover_descriptor_set_bytes` for the full rationale.

#[derive(Clone, PartialEq, Message)]
struct RequestProtoFileBytes {
    #[prost(bytes = "vec", repeated, tag = "15")]
    proto_file: Vec<Vec<u8>>,
}

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorSetBytes {
    #[prost(bytes = "vec", repeated, tag = "1")]
    file: Vec<Vec<u8>>,
}

/// Re-project the raw `CodeGeneratorRequest` stdin bytes into
/// `FileDescriptorSet` bytes that still carry the `(komira.db.*)` options
/// (verbatim sub-message bytes; no lossy prost-types round-trip).
fn recover_descriptor_set_bytes(request_bytes: &[u8]) -> Vec<u8> {
    let projected = match RequestProtoFileBytes::decode(request_bytes) {
        Ok(p) => p,
        Err(_) => return Vec::new(),
    };
    FileDescriptorSetBytes {
        file: projected.proto_file,
    }
    .encode_to_vec()
}
