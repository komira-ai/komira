# =============================================================================
# src/kci_artifact_declaration/tests/test_declaration_validate.mojo
#   Every refusal of `validate_artifact_declarations` and of the check
#   against the channels file, one case per message.
# =============================================================================
#
# Each case builds a small file that is valid except for one thing (the
# control case shows the unbroken file is accepted) and asserts the message
# names that thing. Validation runs inside the parser, so every case goes
# through `parse_artifact_declarations`, the path kci uses.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_channel import parse_channels_file
from kci_artifact_declaration import (
    is_buck2_label,
    is_valid_artifact_name,
    is_valid_conda_subdir,
    parse_artifact_declarations,
    validate_declarations_against_channels,
)

comptime _PREFIX = "decl.textproto: "


def _pkg(
    name: String,
    deps: String = String(""),
    member: String = String("suite"),
    channels: String = String("public"),
    label: String = String(""),
    subdirs: String = String("linux-64"),
) -> String:
    var out = String("artifact {\n")
    out += String("  name: \"") + name + String("\"\n")
    if channels.byte_length() > 0:
        var cs = channels.split(String(","))
        for i in range(len(cs)):
            out += String("  allowed_channels: \"") + String(cs[i]) + String("\"\n")
    var lab = label.copy()
    if lab.byte_length() == 0:
        lab = String("//src/") + name + String(":") + name + String("_conda")
    out += String("  conda_package {\n    build { buck2 { label: \"") + lab + String("\" } }\n")
    if subdirs.byte_length() > 0:
        var ss = subdirs.split(String(","))
        for i in range(len(ss)):
            out += String("    subdirs: \"") + String(ss[i]) + String("\"\n")
    if deps.byte_length() > 0:
        var ds = deps.split(String(","))
        for i in range(len(ds)):
            out += String("    depends_on: \"") + String(ds[i]) + String("\"\n")
    if member.byte_length() > 0:
        out += String("    member_of: \"") + member + String("\"\n")
    out += String("  }\n}\n")
    return out^


def _meta(channels: String = String("public"), subdirs: String = String("linux-64")) -> String:
    var out = String("artifact {\n  name: \"suite\"\n")
    var cs = channels.split(String(","))
    for i in range(len(cs)):
        out += String("  allowed_channels: \"") + String(cs[i]) + String("\"\n")
    out += String("  conda_metapackage {\n    packer { buck2 { label: \"//tools/pack:pack\" } }\n")
    var ss = subdirs.split(String(","))
    for i in range(len(ss)):
        out += String("    subdirs: \"") + String(ss[i]) + String("\"\n")
    out += String("  }\n}\n")
    return out^


def _wheel(name: String, deps: String = String("")) -> String:
    var out = (
        String("artifact {\n  name: \"")
        + name
        + String("\"\n  allowed_channels: \"public\"\n  python_wheel {\n")
        + String("    build { buck2 { label: \"//py:")
        + name
        + String("\" } }\n")
    )
    if deps.byte_length() > 0:
        out += String("    depends_on: \"") + deps + String("\"\n")
    out += String("  }\n}\n")
    return out^


def _ok() -> String:
    return _pkg(String("base_lib")) + _pkg(String("app_core"), deps = String("base_lib")) + _meta()


def _refusal(text: String) -> String:
    try:
        _ = parse_artifact_declarations(text, String("decl.textproto"))
    except e:
        return String(e)
    return String("<parsed>")


def _expect(text: String, message: String) raises:
    assert_equal(_refusal(text), String(_PREFIX) + message)


def test_control_is_accepted() raises:
    assert_equal(_refusal(_ok()), String("<parsed>"))
    assert_equal(_refusal(_ok() + _wheel(String("w_a")) + _wheel(String("w_b"), String("w_a"))), String("<parsed>"))


def test_name_refusals() raises:
    _expect(String(""), String("declares no artifact"))
    _expect(
        _ok().replace(String("name: \"base_lib\""), String("name: \"\"")).replace(String("\"base_lib\""), String("\"x\"")),
        String("artifact #1 has an EMPTY name"),
    )
    _expect(
        _ok().replace(String("\"base_lib\""), String("\"Base-lib\"")),
        String("artifact 'Base-lib' name is not [a-z][a-z0-9_]* of at most 64 bytes"),
    )
    _expect(
        _ok() + _wheel(String("base_lib")),
        String("artifact 'base_lib' is declared twice (names are unique whatever the kind)"),
    )


def test_kind_and_channel_refusals() raises:
    _expect(
        _ok() + String("artifact {\n  name: \"bare\"\n  allowed_channels: \"public\"\n}\n"),
        String(
            "artifact 'bare' declares no kind (expected one of conda_package,"
            " conda_metapackage, python_wheel, oci_image)"
        ),
    )
    _expect(
        _pkg(String("solo"), member = String(""), channels = String("")),
        String("artifact 'solo' has no allowed_channels (an artifact names every channel it may go to)"),
    )
    _expect(
        _pkg(String("solo"), member = String(""), channels = String("Public")),
        String("artifact 'solo' allowed channel 'Public' is not a channel name"),
    )
    _expect(
        _pkg(String("solo"), member = String(""), channels = String("public,public")),
        String("artifact 'solo' names 'public' twice in allowed_channels"),
    )


def test_build_rule_refusals() raises:
    _expect(
        _pkg(String("solo"), member = String(""), label = String("src/solo:solo")),
        String(
            "artifact 'solo' Buck2 label 'src/solo:solo' is not a target label"
            " (//<package>:<name> or <cell>//<package>:<name>)"
        ),
    )
    _expect(
        _pkg(String("solo"), member = String(""), label = String("//src/solo")),
        String(
            "artifact 'solo' Buck2 label '//src/solo' is not a target label"
            " (//<package>:<name> or <cell>//<package>:<name>)"
        ),
    )
    _expect(
        _pkg(String("solo"), member = String(""), label = String("//src/solo:solo_conda[release]")),
        String(
            "artifact 'solo' Buck2 label '//src/solo:solo_conda[release]' names a"
            " sub-target; kci builds '[release]' of the target itself"
        ),
    )
    _expect(
        _pkg(String("solo"), member = String(""), label = String(" ")),
        String(
            "artifact 'solo' Buck2 label ' ' is not a target label"
            " (//<package>:<name> or <cell>//<package>:<name>)"
        ),
    )
    _expect(
        _pkg(String("solo"), member = String("")).replace(
            String("    build { buck2 { label: \"//src/solo:solo_conda\" } }\n"), String("")
        ),
        String("artifact 'solo' has no 'build' (its build rule)"),
    )
    _expect(
        _pkg(String("solo"), member = String("")).replace(
            String("build { buck2 { label: \"//src/solo:solo_conda\" } }"), String("build { }")
        ),
        String("artifact 'solo' 'build' names no build system (expected buck2)"),
    )


def test_subdir_refusals() raises:
    _expect(
        _pkg(String("solo"), member = String(""), subdirs = String("")),
        String("artifact 'solo' has no subdirs (a conda artifact names its platforms)"),
    )
    _expect(
        _pkg(String("solo"), member = String(""), subdirs = String("noarch")),
        String(
            "artifact 'solo' subdir 'noarch' is not published: a compiled package"
            " names its platform subdir"
        ),
    )
    _expect(
        _pkg(String("solo"), member = String(""), subdirs = String("linux")),
        String("artifact 'solo' subdir 'linux' is not <os>-<arch>"),
    )
    _expect(
        _pkg(String("solo"), member = String(""), subdirs = String("linux-64,linux-64")),
        String("artifact 'solo' names 'linux-64' twice in subdirs"),
    )


def test_depends_on_refusals() raises:
    _expect(
        _pkg(String("base_lib")) + _pkg(String("app_core"), deps = String("nope")) + _meta(),
        String("artifact 'app_core' depends on 'nope', which is not declared"),
    )
    _expect(
        _pkg(String("base_lib"), deps = String("base_lib")) + _meta(),
        String("artifact 'base_lib' depends on itself"),
    )
    _expect(
        _pkg(String("base_lib")) + _pkg(String("app_core"), deps = String("base_lib,base_lib")) + _meta(),
        String("artifact 'app_core' names 'base_lib' twice in depends_on"),
    )
    _expect(
        _pkg(String("a_lib"), deps = String("c_lib"))
        + _pkg(String("b_lib"), deps = String("a_lib"))
        + _pkg(String("c_lib"), deps = String("b_lib"))
        + _meta(),
        String("depends_on cycle: a_lib -> c_lib -> b_lib -> a_lib"),
    )
    _expect(
        _ok() + _wheel(String("w_a"), String("base_lib")),
        String(
            "artifact 'w_a' is a python_wheel and depends on 'base_lib', a"
            " conda_package (a dependency is of the same kind)"
        ),
    )
    _expect(
        _ok() + _pkg(String("odd"), deps = String("suite")),
        String(
            "artifact 'odd' is a conda_package and depends on 'suite', a"
            " conda_metapackage (a dependency is of the same kind)"
        ),
    )
    _expect(
        _pkg(String("base_lib"), channels = String("public"))
        + _pkg(String("app_core"), deps = String("base_lib"), channels = String("public,beta"))
        + _meta(),
        String("artifact 'app_core' may go to channel 'beta' but its dependency 'base_lib' may not"),
    )


def test_member_of_refusals() raises:
    _expect(
        _pkg(String("base_lib"), member = String("nope")) + _meta(),
        String("artifact 'base_lib' is a member of 'nope', which is not a declared conda_metapackage"),
    )
    _expect(
        _pkg(String("base_lib"), member = String("")) + _pkg(String("app_core"), member = String("base_lib")),
        String("artifact 'app_core' is a member of 'base_lib', which is not a declared conda_metapackage"),
    )
    _expect(
        _pkg(String("base_lib"), member = String("")) + _meta(),
        String(
            "artifact 'suite' is a conda_metapackage with no member (no"
            " conda_package says member_of: \"suite\")"
        ),
    )
    _expect(
        _pkg(String("base_lib")) + _meta(subdirs = String("linux-64,osx-arm64")),
        String("artifact 'base_lib' is a member of 'suite' but is not built for its subdir 'osx-arm64'"),
    )
    _expect(
        _pkg(String("base_lib")) + _meta(channels = String("public,beta")),
        String("artifact 'base_lib' is a member of 'suite' but may not go to its channel 'beta'"),
    )


def _channels(conda: Bool) -> String:
    var out = String("channel {\n  name: \"public\"\n  visibility: PUBLIC\n")
    if conda:
        out += String("  repository {\n    artifact_type: CONDA\n")
    else:
        out += String("  repository {\n    artifact_type: OCI\n")
    out += String("    location: \"https://registry.example.invalid/public\"\n")
    out += String("    push_identity: \"publisher@example.invalid\"\n")
    out += String("    credential { kind: API_TOKEN secret_name: \"PUBLIC_TOKEN\" }\n  }\n}\n")
    return out^


def test_against_the_channels_file() raises:
    var d = parse_artifact_declarations(_ok(), String("decl.textproto"))
    validate_declarations_against_channels(d, parse_channels_file(_channels(True)))
    var why = String("<accepted>")
    try:
        validate_declarations_against_channels(d, parse_channels_file(_channels(False)))
    except e:
        why = String(e)
    assert_equal(why, String("artifact 'base_lib': channel 'public' declares no CONDA repository"))
    var beta = parse_artifact_declarations(
        _pkg(String("solo"), member = String(""), channels = String("beta")), String("decl.textproto")
    )
    why = String("<accepted>")
    try:
        validate_declarations_against_channels(beta, parse_channels_file(_channels(True)))
    except e:
        why = String(e)
    assert_equal(why, String("artifact 'solo': unknown release channel 'beta' (declared: public)"))


def test_syntax_predicates() raises:
    assert_true(is_buck2_label(String("//src/a:a_conda")))
    assert_true(is_buck2_label(String("komira//tools/build/package:komira_pack")))
    assert_true(is_buck2_label(String("//:root")))
    assert_false(is_buck2_label(String("//src/../a:a")))
    assert_false(is_buck2_label(String("//src//a:a")))
    assert_false(is_buck2_label(String("//src/a:a:b")))
    assert_false(is_buck2_label(String("//src/...")))
    assert_false(is_buck2_label(String("@cell//src/a:a")))
    assert_true(is_valid_artifact_name(String("komira_json")))
    assert_false(is_valid_artifact_name(String("komira-json")))
    assert_false(is_valid_artifact_name(String("_x")))
    assert_true(is_valid_conda_subdir(String("linux-64")))
    assert_true(is_valid_conda_subdir(String("osx-arm64")))
    assert_false(is_valid_conda_subdir(String("noarch")))
    assert_false(is_valid_conda_subdir(String("linux-")))
    assert_false(is_valid_conda_subdir(String("-64")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
