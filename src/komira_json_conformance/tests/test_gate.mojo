# =============================================================================
# test_gate.mojo -- the allowlist reader, the shrink-only gate and the suite
# guard, alone
# =============================================================================
#
# The gate is what turns a parser's verdicts into red or green, so each of
# its refusals is checked here on made-up verdicts and made-up file names (no
# parser runs and no JSON is read or written): a new wrong verdict on a y_
# and on an n_ file (an n_ MISREAD counts as accepted, an n_ BOUNDARY as
# refused), a STALE entry, an i_ entry whose reason starts with none of the
# verdict marks, an unknown name, an ABORTS: file that was run in process, an
# ABORTS: line whose child exited (STALE), died without the recorded text, or
# never ran, an i_ verdict not recorded or changed (a REJECTS: record whose
# error class changed included), a listed y_ or n_ file whose wrong verdict
# differs from the one its line records (a CHANGED VERDICT) or whose line
# records none its prefix allows, a crash-only parser's allowlist holding a
# line that is not ABORTS:, a run over fewer files than the suite, and the
# allowlist's own errors (no reason, a name listed twice). The clean case
# passes with listed wrong verdicts, the i_ verdicts recorded and a live
# ABORTS: line.
#
# The suite guard (`check_suite_names`, `load_suite_from`) is checked on name
# lists: a count off by one, a stray non-.json file, a name with no verdict
# prefix, and on directories: a missing one and an empty one.
#
# Defects it catches: a gate that lets a wrong verdict through, lets a y_ or
# n_ line listed for one wrong verdict excuse another, forgets the
# stale check (a fixed parser would keep its excuse), lets an ABORTS: line
# hide a file that no longer aborts, or counts a short run as complete; a
# suite guard that lets a partial extraction pass.
# =============================================================================

from std.os import mkdir
from std.testing import assert_equal, assert_raises, assert_true

from komira_runtime_paths import test_tmpdir

from komira_json_conformance import (
    KIND_I,
    KIND_N,
    KIND_Y,
    SUITE_FILES,
    SUITE_I_FILES,
    SUITE_N_FILES,
    V_ACCEPT,
    V_BOUNDARY,
    V_MISREAD,
    V_REJECT,
    AbortCheck,
    FileResult,
    aborting_files,
    check_suite_names,
    gate,
    load_suite_from,
    parse_allowlist,
)


def _suite_names() -> List[String]:
    """SUITE_FILES made-up names with the suite's prefixes and counts."""
    var out = List[String]()
    for i in range(SUITE_FILES):
        if i < SUITE_N_FILES:
            out.append("n_" + String(i) + ".json")
        elif i < SUITE_N_FILES + SUITE_I_FILES:
            out.append("i_" + String(i) + ".json")
        else:
            out.append("y_" + String(i) + ".json")
    return out^


def _right_verdicts(names: List[String]) -> List[FileResult]:
    """Every file handled right: n_ rejected, i_ and y_ accepted."""
    var out = List[FileResult]()
    for ref n in names:
        if n.startswith("n_"):
            out.append(FileResult(name=n, kind=KIND_N, verdict=V_REJECT, detail=String("E: x")))
        elif n.startswith("i_"):
            out.append(FileResult(name=n, kind=KIND_I, verdict=V_ACCEPT, detail=String("")))
        else:
            out.append(FileResult(name=n, kind=KIND_Y, verdict=V_ACCEPT, detail=String("")))
    return out^


def _i_record(names: List[String], skip: String = String("")) -> String:
    """An ACCEPTS: line for every i_ name but `skip`."""
    var out = String("")
    for ref n in names:
        if n.startswith("i_") and n != skip:
            out += n + " ACCEPTS: recorded\n"
    return out^


def _first_i() -> String:
    return String("i_") + String(SUITE_N_FILES) + ".json"


def _has(problems: List[String], prefix: String) -> Bool:
    for ref p in problems:
        if p.startswith(prefix):
            return True
    return False


def _at(results: List[FileResult], name: String) -> Int:
    for i in range(len(results)):
        if results[i].name == name:
            return i
    return -1


def _none() -> List[AbortCheck]:
    return List[AbortCheck]()


def test_clean_run_passes() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    assert_equal(len(gate("p", False, r, parse_allowlist(_i_record(names)), _none(), names)), 0)


def test_i_verdicts() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    var i_name = _first_i()
    # Not recorded.
    var problems = gate("p", False, r, parse_allowlist(_i_record(names, i_name)), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "UNRECORDED i_ VERDICT p: i ACCEPT " + i_name))
    # Recorded as REJECTS:, but accepted.
    var text = _i_record(names, i_name) + i_name + " REJECTS: E refuses it\n"
    problems = gate("p", False, r, parse_allowlist(text), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "CHANGED i_ VERDICT p"))
    # Recorded as REJECTS: E, rejected with error class E: passes; with
    # another class: a changed rejection; refused at the boundary: changed.
    r[_at(r, i_name)].verdict = V_REJECT
    r[_at(r, i_name)].detail = String("E: refused")
    assert_equal(len(gate("p", False, r, parse_allowlist(text), _none(), names)), 0)
    r[_at(r, i_name)].detail = String("F: refused elsewhere")
    problems = gate("p", False, r, parse_allowlist(text), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "CHANGED i_ REJECTION p"))
    r[_at(r, i_name)].verdict = V_BOUNDARY
    problems = gate("p", False, r, parse_allowlist(text), _none(), names)
    assert_true(_has(problems, "CHANGED i_ VERDICT p"))


def test_new_wrong_verdicts() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    r[_at(r, "n_0.json")].verdict = V_ACCEPT
    r[_at(r, "n_1.json")].verdict = V_MISREAD
    r[_at(r, String("y_") + String(SUITE_FILES - 1) + ".json")].verdict = V_REJECT
    r[_at(r, String("y_") + String(SUITE_FILES - 2) + ".json")].verdict = V_MISREAD
    # An n_ file refused at the String boundary is refused: not a problem.
    r[_at(r, "n_2.json")].verdict = V_BOUNDARY
    var problems = gate("p", False, r, parse_allowlist(_i_record(names)), _none(), names)
    assert_equal(len(problems), 4)
    var n_wrong = 0
    var y_wrong = 0
    for ref p in problems:
        if "did not reject an n_ file" in p:
            n_wrong += 1
        if "did not accept a y_ file" in p:
            y_wrong += 1
    assert_equal(n_wrong, 2)
    assert_equal(y_wrong, 2)


def _live_abort(name: String) -> AbortCheck:
    return AbortCheck(
        name=name, died=True, how=String("signal 4"), output=String("ABORT: boom at x.mojo:1\n")
    )


def test_listed_wrong_verdicts_pass_and_live_abort() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    r[_at(r, "n_0.json")].verdict = V_ACCEPT
    var aborting = _first_i()
    r.pop(_at(r, aborting))
    var text = (
        "# comment\n\nn_0.json ACCEPTED: lenient\n" + aborting + " ABORTS: boom | a note\n"
        + _i_record(names, aborting)
    )
    var entries = parse_allowlist(text)
    assert_equal(len(aborting_files(entries)), 1)
    assert_equal(aborting_files(entries)[0], aborting)
    var aborts = List[AbortCheck]()
    aborts.append(_live_abort(aborting))
    assert_equal(len(gate("p", False, r, entries, aborts, names)), 0)


def test_abort_entries_checked() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    var aborting = _first_i()
    r.pop(_at(r, aborting))
    var entries = parse_allowlist(_i_record(names, aborting) + aborting + " ABORTS: boom\n")
    # The child exited: the line is stale.
    var aborts = List[AbortCheck]()
    aborts.append(
        AbortCheck(name=aborting, died=False, how=String("exit 0"), output=String("CHILD ACCEPT"))
    )
    var problems = gate("p", False, r, entries, aborts, names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "STALE ABORTS ENTRY " + aborting))
    # The child died, but not with the recorded text.
    aborts[0] = AbortCheck(
        name=aborting, died=True, how=String("signal 6"), output=String("ABORT: other")
    )
    problems = gate("p", False, r, entries, aborts, names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "ABORTS TEXT CHANGED " + aborting))
    # No child ran it.
    problems = gate("p", False, r, entries, _none(), names)
    assert_true(_has(problems, "UNCHECKED ABORTS ENTRY " + aborting))
    # An ABORTS: line with no text to check.
    problems = gate(
        "p", False, r, parse_allowlist(_i_record(names, aborting) + aborting + " ABORTS: | x\n"),
        aborts, names,
    )
    assert_true(_has(problems, "ALLOWLIST ENTRY " + aborting))


def test_crash_only() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    # Wrong verdicts and no i_ records: not gated.
    r[_at(r, "n_0.json")].verdict = V_ACCEPT
    assert_equal(len(gate("p", True, r, parse_allowlist(String("")), _none(), names)), 0)
    # Any line that is not ABORTS: is refused.
    var problems = gate(
        "p", True, r, parse_allowlist(String("n_0.json ACCEPTED: lenient\n")), _none(), names
    )
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "ALLOWLIST ENTRY n_0.json"))


def test_y_n_verdicts_recorded() raises:
    var names = _suite_names()
    var y_name = String("y_") + String(SUITE_FILES - 1) + ".json"
    var r = _right_verdicts(names)
    # A planted y_ line recording MISREAD:, and the parser misreads it: passes.
    var text = _i_record(names) + y_name + " MISREAD: rows made up\n"
    r[_at(r, y_name)].verdict = V_MISREAD
    r[_at(r, y_name)].detail = String("MISREAD: 2 rows")
    assert_equal(len(gate("p", False, r, parse_allowlist(text), _none(), names)), 0)
    # The parser now refuses it instead: a changed verdict, not still excused.
    r[_at(r, y_name)].verdict = V_REJECT
    r[_at(r, y_name)].detail = String("E: refused")
    var problems = gate("p", False, r, parse_allowlist(text), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "CHANGED VERDICT p (line "))
    assert_true("y REJECT " + y_name in problems[0])
    # Refused at the String boundary: changed too.
    r[_at(r, y_name)].verdict = V_BOUNDARY
    problems = gate("p", False, r, parse_allowlist(text), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "CHANGED VERDICT p"))
    # The parser now accepts it: the line is stale.
    r[_at(r, y_name)].verdict = V_ACCEPT
    r[_at(r, y_name)].detail = String("")
    problems = gate("p", False, r, parse_allowlist(text), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "STALE ALLOWLIST ENTRY " + y_name))
    # An n_ line recording MISREAD: and the parser now accepts the file
    # outright: changed; recorded ACCEPTED: it passes.
    r = _right_verdicts(names)
    r[_at(r, "n_0.json")].verdict = V_ACCEPT
    var n_text = _i_record(names) + "n_0.json MISREAD: 0 rows\n"
    problems = gate("p", False, r, parse_allowlist(n_text), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "CHANGED VERDICT p"))
    assert_true("n ACCEPT n_0.json" in problems[0])
    n_text = _i_record(names) + "n_0.json ACCEPTED: lenient\n"
    assert_equal(len(gate("p", False, r, parse_allowlist(n_text), _none(), names)), 0)
    # A y_ or n_ line with no wrong-verdict mark its prefix allows: refused,
    # whatever the verdict (ACCEPTED: is right for a y_ file; REJECTED: and
    # the i_ form MISREADS: are right or wrong-spelled for an n_ file).
    var bad_lines: List[String] = [
        "n_0.json lenient\n",
        "n_0.json REJECTED: x\n",
        "n_0.json MISREADS: x\n",
    ]
    for ref bad in bad_lines:
        problems = gate("p", False, r, parse_allowlist(_i_record(names) + bad), _none(), names)
        assert_equal(len(problems), 1)
        assert_true(_has(problems, "ALLOWLIST ENTRY n_0.json"))
    r = _right_verdicts(names)
    r[_at(r, y_name)].verdict = V_REJECT
    problems = gate(
        "p", False, r, parse_allowlist(_i_record(names) + y_name + " ACCEPTED: x\n"), _none(),
        names,
    )
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "ALLOWLIST ENTRY " + y_name))


def test_stale_entry() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    var problems = gate(
        "p", False, r, parse_allowlist("n_0.json ACCEPTED: lenient\n" + _i_record(names)),
        _none(), names,
    )
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "STALE ALLOWLIST ENTRY n_0.json"))


def test_bad_entries() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    var i_name = _first_i()
    var text = _i_record(names, i_name) + i_name + " either way\nn_nope.json no such file\n"
    var problems = gate("p", False, r, parse_allowlist(text), _none(), names)
    assert_equal(len(problems), 2)
    assert_true(_has(problems, "ALLOWLIST ENTRY " + i_name))
    assert_true(_has(problems, "UNKNOWN ALLOWLIST ENTRY n_nope.json"))
    # An ABORTS: entry whose file was run in process anyway.
    var aborts = List[AbortCheck]()
    aborts.append(_live_abort(i_name))
    var ran = gate(
        "p", False, r, parse_allowlist(_i_record(names, i_name) + i_name + " ABORTS: boom\n"),
        aborts, names,
    )
    assert_true(_has(ran, "ALLOWLIST ENTRY " + i_name))
    assert_true(_has(ran, "p ran " + String(SUITE_FILES)))


def test_short_run_fails() raises:
    var names = _suite_names()
    var r = _right_verdicts(names)
    _ = r.pop()
    var problems = gate("p", False, r, parse_allowlist(_i_record(names)), _none(), names)
    assert_equal(len(problems), 1)
    assert_true(_has(problems, "p ran " + String(SUITE_FILES - 1)))
    _ = names.pop()
    assert_true(
        _has(gate("p", False, r, parse_allowlist(_i_record(names)), _none(), names), "the suite has")
    )


def test_allowlist_errors() raises:
    with assert_raises(contains="has no reason"):
        _ = parse_allowlist(String("n_0.json\n"))
    with assert_raises(contains="already listed on line 1"):
        _ = parse_allowlist(String("n_0.json a\nn_0.json b\n"))


def test_suite_guard() raises:
    var names = _suite_names()
    check_suite_names(names)
    var short = names.copy()
    _ = short.pop()
    with assert_raises(contains="the pinned suite has"):
        check_suite_names(short)
    var stray = names.copy()
    stray[0] = String("README.md")
    with assert_raises(contains="not a .json file"):
        check_suite_names(stray)
    var unprefixed = names.copy()
    unprefixed[0] = String("x_0.json")
    with assert_raises(contains="none of the prefixes"):
        check_suite_names(unprefixed)
    var root = test_tmpdir()
    with assert_raises():
        _ = load_suite_from(root + "/no_such_directory")
    mkdir(root + "/empty_suite")
    with assert_raises(contains="holds 0 y_, 0 n_ and 0 i_ files"):
        _ = load_suite_from(root + "/empty_suite")


def main() raises:
    test_clean_run_passes()
    test_i_verdicts()
    test_new_wrong_verdicts()
    test_listed_wrong_verdicts_pass_and_live_abort()
    test_abort_entries_checked()
    test_crash_only()
    test_y_n_verdicts_recorded()
    test_stale_entry()
    test_bad_entries()
    test_short_run_fails()
    test_allowlist_errors()
    test_suite_guard()
    print("PASS komira_json_conformance gate")
