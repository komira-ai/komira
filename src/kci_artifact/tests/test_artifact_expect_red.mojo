# =============================================================================
# src/kci_artifact/tests/test_artifact_expect_red.mojo
#   The expect_red unit kind: a unit whose ONE target must fail to build,
#   printing a declared text. It parses and round trips with every field
#   number pinned as bytes, shares the units' one name space, is refused one
#   rule at a time, joins the units (after the checks) and the units file,
#   builds through `build_targets`, and `expect_red_passed` reads both
#   directions: a red with the text passes, a green or a red without it
#   does not.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_proto_codec import decode_proto, encode_proto

from kci_artifact_proto.artifact import Artifact, Artifacts, BuildSystem, Check, ExpectRed
from kci_artifact import (
    expect_red_passed,
    find_unit,
    parse_artifacts,
    render_targets_argv,
    require_affected_ready,
    unit_names_of,
    units_file_text,
    units_of,
)

comptime _FILE = """schema_version: 1
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
  affected {
    executable: "/opt/ci/affected"
    args: "{changed_files}"
    args: "{units_file}"
  }
  build_targets {
    executable: "buck2"
    args: "build"
  }
}
artifacts {
  name: "lib_a"
  build_system: "buck2"
  args: "//src/lib_a:lib_a_conda[release]"
  args: "--out"
  args: "{out_dir}"
  targets: "//src/lib_a:lib_a_conda"
}
checks {
  name: "lints"
  build_system: "buck2"
  targets: "//:docs"
}
expect_red {
  name: "gate_red"
  build_system: "buck2"
  target: "tests//negative/libgate_bad:libgate_bad"
  message: "GATED TEST FAILED"
}
expect_red {
  name: "closure_refusal"
  build_system: "buck2"
  target: "tests//negative/closure_refusal:hello_incomplete_toolchain"
  message: "REFUSING: toolchain member"
}
"""


def _parse(text: String) raises -> Artifacts:
    return parse_artifacts(text, String("artifacts.textproto"))


def _refusal(text: String) -> String:
    try:
        _ = _parse(text)
    except e:
        return String(e)
    return String("<parsed>")


def _swap(old: String, new: String) raises -> String:
    var s = String(_FILE)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _expect_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _bytes(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


# ── parse and wire ───────────────────────────────────────────────────────────


def test_expect_red_units_parse() raises:
    var d = _parse(String(_FILE))
    assert_equal(len(d.expect_red), 2)
    assert_equal(d.expect_red[0].name, String("gate_red"))
    assert_equal(d.expect_red[0].build_system, String("buck2"))
    assert_equal(d.expect_red[0].target, String("tests//negative/libgate_bad:libgate_bad"))
    assert_equal(d.expect_red[0].message, String("GATED TEST FAILED"))
    assert_equal(d.expect_red[1].name, String("closure_refusal"))
    require_affected_ready(d)
    # optional: a file without them has none
    var bare = _parse(
        String("schema_version: 1\nbuild_systems { name: \"b\" executable: \"b\" }\n")
        + String("artifacts { name: \"a\" build_system: \"b\" args: \"{out_dir}\" }\n")
    )
    assert_equal(len(bare.expect_red), 0)


def test_expect_red_field_numbers_are_pinned() raises:
    # name = 1 (0x0a), build_system = 2 (0x12), target = 3 (0x1a), message = 4 (0x22)
    _expect_bytes(
        encode_proto[ExpectRed](ExpectRed(String("n"), String("b"), String("t"), String("m"))),
        _bytes(0x0A, 1, 0x6E, 0x12, 1, 0x62, 0x1A, 1, 0x74, 0x22, 1, 0x6D),
    )


def test_file_expect_red_field_number_is_pinned() raises:
    # schema_version = 3 (0x18) then expect_red = 5 (0x2a, 12 bytes)
    var reds = List[ExpectRed]()
    reds.append(ExpectRed(String("n"), String("b"), String("t"), String("m")))
    _expect_bytes(
        encode_proto[Artifacts](Artifacts(List[BuildSystem](), List[Artifact](), Int32(1), List[Check](), reds^)),
        _bytes(0x18, 1, 0x2A, 12, 0x0A, 1, 0x6E, 0x12, 1, 0x62, 0x1A, 1, 0x74, 0x22, 1, 0x6D),
    )


def test_expect_red_round_trips_on_the_wire() raises:
    var d = _parse(String(_FILE))
    var back = decode_proto[Artifacts](encode_proto[Artifacts](d))
    assert_equal(len(back.expect_red), 2)
    assert_equal(back.expect_red[1].target, String("tests//negative/closure_refusal:hello_incomplete_toolchain"))
    assert_equal(back.expect_red[1].message, String("REFUSING: toolchain member"))


def test_expect_red_parse_refusals() raises:
    assert_equal(
        _refusal(_swap(String("  message: \"GATED TEST FAILED\"\n"), String("  message: \"GATED TEST FAILED\"\n  targets: \"x\"\n"))),
        String(
            "artifacts.textproto: line 34: unknown field 'targets' in expect_red unit 'gate_red'"
            " (expected name, build_system, target, message)"
        ),
    )
    assert_equal(
        _refusal(_swap(String("  message: \"GATED TEST FAILED\"\n"), String("  message: \"GATED TEST FAILED\"\n  target: \"//:y\"\n"))),
        String("artifacts.textproto: line 34: field 'target' is set twice in expect_red unit 'gate_red'"),
    )


# ── validation ───────────────────────────────────────────────────────────────


def test_expect_red_refusals() raises:
    var gate = String("  name: \"gate_red\"\n")
    var cases = List[String]()
    var want = List[String]()
    cases.append(_swap(gate, String("  name: \"lints\"\n")))
    want.append(String("check 'lints' is also the name of an expect_red unit (units are one name space)"))
    cases.append(_swap(gate, String("  name: \"lib_a\"\n")))
    want.append(String("artifact 'lib_a' is also the name of an expect_red unit (units are one name space)"))
    cases.append(_swap(String("  name: \"closure_refusal\"\n"), gate))
    want.append(String("expect_red unit 'gate_red' is declared twice"))
    cases.append(_swap(gate, String("  name: \"Gate\"\n")))
    want.append(String("expect_red unit 'Gate' name is not [a-z][a-z0-9_]*"))
    cases.append(_swap(String("  build_system: \"buck2\"\n  target: \"tests//negative/libgate_bad"), String("  target: \"tests//negative/libgate_bad")))
    want.append(String("expect_red unit 'gate_red' names no build_system"))
    cases.append(_swap(String("  build_system: \"buck2\"\n  target: \"tests//negative/libgate_bad"), String("  build_system: \"bazel\"\n  target: \"tests//negative/libgate_bad")))
    want.append(String("expect_red unit 'gate_red' build_system 'bazel' is not declared"))
    cases.append(_swap(String("  target: \"tests//negative/libgate_bad:libgate_bad\"\n"), String("")))
    want.append(String("expect_red unit 'gate_red' has no target (the one target that must fail to build)"))
    cases.append(_swap(String("tests//negative/libgate_bad:libgate_bad"), String("tests//negative/libgate_bad:x {out_dir}")))
    want.append(String("expect_red unit 'gate_red' target #1 'tests//negative/libgate_bad:x {out_dir}' holds whitespace"))
    cases.append(_swap(String("  message: \"GATED TEST FAILED\"\n"), String("")))
    want.append(
        String("expect_red unit 'gate_red' has no message: a build fails for many reasons, and only the declared text")
        + String(" says it failed for the rule under test")
    )
    cases.append(_swap(String("\"GATED TEST FAILED\""), String("\"GATED\\nFAILED\"")))
    want.append(String("expect_red unit 'gate_red' message holds a line break (it is matched within one line)"))
    for i in range(len(cases)):
        assert_equal(_refusal(cases[i]), String("artifacts.textproto: ") + want[i])
    # a build system without build_targets cannot build the unit
    var no_bt = String(_FILE).replace(String("  build_targets {\n    executable: \"buck2\"\n    args: \"build\"\n  }\n"), String(""))
    no_bt = no_bt.replace(String("checks {\n  name: \"lints\"\n  build_system: \"buck2\"\n  targets: \"//:docs\"\n}\n"), String(""))
    assert_equal(
        _refusal(no_bt),
        String(
            "artifacts.textproto: expect_red unit 'gate_red' build_system 'buck2' declares no build_targets command:"
            " kci could not build the unit"
        ),
    )


def test_a_build_system_owning_only_an_expect_red_unit_needs_both_commands() raises:
    var f = String(_FILE) + String(
        "build_systems {\n  name: \"other\"\n  executable: \"other\"\n  build_targets { executable: \"other\" }\n}\n"
        "expect_red {\n  name: \"other_red\"\n  build_system: \"other\"\n  target: \"//x:y\"\n  message: \"no\"\n}\n"
    )
    var d = _parse(f)
    var got = String("<ready>")
    try:
        require_affected_ready(d)
    except e:
        got = String(e)
    assert_equal(got, String("artifacts: build system 'other' owns a unit and declares no affected command (--affected-by needs one)"))


# ── units ────────────────────────────────────────────────────────────────────


def test_expect_red_units_come_after_the_checks() raises:
    var d = _parse(String(_FILE))
    var u = units_of(d)
    assert_equal(len(u), 4)
    assert_equal(u[0].name, String("lib_a"))
    assert_false(u[0].is_expect_red)
    assert_equal(u[1].name, String("lints"))
    assert_false(u[1].is_expect_red)
    assert_equal(u[2].name, String("gate_red"))
    assert_true(u[2].is_expect_red)
    assert_false(u[2].is_check)
    assert_equal(u[2].message, String("GATED TEST FAILED"))
    assert_equal(len(u[2].targets), 1)
    assert_equal(u[3].name, String("closure_refusal"))
    assert_equal(find_unit(d, String("closure_refusal")).message, String("REFUSING: toolchain member"))
    var names = unit_names_of(d, String("buck2"))
    assert_equal(len(names), 4)
    assert_equal(names[3], String("closure_refusal"))
    assert_equal(
        units_file_text(d, String("buck2")),
        String("lib_a\t//src/lib_a:lib_a_conda\nlints\t//:docs\n")
        + String("gate_red\ttests//negative/libgate_bad:libgate_bad\n")
        + String("closure_refusal\ttests//negative/closure_refusal:hello_incomplete_toolchain\n"),
    )


def test_expect_red_builds_through_build_targets() raises:
    var d = _parse(String(_FILE))
    var argv = render_targets_argv(d, String("gate_red"))
    assert_equal(len(argv), 3)
    assert_equal(argv[0], String("buck2"))
    assert_equal(argv[1], String("build"))
    assert_equal(argv[2], String("tests//negative/libgate_bad:libgate_bad"))


def test_expect_red_passed_both_directions() raises:
    var log = String("Action failed\nGATED TEST FAILED: test_bad (1 of 3)\nBUILD FAILED\n")
    # red with the declared text: PASS
    assert_true(expect_red_passed(True, 1, log, String("GATED TEST FAILED")))
    # green: FAIL, whatever it printed
    assert_false(expect_red_passed(True, 0, log, String("GATED TEST FAILED")))
    # red for another reason: FAIL
    assert_false(expect_red_passed(True, 1, String("error: No engine address\n"), String("GATED TEST FAILED")))
    # killed or timed out: never a red that proves the rule
    assert_false(expect_red_passed(False, 1, log, String("GATED TEST FAILED")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
