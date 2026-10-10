# =============================================================================
# src/kci_validate/probe_results.mojo -- what a DEPLOY_PROBE image wrote,
#   read back and judged by kci: the image never decides the verdict.
# =============================================================================
#
# The image writes `/work/out/results.jsonl`: one JSON object per line,
# `{"id": <case id>, "outcome": <string>, "detail": <string>}` (`detail`
# optional). `probe_case_checks` turns it into the row's checks:
#
#   one check per `expect` id, in the order of `expect`:
#     {check: <id>, expected: "pass", got: <outcome>, ok}
#     ok only when exactly ONE row has that id and its outcome is `pass`;
#     got is "" when no row has it, and lists every outcome when several do
#   one check per id the image wrote that `expect` does not name, in the
#   order first written: ok is False, whatever its outcome
#   CHECK_RESULTS (`kci:results`), only when the file is unreadable as
#   results: a line that is not such an object (not JSON, not an object, a
#   missing or non-string `id` or `outcome`, an `id` that is not a case id,
#   a non-string `detail`, another key) is not ok and names its line. Only a final empty line (the file
#   ends in a newline) is not a line; any other empty line is malformed.
#
# An absent file is no rows: every `expect` id is missing. A file over
# RESULTS_MAX_BYTES is refused as a whole. The checks kci adds itself are
# named `kci:<what>`: a case id is [a-z0-9_-]+ and cannot hold `:`, so none
# can take a case's place.
#
# Pure functions over owned values and one file read; no pointer.
# =============================================================================

from std.os.path import exists, getsize

from komira_json import JsonValue, parse_json_value

from kci_api import ResultValidationCheck
from kci_release_machine import is_probe_case_id

comptime RESULTS_FILE: String = "results.jsonl"
"""Under the work mount's `out/`."""
comptime RESULTS_MAX_BYTES: Int = 1048576
comptime CASE_PASS: String = "pass"
comptime CHECK_RESULTS: String = "kci:results"


struct ProbeRow(Copyable, Movable):
    """One line of results.jsonl. Layout: owned Strings."""

    var id: String
    var outcome: String

    def __init__(out self, var id: String, var outcome: String):
        self.id = id^
        self.outcome = outcome^


def _string_member(doc: JsonValue, key: String, required: Bool) raises -> String:
    if not doc.has(key):
        if required:
            raise Error(String("has no \"") + key + String("\""))
        return String("")
    var v = doc.get(key)
    if not v.is_string():
        raise Error(String("\"") + key + String("\" is not a string"))
    return v.as_string()


def parse_probe_line(line: String) raises -> ProbeRow:
    """One results line (file header). RAISES saying what is wrong."""
    var doc: JsonValue
    try:
        doc = parse_json_value(line)
    except e:
        raise Error(String("is not JSON: ") + String(e))
    if not doc.is_object():
        raise Error(String("is not a JSON object"))
    for i in range(doc.num_members()):
        var k = doc.key_at(i)
        if k != String("id") and k != String("outcome") and k != String("detail"):
            raise Error(String("has the key \"") + k + String("\" (only id, outcome and detail)"))
    var id = _string_member(doc, String("id"), True)
    if not is_probe_case_id(id):
        raise Error(String("has the id \"") + id + String("\", not a case id ([a-z0-9_-]+)"))
    var outcome = _string_member(doc, String("outcome"), True)
    _ = _string_member(doc, String("detail"), False)
    return ProbeRow(id^, outcome^)


struct ProbeRows(Movable):
    """Every row read, and why the file could not be read as results ("" when
    it could). Layout: owned values."""

    var rows: List[ProbeRow]
    var problem: String

    def __init__(out self):
        self.rows = List[ProbeRow]()
        self.problem = String("")


def read_probe_rows(path: String) -> ProbeRows:
    """The rows of `path` (file header); an absent file is no rows."""
    var out = ProbeRows()
    try:
        if not exists(path):
            return out^
        if getsize(path) > RESULTS_MAX_BYTES:
            out.problem = String(RESULTS_FILE) + String(" is over ") + String(RESULTS_MAX_BYTES) + String(" bytes")
            return out^
        var lines = open(path, "r").read().split(String("\n"))
        for i in range(len(lines)):
            var line = String(lines[i])
            if line.byte_length() == 0 and i == len(lines) - 1:
                break
            try:
                out.rows.append(parse_probe_line(line))
            except e:
                out.problem = String(RESULTS_FILE) + String(" line ") + String(i + 1) + String(" ") + String(e)
                return out^
    except e:
        out.problem = String(RESULTS_FILE) + String(": ") + String(e)
    return out^


def _named(names: List[String], s: String) -> Bool:
    for i in range(len(names)):
        if names[i] == s:
            return True
    return False


def probe_case_checks(expects: List[String], found: ProbeRows) -> List[ResultValidationCheck]:
    """The case checks of the file header, then CHECK_RESULTS when the file
    could not be read as results."""
    var checks = List[ResultValidationCheck]()
    for i in range(len(expects)):
        ref case_id = expects[i]
        var count = 0
        var got = String("")
        for k in range(len(found.rows)):
            if found.rows[k].id == case_id:
                if count > 0:
                    got += String(", ")
                got += found.rows[k].outcome
                count += 1
        var ok = count == 1 and got == CASE_PASS
        if count > 1:
            got = String("written ") + String(count) + String(" times: ") + got
        checks.append(ResultValidationCheck(case_id.copy(), String(CASE_PASS), got^, ok))
    var extra = List[String]()
    for k in range(len(found.rows)):
        ref row = found.rows[k]
        if _named(expects, row.id) or _named(extra, row.id):
            continue
        extra.append(row.id.copy())
        checks.append(
            ResultValidationCheck(
                row.id.copy(), String(CASE_PASS), row.outcome + String(" (no expect names this case)"), False
            )
        )
    if found.problem.byte_length() > 0:
        checks.append(
            ResultValidationCheck(
                String(CHECK_RESULTS),
                String("one {id, outcome, detail} object per line of ") + String(RESULTS_FILE),
                found.problem.copy(),
                False,
            )
        )
    return checks^
