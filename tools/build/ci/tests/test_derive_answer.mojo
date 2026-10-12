# The answer of //tools/build/ci:derive_checks (change_map/derive.mojo), welded
# to //tools/build/ci:change_map. The universe query's result is a table
# (`Captured`), so each case is the answer kci would read.
#
# The rule of a failed query: ANY failure (buck2 exits non-zero, or is not
# there) is one `BROKEN <reason>` line, which kci turns into a FAILED check
# (KCI-E-BUILD-FAILED), never an exit kci reads as "cannot tell" and never an
# empty answer. buck2's error is in the reason; the target it names, when it
# names one, leads it and decides nothing. The stderr texts are what buck2
# printed for `cquery '//... + tests//...'` over a tree with one planted
# target in tools/build/ci/BUCK.
#
# - the unknown-dependency text ("dependency chain follows") and the
#   invisible-dependency text ("Error looking up configured node") are each
#   BROKEN naming the planted target: a reader of only one form is red.
# - a transport failure naming no target, and a buck2 that is not there (a
#   real process, exit 127), are BROKEN too: an answer that let either through
#   as derived checks or as nothing is red.
# - a stderr over 8 KiB keeps its first and last 4 KiB: a tail-only cut loses
#   the chain's header, and the name with it.
# - a healthy universe answers UNMATCHED, CHECK and DERIVED, in that order:
#   an answer that said BROKEN always, or dropped a declared target matching
#   nothing, is red. The root cell's checks come before the tests cell's, and
#   a group a declared target already matches is not derived.
# - the textproto reader takes each block's first name and every target.

from std.testing import assert_equal, assert_false, assert_true

from change_map.derive import answer_query, broken_line, query_universe, read_artifacts_text, universe_labels
from change_map.graph import kept_stderr
from change_map.process import Captured
from change_map.units import UnitTargets, parse_units_file

comptime UNKNOWN_DEPENDENCY_STDERR = """[2026-10-09T23:48:30.370-05:00] Starting new buck2 daemon...
[2026-10-09T23:48:30.435-05:00] Connected to new buck2 daemon.
[2026-10-09T23:48:30.437-05:00] Build ID: 7bfa5b7e-ebba-42e0-b748-640e03bc7d92
Command failed:
Error in configured node dependency, dependency chain follows (-> indicates depends on, ^ indicates same configuration as previous):
       komira//tools/build/ci:planted_unknown (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)
    -> komira//src/komira_hash:no_such_target_here (^)


Caused by:
    0: looking up unconfigured target node `komira//src/komira_hash:no_such_target_here`
    1: Unknown target `no_such_target_here` from package `komira//src/komira_hash`.
       Did you mean one of the 3 targets in komira//src/komira_hash:BUCK?

       Available targets:
         komira//src/komira_hash:doc_tree
         komira//src/komira_hash:komira_hash
         komira//src/komira_hash:komira_hash_conda
"""
comptime UNKNOWN_DEPENDENCY_LABEL = "komira//tools/build/ci:planted_unknown"

comptime INVISIBLE_DEPENDENCY_STDERR = """[2026-10-09T23:48:34.256-05:00] Build ID: a1ce274c-c2d5-4960-a8cf-59f4c55b7d84
[2026-10-09T23:48:34.270-05:00] File changed: komira//tools/build/ci/BUCK
Command failed:
Error looking up configured node komira//tools/build/ci:planted_invisible (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)

Caused by:
    `komira//third_party/node:node` is not visible to `komira//tools/build/ci:planted_invisible` (run `buck2 uquery --output-attribute visibility komira//third_party/node:node` to check the visibility)
"""
comptime INVISIBLE_DEPENDENCY_LABEL = "komira//tools/build/ci:planted_invisible"

comptime TRANSPORT_STDERR = "Command failed: \nError: the remote execution service did not answer in 600s (transport error: connection reset by peer)\n"

comptime QUERY = "buck2 cquery //... + tests//functional/..."


def _units() raises -> UnitTargets:
    return parse_units_file("lints\t//docs:\n")


def _failed(code: Int, stderr: String) -> Captured:
    return Captured(code, False, String(""), stderr.copy())


def _ok(stdout: String) -> Captured:
    return Captured(0, False, stdout.copy(), String(""))


def _assert_broken(answer: String, named: String, cause: String) raises:
    var lines = answer.split("\n")
    assert_equal(len(lines), 2, answer)
    assert_equal(String(lines[1]), "")
    var head = String("BROKEN the universe query failed")
    if named.byte_length() > 0:
        head += String(", naming ") + named
    assert_true(String(lines[0]).startswith(head + String(": ") + String(QUERY)), answer)
    assert_true(String(lines[0]).find(cause) >= 0, answer)


def test_an_unknown_dependency_is_broken() raises:
    var out = answer_query(_units(), _failed(3, UNKNOWN_DEPENDENCY_STDERR))
    _assert_broken(out, UNKNOWN_DEPENDENCY_LABEL, "Unknown target `no_such_target_here`")


def test_an_invisible_dependency_is_broken() raises:
    var out = answer_query(_units(), _failed(3, INVISIBLE_DEPENDENCY_STDERR))
    _assert_broken(out, INVISIBLE_DEPENDENCY_LABEL, "is not visible to")


def test_any_other_failure_is_broken() raises:
    var out = answer_query(_units(), _failed(1, TRANSPORT_STDERR))
    _assert_broken(out, "", "failed (exit 1): Command failed: Error: the remote execution service")
    assert_true(out.find("connection reset by peer") >= 0)


def test_a_buck2_that_is_not_there_is_broken() raises:
    var q = query_universe("/no/such/buck2")
    assert_false(q.ok())
    var out = answer_query(_units(), q)
    _assert_broken(out, "", "failed (exit 127)")


def test_a_failed_query_is_broken_even_with_targets_on_stdout() raises:
    var q = Captured(3, False, String("komira//src/a:a (cfg)\n"), String(TRANSPORT_STDERR))
    _assert_broken(answer_query(_units(), q), "", "connection reset by peer")


def test_a_long_stderr_keeps_both_ends() raises:
    var long = String(UNKNOWN_DEPENDENCY_STDERR)
    for _ in range(2000):
        long += "yyyyyyyyyy"
    long += "THE-LAST-LINE"
    var kept = kept_stderr(long)
    var n = long.byte_length()
    assert_true(kept.startswith(String(long[byte=0:4096])))
    assert_true(kept.endswith(String(long[byte = n - 4096 :])))
    assert_true(kept.find(String("[... ") + String(n - 8192) + String(" bytes of buck2's stderr cut ...]")) >= 0)
    assert_equal(kept_stderr(UNKNOWN_DEPENDENCY_STDERR), UNKNOWN_DEPENDENCY_STDERR)
    _assert_broken(answer_query(_units(), _failed(3, long)), UNKNOWN_DEPENDENCY_LABEL, "THE-LAST-LINE")


def test_the_broken_line_is_one_line() raises:
    var line = broken_line("a\n  b\tc\r\n")
    assert_equal(line, "BROKEN the universe query failed: a b c\n")


def test_a_healthy_universe_still_derives() raises:
    var out = answer_query(_units(), _ok("komira//src/new_pkg:new_pkg (komira//tools/build/platforms:linux-x86_64#0)\n"))
    assert_equal(out, "UNMATCHED lints //docs:\nCHECK new_pkg //src/new_pkg/...\nDERIVED 1\n")


def test_the_answer_over_a_universe() raises:
    var universe = (
        "tests//functional/a:t (cfg)\n"
        + "komira//src/komira_encoding:komira_encoding (cfg)\n"
        + "komira//src/komira_encoding:komira_encoding_conda (cfg)\n"
        + "komira//src/komira_clock:komira_clock (cfg)\n"
        + "komira//:docs (cfg)\n"
        + "komira//tools/build/ci:affected (cfg)\n"
        + "komira//tools/build/mojo:rules (cfg)\n"
        + "komira//docs:links (cfg)\n"
        + "komira//src/komira_clock:komira_clock (other-cfg)\n"
    )
    var units = parse_units_file(
        "komira_encoding\t//src/komira_encoding:komira_encoding_conda\nlints\t//docs:\ngone\t//src/gone:gone\n"
    )
    var out = answer_query(units, _ok(universe))
    assert_equal(
        out,
        "UNMATCHED gone //src/gone:gone\n"
        + "CHECK repo_root //:\n"
        + "CHECK komira_clock //src/komira_clock/...\n"
        + "CHECK komira_encoding_package //src/komira_encoding/...\n"
        + "CHECK tools_build //tools/build/...\n"
        + "CHECK functional_tests tests//functional/...\n"
        + "DERIVED 5\n",
    )


def test_the_universe_is_its_labels_once_each() raises:
    var labels = universe_labels("komira//b:b (c1)\nkomira//a:a (c1)\nkomira//b:b (c2)\ntests//functional/x:x (c1)\n\n")
    assert_equal(len(labels), 3)
    assert_equal(labels[0], "//a:a")
    assert_equal(labels[1], "//b:b")
    assert_equal(labels[2], "tests//functional/x:x")
    try:
        _ = universe_labels("\n")
        raise Error("an empty universe was answered")
    except e:
        assert_true(String(e).find("the universe is empty") >= 0, String(e))


def test_the_textproto_reader() raises:
    var u = read_artifacts_text(
        "schema_version: 1\nbuild_systems {\n  name: \"buck2\"\n  args: \"build\"\n}\n"
        + "artifacts {\n  name: \"komira_encoding\"\n  build_system: \"buck2\"\n"
        + "  targets: \"//src/komira_encoding:komira_encoding_conda\"\n}\n"
        + "checks {\n  name: \"lints\"\n  targets: \"//:\"\n  targets: \"//docs/...\"\n}\n"
    )
    assert_equal(len(u.names), 3)
    assert_equal(u.names[0], "komira_encoding")
    assert_equal(u.targets[0], "//src/komira_encoding:komira_encoding_conda")
    assert_equal(u.names[2], "lints")
    assert_equal(u.targets[2], "//docs/...")


def main() raises:
    test_an_unknown_dependency_is_broken()
    test_an_invisible_dependency_is_broken()
    test_any_other_failure_is_broken()
    test_a_buck2_that_is_not_there_is_broken()
    test_a_failed_query_is_broken_even_with_targets_on_stdout()
    test_a_long_stderr_keeps_both_ends()
    test_the_broken_line_is_one_line()
    test_a_healthy_universe_still_derives()
    test_the_answer_over_a_universe()
    test_the_universe_is_its_labels_once_each()
    test_the_textproto_reader()
    print("test_derive_answer: PASS")
