from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_COBERTURA, Analysis, Input, Options, Sources, analyze
from covcheck.paths import RepoFiles, generated_test_main, report_test_main, repo_files_of
from covcheck.ratchet import Ratchet

# A welded test's generated main (the layout probe a mojo_gcp_client or
# mojo_aws_client generates) is named in its report by its output path in
# the package, which is no file of the checkout. `covcheck report` sets it
# aside as a test source; every other path that names a repository
# directory but no repository file stays an error.

comptime PKG = "src/komira_gcp_firestore"
# The two reports of the failing coverage run, as the build names them.
comptime LISTEN = "buck-out/v2/art/komira/03cc1a891c89e4be/src/komira_gcp_firestore/__komira_gcp_firestore_listen__/cov/tests/_layout_probe.xml"
comptime V1 = "buck-out/v2/art/komira/03cc1a891c89e4be/src/komira_gcp_firestore/__komira_gcp_firestore_v1__/cov/tests/_layout_probe.xml"
comptime LISTEN_PROBE = "src/komira_gcp_firestore/gen/komira_gcp_firestore_listen/_layout_probe.mojo"
comptime V1_PROBE = "src/komira_gcp_firestore/gen/komira_gcp_firestore_v1/_layout_probe.mojo"


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("BUCK")
    l.append(String(PKG) + "/BUCK")
    l.append(String(PKG) + "/firestore_value.mojo")
    # A repository directory with no .mojo file (one would count as a file
    # no test compiled).
    l.append(String(PKG) + "/tests/README.md")
    return repo_files_of(l)


def _sources() -> Sources:
    var s = Sources(String(""))
    s.texts[String(PKG) + "/firestore_value.mojo"] = String("a\nb\nc\n")
    return s^


def _report(origin: String, path: String) -> Input:
    """A Cobertura report from `origin` naming `path` (hits on line 1) and
    the package's source (line 1 hit, line 2 not)."""
    return Input(String(FORMAT_COBERTURA), String(""), origin, String(
        "<coverage><classes><class filename=\"") + path + String("\"><lines>"
        "<line number=\"1\" hits=\"1\"/></lines></class>"
        "<class filename=\"src/komira_gcp_firestore/firestore_value.mojo\"><lines>"
        "<line number=\"1\" hits=\"1\"/><line number=\"2\" hits=\"0\"/></lines></class></classes></coverage>"
    ))


def _run(reports: List[Input], opts: Options) raises -> Analysis:
    return analyze(reports, List[Input](), _repo(), Ratchet(), _sources(), opts)


def _error_of(origin: String, path: String) raises -> String:
    """The error analyze raises on one report from `origin` naming `path`;
    the empty string when it raises none."""
    var r = List[Input]()
    r.append(_report(origin, path))
    try:
        _ = _run(r, Options())
    except e:
        return String(e)
    return String("")


def test_generated_layout_probes_are_test_sources() raises:
    # The failing run: each client's report names its own generated probe.
    # Before the fix: "unmapped paths (each names a repository directory but
    # no repository file)" naming both.
    var r = List[Input]()
    r.append(_report(String(LISTEN), String(LISTEN_PROBE)))
    r.append(_report(String(V1), String(V1_PROBE)))
    var a = _run(r, Options())
    assert_equal(a.excluded_test_files, 2)
    assert_equal(len(a.packages), 1)
    assert_equal(a.packages[0].package, String(PKG))
    assert_equal(a.packages[0].files, 1)
    assert_equal(a.packages[0].line_found, 2)
    assert_equal(a.packages[0].line_hit, 1)
    # No source to measure: left out with --include-tests too.
    var o = Options()
    o.include_tests = True
    var b = _run(r, o)
    assert_equal(b.excluded_test_files, 2)
    assert_equal(b.packages[0].line_found, 2)
    # The gate of another package does not count it.
    o = Options()
    o.only_package = String("src/other")
    o.target_bp = 0
    assert_equal(_run(r, o).excluded_test_files, 0)


def test_unmapped_repository_paths_stay_errors() raises:
    var prefix = String("unmapped paths (each names a repository directory but no repository file)")
    # A file missing from a repository directory, in a test's report.
    var e = _error_of(String(LISTEN), String(PKG) + "/gone.mojo")
    assert_true(e.startswith(prefix) and e.find("gone.mojo") >= 0, e)
    # In an output directory, but not the report's own test.
    e = _error_of(String(LISTEN), String(PKG) + "/gen/komira_gcp_firestore_listen/firestore.mojo")
    assert_true(e.startswith(prefix) and e.find("firestore.mojo") >= 0, e)
    # The report's own test name, in a repository directory (a deleted
    # hand-written test): the checkout and the report disagree.
    e = _error_of(String(LISTEN), String(PKG) + "/tests/_layout_probe.mojo")
    assert_true(e.startswith(prefix) and e.find("tests/_layout_probe.mojo") >= 0, e)
    # The same generated path from a report that is no test's.
    e = _error_of(String("cov.xml"), String(LISTEN_PROBE))
    assert_true(e.startswith(prefix) and e.find("_layout_probe.mojo") >= 0, e)
    # A report under cov/ that is not a test's (cov/gate/...).
    e = _error_of(String("x/cov/gate/_layout_probe.xml"), String(LISTEN_PROBE))
    assert_true(e.startswith(prefix), e)


def test_report_test_main() raises:
    assert_equal(report_test_main(String(LISTEN)), String("_layout_probe.mojo"))
    assert_equal(report_test_main(String("a/cov/branch/test_x.info")), String("test_x.mojo"))
    assert_equal(report_test_main(String("cov/tests/test_x.xml")), String("test_x.mojo"))
    assert_equal(report_test_main(String("a/cov/tests/test_x.info")), String(""))
    assert_equal(report_test_main(String("a/cov/branch/test_x.xml")), String(""))
    assert_equal(report_test_main(String("a/cov/tests/.xml")), String(""))
    assert_equal(report_test_main(String("a/kcov/tests/test_x.xml")), String(""))
    assert_equal(report_test_main(String("test_x.xml")), String(""))
    var repo = _repo()
    assert_true(generated_test_main(String(LISTEN), String(LISTEN_PROBE), repo))
    # No BUCK file above it: no package to set it aside in.
    assert_true(not generated_test_main(String(LISTEN), String("nowhere/gen/x/_layout_probe.mojo"), repo))
    assert_true(not generated_test_main(String(LISTEN), String("_layout_probe.mojo"), repo))


def main() raises:
    test_generated_layout_probes_are_test_sources()
    test_unmapped_repository_paths_stay_errors()
    test_report_test_main()
    print("test_generated_tests: PASS")
