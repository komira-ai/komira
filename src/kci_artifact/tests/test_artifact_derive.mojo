# =============================================================================
# src/kci_artifact/tests/test_artifact_derive.mojo
#   The DERIVED checks: a build system's `derive_checks` command parses,
#   round trips with its field number pinned as bytes, and is refused one
#   rule at a time; `{units_file}` holds every declared unit; every accepted
#   and refused answer of the command; the derived checks join the file's
#   value under its own rules; an UNMATCHED artifact target is told apart
#   from a check's; a BROKEN answer (the tool's graph query failed) parses
#   alone, with its reason, and nowhere else.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_proto_codec import encode_proto

from kci_artifact_proto.artifact import BuildSystem, Command
from kci_artifact import (
    AffectedValues,
    add_derived_checks,
    declared_units_file_text,
    parse_artifacts,
    parse_derive_answer,
    render_derive_argv,
    unmatched_artifacts,
    units_of,
)

comptime _BASE = "0123456789abcdef0123456789abcdef01234567"
comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

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
  derive_checks {
    executable: "python3"
    args: "release/ci/derive_checks.py"
    args: "{units_file}"
    args: "--base={base_commit}"
  }
}
build_systems {
  name: "pack"
  executable: "buck2"
  args: "run"
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
artifacts {
  name: "meta"
  build_system: "pack"
  args: "--out-dir={out_dir}"
  targets: "//tools/pack:pack"
}
checks {
  name: "lints"
  build_system: "buck2"
  targets: "//:"
  targets: "//docs/..."
}
"""


def _refusal(text: String) -> String:
    try:
        _ = parse_artifacts(text, String("artifacts.textproto"))
    except e:
        return String(e)
    return String("<parsed>")


def _without(old: String, new: String) raises -> String:
    var s = String(_FILE)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _bytes(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def test_the_derive_checks_field_number_is_pinned() raises:
    # derive_checks = 6 (0x32, 6 bytes), after name 1, executable 2
    var b = BuildSystem(String("b"), String("e"), List[String](), None, None, Command(String("h"), _one(String("w"))))
    var got = encode_proto[BuildSystem](b)
    var want = _bytes(0x0A, 1, 0x62, 0x12, 1, 0x65, 0x32, 6, 0x0A, 1, 0x68, 0x12, 1, 0x77)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def test_the_command_parses_and_renders() raises:
    var a = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    assert_true(Bool(a.build_systems[0].derive_checks))
    assert_true(not a.build_systems[1].derive_checks)
    var argv = render_derive_argv(
        a, String("buck2"), AffectedValues(String("/l/_changed_files"), String("/l/_declared_units.tsv"), String(_BASE), String(_REV))
    )
    assert_equal(len(argv), 4)
    assert_equal(argv[0], String("python3"))
    assert_equal(argv[1], String("release/ci/derive_checks.py"))
    assert_equal(argv[2], String("/l/_declared_units.tsv"))
    assert_equal(argv[3], String("--base=") + String(_BASE))
    try:
        _ = render_derive_argv(a, String("pack"), AffectedValues(String("c"), String("u"), String(_BASE), String(_REV)))
        raise Error("rendered a derive_checks command 'pack' does not declare")
    except e:
        assert_equal(String(e), String("build system 'pack' declares no derive_checks command"))


def test_the_units_file_holds_every_declared_unit() raises:
    var a = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    assert_equal(
        declared_units_file_text(a),
        String("lib_a\t//src/lib_a:lib_a_conda\nmeta\t//tools/pack:pack\nlints\t//:\nlints\t//docs/...\n"),
    )


def test_the_refusals_of_the_command() raises:
    assert_equal(
        _refusal(_without(String("    args: \"{units_file}\"\n    args: \"--base"), String("    args: \"--base"))),
        String(
            "artifacts.textproto: the derive_checks command of build system 'buck2' never names '{units_file}':"
            " the tool could not know what the declared units already name"
        ),
    )
    assert_equal(
        _refusal(_without(String("--base={base_commit}"), String("--out={out_dir}"))),
        String(
            "artifacts.textproto: the derive_checks command of build system 'buck2' arg '--out={out_dir}' holds"
            " the placeholder '{out_dir}', which is not an affected command's"
        ),
    )
    assert_equal(
        _refusal(_without(String("    executable: \"python3\"\n"), String("    executable: \"./py\"\n"))),
        String(
            "artifacts.textproto: the derive_checks command of build system 'buck2' executable './py' is a"
            " relative path (expected a program name found on PATH, or an absolute path)"
        ),
    )
    var no_build_targets = _without(
        String("  build_targets {\n    executable: \"buck2\"\n    args: \"build\"\n  }\n  derive_checks"),
        String("  derive_checks"),
    )
    assert_equal(
        _refusal(no_build_targets),
        String(
            "artifacts.textproto: build system 'buck2' declares derive_checks but not both affected and"
            " build_targets: kci could not select or build the checks it derives"
        ),
    )
    assert_true(
        _refusal(_without(String("  derive_checks {\n"), String("  derive_checks { executable: \"x\" args: \"{units_file}\" }\n  derive_checks {\n"))).find(
            String("field 'derive_checks' is set twice in build system 'buck2'")
        ) >= 0
    )


def _answer_refusal(text: String) raises -> String:
    var a = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    try:
        _ = parse_derive_answer(text, units_of(a))
    except e:
        return String(e)
    return String("<parsed>")


def test_the_answers_kci_accepts() raises:
    var a = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    var d = parse_derive_answer(
        String("CHECK lib_b //src/lib_b/...\nUNMATCHED lints //docs/...\nCHECK tools //tools/x/...\nCHECK lib_b //src/lib_b:\nDERIVED 2\n"),
        units_of(a),
    )
    assert_equal(len(d.names), 2)
    assert_equal(d.names[0], String("lib_b"))
    assert_equal(len(d.targets[0]), 2)
    assert_equal(d.targets[0][1], String("//src/lib_b:"))
    assert_equal(d.names[1], String("tools"))
    assert_equal(len(d.unmatched_units), 1)
    assert_equal(len(unmatched_artifacts(a, d)), 0)
    var none = parse_derive_answer(String("DERIVED 0"), units_of(a))
    assert_equal(len(none.names), 0)
    var art = parse_derive_answer(String("UNMATCHED lib_a //src/lib_a:lib_a_conda\nDERIVED 0\n"), units_of(a))
    var refused = unmatched_artifacts(a, art)
    assert_equal(len(refused), 1)
    assert_equal(refused[0], String("lib_a //src/lib_a:lib_a_conda"))
    # BROKEN: the tool's graph query failed; kci_build fails the check on it.
    # A parser that read it as an unknown line would turn a broken graph
    # into "cannot tell"; one that dropped the reason would hide buck2's error.
    var b = parse_derive_answer(String("BROKEN the universe query failed: buck2 cquery failed (exit 3): x\n"), units_of(a))
    assert_true(b.broken)
    assert_equal(b.reason, String("the universe query failed: buck2 cquery failed (exit 3): x"))
    assert_equal(len(b.names), 0)
    assert_true(not d.broken)


def test_every_answer_outside_the_grammar_is_refused() raises:
    var rows = List[Tuple[String, String]]()
    rows.append((String(""), String("printed nothing")))
    rows.append((String("CHECK a //x/...\n"), String("the last line must be the verdict")))
    rows.append((String("CHECK a //x/...\nDERIVED 2\n"), String("says 2 check(s) but CHECK lines name 1")))
    rows.append((String("CHECK a //x/...\nDERIVED 01\n"), String("is not a count")))
    rows.append((String("DERIVED 0\nCHECK a //x/...\n"), String("the verdict must be the last line")))
    rows.append((String("DERIVED 0\nDERIVED 0\n"), String("the verdict must be the last line")))
    rows.append((String("CHECK a\nDERIVED 1\n"), String("expected CHECK <name> <target>")))
    rows.append((String("CHECK a //x/... y\nDERIVED 1\n"), String("a target holds no whitespace")))
    rows.append((String("CHECK a //x/...\nCHECK a //x/...\nDERIVED 1\n"), String("names '//x/...' twice")))
    rows.append((String("UNMATCHED nope //:\nDERIVED 0\n"), String("'nope' is not a declared unit")))
    rows.append((String("UNMATCHED lints //src/...\nDERIVED 0\n"), String("unit 'lints' declares no target '//src/...'")))
    rows.append((String("UNMATCHED lints //:\nUNMATCHED lints //:\nDERIVED 0\n"), String("given twice")))
    rows.append((String("\nDERIVED 0\n"), String("not CHECK <name> <target>")))
    rows.append((String("WIDENED x\n"), String("not CHECK <name> <target>")))
    rows.append((String("check a //x/...\nDERIVED 1\n"), String("not CHECK <name> <target>")))
    rows.append((String("BROKEN\n"), String("BROKEN needs a reason")))
    rows.append((String("CHECK a //x/...\nBROKEN x\n"), String("BROKEN fails the check, so it is the only line")))
    rows.append((String("BROKEN x\nDERIVED 0\n"), String("BROKEN fails the check, so it is the only line")))
    for i in range(len(rows)):
        var got = _answer_refusal(rows[i][0])
        if got.find(rows[i][1]) < 0:
            raise Error(String("answer row ") + String(i) + String(": expected '") + rows[i][1] + String("', got: ") + got)


def test_derived_checks_join_the_file_under_its_rules() raises:
    var a = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    var d = parse_derive_answer(String("CHECK lib_b //src/lib_b/...\nCHECK tools //tools/...\nDERIVED 2\n"), units_of(a))
    add_derived_checks(a, String("buck2"), d, String("artifacts.textproto"))
    var u = units_of(a)
    assert_equal(len(u), 5)
    assert_equal(u[3].name, String("lib_b"))
    assert_equal(u[3].build_system, String("buck2"))
    assert_true(u[3].is_check)
    assert_equal(u[4].targets[0], String("//tools/..."))
    # a derived name a declared unit has is refused, as a declared one is
    for clash in [String("lib_a"), String("lints")]:
        var b = parse_artifacts(String(_FILE), String("artifacts.textproto"))
        var c = parse_derive_answer(String("CHECK ") + clash + String(" //src/x/...\nDERIVED 1\n"), units_of(b))
        try:
            add_derived_checks(b, String("buck2"), c, String("artifacts.textproto"))
            raise Error(String("accepted a derived check named ") + clash)
        except e:
            assert_true(String(e).find(String("with the checks build system 'buck2' derived")) >= 0, String(e))
    # a derived name that is not a unit name is refused
    var bad = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    var n = parse_derive_answer(String("CHECK Tools //tools/...\nDERIVED 1\n"), units_of(bad))
    try:
        add_derived_checks(bad, String("buck2"), n, String("artifacts.textproto"))
        raise Error("accepted the name 'Tools'")
    except e:
        assert_true(String(e).find(String("check 'Tools'")) >= 0, String(e))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
