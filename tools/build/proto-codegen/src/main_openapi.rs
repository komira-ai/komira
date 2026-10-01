//! `protoc-gen-openapi`: a protoc plugin that emits one OpenAPI v3 document
//! for the request.

use std::io::{Read, Write};

use komira_proto_codegen::http_options::HttpRuleTable;
use komira_proto_codegen::openapi_emit::emit_openapi_files;
use komira_proto_codegen::plugin::{
    code_generator_response, CodeGeneratorRequest, CodeGeneratorResponse,
};
use komira_proto_codegen::{lower, PluginParameters, FEATURE_PROTO3_OPTIONAL};

fn main() -> std::io::Result<()> {
    let mut buf = Vec::new();
    std::io::stdin().read_to_end(&mut buf)?;

    // The raw stdin bytes are threaded into `respond` so the `(google.api.http)`
    // annotation can be recovered — `prost-types` strips the custom
    // `MethodOptions` extension on the typed decode, exactly as the REST + db +
    // routing paths must re-decode it (see `http_options.rs`). Without this the
    // OpenAPI doc would project the Connect-style `POST /Service/Method` paths
    // instead of the real REST routes.
    let response = match CodeGeneratorRequest::from_stdin_bytes(&buf) {
        Ok(request) => respond(&request, &buf),
        Err(e) => CodeGeneratorResponse::with_error(format!(
            "protoc-gen-openapi: failed to decode CodeGeneratorRequest: {e}"
        )),
    };

    std::io::stdout().write_all(&response.to_stdout_bytes())?;
    Ok(())
}

fn respond(request: &CodeGeneratorRequest, request_bytes: &[u8]) -> CodeGeneratorResponse {
    let params = match PluginParameters::parse(request.parameter.as_deref().unwrap_or("")) {
        Ok(p) => p,
        Err(e) => return CodeGeneratorResponse::with_error(format!("protoc-gen-openapi: {e}")),
    };
    if let Err(e) = params.require_only_package_prefix("protoc-gen-openapi") {
        return CodeGeneratorResponse::with_error(format!("protoc-gen-openapi: {e}"));
    }
    let http_rules = match HttpRuleTable::from_request_bytes(request_bytes) {
        Ok(t) => t,
        Err(e) => {
            return CodeGeneratorResponse::with_error(format!(
                "protoc-gen-openapi: {e}"
            ))
        }
    };
    let model = match lower::lower_with_http_rules(
        &request.proto_file,
        &request.file_to_generate,
        &params.package_prefix,
        http_rules,
    ) {
        Ok(m) => m,
        Err(e) => {
            return CodeGeneratorResponse::with_error(format!(
                "protoc-gen-openapi: {e}"
            ))
        }
    };
    CodeGeneratorResponse {
        error: None,
        supported_features: Some(FEATURE_PROTO3_OPTIONAL),
        file: emit_openapi_files(&model)
            .into_iter()
            .map(|(name, content)| code_generator_response::File {
                name: Some(name),
                content: Some(content),
            })
            .collect(),
    }
}
