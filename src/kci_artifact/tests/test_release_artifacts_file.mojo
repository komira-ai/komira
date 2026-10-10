# =============================================================================
# src/kci_artifact/tests/test_release_artifacts_file.mojo
#   The repository's own release artifacts, release/artifacts.textproto,
#   read through the real reader: it parses and validates, the libraries
#   build stamped, the metapackage is last with every library a member,
#   each artifact's targets are the labels its args build, a declared check
#   (there may be none) names buck2 target patterns only and no package is
#   in two checks, and the per-change check is ready to run (both commands
#   on every build system, and the buck2 build system derives the rest of
#   the checks from the graph, release/ci/derive_checks.py, so every target
#   of the graph is in some unit by construction), and the release set that
#   //tools/build/package:release_set_check builds with the test stamp
#   (tools/build/package/release_set.txt) is this file's metapackage.
# =============================================================================
#
# The file is staged as test data at `artifacts.textproto` (BUCK). A typo
# in it, a forgotten stamp, a library left out of the metapackage, or the
# metapackage moved off the end fails this test, and with it
# `./buck2 build //...`: the release workflow cannot be the first to find it.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from kci_artifact import (
    ReleaseStamp,
    find_build_system,
    parse_affected_answer,
    read_artifacts,
    render_build_argv,
    unit_names_of,
    require_affected_ready,
)

comptime _FILE = "artifacts.textproto"
comptime _SET = "release_set.txt"
comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"
comptime _REL = "/work/rel"


def _stamp() raises -> ReleaseStamp:
    return ReleaseStamp(String(_REV), String(_SRC), 154, 1790994309000)


def _count(argv: List[String], want: String) -> Int:
    var n = 0
    for i in range(len(argv)):
        if argv[i] == want:
            n += 1
    return n


def _flag_values(argv: List[String], flag: String) -> List[String]:
    var out = List[String]()
    for i in range(len(argv) - 1):
        if argv[i] == flag:
            out.append(argv[i + 1])
    return out^


def test_the_declared_names_in_release_order() raises:
    """The names this file declares, in build order: each library after the
    libraries it depends on (release_set_check's stamp check refuses a member
    whose package requires a member listed after it in release_set.txt, which
    this file's test below holds equal to these names), and the metapackage
    last. A name added or dropped here is a change to what is published, so
    it changes this list."""
    assert_equal(read_artifacts(String(_FILE)).schema_version, Int32(1))
    var d = read_artifacts(String(_FILE))
    var want = List[String]()
    want.append(String("komira_encoding"))
    want.append(String("komira_json"))
    want.append(String("komira_protobuf"))
    want.append(String("komira_xml"))
    want.append(String("komira_retry"))
    want.append(String("komira_datetime"))
    want.append(String("komira_textproto"))
    want.append(String("komira_hash"))
    want.append(String("komira_atomic_alias"))
    want.append(String("komira_proto_codec"))
    want.append(String("kci_api"))
    want.append(String("kci_release_channel"))
    want.append(String("kci_artifact_manifest"))
    want.append(String("kci_logs"))
    want.append(String("kci_params"))
    want.append(String("kci_release_machine"))
    want.append(String("komira_wkt"))
    want.append(String("kci_resource_proto"))
    want.append(String("kci_validator_rows"))
    want.append(String("kci_validator_report"))
    want.append(String("kci_workflow_check"))
    want.append(String("komira_anomaly"))
    want.append(String("komira_clock"))
    want.append(String("komira_counters"))
    want.append(String("komira_fork_join"))
    want.append(String("komira_host"))
    want.append(String("komira_job_report_proto"))
    want.append(String("komira_name_registry"))
    want.append(String("komira_parquet_api"))
    want.append(String("komira_runtime_paths"))
    want.append(String("komira_resources"))
    want.append(String("komira_scalar_arithmetic"))
    want.append(String("komira_simd"))
    want.append(String("komira_validation_run"))
    want.append(String("komira_test_run_id"))
    want.append(String("komira_test_verdict"))
    want.append(String("komira_kafka_server"))
    want.append(String("komira_collections"))
    want.append(String("komira_broker_proto"))
    want.append(String("komira_supervisor_proto"))
    want.append(String("komira_plan_proto"))
    want.append(String("komira_rowcell"))
    want.append(String("komira_mail_address"))
    want.append(String("komira_content_line"))
    want.append(String("komira_spsc_ring"))
    want.append(String("komira_sync"))
    want.append(String("kci_cell"))
    want.append(String("komira_mcp_server"))
    want.append(String("komira_chat_proto"))
    want.append(String("komira_contacts_proto"))
    want.append(String("komira_managed_mail_proto"))
    want.append(String("komira_calendar_proto"))
    want.append(String("komira_snapshotter"))
    want.append(String("komira_mail_message"))
    want.append(String("komira_vcard"))
    want.append(String("komira_trace"))
    want.append(String("komira_calendar"))
    want.append(String("komira_calendar_ics"))
    want.append(String("komira_all"))
    assert_equal(len(d.artifacts), len(want))
    for i in range(len(want)):
        assert_equal(d.artifacts[i].name, want[i], String("artifact ") + String(i))


def test_every_library_builds_stamped_into_its_own_directory() raises:
    var d = read_artifacts(String(_FILE))
    for i in range(len(d.artifacts) - 1):
        var name = d.artifacts[i].name.copy()
        var argv = render_build_argv(d, name, String(_REL), String("linux-x86_64"), _stamp())
        assert_equal(argv[0], String("buck2"))
        assert_equal(argv[1], String("build"))
        assert_equal(_count(argv, String("komira.package_stamp=154")), 1)
        assert_equal(_count(argv, String("komira.package_commit=") + String(_SRC)), 1)
        assert_equal(_count(argv, String("komira.package_timestamp_ms=1790994309000")), 1)
        # Exactly one release label, and it is the artifact's own target plus
        # [release]: `//<package path>:<name>_conda[release]`, where the
        # package path is pinned by the target (a library may live outside
        # src/: komira_runtime_paths is in tools/build/mojo).
        assert_equal(len(d.artifacts[i].targets), 1, name)
        var target = d.artifacts[i].targets[0].copy()
        assert_true(target.endswith(String(":") + name + String("_conda")), name)
        assert_equal(_count(argv, target + String("[release]")), 1, name)
        var outs = _flag_values(argv, String("--out"))
        assert_equal(len(outs), 1)
        assert_equal(outs[0], String(_REL) + String("/") + name)


def test_the_metapackage_is_last_and_holds_every_library() raises:
    var d = read_artifacts(String(_FILE))
    var last = len(d.artifacts) - 1
    var meta = d.artifacts[last].name.copy()
    var argv = render_build_argv(d, meta, String(_REL), String("linux-x86_64"), _stamp())
    assert_equal(_count(argv, String("conda-meta")), 1)
    var names = _flag_values(argv, String("--name"))
    assert_equal(len(names), 1)
    assert_equal(names[0], meta)
    var members = _flag_values(argv, String("--member-manifest"))
    assert_equal(len(members), last)
    for i in range(last):
        assert_equal(
            members[i],
            String(_REL) + String("/") + d.artifacts[i].name + String("/manifest.json"),
        )
    var outs = _flag_values(argv, String("--out-dir"))
    assert_equal(len(outs), 1)
    assert_equal(outs[0], String(_REL) + String("/") + meta)
    var labels = _flag_values(argv, String("--label"))
    assert_equal(len(labels), 1)
    assert_true(labels[0].endswith(String(_REV)))
    # The label names the one verb for stages, `kci run`.
    assert_equal(labels[0], String("kci run ") + String(_REV))


def _is_label(arg: String) -> Bool:
    """`//...` or `<cell>//...`, the cell `[A-Za-z0-9_]+`: a buck2 label in
    THIS repository's file (kci itself names no build tool)."""
    var at = arg.find(String("//"))
    if at < 0:
        return False
    var b = arg.as_bytes()
    for i in range(at):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95):
            return False
    return arg.byte_length() > at + 2


def _strip_subtarget(label: String) -> String:
    var at = label.find(String("["))
    if at < 0:
        return label.copy()
    return String(label[byte = 0:at])


def test_every_artifact_names_the_labels_of_its_args_as_targets() raises:
    var d = read_artifacts(String(_FILE))
    for i in range(len(d.artifacts)):
        ref a = d.artifacts[i]
        ref b = d.build_systems[find_build_system(d, a.build_system)]
        var want = List[String]()
        for k in range(len(b.args) + len(a.args)):
            var arg = b.args[k].copy() if k < len(b.args) else a.args[k - len(b.args)].copy()
            if _is_label(arg):
                var t = _strip_subtarget(arg)
                var seen = False
                for j in range(len(want)):
                    if want[j] == t:
                        seen = True
                if not seen:
                    want.append(t^)
        assert_true(len(want) > 0, a.name)
        assert_equal(len(a.targets), len(want), a.name)
        for k in range(len(want)):
            assert_equal(a.targets[k], want[k], a.name)


def _is_pattern(t: String) -> Bool:
    """`<cell>//<path>/...` (a package and every package below it; the path
    not empty) or `<cell>//<path>:` (one package's targets; `//:` is the
    root's), the cell `[A-Za-z0-9_]*`: what buck2 resolves when the check is
    built, so a new target of a covered package is in the check."""
    var at = t.find(String("//"))
    if at < 0 or not _is_label(t):
        return False
    var path = String(t[byte = at + 2 :])
    if path.endswith(String("/...")):
        var root = String(path[byte = 0 : path.byte_length() - 4])
        return root.byte_length() > 0 and root.find(String(":")) < 0 and root.find(String("...")) < 0
    if path.endswith(String(":")):
        var root = String(path[byte = 0 : path.byte_length() - 1])
        return root.find(String(":")) < 0 and root.find(String("...")) < 0 and not root.endswith(String("/"))
    return False


def _cell_and_root(t: String) -> Tuple[String, String, Bool]:
    """(cell, package path, recursive) of a pattern."""
    var at = t.find(String("//"))
    var cell = String(t[byte=0:at])
    var path = String(t[byte = at + 2 :])
    if path.endswith(String("/...")):
        return (cell^, String(path[byte = 0 : path.byte_length() - 4]), True)
    return (cell^, String(path[byte = 0 : path.byte_length() - 1]), False)


def _covers(outer: Tuple[String, String, Bool], pkg_cell: String, pkg: String) -> Bool:
    if outer[0] != pkg_cell:
        return False
    if not outer[2]:
        return pkg == outer[1]
    return pkg == outer[1] or pkg.startswith(outer[1] + String("/"))


def _overlap(a: String, b: String) -> Bool:
    """Some package is matched by both patterns."""
    var x = _cell_and_root(a)
    var y = _cell_and_root(b)
    return _covers(x, y[0], y[1]) or _covers(y, x[0], x[1])


def test_every_check_names_target_patterns() raises:
    """A declared check names buck2 target patterns, never an enumerated
    target, so a target added to a covered package is in the check with no
    edit here."""
    var d = read_artifacts(String(_FILE))
    var bad = String("")
    for i in range(len(d.checks)):
        for k in range(len(d.checks[i].targets)):
            if not _is_pattern(d.checks[i].targets[k]):
                bad += String("\n  ") + d.checks[i].name + String(": ") + d.checks[i].targets[k]
    if bad.byte_length() > 0:
        raise Error(String("check targets that are not `<cell>//<path>/...` or `<cell>//<path>:`:") + bad)


def test_no_package_is_in_two_checks() raises:
    """No package is matched by patterns of two declared checks, or twice by
    one check."""
    var d = read_artifacts(String(_FILE))
    var pats = List[String]()
    var owner = List[String]()
    for i in range(len(d.checks)):
        for k in range(len(d.checks[i].targets)):
            if _is_pattern(d.checks[i].targets[k]):  # the rest: the test above
                pats.append(d.checks[i].targets[k].copy())
                owner.append(d.checks[i].name.copy())
    var bad = String("")
    var n = 0
    for i in range(len(pats)):
        for j in range(i):
            if _overlap(pats[i], pats[j]):
                n += 1
                if n <= 20:
                    bad += String("\n  ") + owner[j] + String(" ") + pats[j] + String(" / ") + owner[i] + String(" ") + pats[i]
    if n > 0:
        raise Error(String(n) + String(" pair(s) of check patterns that match one package twice:") + bad)


def test_the_pattern_reader() raises:
    assert_true(_is_pattern(String("//:")))
    assert_true(_is_pattern(String("//src/kci_api/...")))
    assert_true(_is_pattern(String("//src:")))
    assert_true(_is_pattern(String("tests//functional/...")))
    assert_true(not _is_pattern(String("//...")))
    assert_true(not _is_pattern(String("//src/kci_api:kci_api")))
    assert_true(not _is_pattern(String("//src/kci_api/...:x")))
    assert_true(not _is_pattern(String("//src/.../x/...")))
    assert_true(not _is_pattern(String("//src/:")))
    assert_true(not _is_pattern(String("src/kci_api/...")))
    assert_true(_overlap(String("//src/a/..."), String("//src/a/b/...")))
    assert_true(_overlap(String("//src/a/..."), String("//src/a:")))
    assert_true(_overlap(String("//src/a/b:"), String("//src/a/...")))
    assert_true(not _overlap(String("//src/a/..."), String("//src/ab/...")))
    assert_true(not _overlap(String("//:"), String("//src/...")))
    assert_true(not _overlap(String("//src:"), String("//src/a/...")))
    assert_true(not _overlap(String("//src/a/..."), String("tests//src/a/...")))


def test_the_per_change_check_is_ready() raises:
    var d = read_artifacts(String(_FILE))
    require_affected_ready(d)
    for i in range(len(d.build_systems)):
        ref b = d.build_systems[i]
        assert_true(Bool(b.affected), b.name)
        assert_true(Bool(b.build_targets), b.name)
        assert_equal(b.build_targets.value().args[0], String("release/ci/build_targets.sh"), b.name)


def test_the_affected_command_is_the_real_tool_not_the_widening_script() raises:
    """Every build system's `affected` runs //tools/build/ci:affected through
    buck2, over the change's files, the base commit (for the files the change
    deleted) and the units file; none names the retired widening script (which
    answered WIDENED for every change)."""
    var d = read_artifacts(String(_FILE))
    var want = List[String]()
    want.append(String("run"))
    want.append(String("//tools/build/ci:affected"))
    want.append(String("--"))
    want.append(String("--files"))
    want.append(String("{changed_files}"))
    want.append(String("--base"))
    want.append(String("{base_commit}"))
    want.append(String("--units-file"))
    want.append(String("{units_file}"))
    for i in range(len(d.build_systems)):
        ref b = d.build_systems[i]
        ref c = b.affected.value()
        assert_equal(c.executable, String("buck2"), b.name)
        assert_equal(len(c.args), len(want), b.name)
        for k in range(len(want)):
            assert_equal(c.args[k], want[k], b.name)
        for k in range(len(c.args)):
            assert_true(c.args[k].find(String("widened")) < 0, b.name)
            assert_true(c.args[k].find(String(".sh")) < 0, b.name)


def test_the_text_of_the_file_no_longer_names_the_widening_script() raises:
    """The retired script is named nowhere in the file, in a comment either:
    a reader of the file would go looking for it."""
    var text = Path(String(_FILE)).read_text()
    assert_true(text.find(String("affected_widened")) < 0)
    assert_true(text.find(String("WIDENED every unit")) < 0)


def test_what_the_tool_prints_is_what_kci_reads() raises:
    """The goldens of //tools/build/ci:affected's `--units-file` answers (the
    same strings its own test_the_protocol_answer pins), through kci's parser
    over the units of this file's buck2 build system."""
    var d = read_artifacts(String(_FILE))
    var owned = unit_names_of(d, String("buck2"))
    assert_true(len(owned) >= 1)
    var a = parse_affected_answer(String("UNIT ") + owned[0] + String("\nAFFECTED 1\n"), owned)
    assert_equal(len(a.units), 1)
    assert_true(not a.widened)
    var w = parse_affected_answer(String("WIDENED the project configuration changed\n"), owned)
    assert_true(w.widened)
    assert_equal(len(w.units), 0)
    # a change that reaches no unit is AFFECTED 0: parsed, and kci's
    # decision over every build system's answer refuses it (KCI-E-AFFECTED-VACUOUS)
    var z = parse_affected_answer(String("AFFECTED 0\n"), owned)
    assert_equal(len(z.units), 0)
    assert_true(not z.widened)


def test_the_buck2_build_system_derives_the_checks_from_the_graph() raises:
    """The checks are not listed here: the buck2 build system's
    derive_checks command answers them from the live graph when the check
    runs, so a package added or deleted needs no edit to this file."""
    var d = read_artifacts(String(_FILE))
    var j = find_build_system(d, String("buck2"))
    assert_true(j >= 0)
    assert_true(Bool(d.build_systems[j].derive_checks))
    ref c = d.build_systems[j].derive_checks.value()
    assert_equal(c.executable, String("python3"))
    assert_equal(len(c.args), 2)
    assert_equal(c.args[0], String("release/ci/derive_checks.py"))
    assert_equal(c.args[1], String("{units_file}"))


def _release_set_values(key: String) raises -> List[String]:
    """The values of `key` in release_set.txt, in order: each line not
    empty and not a `#` comment is `<key> <value>`."""
    var out = List[String]()
    var lines = Path(String(_SET)).read_text().split(String("\n"))
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0 or line.startswith(String("#")):
            continue
        var at = line.find(String(" "))
        assert_true(at > 0, String("release_set.txt: a line is not `<key> <value>`: ") + line)
        if String(line[byte = 0:at]) == key:
            out.append(String(line[byte = at + 1 :]))
    return out^


def test_the_stamped_release_set_check_builds_this_files_metapackage() raises:
    """//tools/build/package:release_set_check builds the release set with
    a test stamp from release_set.txt's list (its stamp check holds its
    `libs` and conda-meta arguments to that file). Here the file is held to
    this one: the metapackage, its member libraries in order, and its
    --license, --summary and --home. A library added to the release set and
    not to release_set.txt, or the reverse, fails this library's build."""
    var d = read_artifacts(String(_FILE))
    var last = len(d.artifacts) - 1
    var meta = d.artifacts[last].name.copy()
    var metas = _release_set_values(String("metapackage"))
    assert_equal(len(metas), 1)
    assert_equal(metas[0], meta)
    var members = _release_set_values(String("member"))
    assert_equal(
        len(members),
        last,
        String("release_set.txt names ") + String(len(members)) + String(" member(s), ") + String(_FILE)
        + String(" has ") + String(last) + String(" librar(ies) before its metapackage"),
    )
    for i in range(last):
        assert_equal(members[i], d.artifacts[i].name, String("release_set.txt member ") + String(i))
    var argv = render_build_argv(d, meta, String(_REL), String("linux-x86_64"), _stamp())
    var flags = List[String]()
    flags.append(String("license"))
    flags.append(String("summary"))
    flags.append(String("home"))
    for k in range(len(flags)):
        var flag = flags[k].copy()
        var want = _flag_values(argv, String("--") + flag)
        var got = _release_set_values(flag)
        assert_equal(len(want), 1, String("--") + flag)
        assert_equal(len(got), 1, String("release_set.txt ") + flag)
        assert_equal(got[0], want[0], String("release_set.txt ") + flag)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
