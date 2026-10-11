# =============================================================================
# src/kci_artifact/tests/test_artifact_units.mojo
#   The per-change check's half of the artifacts file: `targets`, `checks`
#   and a build system's `affected` / `build_targets` commands parse, round
#   trip with every new field number pinned as bytes, and are refused one
#   rule at a time; the units, `{units_file}`, the two argvs, and every
#   accepted and refused answer of an affected command.
# =============================================================================
#
# A control file parses and reads every new field back, so each refusal
# below is caused by its one change. Argvs and the units file are compared
# exactly (goldens). The answer grammar is the protocol a build system's
# affected tool speaks; each refusal is one broken line.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_proto_codec import decode_proto, encode_proto

from kci_artifact_proto.artifact import (
    Artifact,
    Artifacts,
    BuildSystem,
    Check,
    Command,
)
from kci_artifact import (
    AffectedValues,
    ReleaseStamp,
    batch_groups,
    parse_affected_answer,
    parse_artifacts,
    render_affected_argv,
    render_batch_argv,
    render_build_argv,
    render_targets_argv,
    require_affected_ready,
    unit_names_of,
    units_file_text,
    units_of,
)

comptime _BASE = "0123456789abcdef0123456789abcdef01234567"
comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

# Two build systems, two artifacts, two checks. Line numbers are not
# load-bearing here: every refusal names its unit or build system.
comptime _FILE = """schema_version: 1
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
  affected {
    executable: "/opt/ci/affected"
    args: "--changed={changed_files}"
    args: "--units"
    args: "{units_file}"
    args: "--base={base_commit}"
    args: "--head={revision_id}"
  }
  build_targets {
    executable: "buck2"
    args: "build"
    args: "--keep-going"
  }
}
build_systems {
  name: "pack"
  executable: "buck2"
  args: "run"
  args: "//tools/pack:pack"
  args: "--"
  affected: {
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
  targets: "//:docs"
  targets: "//:shell_lint"
}
checks {
  name: "tests_cell"
  build_system: "buck2"
  targets: "tests//functional/..."
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


def _expect(text: String, message: String) raises:
    assert_equal(_refusal(text), String("artifacts.textproto: ") + message)


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _assert_list(got: List[String], want: List[String]) raises:
    var g = String("")
    for i in range(len(got)):
        g += String("[") + got[i] + String("]")
    var w = String("")
    for i in range(len(want)):
        w += String("[") + want[i] + String("]")
    assert_equal(g, w)


# ── parse and wire ───────────────────────────────────────────────────────────


def test_control_file_parses_every_new_field() raises:
    var d = _parse(String(_FILE))
    assert_equal(len(d.build_systems), 2)
    ref b = d.build_systems[0]
    assert_true(Bool(b.affected))
    assert_equal(b.affected.value().executable, String("/opt/ci/affected"))
    _assert_list(
        b.affected.value().args,
        _argv("--changed={changed_files}", "--units", "{units_file}", "--base={base_commit}", "--head={revision_id}"),
    )
    assert_true(Bool(b.build_targets))
    assert_equal(b.build_targets.value().executable, String("buck2"))
    _assert_list(b.build_targets.value().args, _argv("build", "--keep-going"))
    _assert_list(d.artifacts[0].targets, _argv("//src/lib_a:lib_a_conda"))
    _assert_list(d.artifacts[1].targets, _argv("//tools/pack:pack"))
    assert_equal(len(d.checks), 2)
    assert_equal(d.checks[0].name, String("lints"))
    assert_equal(d.checks[0].build_system, String("buck2"))
    _assert_list(d.checks[0].targets, _argv("//:docs", "//:shell_lint"))
    assert_equal(d.checks[1].name, String("tests_cell"))
    require_affected_ready(d)


def test_a_file_without_the_new_fields_still_parses() raises:
    # fields added inside major 1 are optional: the release build ignores them
    var d = _parse(
        String("schema_version: 1\nbuild_systems { name: \"b\" executable: \"b\" }\n")
        + String("artifacts { name: \"a\" build_system: \"b\" args: \"{out_dir}\" }\n")
    )
    assert_equal(len(d.checks), 0)
    assert_false(Bool(d.build_systems[0].affected))
    assert_false(Bool(d.build_systems[0].build_targets))
    assert_equal(len(d.artifacts[0].targets), 0)


def test_new_fields_round_trip_on_the_wire() raises:
    var d = _parse(String(_FILE))
    var back = decode_proto[Artifacts](encode_proto[Artifacts](d))
    assert_equal(len(back.checks), 2)
    for i in range(len(d.checks)):
        assert_equal(back.checks[i].name, d.checks[i].name)
        assert_equal(back.checks[i].build_system, d.checks[i].build_system)
        _assert_list(back.checks[i].targets, d.checks[i].targets)
    for i in range(len(d.artifacts)):
        _assert_list(back.artifacts[i].targets, d.artifacts[i].targets)
    for i in range(len(d.build_systems)):
        ref x = back.build_systems[i]
        ref y = d.build_systems[i]
        assert_equal(x.affected.value().executable, y.affected.value().executable)
        _assert_list(x.affected.value().args, y.affected.value().args)
        assert_equal(x.build_targets.value().executable, y.build_targets.value().executable)
        _assert_list(x.build_targets.value().args, y.build_targets.value().args)


def _expect_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _bytes(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def test_command_field_numbers_are_pinned() raises:
    # executable = 1 (0x0a), args = 2 (0x12)
    _expect_bytes(encode_proto[Command](Command(String("e"), _one(String("x")))), _bytes(0x0A, 1, 0x65, 0x12, 1, 0x78))


def test_build_system_command_field_numbers_are_pinned() raises:
    # name 1, executable 2, args 3 as before; affected = 4 (0x22, 6 bytes),
    # build_targets = 5 (0x2a, 6 bytes)
    var b = BuildSystem(
        String("b"), String("e"), _one(String("x")),
        Command(String("f"), _one(String("y"))), Command(String("g"), _one(String("z"))), None,
    )
    _expect_bytes(
        encode_proto[BuildSystem](b),
        _bytes(
            0x0A, 1, 0x62, 0x12, 1, 0x65, 0x1A, 1, 0x78,
            0x22, 6, 0x0A, 1, 0x66, 0x12, 1, 0x79,
            0x2A, 6, 0x0A, 1, 0x67, 0x12, 1, 0x7A,
        ),
    )


def test_artifact_targets_field_number_is_pinned() raises:
    # name 1, build_system 3, args 4 as before; targets = 5 (0x2a)
    _expect_bytes(
        encode_proto[Artifact](Artifact(String("a"), String("b"), _one(String("x")), _one(String("t")))),
        _bytes(0x0A, 1, 0x61, 0x1A, 1, 0x62, 0x22, 1, 0x78, 0x2A, 1, 0x74),
    )


def test_check_field_numbers_are_pinned() raises:
    # name = 1 (0x0a), build_system = 2 (0x12), targets = 3 (0x1a)
    _expect_bytes(
        encode_proto[Check](Check(String("c"), String("b"), _one(String("t")))),
        _bytes(0x0A, 1, 0x63, 0x12, 1, 0x62, 0x1A, 1, 0x74),
    )


def test_file_checks_field_number_is_pinned() raises:
    # schema_version = 3 (0x18) then checks = 4 (0x22, 9 bytes)
    var checks = List[Check]()
    checks.append(Check(String("c"), String("b"), _one(String("t"))))
    _expect_bytes(
        encode_proto[Artifacts](Artifacts(List[BuildSystem](), List[Artifact](), Int32(1), checks^)),
        _bytes(0x18, 1, 0x22, 9, 0x0A, 1, 0x63, 0x12, 1, 0x62, 0x1A, 1, 0x74),
    )


def test_parse_refusals_of_the_new_fields() raises:
    var f = String(_FILE)
    assert_equal(
        _refusal(f.replace(String("    args: \"--keep-going\"\n"), String("    args: \"--keep-going\"\n    name: \"x\"\n"))),
        String(
            "artifacts.textproto: line 18: unknown field 'name' in the build_targets command of"
            " build system 'buck2' (expected executable, args)"
        ),
    )
    assert_equal(
        _refusal(f.replace(String("  build_targets {\n    executable: \"buck2\"\n    args: \"build\"\n  }\n}\nartifacts"), String("  build_targets { executable: \"buck2\" }\n  build_targets { executable: \"b\" }\n}\nartifacts"))),
        String("artifacts.textproto: line 32: field 'build_targets' is set twice in build system 'pack'"),
    )
    assert_equal(
        _refusal(f.replace(String("    executable: \"/opt/ci/affected\"\n    args: \"--changed"), String("    executable: \"/opt/ci/affected\"\n    executable: \"/x\"\n    args: \"--changed"))),
        String("artifacts.textproto: line 8: field 'executable' is set twice in the affected command of build system 'buck2'"),
    )
    assert_equal(
        _refusal(f.replace(String("  targets: \"tests//functional/...\"\n"), String("  targets: \"tests//functional/...\"\n  args: \"x\"\n"))),
        String(
            "artifacts.textproto: line 60: unknown field 'args' in check 'tests_cell'"
            " (expected name, build_system, targets)"
        ),
    )
    assert_equal(
        _refusal(String("schema_version: 1\nchecks {\n  name: \"x\"\n")),
        String("artifacts.textproto: line 2: check 'x' is not closed (expected '}')"),
    )


# ── validation ───────────────────────────────────────────────────────────────


def test_unit_names_are_one_name_space() raises:
    var f = String(_FILE)
    _expect(
        f.replace(String("name: \"lints\""), String("name: \"lib_a\"")),
        String("artifact 'lib_a' is also the name of a check (artifacts and checks are one name space)"),
    )
    _expect(
        f.replace(String("name: \"tests_cell\""), String("name: \"lints\"")),
        String("check 'lints' is declared twice"),
    )
    _expect(
        f.replace(String("name: \"tests_cell\""), String("name: \"tests-cell\"")),
        String("check 'tests-cell' name is not [a-z][a-z0-9_]*"),
    )


def test_check_refusals() raises:
    var f = String(_FILE)
    _expect(
        f.replace(String("  name: \"tests_cell\"\n  build_system: \"buck2\"\n"), String("  name: \"tests_cell\"\n")),
        String("check 'tests_cell' names no build_system"),
    )
    _expect(
        f.replace(String("  name: \"tests_cell\"\n  build_system: \"buck2\"\n"), String("  name: \"tests_cell\"\n  build_system: \"bazel\"\n")),
        String("check 'tests_cell' build_system 'bazel' is not declared"),
    )
    _expect(
        f.replace(String("  targets: \"tests//functional/...\"\n"), String("")),
        String("check 'tests_cell' has no targets (they are what the check builds)"),
    )
    _expect(
        f.replace(String("  build_targets {\n    executable: \"buck2\"\n    args: \"build\"\n    args: \"--keep-going\"\n  }\n"), String("")),
        String("check 'lints' build_system 'buck2' declares no build_targets command: kci could not build the check"),
    )


def test_target_refusals() raises:
    var f = String(_FILE)
    _expect(
        f.replace(String("targets: \"//:shell_lint\""), String("targets: \"\"")),
        String("check 'lints' target #2 is empty"),
    )
    _expect(
        f.replace(String("targets: \"//:shell_lint\""), String("targets: \"//:a //:b\"")),
        String("check 'lints' target #2 '//:a //:b' holds whitespace"),
    )
    _expect(
        f.replace(String("targets: \"//:shell_lint\""), String("targets: \"//:docs\"")),
        String("check 'lints' target '//:docs' is given twice"),
    )
    _expect(
        f.replace(String("targets: \"//src/lib_a:lib_a_conda\""), String("targets: \"//src/{platform}:x\"")),
        String("artifact 'lib_a' target #1 '//src/{platform}:x' holds a placeholder (a target is substituted by nothing)"),
    )


def test_command_refusals() raises:
    var f = String(_FILE)
    _expect(
        f.replace(String("    executable: \"/opt/ci/affected\"\n    args: \"--changed"), String("    executable: \"ci/affected\"\n    args: \"--changed")),
        String(
            "the affected command of build system 'buck2' executable 'ci/affected' is a relative path"
            " (expected a program name found on PATH, or an absolute path)"
        ),
    )
    _expect(
        f.replace(String("    args: \"--units\"\n"), String("    args: \"\"\n")),
        String("the affected command of build system 'buck2' arg #2 is empty"),
    )
    _expect(
        f.replace(String("args: \"--base={base_commit}\""), String("args: \"--out={out_dir}\"")),
        String(
            "the affected command of build system 'buck2' arg '--out={out_dir}' holds the placeholder"
            " '{out_dir}', which is not an affected command's (known: {changed_files} {units_file}"
            " {base_commit} {revision_id})"
        ),
    )
    _expect(
        f.replace(String("    args: \"{units_file}\"\n    args: \"--base"), String("    args: \"units\"\n    args: \"--base")),
        String("the affected command of build system 'buck2' never names '{units_file}': the tool could not know what to answer"),
    )
    _expect(
        f.replace(String("args: \"--changed={changed_files}\""), String("args: \"--changed=all\"")),
        String("the affected command of build system 'buck2' never names '{changed_files}': the tool could not know what to answer"),
    )
    _expect(
        f.replace(String("    args: \"--keep-going\"\n"), String("    args: \"--stamp={build_number}\"\n")),
        String(
            "the build_targets command of build system 'buck2' arg '--stamp={build_number}' holds a"
            " placeholder (this command is run unstamped, with no output directory)"
        ),
    )
    _expect(
        f.replace(String("  build_targets {\n    executable: \"buck2\"\n    args: \"build\"\n  }\n}\nartifacts"), String("  build_targets {\n    args: \"build\"\n  }\n}\nartifacts")),
        String("the build_targets command of build system 'pack' has no executable"),
    )


def test_affected_ready_refusals() raises:
    var f = String(_FILE)
    var cases = List[String]()
    var want = List[String]()
    cases.append(f.replace(String("  targets: \"//tools/pack:pack\"\n"), String("")))
    want.append(String("artifacts: artifact 'meta' has no targets: the per-change check cannot tell whether a change reaches it"))
    cases.append(
        f.replace(
            String("  affected: {\n    executable: \"/opt/ci/affected\"\n    args: \"{changed_files}\"\n    args: \"{units_file}\"\n  }\n"),
            String(""),
        )
    )
    want.append(String("artifacts: build system 'pack' owns a unit and declares no affected command (--affected-by needs one)"))
    cases.append(
        f.replace(String("  build_targets {\n    executable: \"buck2\"\n    args: \"build\"\n  }\n}\nartifacts"), String("}\nartifacts"))
    )
    want.append(String("artifacts: build system 'pack' owns a unit and declares no build_targets command (--affected-by needs one)"))
    for i in range(len(cases)):
        var d = _parse(cases[i])
        var got = String("<ready>")
        try:
            require_affected_ready(d)
        except e:
            got = String(e)
        assert_equal(got, want[i])
    # a build system owning no unit needs neither command
    var lone = f + String("build_systems {\n  name: \"spare\"\n  executable: \"spare\"\n}\n")
    require_affected_ready(_parse(lone))


# ── units, argvs ─────────────────────────────────────────────────────────────


def test_units_are_artifacts_then_checks_in_file_order() raises:
    var d = _parse(String(_FILE))
    var u = units_of(d)
    assert_equal(len(u), 4)
    assert_equal(u[0].name, String("lib_a"))
    assert_false(u[0].is_check)
    assert_equal(u[1].name, String("meta"))
    assert_equal(u[2].name, String("lints"))
    assert_true(u[2].is_check)
    assert_equal(u[3].name, String("tests_cell"))
    _assert_list(unit_names_of(d, String("buck2")), _argv("lib_a", "lints", "tests_cell"))
    _assert_list(unit_names_of(d, String("pack")), _argv("meta"))


def test_units_file_golden() raises:
    var d = _parse(String(_FILE))
    assert_equal(
        units_file_text(d, String("buck2")),
        String("lib_a\t//src/lib_a:lib_a_conda\nlints\t//:docs\nlints\t//:shell_lint\ntests_cell\ttests//functional/...\n"),
    )
    assert_equal(units_file_text(d, String("pack")), String("meta\t//tools/pack:pack\n"))


def test_affected_argv_golden() raises:
    var d = _parse(String(_FILE))
    var v = AffectedValues(String("/logs/c.bin"), String("/logs/u.tsv"), String(_BASE), String(_REV))
    _assert_list(
        render_affected_argv(d, String("buck2"), v),
        _argv(
            "/opt/ci/affected", "--changed=/logs/c.bin", "--units", "/logs/u.tsv",
            "--base=0123456789abcdef0123456789abcdef01234567",
            "--head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
        ),
    )
    _assert_list(render_affected_argv(d, String("pack"), v), _argv("/opt/ci/affected", "/logs/c.bin", "/logs/u.tsv"))


def test_build_targets_argv_golden() raises:
    var d = _parse(String(_FILE))
    _assert_list(render_targets_argv(d, String("lib_a")), _argv("buck2", "build", "--keep-going", "//src/lib_a:lib_a_conda"))
    _assert_list(render_targets_argv(d, String("meta")), _argv("buck2", "build", "//tools/pack:pack"))
    _assert_list(
        render_targets_argv(d, String("lints")), _argv("buck2", "build", "--keep-going", "//:docs", "//:shell_lint")
    )
    var got = String("<rendered>")
    try:
        _ = render_targets_argv(d, String("nope"))
    except e:
        got = String(e)
    assert_equal(got, String("no unit 'nope' is declared"))


def _groups(d: Artifacts, units: List[String]) raises -> String:
    var g = batch_groups(d, units)
    var s = String("")
    for i in range(len(g)):
        s += String("{")
        for k in range(len(g[i])):
            s += String("[") + g[i][k] + String("]")
        s += String("}")
    return s^


def _batch_refusal(d: Artifacts, units: List[String]) -> String:
    try:
        _ = render_batch_argv(d, units)
    except e:
        return String(e)
    return String("<rendered>")


def _shared() raises -> Artifacts:
    """`_FILE` with pack's build_targets equal to buck2's, element-wise
    (both build systems with one command: one group)."""
    var text = String(_FILE).replace(
        String("    args: \"build\"\n  }\n}\nartifacts {\n  name: \"lib_a\""),
        String("    args: \"build\"\n    args: \"--keep-going\"\n  }\n}\nartifacts {\n  name: \"lib_a\""),
    )
    assert_true(text != String(_FILE))
    return _parse(text)


def test_batch_groups_split_by_the_whole_command_in_first_appearance_order() raises:
    var d = _parse(String(_FILE))
    # buck2's command is `buck2 build --keep-going`, pack's `buck2 build`: the
    # same executable, different args, so two groups; the first group is the
    # one whose first unit comes first, units in the order given
    assert_equal(_groups(d, _argv("lib_a", "meta", "lints", "tests_cell")), String("{[lib_a][lints][tests_cell]}{[meta]}"))
    assert_equal(_groups(d, _argv("meta", "tests_cell", "lib_a")), String("{[meta]}{[tests_cell][lib_a]}"))
    assert_equal(_groups(d, List[String]()), String(""))
    # two build systems with one command element-wise are ONE group
    var s = _shared()
    assert_equal(_groups(s, _argv("lib_a", "meta", "lints")), String("{[lib_a][meta][lints]}"))
    assert_equal(_batch_refusal(d, _argv("lib_a", "nope")), String("no unit 'nope' is declared"))
    var got = String("<grouped>")
    try:
        _ = batch_groups(d, _argv("lib_a", "nope"))
    except e:
        got = String(e)
    assert_equal(got, String("no unit 'nope' is declared"))


def test_batch_argv_golden() raises:
    var s = _shared()
    # the shared command, then every unit's targets in the order given
    _assert_list(
        render_batch_argv(s, _argv("lib_a", "meta", "lints")),
        _argv("buck2", "build", "--keep-going", "//src/lib_a:lib_a_conda", "//tools/pack:pack", "//:docs", "//:shell_lint"),
    )
    # one unit: exactly render_targets_argv
    _assert_list(render_batch_argv(s, _argv("lints")), render_targets_argv(s, String("lints")))
    # a target two units share appears once, where it first came
    var dup = _parse(
        String(_FILE).replace(String("  targets: \"tests//functional/...\""), String("  targets: \"//:docs\"\n  targets: \"tests//functional/...\""))
    )
    _assert_list(
        render_batch_argv(dup, _argv("lints", "tests_cell")),
        _argv("buck2", "build", "--keep-going", "//:docs", "//:shell_lint", "tests//functional/..."),
    )


def test_batch_argv_refusals() raises:
    var d = _parse(String(_FILE))
    assert_equal(
        _batch_refusal(d, _argv("lib_a", "meta")),
        String("unit 'meta' builds with `buck2 build` and unit 'lib_a' with `buck2 build --keep-going`: ")
        + String("one batch runs one build_targets command"),
    )
    assert_equal(_batch_refusal(d, List[String]()), String("a batch needs at least one unit"))
    assert_equal(_batch_refusal(d, _argv("lib_a", "nope")), String("no unit 'nope' is declared"))


def test_the_release_argv_ignores_targets() raises:
    # a BUILD step without --affected-by renders exactly what it did before
    var d = _parse(String(_FILE))
    var stamp = ReleaseStamp(String(_REV), String(_REV), 3, 1000)
    _assert_list(
        render_build_argv(d, String("lib_a"), String("/r"), String("linux-x86_64"), stamp),
        _argv("buck2", "build", "//src/lib_a:lib_a_conda[release]", "--out", "/r/lib_a"),
    )


# ── the answer grammar ───────────────────────────────────────────────────────


def _owned() -> List[String]:
    return _argv("lib_a", "lints", "tests_cell")


def _answer_refusal(text: String) -> String:
    try:
        _ = parse_affected_answer(text, _owned())
    except e:
        return String(e)
    return String("<parsed>")


def test_answers_accepted() raises:
    var a = parse_affected_answer(String("UNIT lints\nUNIT lib_a\nAFFECTED 2\n"), _owned())
    assert_false(a.widened)
    _assert_list(a.units, _argv("lints", "lib_a"))
    var none = parse_affected_answer(String("AFFECTED 0"), _owned())
    assert_false(none.widened)
    assert_equal(len(none.units), 0)
    var w = parse_affected_answer(String("WIDENED tools/build/mojo/defs.bzl is a build file\n"), _owned())
    assert_true(w.widened)
    assert_equal(w.reason, String("tools/build/mojo/defs.bzl is a build file"))
    assert_equal(len(w.units), 0)
    # BROKEN: the build graph cannot be configured; never a widening, and no
    # unit (kci_build fails the check on it)
    assert_equal(_answer_refusal(String("BROKEN tests//p:t cannot be configured\n")), String("<parsed>"))
    var b = parse_affected_answer(String("BROKEN tests//p:t cannot be configured"), _owned())
    assert_false(b.widened)
    assert_equal(b.reason, String("tests//p:t cannot be configured"))
    assert_equal(len(b.units), 0)


def test_answers_refused() raises:
    assert_equal(_answer_refusal(String("")), String("printed nothing (expected UNIT lines and one verdict line)"))
    assert_equal(_answer_refusal(String("\n")), String("printed nothing (expected UNIT lines and one verdict line)"))
    assert_equal(
        _answer_refusal(String("UNIT lints\n")),
        String("line 1 'UNIT lints': the last line must be the verdict (AFFECTED <n>, WIDENED <reason> or BROKEN <reason>)"),
    )
    assert_equal(
        _answer_refusal(String("UNIT meta\nAFFECTED 1\n")),
        String("line 1 'UNIT meta': 'meta' is not a unit this build system owns"),
    )
    assert_equal(
        _answer_refusal(String("UNIT lints\nUNIT lints\nAFFECTED 2\n")),
        String("line 2 'UNIT lints': unit 'lints' is named twice"),
    )
    assert_equal(
        _answer_refusal(String("UNIT lints\nAFFECTED 2\n")),
        String("line 2 'AFFECTED 2': says 2 unit(s) but 1 UNIT line(s) came before it"),
    )
    assert_equal(
        _answer_refusal(String("AFFECTED 01\n")), String("line 1 'AFFECTED 01': '01' is not a count")
    )
    assert_equal(
        _answer_refusal(String("AFFECTED 0\nUNIT lints\n")),
        String("line 1 'AFFECTED 0': the verdict must be the last line, and there is one"),
    )
    assert_equal(_answer_refusal(String("WIDENED\n")), String("line 1 'WIDENED': WIDENED needs a reason"))
    assert_equal(
        _answer_refusal(String("UNIT lints\nWIDENED x\n")),
        String("line 2 'WIDENED x': WIDENED reaches every unit, so it comes with no UNIT line"),
    )
    assert_equal(_answer_refusal(String("BROKEN\n")), String("line 1 'BROKEN': BROKEN needs a reason"))
    assert_equal(
        _answer_refusal(String("UNIT lints\nBROKEN x\n")),
        String("line 2 'BROKEN x': BROKEN fails the check, so it comes with no UNIT line"),
    )
    assert_equal(
        _answer_refusal(String("BROKEN x\nAFFECTED 0\n")),
        String("line 1 'BROKEN x': the verdict must be the last line, and there is one"),
    )
    assert_equal(
        _answer_refusal(String("UNIT lints\n\nAFFECTED 1\n")),
        String("line 2 '': not UNIT <name>, AFFECTED <n>, WIDENED <reason> or BROKEN <reason>"),
    )
    assert_equal(
        _answer_refusal(String("unit lints\nAFFECTED 1\n")),
        String("line 1 'unit lints': not UNIT <name>, AFFECTED <n>, WIDENED <reason> or BROKEN <reason>"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
