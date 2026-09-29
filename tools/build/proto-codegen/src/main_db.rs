//! `protoc-gen-mojo-db`: a protoc plugin that emits `<stem>_db.mojo` (a
//! DbStorable implementation) for each input `.proto` declaring a table
//! message.

use std::io::{Read, Write};

use prost::Message;
use komira_proto_codegen::plugin::{
    code_generator_response, CodeGeneratorRequest, CodeGeneratorResponse,
};
use komira_proto_codegen::{generate_db, FEATURE_PROTO3_OPTIONAL};

fn main() -> std::io::Result<()> {
    let mut buf = Vec::new();
    std::io::stdin().read_to_end(&mut buf)?;

    let response = match CodeGeneratorRequest::from_stdin_bytes(&buf) {
        Ok(request) => respond(&request, &buf),
        Err(e) => CodeGeneratorResponse::with_error(format!(
            "protoc-gen-mojo-db: failed to decode CodeGeneratorRequest: {e}"
        )),
    };

    std::io::stdout().write_all(&response.to_stdout_bytes())?;
    Ok(())
}

/// Run the DECODE -> LOWER -> DB-EMIT pipeline and build the response.
///
/// `request` is the prost-types-decoded request (drives LOWER); `request_bytes`
/// are the raw stdin bytes (carry the `(komira.db.*)` options the decode
/// dropped — see `recover_descriptor_set_bytes`).
fn respond(request: &CodeGeneratorRequest, request_bytes: &[u8]) -> CodeGeneratorResponse {
    let fds_bytes = recover_descriptor_set_bytes(request_bytes);
    match generate_db(request, &fds_bytes) {
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
        Err(e) => CodeGeneratorResponse::with_error(format!("protoc-gen-mojo-db: {e}")),
    }
}

/// A minimal prost mirror of the request that copies `proto_file` (tag 15)
/// through as OPAQUE bytes — `prost(bytes)` on a `repeated` field captures the
/// length-delimited sub-message payload VERBATIM, including the
/// `(komira.db.*)` extension bytes that the `prost-types` `FileDescriptorProto`
/// decode would drop.
#[derive(Clone, PartialEq, Message)]
struct RequestProtoFileBytes {
    /// `CodeGeneratorRequest.proto_file` (tag 15), each element captured as the
    /// raw `FileDescriptorProto` wire bytes (no lossy descriptor decode).
    #[prost(bytes = "vec", repeated, tag = "15")]
    proto_file: Vec<Vec<u8>>,
}

/// A `FileDescriptorSet` whose `file` (tag 1) elements are pre-encoded
/// `FileDescriptorProto` bytes, re-emitted verbatim. Encoding this yields a
/// byte stream the `db_options` mirror decodes as a `FileDescriptorSet`.
#[derive(Clone, PartialEq, Message)]
struct FileDescriptorSetBytes {
    #[prost(bytes = "vec", repeated, tag = "1")]
    file: Vec<Vec<u8>>,
}

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
