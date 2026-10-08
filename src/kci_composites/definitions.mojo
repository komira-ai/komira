# =============================================================================
# kci_composites/definitions.mojo: the definition files kci ships, and their
#   reader.
# =============================================================================
#
# Each file is one `CompositeDefinition` in proto3 JSON. `read_kci_definitions`
# reads it as a resource of the running program (`komira_resources`: a test
# declares it in `test_data`, a shipped program in its bundle's `data`) and
# decodes it with `decode_json`, which refuses an unknown field or enum name:
# the same strict reading as an author's file. What the definitions may hold
# is composite.proto's; the `kci` namespace rule (only these, by name,
# version and digest) is kci_cloud's compose_kci.mojo.
# =============================================================================

from komira_proto_codec import decode_json
from komira_resources import read_resource
from kci_resource_proto.composite import CompositeDefinition


comptime KCI_DEFINITIONS_DIR = "src/kci_composites/definitions"
"""Where the files are, as resource names (their repository paths)."""


def kci_definition_files() -> List[String]:
    """Every definition file kci ships, as a resource name, in order:
    `kci.job`, then `kci.app`."""
    var l = List[String]()
    l.append(String(KCI_DEFINITIONS_DIR) + String("/kci.job.json"))
    l.append(String(KCI_DEFINITIONS_DIR) + String("/kci.app.json"))
    return l^


def read_kci_definitions() raises -> List[CompositeDefinition]:
    """Every definition kci ships, read and decoded strictly. Raises,
    naming the file, when one is not declared for this program or does not
    decode."""
    var out = List[CompositeDefinition]()
    var files = kci_definition_files()
    for i in range(len(files)):
        try:
            out.append(decode_json[CompositeDefinition](read_resource(files[i])))
        except e:
            raise Error(String("kci_composites: ") + files[i] + String(": ") + String(e))
    return out^
