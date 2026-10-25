//! The protoc plugin-protocol messages, `CodeGeneratorRequest` and
//! `CodeGeneratorResponse` (protobuf's `compiler/plugin.proto`), mirrored with
//! `prost` derives over `prost-types` descriptors.

use std::collections::BTreeMap;

use prost::Message;
use prost_types::FileDescriptorProto;

/// `google.protobuf.compiler.Version` — the protobuf compiler version.
#[derive(Clone, PartialEq, Message)]
pub struct Version {
    #[prost(int32, optional, tag = "1")]
    pub major: Option<i32>,
    #[prost(int32, optional, tag = "2")]
    pub minor: Option<i32>,
    #[prost(int32, optional, tag = "3")]
    pub patch: Option<i32>,
    #[prost(string, optional, tag = "4")]
    pub suffix: Option<String>,
}

/// `google.protobuf.compiler.CodeGeneratorRequest` — the plugin's stdin.
///
/// `proto_file` (tag 15) carries every transitively-needed
/// `FileDescriptorProto` in topological order; `file_to_generate` (tag 1)
/// names the subset the plugin must actually emit for.
#[derive(Clone, PartialEq, Message)]
pub struct CodeGeneratorRequest {
    /// The `.proto` files explicitly listed on the command line — the
    /// generator emits code only for these.
    #[prost(string, repeated, tag = "1")]
    pub file_to_generate: Vec<String>,
    /// The `--mojo_opt` parameter string (`buf.gen.yaml` `opt:` values).
    #[prost(string, optional, tag = "2")]
    pub parameter: Option<String>,
    /// Descriptors for every file in `file_to_generate` AND everything they
    /// import — topologically ordered (importee before importer).
    #[prost(message, repeated, tag = "15")]
    pub proto_file: Vec<FileDescriptorProto>,
    /// The protobuf compiler version.
    #[prost(message, optional, tag = "3")]
    pub compiler_version: Option<Version>,
}

/// `google.protobuf.compiler.CodeGeneratorResponse` — the plugin's stdout.
#[derive(Clone, PartialEq, Message)]
pub struct CodeGeneratorResponse {
    /// If non-empty, code generation failed; protoc prints it and fails.
    #[prost(string, optional, tag = "1")]
    pub error: Option<String>,
    #[prost(uint64, optional, tag = "2")]
    pub supported_features: Option<u64>,
    /// The generated files.
    #[prost(message, repeated, tag = "15")]
    pub file: Vec<code_generator_response::File>,
}

pub mod code_generator_response {
    /// `CodeGeneratorResponse.File` — one generated file.
    #[derive(Clone, PartialEq, ::prost::Message)]
    pub struct File {
        /// The file name, relative to the output directory.
        #[prost(string, optional, tag = "1")]
        pub name: Option<String>,
        /// The file contents.
        #[prost(string, optional, tag = "15")]
        pub content: Option<String>,
    }

    /// `CodeGeneratorResponse.Feature` — the `supported_features` bitmask
    /// values.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    #[repr(u64)]
    pub enum Feature {
        None = 0,
        Proto3Optional = 1,
        SupportsEditions = 2,
    }
}

impl CodeGeneratorRequest {
    /// Decode a request from the protobuf-binary bytes on stdin.
    pub fn from_stdin_bytes(buf: &[u8]) -> Result<Self, prost::DecodeError> {
        Self::decode(buf)
    }
}

impl CodeGeneratorResponse {
    /// A response carrying a single error message — the protoc-plugin-
    /// protocol-correct way to surface a generation failure (protoc prints
    /// the message and fails the build; the plugin process still exits 0).
    ///
    /// Named `with_error` rather than `error` because the `prost::Message`
    /// derive macro generates its own `error` accessor for the optional
    /// `error` field — the two would collide.
    pub fn with_error(message: impl Into<String>) -> Self {
        Self {
            error: Some(message.into()),
            supported_features: None,
            file: Vec::new(),
        }
    }

    /// Encode this response to the protobuf-binary bytes for stdout.
    pub fn to_stdout_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.encoded_len());
        // `encode` to a `Vec` is infallible (the buffer grows).
        self.encode(&mut out).expect("CodeGeneratorResponse encode");
        out
    }
}

/// The sha256 of each input `.proto`, by import path: what a generated
/// file's header pins ([`crate::header`]).
///
/// The digest is of the file's `FileDescriptorProto` bytes without its
/// `source_code_info` (field 9: spans and comments, which no generator reads,
/// so a comment-only edit is not a new input). The bytes carry the
/// `(google.api.http)` and `(komira.db.*)` options that `prost-types` drops
/// on decode, so an annotation-only change moves the digest, when the bytes
/// protoc sent are at hand ([`InputPins::from_request_bytes`],
/// [`InputPins::from_descriptor_set_bytes`]). [`InputPins::from_request`]
/// re-encodes the decoded descriptor instead, which does not carry them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InputPins(BTreeMap<String, String>);

/// A `CodeGeneratorRequest` whose `proto_file` elements (tag 15) are kept as
/// the bytes protoc wrote.
#[derive(Clone, PartialEq, Message)]
struct RequestFileBytes {
    #[prost(bytes = "vec", repeated, tag = "15")]
    proto_file: Vec<Vec<u8>>,
}

/// A `FileDescriptorSet` whose `file` elements (tag 1) are kept as bytes.
#[derive(Clone, PartialEq, Message)]
struct DescriptorSetFileBytes {
    #[prost(bytes = "vec", repeated, tag = "1")]
    file: Vec<Vec<u8>>,
}

/// `FileDescriptorProto.source_code_info`.
const SOURCE_CODE_INFO_FIELD: u64 = 9;

/// `bytes`, a serialized message, without its field 9. A message that does
/// not parse as protobuf wire format is returned as it is.
fn without_source_info(bytes: Vec<u8>) -> Vec<u8> {
    fn varint(b: &[u8], at: &mut usize) -> Option<u64> {
        let mut v = 0u64;
        for shift in (0..70).step_by(7) {
            let byte = *b.get(*at)?;
            *at += 1;
            v |= u64::from(byte & 0x7f).checked_shl(shift)?;
            if byte & 0x80 == 0 {
                return Some(v);
            }
        }
        None
    }
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let start = at;
        let Some(tag) = varint(&bytes, &mut at) else { return bytes };
        let end = match tag & 7 {
            0 => varint(&bytes, &mut at).map(|_| at),
            1 => Some(at + 8),
            2 => varint(&bytes, &mut at).and_then(|n| at.checked_add(usize::try_from(n).ok()?)),
            5 => Some(at + 4),
            _ => None,
        };
        match end {
            Some(e) if e <= bytes.len() => at = e,
            _ => return bytes,
        }
        if tag >> 3 != SOURCE_CODE_INFO_FIELD {
            out.extend_from_slice(&bytes[start..at]);
        }
    }
    out
}

impl InputPins {
    /// Pins from the descriptors as decoded, re-encoded. Options `prost-types`
    /// does not model are not in these bytes.
    pub fn from_request(request: &CodeGeneratorRequest) -> Self {
        let files = request
            .proto_file
            .iter()
            .map(|f| FileDescriptorProto { source_code_info: None, ..f.clone() }.encode_to_vec())
            .collect();
        Self::from_files(request, files)
    }

    /// Pins from the bytes of a `CodeGeneratorRequest`, as protoc wrote them.
    /// Falls back to [`InputPins::from_request`] when they do not decode.
    pub fn from_request_bytes(request: &CodeGeneratorRequest, request_bytes: &[u8]) -> Self {
        match RequestFileBytes::decode(request_bytes) {
            Ok(raw) => Self::from_files(request, raw.proto_file),
            Err(_) => Self::from_request(request),
        }
    }

    /// Pins from the bytes of the `FileDescriptorSet` the db, index and REST
    /// entry points recover from the request, one element per `proto_file`.
    pub fn from_descriptor_set_bytes(request: &CodeGeneratorRequest, set_bytes: &[u8]) -> Self {
        match DescriptorSetFileBytes::decode(set_bytes) {
            Ok(raw) => Self::from_files(request, raw.file),
            Err(_) => Self::from_request(request),
        }
    }

    /// `files[i]` is the bytes of `request.proto_file[i]`; when the counts
    /// differ the pairing is unknown, and the re-encoded descriptors stand in.
    fn from_files(request: &CodeGeneratorRequest, files: Vec<Vec<u8>>) -> Self {
        if files.len() != request.proto_file.len() {
            return Self::from_request(request);
        }
        let files: Vec<Vec<u8>> = files.into_iter().map(without_source_info).collect();
        Self(
            request
                .proto_file
                .iter()
                .zip(&files)
                .map(|(f, bytes)| (f.name().to_string(), crate::sha256::hex(bytes)))
                .collect(),
        )
    }

    /// The digest of `proto_path`, or empty when it is not an input.
    pub fn get(&self, proto_path: &str) -> &str {
        self.0.get(proto_path).map(String::as_str).unwrap_or("")
    }

    /// Record each model file's digest in its `source_sha256`.
    pub fn apply(&self, model: &mut crate::ir::IrModel) {
        for f in &mut model.files {
            f.source_sha256 = self.get(&f.proto_path).to_string();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(name: &str) -> FileDescriptorProto {
        FileDescriptorProto {
            name: Some(name.to_string()),
            package: Some("example.v1".to_string()),
            ..FileDescriptorProto::default()
        }
    }

    fn request(files: Vec<FileDescriptorProto>) -> CodeGeneratorRequest {
        CodeGeneratorRequest {
            file_to_generate: files.iter().map(|f| f.name().to_string()).collect(),
            parameter: None,
            proto_file: files,
            compiler_version: None,
        }
    }

    /// A request's bytes with each file's bytes given, as protoc writes them.
    #[derive(Clone, PartialEq, Message)]
    struct Raw {
        #[prost(bytes = "vec", repeated, tag = "15")]
        proto_file: Vec<Vec<u8>>,
    }

    #[test]
    fn a_pin_is_the_sha256_of_the_file_bytes_by_import_path() {
        let a = file("a/a.proto");
        let b = file("b/b.proto");
        let req = request(vec![a.clone(), b.clone()]);
        let pins = InputPins::from_request(&req);
        assert_eq!(pins.get("a/a.proto"), crate::sha256::hex(&a.encode_to_vec()));
        assert_eq!(pins.get("b/b.proto"), crate::sha256::hex(&b.encode_to_vec()));
        assert_ne!(pins.get("a/a.proto"), pins.get("b/b.proto"));
        assert_eq!(pins.get("c/c.proto"), "");
    }

    #[test]
    fn source_info_is_not_part_of_a_pin() {
        use prost_types::SourceCodeInfo;
        let plain = file("a/a.proto");
        let mut commented = plain.clone();
        commented.source_code_info = Some(SourceCodeInfo { location: vec![] });
        commented.source_code_info.as_mut().unwrap().location.push(
            prost_types::source_code_info::Location {
                leading_comments: Some(" a comment".into()),
                ..Default::default()
            },
        );
        assert_ne!(plain.encode_to_vec(), commented.encode_to_vec());
        let a = request(vec![plain]);
        let b = request(vec![commented]);
        assert_eq!(InputPins::from_request(&a), InputPins::from_request(&b));
        assert_eq!(
            InputPins::from_request_bytes(&a, &a.encode_to_vec()),
            InputPins::from_request_bytes(&b, &b.encode_to_vec())
        );
    }

    #[test]
    fn stripping_leaves_other_fields_and_unparseable_bytes_alone() {
        let plain = file("a/a.proto").encode_to_vec();
        assert_eq!(without_source_info(plain.clone()), plain);
        // field 9, length 1; then an unknown field 99 varint
        let mut with = plain.clone();
        with.extend_from_slice(&[0x4a, 0x01, 0xff]);
        with.extend_from_slice(&[0x98, 0x06, 0x01]);
        let mut want = plain.clone();
        want.extend_from_slice(&[0x98, 0x06, 0x01]);
        assert_eq!(without_source_info(with), want);
        // a length that runs past the end
        let bad = vec![0x4a, 0x09, 0x01];
        assert_eq!(without_source_info(bad.clone()), bad);
    }

    #[test]
    fn the_same_request_pins_the_same_digests() {
        let req = request(vec![file("a/a.proto")]);
        let bytes = req.encode_to_vec();
        assert_eq!(
            InputPins::from_request_bytes(&req, &bytes),
            InputPins::from_request_bytes(&req, &bytes)
        );
    }

    #[test]
    fn an_option_the_decode_drops_still_moves_the_pin() {
        // Field 99 of the file, a varint: an extension `prost-types` does not
        // model, as `(google.api.http)` is on a method.
        let plain = file("a/a.proto").encode_to_vec();
        let mut annotated = plain.clone();
        annotated.extend_from_slice(&[0x98, 0x06, 0x01]);
        let req = request(vec![file("a/a.proto")]);
        let with = Raw { proto_file: vec![annotated.clone()] }.encode_to_vec();
        let without = Raw { proto_file: vec![plain] }.encode_to_vec();
        let decoded = CodeGeneratorRequest::decode(with.as_slice()).unwrap();
        assert_eq!(decoded.proto_file[0].name(), "a/a.proto");
        assert_eq!(
            InputPins::from_request_bytes(&req, &with).get("a/a.proto"),
            crate::sha256::hex(&annotated)
        );
        assert_ne!(
            InputPins::from_request_bytes(&req, &with),
            InputPins::from_request_bytes(&req, &without)
        );
    }

    #[test]
    fn descriptor_set_bytes_pin_each_file_in_order() {
        let a = file("a/a.proto");
        let b = file("b/b.proto");
        let req = request(vec![a.clone(), b.clone()]);
        let set = DescriptorSetFileBytes { file: vec![a.encode_to_vec(), b.encode_to_vec()] }
            .encode_to_vec();
        assert_eq!(InputPins::from_descriptor_set_bytes(&req, &set), InputPins::from_request(&req));
    }

    #[test]
    fn bytes_that_do_not_pair_with_the_files_fall_back_to_the_decoded_descriptors() {
        let a = file("a/a.proto");
        let req = request(vec![a.clone(), file("b/b.proto")]);
        let one = Raw { proto_file: vec![a.encode_to_vec()] }.encode_to_vec();
        assert_eq!(InputPins::from_request_bytes(&req, &one), InputPins::from_request(&req));
        assert_eq!(InputPins::from_request_bytes(&req, &[0xff]), InputPins::from_request(&req));
    }
}
