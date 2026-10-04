//! Decoding the `(google.api.default_host)` service option, the host a
//! generated REST client starts at.
//!
//! googleapis declares it in `google/api/client.proto`:
//! `extend google.protobuf.ServiceOptions { string default_host = 1049; }`.
//! `prost-types` drops an extension on its typed decode, so (like the `http`
//! and `routing` annotations) it is read back out of the raw descriptor bytes.

use std::collections::BTreeMap;

use prost::Message;

// ===========================================================================
// The prost mirror: only the descriptor fields the option rides on. The
// structural tags mirror `descriptor.proto`; the extension tag mirrors
// `google/api/client.proto`.
// ===========================================================================

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorSetMirror {
    #[prost(message, repeated, tag = "1")]
    file: Vec<FileDescriptorProtoMirror>,
}

/// The `CodeGeneratorRequest` wire shape, just enough to recover its
/// `proto_file` set (tag 15).
#[derive(Clone, PartialEq, Message)]
struct CodeGeneratorRequestMirror {
    #[prost(message, repeated, tag = "15")]
    proto_file: Vec<FileDescriptorProtoMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct FileDescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    #[prost(string, optional, tag = "2")]
    package: Option<String>,
    // FileDescriptorProto.service = 6.
    #[prost(message, repeated, tag = "6")]
    service: Vec<ServiceDescriptorProtoMirror>,
}

#[derive(Clone, PartialEq, Message)]
struct ServiceDescriptorProtoMirror {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    // ServiceDescriptorProto.options = 3.
    #[prost(message, optional, tag = "3")]
    options: Option<ServiceOptionsExt>,
}

#[derive(Clone, PartialEq, Message)]
struct ServiceOptionsExt {
    // `google.api.default_host`.
    #[prost(string, optional, tag = "1049")]
    default_host: Option<String>,
}

/// The recovered `(google.api.default_host)` of every service that declares
/// one, keyed by `(proto package, service name)`: the identity the IR
/// exposes as `IrFile.proto_package` and `IrService.name`. The package is in
/// the key so two packages' services of one name keep their own hosts.
#[derive(Clone, Debug, Default)]
pub struct DefaultHostTable {
    hosts: BTreeMap<(String, String), String>,
}

impl DefaultHostTable {
    /// Decode the option out of a `FileDescriptorSet`'s raw bytes.
    pub fn from_descriptor_set_bytes(bytes: &[u8]) -> Result<Self, String> {
        let fds = FileDescriptorSetMirror::decode(bytes)
            .map_err(|e| format!("service_options: decode FileDescriptorSet: {e}"))?;
        Ok(Self::from_files(&fds.file))
    }

    /// Decode the option out of a `CodeGeneratorRequest`'s raw bytes (the
    /// plugin's stdin), whose `proto_file` set carries the same descriptors.
    pub fn from_request_bytes(bytes: &[u8]) -> Result<Self, String> {
        let req = CodeGeneratorRequestMirror::decode(bytes)
            .map_err(|e| format!("service_options: decode CodeGeneratorRequest: {e}"))?;
        Ok(Self::from_files(&req.proto_file))
    }

    fn from_files(files: &[FileDescriptorProtoMirror]) -> Self {
        let mut table = DefaultHostTable::default();
        for file in files {
            let pkg = file.package.clone().unwrap_or_default();
            for svc in &file.service {
                let Some(name) = &svc.name else { continue };
                let Some(host) = svc.options.as_ref().and_then(|o| o.default_host.as_ref())
                else {
                    continue;
                };
                // Recorded as declared, an empty value included: the emitter
                // judges the value, so a declared-but-unusable host is refused
                // by name rather than read as no declaration.
                table.hosts.insert((pkg.clone(), name.clone()), host.clone());
            }
        }
        table
    }

    /// The declared host of `package.service`, if it declares one.
    pub fn host_for(&self, package: &str, service: &str) -> Option<&str> {
        self.hosts
            .get(&(package.to_string(), service.to_string()))
            .map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn svc(name: &str, host: Option<&str>) -> ServiceDescriptorProtoMirror {
        ServiceDescriptorProtoMirror {
            name: Some(name.into()),
            options: host.map(|h| ServiceOptionsExt {
                default_host: Some(h.into()),
            }),
        }
    }

    fn set_bytes(files: Vec<FileDescriptorProtoMirror>) -> Vec<u8> {
        FileDescriptorSetMirror { file: files }.encode_to_vec()
    }

    #[test]
    fn empty_bytes_is_empty_table() {
        let t = DefaultHostTable::from_descriptor_set_bytes(&[]).unwrap();
        assert!(t.host_for("google.logging.v2", "LoggingServiceV2").is_none());
    }

    #[test]
    fn recovers_the_host_per_package_and_service() {
        let bytes = set_bytes(vec![
            FileDescriptorProtoMirror {
                name: Some("google/logging/v2/logging.proto".into()),
                package: Some("google.logging.v2".into()),
                service: vec![svc("LoggingServiceV2", Some("logging.googleapis.com"))],
            },
            FileDescriptorProtoMirror {
                name: Some("other/v1/svc.proto".into()),
                package: Some("other.v1".into()),
                service: vec![svc("LoggingServiceV2", None), svc("Plain", None)],
            },
        ]);
        let t = DefaultHostTable::from_descriptor_set_bytes(&bytes).unwrap();
        assert_eq!(
            t.host_for("google.logging.v2", "LoggingServiceV2"),
            Some("logging.googleapis.com")
        );
        // Same service name, other package, no option: no host.
        assert!(t.host_for("other.v1", "LoggingServiceV2").is_none());
        assert!(t.host_for("other.v1", "Plain").is_none());
    }

    #[test]
    fn recovers_from_a_code_generator_request() {
        let bytes = CodeGeneratorRequestMirror {
            proto_file: vec![FileDescriptorProtoMirror {
                name: Some("a.proto".into()),
                package: Some("a".into()),
                service: vec![svc("S", Some("s.googleapis.com"))],
            }],
        }
        .encode_to_vec();
        let t = DefaultHostTable::from_request_bytes(&bytes).unwrap();
        assert_eq!(t.host_for("a", "S"), Some("s.googleapis.com"));
    }

    #[test]
    fn a_declared_empty_host_is_kept_for_the_emitter_to_refuse() {
        let bytes = set_bytes(vec![FileDescriptorProtoMirror {
            name: Some("a.proto".into()),
            package: Some("a".into()),
            service: vec![svc("S", Some(""))],
        }]);
        let t = DefaultHostTable::from_descriptor_set_bytes(&bytes).unwrap();
        assert_eq!(t.host_for("a", "S"), Some(""));
    }
}
