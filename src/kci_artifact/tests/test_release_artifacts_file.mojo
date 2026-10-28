# =============================================================================
# src/kci_artifact/tests/test_release_artifacts_file.mojo
#   The repository's own release artifacts, release/artifacts.textproto,
#   read through the real reader: it parses and validates, the libraries
#   build stamped, the metapackage is last with every library a member,
#   each artifact's targets are the labels its args build, a declared check
#   (there may be none) names buck2 target patterns only and no package is
#   in two checks, no build system declares a per-change command (the pull
#   request's check selects with a BXL script and runs no kci), and the release set that
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
    read_artifacts,
    render_build_argv,
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
    want.append(String("komira_vcard"))
    want.append(String("komira_trace"))
    want.append(String("komira_calendar"))
    want.append(String("komira_calendar_ics"))
    want.append(String("kci_artifact_proto"))
    want.append(String("kci_deploy_model_proto"))
    want.append(String("kci_manifest_proto"))
    want.append(String("kci_artifact"))
    want.append(String("komira_libc"))
    want.append(String("komira_lz4"))
    want.append(String("komira_zlib"))
    want.append(String("komira_async_api"))
    want.append(String("komira_buffer"))
    want.append(String("komira_mail_message"))
    want.append(String("komira_compression"))
    want.append(String("komira_crypto"))
    want.append(String("komira_arrow"))
    want.append(String("komira_dynamic_filter"))
    want.append(String("komira_metrics"))
    want.append(String("komira_secret_store"))
    want.append(String("kci_secret_writer"))
    want.append(String("komira_arrow_ipc"))
    want.append(String("komira_plan_expr"))
    want.append(String("komira_secret_env"))
    want.append(String("komira_column_kernels"))
    want.append(String("komira_log"))
    want.append(String("komira_plan_stats"))
    want.append(String("kci_reconciler"))
    want.append(String("komira_scan_source"))
    want.append(String("kci_cloud"))
    want.append(String("komira_plan_ir"))
    want.append(String("kci_composites"))
    want.append(String("komira_join_assembly"))
    want.append(String("kci_cloud_fake"))
    want.append(String("komira_async"))
    want.append(String("komira_fs"))
    want.append(String("komira_http_core"))
    want.append(String("komira_net"))
    want.append(String("komira_supervisor"))
    want.append(String("komira_http_client"))
    want.append(String("komira_objectstore"))
    want.append(String("kci_pkg_upload"))
    want.append(String("komira_aws_core"))
    want.append(String("komira_gcp_core"))
    want.append(String("komira_oci"))
    want.append(String("kci_publish_oci"))
    want.append(String("kci_release_set"))
    want.append(String("komira_gcp_cloudresourcemanager"))
    want.append(String("komira_gcp_iam"))
    want.append(String("komira_gcp_run"))
    want.append(String("komira_gcp_wif"))
    want.append(String("kci_cloud_gcp"))
    want.append(String("komira_kafka_broker"))
    want.append(String("komira_bench_duckdb"))
    want.append(String("komira_bench_report"))
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


def test_no_build_system_declares_a_per_change_command() raises:
    """The pull request's check runs no kci (pr.yml selects with
    tools/build/ci/affected.bxl): no build system declares an `affected`,
    `build_targets` or `derive_checks` command, and the file declares no check
    (a check is selected by those commands)."""
    var d = read_artifacts(String(_FILE))
    assert_true(len(d.build_systems) >= 1)
    for i in range(len(d.build_systems)):
        ref b = d.build_systems[i]
        assert_true(not Bool(b.affected), b.name)
        assert_true(not Bool(b.build_targets), b.name)
        assert_true(not Bool(b.derive_checks), b.name)
    assert_equal(len(d.checks), 0)


def test_the_text_of_the_file_names_no_retired_command() raises:
    """The retired pieces are named nowhere in the file, in a comment either:
    a reader of the file would go looking for them."""
    var text = Path(String(_FILE)).read_text()
    assert_true(text.find(String("affected_widened")) < 0)
    assert_true(text.find(String("derive_checks")) < 0)
    assert_true(text.find(String("build_targets")) < 0)
    assert_true(text.find(String("ci:affected")) < 0)
    assert_true(text.find(String("rules.txt")) < 0)


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


def test_a_release_declares_one_of_the_two_komira_so_packages() raises:
    """`komira_so_conda` and `komira_so_libkomira_conda` are one package name,
    version and build with different contents (the second adds
    lib/libkomira.so). Two artifacts naming both would hand a channel two
    different files for one name, so the file may declare at most one."""
    var d = read_artifacts(String(_FILE))
    var held = 0
    for i in range(len(d.artifacts)):
        for k in range(len(d.artifacts[i].targets)):
            var t = d.artifacts[i].targets[k].copy()
            if t.endswith(String(":komira_so_conda")) or t.endswith(String(":komira_so_libkomira_conda")):
                held += 1
    assert_true(held <= 1, "release/artifacts.textproto declares both komira_so packages")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
