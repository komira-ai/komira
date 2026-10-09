from std.testing import assert_equal, assert_true

from mutate.score import Scored, check_baseline, TestSteps, Verdict, render_bp, render_mutants, render_summary, verdict

# The scorer: each verdict rule and its precedence, statuses that disagree
# with how the steps were declared refused, and the report: a surviving
# mutant is a `survived` row and listed under Survivors, a killed one is
# not; the score line; covcheck's five-field rows.


def _t(name: String, build: String, run: String) -> TestSteps:
    return TestSteps(name, build, run)


def _v(pre: String, var tests: List[TestSteps]) raises -> Verdict:
    return verdict(pre, tests)


def test_survived_when_every_test_passes() raises:
    var ts = List[TestSteps]()
    ts.append(_t("test_a", "ok", "ok"))
    ts.append(_t("test_b", "ok", "ok"))
    var v = _v("ok", ts^)
    assert_equal(v.status, "survived")


def test_killed_by_a_failing_run() raises:
    var ts = List[TestSteps]()
    ts.append(_t("test_a", "ok", "ok"))
    ts.append(_t("test_b", "ok", "fail 1"))
    var v = _v("ok", ts^)
    assert_equal(v.status, "killed")
    assert_equal(v.why, "test_b: failed (exit 1)")


def test_killed_beats_timeout_and_first_kill_named() raises:
    var ts = List[TestSteps]()
    ts.append(_t("test_a", "ok", "timeout 60"))
    ts.append(_t("test_b", "ok", "fail 137"))
    ts.append(_t("test_c", "ok", "fail 1"))
    var v = _v("ok", ts^)
    assert_equal(v.status, "killed")
    assert_equal(v.why, "test_b: failed (exit 137)")
    var only = List[TestSteps]()
    only.append(_t("test_a", "ok", "ok"))
    only.append(_t("test_b", "ok", "timeout 60"))
    var w = _v("ok", only^)
    assert_equal(w.status, "timeout")
    assert_equal(w.why, "test_b: timed out after 60 s")


def test_error_when_the_library_does_not_compile() raises:
    var ts = List[TestSteps]()
    ts.append(_t("test_a", "skipped", "skipped"))
    var v = _v("fail 1", ts^)
    assert_equal(v.status, "error")
    assert_equal(v.why, "the mutated library does not compile (exit 1)")
    var us = List[TestSteps]()
    var w = _v("timeout 600", us^)
    assert_equal(w.status, "error")


def test_a_test_that_does_not_compile_is_error() raises:
    # the compiler's rejection, not a test's kill; its log is kept
    var bs = List[TestSteps]()
    bs.append(_t("test_a", "ok", "ok"))
    bs.append(_t("test_b", "fail 1\npem.mojo:219:43: error: index out of bounds\n", "skipped"))
    var w = _v("ok", bs^)
    assert_equal(w.status, "error")
    assert_equal(w.why, "test_b: does not compile against the mutated library (exit 1)")
    assert_equal(w.log, "pem.mojo:219:43: error: index out of bounds\n")
    var slow = List[TestSteps]()
    slow.append(_t("test_a", "timeout 900", "skipped"))
    assert_equal(_v("ok", slow^).status, "error")
    # a run that fails or times out still decides
    var ks = List[TestSteps]()
    ks.append(_t("test_a", "fail 1", "skipped"))
    ks.append(_t("test_b", "ok", "fail 1"))
    assert_equal(_v("ok", ks^).status, "killed")
    var ts = List[TestSteps]()
    ts.append(_t("test_a", "fail 1", "skipped"))
    ts.append(_t("test_b", "ok", "timeout 120"))
    assert_equal(_v("ok", ts^).status, "timeout")


def test_baseline_must_pass_every_step() raises:
    var ok = List[TestSteps]()
    ok.append(_t("test_a", "ok", "ok"))
    check_baseline("ok", ok)
    # a harness that fails every test (exit 2: the runner refused), a test
    # that does not build unchanged, a library that does not compile
    var flat = List[String]()
    for x in [
        "ok", "ok", "fail 2\ngate_runner: usage error\n", "test_a run: fail 2",
        "ok", "fail 1", "skipped", "test_a build: fail 1",
        "fail 1", "skipped", "skipped", "precompile: fail 1",
        "ok", "ok", "timeout 120", "test_a run: timeout 120",
    ]:
        flat.append(String(x))
    var cases = List[List[String]]()
    for k in range(0, len(flat), 4):
        var row = List[String]()
        for j in range(4):
            row.append(flat[k + j])
        cases.append(row^)
    for c in cases:
        var ts = List[TestSteps]()
        ts.append(_t("test_a", c[1], c[2]))
        var msg = String("")
        try:
            check_baseline(c[0], ts)
        except e:
            msg = String(e)
        assert_true(msg.find(c[3]) >= 0, msg)
        assert_true(msg.find("the mutation harness is broken") >= 0, msg)
    var runner = List[TestSteps]()
    runner.append(_t("test_a", "ok", "fail 2\ngate_runner: usage error\n"))
    try:
        check_baseline("ok", runner)
    except e:
        assert_true(String(e).find("gate_runner: usage error") >= 0, "the failing step's output is in the error")


def test_inconsistent_statuses_refused() raises:
    # precompile failed but a test ran; skipped although its prerequisite
    # was ok; ran although its build failed; unknown words. Three per case:
    # precompile, build, run.
    var flat = List[String]()
    for s in [
        "fail 1", "ok", "ok",
        "ok", "skipped", "skipped",
        "ok", "ok", "skipped",
        "ok", "fail 1", "ok",
        "skipped", "skipped", "skipped",
        "passed", "ok", "ok",
        "ok", "ok", "fail",
        "ok", "ok", "timeout",
    ]:
        flat.append(String(s))
    var cases = List[List[String]]()
    for k in range(0, len(flat), 3):
        var row = List[String]()
        row.append(flat[k])
        row.append(flat[k + 1])
        row.append(flat[k + 2])
        cases.append(row^)
    for c in cases:
        var ts = List[TestSteps]()
        ts.append(_t("test_a", c[1], c[2]))
        var refused = False
        try:
            _ = _v(c[0], ts^)
        except:
            refused = True
        assert_true(refused, c[0] + "/" + c[1] + "/" + c[2])


def _rows() raises -> List[Scored]:
    var rows = List[Scored]()
    var killed = List[TestSteps]()
    killed.append(_t("test_a", "ok", "fail 1"))
    rows.append(Scored("a.mojo", 3, 9, "cmp_negate", "< -> >=", _v("ok", killed^)))
    var planted = List[TestSteps]()
    planted.append(_t("test_a", "ok", "ok"))
    rows.append(Scored("b.mojo", 7, 14, "const_inc", "0 -> 1", _v("ok", planted^)))
    var err = List[TestSteps]()
    err.append(_t("test_a", "skipped", "skipped"))
    rows.append(Scored("b.mojo", 9, 5, "return_early", "insert `return`", _v("fail 1", err^)))
    return rows^


def test_mutants_file() raises:
    var got = render_mutants(_rows(), "src/p/")
    var want = String(
        "# mutation score: killed 1 of 3 (33.33%); survived 1, timeout 0, error 1\n"
        + "src/p/a.mojo\t3\tkilled\tcmp_negate\tcol 9: < -> >=; test_a: failed (exit 1)\n"
        + "src/p/b.mojo\t7\tsurvived\tconst_inc\tcol 14: 0 -> 1; every test passed\n"
        + "src/p/b.mojo\t9\terror\treturn_early\tcol 5: insert `return`; the mutated library does not compile (exit 1)\n"
    )
    assert_equal(got, want)


def test_summary_lists_the_survivor_not_the_killed() raises:
    var ids = List[String]()
    ids.append("c.mojo:1:1:const_dec")
    var why = List[String]()
    why.append("equivalent: unused")
    var md = render_summary("//src/p:p", "# mutate list: 9 mutants, 3 sampled, seed s", _rows(), "src/p/", ids, why)
    var survivors = String(md[byte = md.find("## Survivors") : md.find("## Timeouts")])
    assert_equal(survivors, "## Survivors\n\n- `src/p/b.mojo:7:14` const_inc: 0 -> 1\n\n")
    assert_true(md.find("a.mojo") < 0 or md.find("a.mojo") > md.find("## Timeouts"), "the killed mutant is not listed")
    assert_true(md.find("Score: killed 1 of 3 (33.33%); survived 1, timeout 0, error 1.") >= 0)
    assert_true(md.find("score over compiling mutants: 50.00%") >= 0)
    assert_true(md.find("- `src/p/b.mojo:9:5` return_early (error): the mutated library does not compile (exit 1)") >= 0)
    assert_true(md.find("- `src/p/c.mojo:1:1:const_dec`: equivalent: unused") >= 0)


def test_no_survivor_says_none() raises:
    var rows = List[Scored]()
    var killed = List[TestSteps]()
    killed.append(_t("test_a", "ok", "fail 1"))
    rows.append(Scored("a.mojo", 3, 9, "cmp_negate", "< -> >=", _v("ok", killed^)))
    var md = render_summary("//p:p", "h", rows, "", List[String](), List[String]())
    assert_true(md.find("## Survivors\n\nNone.\n") >= 0)


def test_basis_points() raises:
    assert_equal(render_bp(1, 3), "33.33%")
    assert_equal(render_bp(2, 3), "66.66%")
    assert_equal(render_bp(1, 20), "5.00%")
    assert_equal(render_bp(3, 3), "100.00%")
    assert_equal(render_bp(0, 0), "n/a")


def main() raises:
    test_survived_when_every_test_passes()
    test_killed_by_a_failing_run()
    test_a_test_that_does_not_compile_is_error()
    test_killed_beats_timeout_and_first_kill_named()
    test_error_when_the_library_does_not_compile()
    test_baseline_must_pass_every_step()
    test_inconsistent_statuses_refused()
    test_mutants_file()
    test_summary_lists_the_survivor_not_the_killed()
    test_no_survivor_says_none()
    test_basis_points()
    print("test_score: PASS")
