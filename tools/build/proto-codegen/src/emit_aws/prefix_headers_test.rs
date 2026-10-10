//! The response side of a prefix-header map (`location: headers`) in every
//! REST protocol: set whether or not a header carries the prefix, as
//! botocore's `BaseRestParser._parse_non_payload_attrs` sets it.

use crate::aws_in::lower_aws_service;
use crate::emit_aws::{emit_aws_client, AwsEmitOptions};
use crate::json::parse;
use crate::overrides::AwsOverrides;

/// A one-operation `protocol` model whose output `Out` holds `Meta`, a map
/// of the headers prefixed `x-meta-`, emitted pure with no preamble.
fn emit(protocol: &str) -> String {
    let model = parse(&format!(
        r#"{{"version": "2.0",
            "metadata": {{"apiVersion": "2026-10-06", "endpointPrefix": "tiny",
                "protocol": "{protocol}", "serviceFullName": "Tiny",
                "serviceId": "Tiny", "signatureVersion": "v4",
                "uid": "tiny-2026-10-06"}},
            "operations": {{"Op": {{"name": "Op",
                "http": {{"method": "GET", "requestUri": "/"}},
                "output": {{"shape": "Out"}}}}}},
            "shapes": {{"Out": {{"type": "structure",
                               "members": {{"Meta": {{"shape": "Meta", "location": "headers",
                                                     "locationName": "x-meta-"}}}}}},
                       "Meta": {{"type": "map", "key": {{"shape": "Str"}},
                                "value": {{"shape": "Str"}}}},
                       "Str": {{"type": "string"}}}}}}"#
    ))
    .unwrap();
    let lowering =
        lower_aws_service(&model, "tiny", &["Op".to_string()], "tiny.json", "aws.tiny").unwrap();
    let options = AwsEmitOptions {
        pure_only: true,
        omit_preamble: true,
        ..AwsEmitOptions::default()
    };
    emit_aws_client(&lowering, &AwsOverrides::empty(), "tiny", options)
        .map(|(_, s)| s)
        .unwrap()
}

#[test]
fn a_prefix_header_map_is_set_when_no_header_carries_the_prefix() {
    for protocol in ["rest-json", "rest-xml"] {
        let src = emit(protocol);
        assert!(!src.contains("if len(_ph_meta) > 0:"), "{protocol}:\n{src}");
        let parse = "    var _ph_meta = aws_prefix_headers(resp, String(\"x-meta-\"))\n    \
                     var _pm_meta = Dict[String, String]()\n    \
                     for _i in range(len(_ph_meta)):\n";
        assert_eq!(src.matches(parse).count(), 1, "{protocol}:\n{src}");
    }
}
