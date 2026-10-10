"""The pinned protobuf runtime loads a module the pinned protoc generated, and parses with it.

    protobuf_gencode.py gencode=<version> runtime=<version>

Importing `gencode_probe_pb2` (protoc's `--python_out` for
gencode_probe.proto, staged next to this script) runs the runtime's
`ValidateProtobufRuntimeVersion` on the gencode version the module records,
so a runtime that refuses that gencode fails the import with its
`VersionError`. Then: the module records `gencode` (protoc's Python version),
the runtime is `runtime` with its upb backend, and fixed wire bytes (id 42,
name "kom", packed values 1, 2, 300) parse to those values and serialize back
to the same bytes.
"""

import sys

args = dict(a.split("=", 1) for a in sys.argv[1:])

import google.protobuf  # noqa: E402
from google.protobuf.internal import api_implementation  # noqa: E402

import gencode_probe_pb2 as pb  # noqa: E402

with open(pb.__file__) as f:
    header = [line.rstrip("\n") for line in f if line.startswith("# Protobuf Python Version:")]
want = "# Protobuf Python Version: " + args["gencode"]
assert header == [want], "the generated module records {}, want [{!r}]".format(header, want)
assert google.protobuf.__version__ == args["runtime"], "runtime {}, want {}".format(google.protobuf.__version__, args["runtime"])
assert api_implementation.Type() == "upb", "backend {}, want upb".format(api_implementation.Type())

wire = bytes.fromhex("082a" + "12036b6f6d" + "1a040102ac02")
m = pb.Probe()
m.ParseFromString(wire)
assert m.DESCRIPTOR.full_name == "komira.test.python.Probe", m.DESCRIPTOR.full_name
assert (m.id, m.name, list(m.values)) == (42, "kom", [1, 2, 300]), (m.id, m.name, list(m.values))
assert m.SerializeToString() == wire, m.SerializeToString().hex()
print("protobuf", google.protobuf.__version__, "loaded gencode", args["gencode"], "and parsed", (m.id, m.name, list(m.values)))
