//! The protoc plugin-protocol messages, `CodeGeneratorRequest` and
//! `CodeGeneratorResponse` (protobuf's `compiler/plugin.proto`), mirrored with
//! `prost` derives over `prost-types` descriptors.

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
