"""The generated plan modules (`komira.plan.v1`) under one protobuf runtime.

    test_plan_pb2.py --golden <dir> --requirement <requirement>
                     --runtime <version> --edge lower|upper|below

`--golden` is the directory of plan_wire's goldens: for each plan, `<stem>.hex`
(plan_wire's own encoding), `<stem>.canonical.hex` (protoc's encoding of the
same message, which plan_wire's golden test decodes back to the same plan) and
`<stem>.txtpb` (protoc's text of it). `--requirement` is the range the package
declares (`protobuf>=<x.y.z>,<<major>`), `--runtime` the version of the protobuf
the target installs, and `--edge` which edge of the range that runtime is:

- `lower` and `upper`: the runtime is in the range, at its lowest version or
  in its newest major. The modules load, every golden decodes from both
  encodings to one message, which its text parses to as well and which encodes
  to exactly protoc's bytes; a plan built through the Python API encodes to
  protoc's bytes of the `scan` golden; that golden cut short is refused.
- `below`: the runtime is older than the range, and importing the modules must
  fail with the runtime's version error naming the gencode's version and its
  own.

In every case the range must start at the version of the gencode, the oldest
runtime the gencode's own check admits.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODULES = os.path.join(HERE, "komira", "plan", "v1")

# The protoc gencode's call of the runtime check, which carries the version of
# the protoc that wrote it.
_GENCODE_CHECK = re.compile(
    r"ValidateProtobufRuntimeVersion\(\s*_runtime_version\.Domain\.PUBLIC,"
    r"\s*(\d+),\s*(\d+),\s*(\d+),\s*'',\s*'komira/plan/v1/([a-z_]+)\.proto'\s*\)"
)

_REQUIREMENT = re.compile(r"protobuf>=(\d+\.\d+\.\d+),<(\d+)")


def version(text):
    """`x.y.z` as a tuple of three ints."""
    parts = text.split(".")
    assert len(parts) == 3 and all(p.isdigit() for p in parts), f"{text} is not a version x.y.z"
    return tuple(int(p) for p in parts)


def spell(v):
    return ".".join(str(p) for p in v)


def gencode_version():
    """The version each generated module was written for; they must agree."""
    found = {}
    for module in ("plan_pb2", "plan_vocabulary_pb2"):
        with open(os.path.join(MODULES, module + ".py"), encoding="utf-8") as f:
            checks = _GENCODE_CHECK.findall(f.read())
        assert len(checks) == 1, f"{module}.py holds {len(checks)} runtime checks, not one"
        major, minor, patch, stem = checks[0]
        assert stem + "_pb2" == module, f"{module}.py checks the runtime for {stem}.proto"
        found[module] = (int(major), int(minor), int(patch))
    assert found["plan_pb2"] == found["plan_vocabulary_pb2"], f"the modules were generated for different versions: {found}"
    return found["plan_pb2"]


def read_hex(path):
    with open(path, encoding="ascii") as f:
        return bytes.fromhex(f.read())


def golden_stems(golden):
    """Every plan of the golden directory, each with its three files."""
    names = set(os.listdir(golden))
    suffix = ".canonical.hex"
    stems = sorted(n[: -len(suffix)] for n in names if n.endswith(suffix))
    assert stems, f"{golden} holds no <stem>{suffix}"
    want = {s + ext for s in stems for ext in (".hex", suffix, ".txtpb")}
    assert names == want, f"{golden}: files without the other two of their plan: {sorted(names ^ want)}"
    assert "scan" in stems, f"{golden} has no scan golden"
    return stems


def check_goldens(golden, plan_pb2, text_format):
    for stem in golden_stems(golden):
        ours = read_hex(os.path.join(golden, stem + ".hex"))
        theirs = read_hex(os.path.join(golden, stem + ".canonical.hex"))
        with open(os.path.join(golden, stem + ".txtpb"), encoding="utf-8") as f:
            text = f.read()
        from_ours = plan_pb2.WirePlanEnvelope.FromString(ours)
        from_theirs = plan_pb2.WirePlanEnvelope.FromString(theirs)
        assert from_ours == from_theirs, f"{stem}: plan_wire's bytes and protoc's decode to different messages"
        from_text = text_format.Parse(text, plan_pb2.WirePlanEnvelope())
        assert from_text == from_theirs, f"{stem}: the text and protoc's bytes are different messages"
        for source, message in (("plan_wire's", from_ours), ("protoc's", from_theirs)):
            encoded = message.SerializeToString(deterministic=True)
            assert encoded == theirs, (
                f"{stem}: the message decoded from {source} bytes encodes to {len(encoded)} bytes"
                f" that are not protoc's {len(theirs)}"
            )


def scan_envelope(plan_pb2, vocabulary):
    """The `scan` golden's plan, built through the Python API."""

    def schema():
        return plan_pb2.WireSchema(
            fields=[
                plan_pb2.WireField(
                    name="a",
                    arrow_type_id=5,
                    dtype_code=vocabulary._DT_INT64,
                    dict_index_type_id=4,
                    metadata_keys=["unit"],
                    metadata_values=["cents"],
                ),
                plan_pb2.WireField(
                    name="b",
                    arrow_type_id=5,
                    dtype_code=vocabulary._DT_INT64,
                    nullable=True,
                    dict_index_type_id=4,
                ),
                plan_pb2.WireField(name="s", arrow_type_id=13, nullable=True, dict_index_type_id=4),
            ]
        )

    binding = plan_pb2.WireScanBinding(
        kind_id=1056219456,
        kind_name="komira.orc",
        name="orders",
        params=[
            plan_pb2.WireParam(key="has_footer", tag=vocabulary.PARAM_BOOL, i=1),
            plan_pb2.WireParam(key="path", tag=vocabulary.PARAM_STR, s="/data/orders.orc"),
            plan_pb2.WireParam(key="stripe_count", tag=vocabulary.PARAM_I64, i=7),
        ],
        schema=schema(),
        fingerprint=3735928559,
        structural_id=4277009102,
        pushdown_gate=plan_pb2.WirePushdownGate(
            mode=vocabulary.GATE_SHAPED,
            allowed_binary_ops=63,
            allow_and_recurse=True,
            allow_in_list=True,
            require_stat_friendly_col=True,
        ),
        snapshot_policy=vocabulary.SNAPSHOT_PINNED,
        snapshot_token=1234567890,
        orientation=vocabulary.SOURCE_KIND_COLUMNAR,
        variant_tag=vocabulary.SOURCE_VARIANT_ORC,
    )
    envelope = plan_pb2.WirePlanEnvelope(format_version=4)
    envelope.plan.output_schema.CopyFrom(schema())
    envelope.plan.scan.source.binding.CopyFrom(binding)
    envelope.plan.scan.has_schema = True
    envelope.plan.scan.schema.CopyFrom(schema())
    envelope.plan.scan.source_kind = vocabulary.SOURCE_KIND_COLUMNAR
    return envelope


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--golden", required=True)
    parser.add_argument("--requirement", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--edge", required=True, choices=["lower", "upper", "below"])
    args = parser.parse_args(argv)

    gencode = gencode_version()

    import google.protobuf

    runtime = version(google.protobuf.__version__)
    assert runtime == version(args.runtime), (
        f"the runtime is protobuf {google.protobuf.__version__}, the target names {args.runtime}"
    )

    match = _REQUIREMENT.fullmatch(args.requirement)
    assert match, f"{args.requirement} is not protobuf>=<x.y.z>,<<major>"
    lower, upper_major = version(match.group(1)), int(match.group(2))
    # The gencode's check refuses a runtime older than the gencode, so a range
    # starting lower admits runtimes that cannot load the modules, and one
    # starting higher refuses runtimes that can.
    assert lower == gencode, (
        f"{args.requirement} starts at {spell(lower)}, not at {spell(gencode)}, the version of the gencode"
    )

    if args.edge == "below":
        assert runtime < lower, f"protobuf {spell(runtime)} is not below {args.requirement}"
        from google.protobuf import runtime_version

        try:
            import komira.plan.v1.plan_pb2  # noqa: F401
        except runtime_version.VersionError as e:
            refusal = str(e)
        else:
            raise AssertionError(f"protobuf {spell(runtime)} loaded the gencode of {spell(gencode)}")
        want = (
            "Detected incompatible Protobuf Gencode/Runtime versions when loading"
            f" komira/plan/v1/plan.proto: gencode {spell(gencode)} runtime {spell(runtime)}."
            " Runtime version cannot be older than the linked gencode version."
        )
        assert refusal.startswith(want), f"the refusal is {refusal!r}, not {want!r}"
        return

    assert lower <= runtime < (upper_major, 0, 0), f"protobuf {spell(runtime)} is not in {args.requirement}"
    if args.edge == "lower":
        assert runtime == lower, f"protobuf {spell(runtime)} is not the lower edge of {args.requirement}"
    else:
        assert runtime[0] == upper_major - 1, (
            f"protobuf {spell(runtime)} is not of {upper_major - 1}, the newest major of {args.requirement}"
        )

    from google.protobuf import message, text_format
    from google.protobuf.internal import api_implementation

    import komira.plan.v1.plan_pb2 as plan_pb2
    import komira.plan.v1.plan_vocabulary_pb2 as vocabulary

    # The binary wheel's implementation, the one the release platforms install.
    assert api_implementation.Type() == "upb", f"protobuf runs its {api_implementation.Type()} implementation, not upb"

    check_goldens(args.golden, plan_pb2, text_format)

    scan = read_hex(os.path.join(args.golden, "scan.canonical.hex"))
    built = scan_envelope(plan_pb2, vocabulary).SerializeToString(deterministic=True)
    assert built == scan, f"the scan built through the API encodes to {len(built)} bytes that are not protoc's {len(scan)}"

    # Cut after the plan field's tag (before its length), inside the plan,
    # and one byte short of the end.
    assert scan[2] == 0x12, f"the scan golden's third byte is {scan[2]:#x}, not the plan field's tag"
    for keep in (3, len(scan) // 2, len(scan) - 1):
        try:
            plan_pb2.WirePlanEnvelope.FromString(scan[:keep])
        except message.DecodeError:
            continue
        raise AssertionError(f"the first {keep} of the scan golden's {len(scan)} bytes decoded")


if __name__ == "__main__":
    main(sys.argv[1:])
