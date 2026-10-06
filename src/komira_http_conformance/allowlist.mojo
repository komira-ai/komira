# =============================================================================
# allowlist.mojo -- the reviewed list of h2spec cases the server does not pass
# =============================================================================
#
# The allowlist is a text file, one case per line:
#
#     <case id> <reason>             the case fails; the reason says what the
#                                    server does instead
#     <case id> skip: <reason>       h2spec skips the case; the reason says why
#                                    (what the server does not advertise)
#
# where the case id is h2spec's (`http2/6.5/3`, see report.mojo). A reason is
# required. Blank lines and lines starting with `#` are comments.
#
# The gate (`gate`) is shrink-only. It refuses:
#   - a failed case the allowlist does not list as a failure (a new failure);
#   - a skipped case the allowlist does not list as a skip (a new skip: h2spec
#     skips a case when the server does not advertise what it needs, e.g. the
#     concurrent-stream limit case without SETTINGS_MAX_CONCURRENT_STREAMS, so
#     a case that stops running is a lost check, not a pass);
#   - a listed case that passed (a stale entry: the server was fixed, so the
#     line must go, or the list would keep excusing a failure that could come
#     back unnoticed);
#   - a listed case the run did not report at all (a typo, or a suite whose
#     numbering moved);
#   - a line without a reason, and a case listed twice;
#   - a run that did not report exactly `expected_cases` cases, the size of
#     the pinned suite, so a suite that silently ran less (or a report the
#     parser misread) cannot pass.
# Every problem is returned, not only the first, so one red run shows them
# all.
# =============================================================================

from komira_http_conformance.report import (
    CASE_FAILED,
    CASE_PASSED,
    CASE_SKIPPED,
    CaseResult,
)

comptime _SKIP_MARK = "skip:"


@fieldwise_init
struct AllowEntry(Copyable, Movable):
    var id: String
    var reason: String
    var line: Int
    # True for a `skip:` line: the case is expected to be skipped, not failed.
    var skip: Bool


def parse_allowlist(text: String) raises -> List[AllowEntry]:
    """The entries of an allowlist file. Raises on a line with no reason and
    on a case listed twice, naming the line."""
    var out = List[AllowEntry]()
    var n = 0
    for raw in text.split("\n"):
        n += 1
        var line = String(String(raw).strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var sp = line.find(" ")
        if sp < 0:
            raise Error("allowlist line " + String(n) + ": '" + line + "' has no reason")
        var id = String(line[byte=0:sp])
        var reason = String(String(line[byte = sp + 1 :]).strip())
        var skip = reason.startswith(_SKIP_MARK)
        if skip:
            reason = String(String(reason[byte = String(_SKIP_MARK).byte_length() :]).strip())
        if reason.byte_length() == 0:
            raise Error("allowlist line " + String(n) + ": '" + id + "' has no reason")
        for ref e in out:
            if e.id == id:
                raise Error(
                    "allowlist line " + String(n) + ": " + id
                    + " is already listed on line " + String(e.line)
                )
        out.append(AllowEntry(id=id, reason=reason, line=n, skip=skip))
    return out^


def _entry_at(entries: List[AllowEntry], id: String) -> Int:
    """The index of `id`'s entry, or -1."""
    for i in range(len(entries)):
        if entries[i].id == id:
            return i
    return -1


def _listed_as(entries: List[AllowEntry], at: Int) -> String:
    if at < 0:
        return String("")
    var kind = String("a skip") if entries[at].skip else String("a failure")
    return " (listed as " + kind + " on line " + String(entries[at].line) + ")"


def gate(
    results: List[CaseResult], allowlist_text: String, expected_cases: Int
) -> List[String]:
    """Every reason the run fails the shrink-only gate; empty when it passes."""
    var problems = List[String]()
    var entries: List[AllowEntry]
    try:
        entries = parse_allowlist(allowlist_text)
    except e:
        problems.append(String(e))
        return problems^
    if len(results) != expected_cases:
        problems.append(
            "h2spec reported " + String(len(results)) + " cases; the pinned suite has "
            + String(expected_cases)
        )
    for ref r in results:
        var at = _entry_at(entries, r.id)
        if r.outcome == CASE_FAILED and (at < 0 or entries[at].skip):
            problems.append(
                "NEW FAILURE " + r.id + _listed_as(entries, at) + " (" + r.desc + "): "
                + r.detail.replace("\n", " | ")
            )
        elif r.outcome == CASE_SKIPPED and (at < 0 or not entries[at].skip):
            problems.append(
                "NEW SKIP " + r.id + _listed_as(entries, at) + " (" + r.desc
                + "): h2spec skipped the case, so it no longer checks anything"
            )
    for ref e in entries:
        var seen = False
        for ref r in results:
            if r.id != e.id:
                continue
            seen = True
            if r.outcome == CASE_PASSED:
                problems.append(
                    "STALE ALLOWLIST ENTRY " + e.id + " (line " + String(e.line)
                    + "): the case passes now; remove the line"
                )
        if not seen:
            problems.append(
                "UNKNOWN ALLOWLIST ENTRY " + e.id + " (line " + String(e.line)
                + "): the run reported no such case"
            )
    return problems^
