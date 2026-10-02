# =============================================================================
# src/kci_artifact_declaration/tests/test_declaration_parse.mojo
#   Read a declarations file, round-trip it on the wire, refuse what the
#   parser refuses.
# =============================================================================
#
# A control case parses a file holding every kind and reads every field
# back, so each refusal below is caused by its one change. The wire round
# trip encodes the parsed value and decodes it: every field must survive.
# A round trip cannot see a renumbered field (encoder and decoder move
# together), so each kind arm's field number is also pinned as bytes, and
# with it the KIND_* discriminants the validator reads.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_proto_codec import decode_proto, encode_proto

from kci_artifact_declaration_proto.artifact_declaration import (
    ArtifactDeclaration,
    ArtifactDeclarations,
    CondaMetapackage,
    CondaPackage,
    OciImage,
    PythonWheel,
)
from kci_artifact_declaration import (
    KIND_CONDA_METAPACKAGE,
    KIND_CONDA_PACKAGE,
    KIND_OCI_IMAGE,
    KIND_PYTHON_WHEEL,
    artifact_type,
    buck2_label,
    build_order,
    kind_name,
    members_of,
    parse_artifact_declarations,
)


def _conda(name: String, extra: String) -> String:
    return (
        String("artifact {\n  name: \"")
        + name
        + String("\"\n  allowed_channels: \"public\"\n  conda_package {\n")
        + String("    build { buck2 { label: \"//src/")
        + name
        + String(":")
        + name
        + String("_conda\" } }\n    subdirs: \"linux-64\"\n")
        + extra
        + String("  }\n}\n")
    )


def _file() -> String:
    return (
        String("# every kind, members first in no particular order\n")
        + _conda(String("app_core"), String("    depends_on: \"base_lib\"\n    member_of: \"suite\"\n"))
        + _conda(String("base_lib"), String("    member_of: \"suite\"\n"))
        + String("artifact {\n  name: \"suite\"\n  allowed_channels: \"public\"\n")
        + String("  conda_metapackage {\n    packer { buck2 { label: \"//tools/pack:pack\" } }\n")
        + String("    subdirs: \"linux-64\"\n  }\n}\n")
        + String("artifact {\n  name: \"front_end\"\n  allowed_channels: \"public\"\n")
        + String("  allowed_channels: \"internal\"\n")
        + String("  python_wheel { build { buck2 { label: \"cell//py/front:wheel\" } } }\n}\n")
        + String("artifact {\n  name: \"server\"\n  allowed_channels: \"internal\"\n")
        + String("  oci_image: { build: { buck2: { label: \"//images:server\" } } }\n}\n")
    )


def _refusal(text: String) -> String:
    try:
        _ = parse_artifact_declarations(text, String("decl.textproto"))
    except e:
        return String(e)
    return String("<parsed>")


def test_control_file_parses_every_kind() raises:
    var d = parse_artifact_declarations(_file(), String("decl.textproto"))
    assert_equal(len(d.artifact), 5)
    ref a = d.artifact[0]
    assert_equal(a.name, String("app_core"))
    assert_equal(kind_name(a), String("conda_package"))
    assert_equal(artifact_type(a), String("CONDA"))
    assert_equal(buck2_label(a), String("//src/app_core:app_core_conda"))
    assert_equal(a.conda_package.value().subdirs[0], String("linux-64"))
    assert_equal(a.conda_package.value().depends_on[0], String("base_lib"))
    assert_equal(a.conda_package.value().member_of, String("suite"))
    assert_equal(kind_name(d.artifact[2]), String("conda_metapackage"))
    assert_equal(artifact_type(d.artifact[2]), String("CONDA"))
    assert_equal(buck2_label(d.artifact[2]), String("//tools/pack:pack"))
    assert_equal(kind_name(d.artifact[3]), String("python_wheel"))
    assert_equal(artifact_type(d.artifact[3]), String("PYTHON"))
    assert_equal(buck2_label(d.artifact[3]), String("cell//py/front:wheel"))
    assert_equal(len(d.artifact[3].allowed_channels), 2)
    assert_equal(kind_name(d.artifact[4]), String("oci_image"))
    assert_equal(artifact_type(d.artifact[4]), String("OCI"))
    assert_equal(buck2_label(d.artifact[4]), String("//images:server"))
    var members = members_of(d, String("suite"))
    assert_equal(len(members), 2)
    assert_equal(members[0], String("app_core"))
    assert_equal(members[1], String("base_lib"))


def test_build_order_puts_dependencies_and_members_first() raises:
    var d = parse_artifact_declarations(_file(), String("decl.textproto"))
    var order = build_order(d)
    assert_equal(len(order), 5)
    assert_equal(order[0], String("base_lib"))
    assert_equal(order[1], String("app_core"))
    assert_equal(order[2], String("suite"))
    assert_equal(order[3], String("front_end"))
    assert_equal(order[4], String("server"))


def test_parsed_value_round_trips_on_the_wire() raises:
    var d = parse_artifact_declarations(_file(), String("decl.textproto"))
    var back = decode_proto[ArtifactDeclarations](encode_proto[ArtifactDeclarations](d))
    assert_equal(len(back.artifact), len(d.artifact))
    for i in range(len(d.artifact)):
        assert_equal(back.artifact[i].name, d.artifact[i].name)
        assert_equal(kind_name(back.artifact[i]), kind_name(d.artifact[i]))
        assert_equal(buck2_label(back.artifact[i]), buck2_label(d.artifact[i]))
        assert_equal(
            len(back.artifact[i].allowed_channels), len(d.artifact[i].allowed_channels)
        )
        for k in range(len(d.artifact[i].allowed_channels)):
            assert_equal(back.artifact[i].allowed_channels[k], d.artifact[i].allowed_channels[k])
    ref a = back.artifact[0].conda_package.value()
    assert_equal(a.subdirs[0], String("linux-64"))
    assert_equal(a.depends_on[0], String("base_lib"))
    assert_equal(a.member_of, String("suite"))
    assert_equal(back.artifact[2].conda_metapackage.value().subdirs[0], String("linux-64"))


def _only_kind_bytes(var d: ArtifactDeclaration) raises -> List[UInt8]:
    return encode_proto[ArtifactDeclaration](d)


def test_kind_field_numbers_and_discriminants_are_pinned() raises:
    # An artifact with only a kind arm set carries that arm's tag
    # (field << 3 | 2: 10 -> 0x52, 11 -> 0x5a, 12 -> 0x62, 13 -> 0x6a). Decoding it sets the discriminant the
    # validator reads as KIND_*.
    var none = List[String]()
    var tags = List[UInt8]()
    tags.append(0x52)
    tags.append(0x5A)
    tags.append(0x62)
    tags.append(0x6A)
    var kinds = List[Int]()
    kinds.append(KIND_CONDA_PACKAGE)
    kinds.append(KIND_CONDA_METAPACKAGE)
    kinds.append(KIND_PYTHON_WHEEL)
    kinds.append(KIND_OCI_IMAGE)
    for k in range(4):
        var d = ArtifactDeclaration(
            String(""),
            none.copy(),
            kinds[k],
            Optional(CondaPackage(None, none.copy(), none.copy(), String(""))),
            Optional(CondaMetapackage(None, none.copy())),
            Optional(PythonWheel(None, none.copy())),
            Optional(OciImage(None)),
        )
        var b = _only_kind_bytes(d^)
        # The arm's tag appears once and no other arm's does. (The bodies
        # hold only tags of fields 1..4, 0x0a..0x22, and zero lengths, so a
        # byte scan cannot mistake one for a kind tag.)
        for t in range(4):
            var seen = 0
            for i in range(len(b)):
                if b[i] == tags[t]:
                    seen += 1
            assert_equal(seen, 1 if t == k else 0)
        var back = decode_proto[ArtifactDeclaration](b^)
        assert_equal(back._oneof0_case, kinds[k])


def test_name_and_channels_field_numbers_are_pinned() raises:
    var chans = List[String]()
    chans.append(String("p"))
    var d = ArtifactDeclaration(String("a"), chans^, 0, None, None, None, None)
    var b = encode_proto[ArtifactDeclaration](d)
    # field 1 "a", then field 2 "p".
    assert_equal(len(b), 6)
    assert_equal(b[0], UInt8(0x0A))
    assert_equal(b[2], UInt8(0x61))
    assert_equal(b[3], UInt8(0x12))
    assert_equal(b[5], UInt8(0x70))


def test_parse_refusals() raises:
    assert_equal(
        _refusal(_file().replace(String("oci_image:"), String("tarball:"))),
        String(
            "decl.textproto: line 38: unknown field 'tarball' in artifact 'server'"
            " (expected name, allowed_channels, conda_package, conda_metapackage,"
            " python_wheel, oci_image)"
        ),
    )
    assert_equal(
        _refusal(
            _file().replace(
                String("  python_wheel {"),
                String("  oci_image { build { buck2 { label: \"//a:b\" } } }\n  python_wheel {"),
            )
        ),
        String(
            "decl.textproto: line 34: artifact 'front_end' sets a second kind"
            " 'python_wheel' (it is already 'oci_image'); an artifact is exactly one kind"
        ),
    )
    assert_equal(
        _refusal(_conda(String("a"), String("    member_of: \"s\"\n    member_of: \"t\"\n"))),
        String("decl.textproto: line 8: field 'member_of' is set twice in the conda_package of artifact 'a'"),
    )
    assert_equal(
        _refusal(_conda(String("a"), String("    version: \"1.0\"\n"))),
        String(
            "decl.textproto: line 7: unknown field 'version' in the conda_package of"
            " artifact 'a' (expected build, subdirs, depends_on, member_of)"
        ),
    )
    assert_equal(
        _refusal(_conda(String("a"), String("")).replace(String("name: \"a\""), String("name: a"))),
        String("decl.textproto: line 2: expected a quoted string for 'name' but got word 'a'"),
    )
    assert_equal(
        _refusal(_conda(String("a"), String("")).replace(String("  name: \"a\"\n"), String("  name: \"a\"\n  name: \"b\"\n"))),
        String("decl.textproto: line 3: field 'name' is set twice in artifact 'a'"),
    )
    assert_equal(
        _refusal(String("artifact {\n  name: \"a\"\n")),
        String("decl.textproto: line 1: artifact 'a' is not closed (expected '}')"),
    )
    assert_equal(
        _refusal(String("channel {\n}\n")),
        String("decl.textproto: line 1: unknown top-level field 'channel' (expected artifact)"),
    )
    assert_equal(
        _refusal(_conda(String("a"), String("")).replace(String("buck2 {"), String("buck2 { label: \"//x:y\" } buck2 {"))),
        String("decl.textproto: line 5: the build of artifact 'a' names a second build system 'buck2'"),
    )
    assert_equal(
        _refusal(_conda(String("a"), String("")).replace(String("buck2 {"), String("bazel {"))),
        String("decl.textproto: line 5: unknown field 'bazel' in the build of artifact 'a' (expected buck2)"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
