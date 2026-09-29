//! `protoc-gen-mojo`: a protoc plugin. Reads a `CodeGeneratorRequest` on
//! stdin and writes a `CodeGeneratorResponse` on stdout holding one
//! `<stem>.mojo` per input `.proto`. A generation error is reported in the
//! response's `error` field.

use std::io::{Read, Write};

use komira_proto_codegen::plugin::{CodeGeneratorRequest, CodeGeneratorResponse};
use komira_proto_codegen::respond_with_bytes;

fn main() -> std::io::Result<()> {
    // [1] Read the whole CodeGeneratorRequest off stdin.
    let mut buf = Vec::new();
    std::io::stdin().read_to_end(&mut buf)?;

    let response = match CodeGeneratorRequest::from_stdin_bytes(&buf) {
        Ok(request) => {
            // [2] LOWER + [3] EMIT — the library does the pipeline. The raw
            // stdin bytes are passed through so a `rest` target can recover
            // the `(google.api.http)` annotation prost strips on decode.
            respond_with_bytes(&request, &buf)
        }
        Err(e) => {
            // A request that does not decode — surfaced through the
            // protocol's `error` field.
            CodeGeneratorResponse::with_error(format!(
                "protoc-gen-mojo: failed to decode CodeGeneratorRequest: {e}"
            ))
        }
    };

    std::io::stdout().write_all(&response.to_stdout_bytes())?;
    Ok(())
}
