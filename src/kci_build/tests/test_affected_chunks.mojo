# =============================================================================
# src/kci_build/tests/test_affected_chunks.mojo
#   The batch size of the per-change check (komira#1153,
#   affected_batch.mojo step 1): `batch_chunks` splits a group of n units
#   into ceil(n / max) consecutive slices of near-equal size, the first
#   n % slices one larger, groups and units in order; a group within the
#   limit is untouched; a limit under 1 is refused. Through
#   `build_affected_units`, `BuildRequest.max_batch_units` sizes the runs,
#   each group split on its own, and a slice of one unit runs as a unit
#   alone. The default is DEFAULT_MAX_BATCH_UNITS, 32.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import realpath

from std.testing import TestSuite, assert_equal, assert_true

from kci_api import OUTCOME_SUCCEEDED, RunIdentity
from kci_artifact import parse_artifacts
from kci_build import (
    DEFAULT_MAX_BATCH_UNITS,
    BuildRequest,
    ScriptedRunner,
    ScriptedStep,
    batch_chunks,
    build_affected_units,
)

comptime _HEAD = "BUILD step: --affected-by 0123: AFFECTED"

# Two build_targets commands: `buck2 build` (lib_a, lib_b, lints) and
# `buck2 build --keep-going` (lib_c, lib_d).
comptime _FILE = """schema_version: 1
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
  build_targets {
    executable: "buck2"
    args: "build"
  }
}
build_systems {
  name: "other"
  executable: "buck2"
  args: "build"
  build_targets {
    executable: "buck2"
    args: "build"
    args: "--keep-going"
  }
}
artifacts {
  name: "lib_a"
  build_system: "buck2"
  args: "--out={out_dir}"
  targets: "//src/lib_a:lib_a_conda"
}
artifacts {
  name: "lib_b"
  build_system: "buck2"
  args: "--out={out_dir}"
  targets: "//src/lib_b:lib_b_conda"
}
artifacts {
  name: "lib_c"
  build_system: "other"
  args: "--out={out_dir}"
  targets: "//src/lib_c:lib_c_conda"
}
artifacts {
  name: "lib_d"
  build_system: "other"
  args: "--out={out_dir}"
  targets: "//src/lib_d:lib_d_conda"
}
checks {
  name: "lints"
  build_system: "buck2"
  targets: "//:docs"
}
"""


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _seq(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(String("u") + String(i))
    return out^


def _shape(groups: List[List[String]]) -> String:
    """`[u0 u1][u2]...`: every group's units, in order."""
    var s = String("")
    for g in range(len(groups)):
        s += String("[")
        for i in range(len(groups[g])):
            if i > 0:
                s += String(" ")
            s += groups[g][i]
        s += String("]")
    return s^


def _one(var g: List[String]) -> List[List[String]]:
    var out = List[List[String]]()
    out.append(g^)
    return out^


def test_c1_the_default_is_32() raises:
    assert_equal(DEFAULT_MAX_BATCH_UNITS, 32)
    assert_equal(BuildRequest(RunIdentity(String("gh-9"), 1)).max_batch_units, DEFAULT_MAX_BATCH_UNITS)


def test_c2_ceil_n_over_max_slices_of_near_equal_size_in_order() raises:
    # 7 over 3: ceil = 3 slices, 7 % 3 = 1 of them one larger
    assert_equal(_shape(batch_chunks(_one(_seq(7)), 3)), String("[u0 u1 u2][u3 u4][u5 u6]"))
    # exact multiple
    assert_equal(_shape(batch_chunks(_one(_seq(6)), 3)), String("[u0 u1 u2][u3 u4 u5]"))
    # 299 over 32: 10 slices, 9 of 30 and 1 of 29
    var big = batch_chunks(_one(_seq(299)), 32)
    assert_equal(len(big), 10)
    var total = 0
    for k in range(len(big)):
        assert_equal(len(big[k]), 30 if k < 9 else 29)
        assert_equal(big[k][0], String("u") + String(total))
        total += len(big[k])
    assert_equal(total, 299)


def test_c3_a_group_within_the_limit_and_the_group_order_are_kept() raises:
    var groups = List[List[String]]()
    groups.append(_argv("a", "b"))
    groups.append(_argv("c", "d", "e", "f", "g"))
    groups.append(_argv("h"))
    assert_equal(_shape(batch_chunks(groups, 3)), String("[a b][c d e][f g][h]"))
    assert_equal(_shape(batch_chunks(groups, 5)), String("[a b][c d e f g][h]"))
    # one unit a batch: every unit alone
    assert_equal(_shape(batch_chunks(groups, 1)), String("[a][b][c][d][e][f][g][h]"))


def test_c4_a_limit_under_one_is_refused() raises:
    for bad in range(-1, 1):
        var raised = False
        try:
            _ = batch_chunks(_one(_seq(3)), bad)
        except e:
            raised = True
            assert_true(String(e).find(String("at least 1")) >= 0, String(e))
        assert_true(raised, String("max ") + String(bad))


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kbc_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    return realpath(d)


def _step(var argv: List[String]) -> ScriptedStep:
    var a = _argv("build")
    for i in range(len(argv)):
        a.append(argv[i].copy())
    return ScriptedStep(a^)


def test_c5_max_batch_units_sizes_the_runs_per_group() raises:
    # max 2: the `buck2 build` group (lib_a lib_b lints) is [lib_a lib_b]
    # then lints alone; the --keep-going group (lib_c lib_d) one batch
    var root = _fresh(String("c5"))
    var req = BuildRequest(RunIdentity(String("gh-9"), 1))
    req.work_dir = root + String("/repo")
    req.log_dir = root + String("/logs")
    req.max_batch_units = 2
    var runner = ScriptedRunner()
    runner.expect(_step(_argv("//src/lib_a:lib_a_conda", "//src/lib_b:lib_b_conda")))
    runner.expect(_step(_argv("//:docs")))
    runner.expect(_step(_argv("--keep-going", "//src/lib_c:lib_c_conda", "//src/lib_d:lib_d_conda")))
    var arts = parse_artifacts(String(_FILE), String("artifacts.textproto"))
    var o = build_affected_units(
        req, arts, _argv("lib_a", "lib_b", "lints", "lib_c", "lib_d"), String(_HEAD), List[String](), runner
    )
    assert_equal(o.outcome, String(OUTCOME_SUCCEEDED), o.message)
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.remaining(), 0)
    assert_equal(runner.calls[0].stderr_path, req.log_dir + String("/_batch_1.stderr"))
    # a slice of one runs as a unit alone, with the unit's own logs
    assert_equal(runner.calls[1].stderr_path, req.log_dir + String("/lints.stderr"))
    assert_equal(runner.calls[2].stderr_path, req.log_dir + String("/_batch_2.stderr"))
    assert_equal(o.message, String(_HEAD) + String(": 5 unit(s) built"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
