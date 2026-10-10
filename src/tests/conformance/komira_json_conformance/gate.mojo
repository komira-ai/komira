# =============================================================================
# gate.mojo -- one parser's verdicts against the suite and its allowlist
# =============================================================================
#
# A parser gives each file one of four verdicts (runner.mojo assigns them):
#   ACCEPT    the parser returned and, where the testee checks its output,
#             the output represents the text;
#   REJECT    the parser raised;
#   BOUNDARY  the file is not UTF-8 and the entry point takes a String, so
#             the harness refused it before the parser ran (testees.mojo);
#   MISREAD   the parser returned, but its output does not represent the
#             text (komira_jsonl: rows dropped or made up).
# A y_ file is handled right only by ACCEPT; an n_ file by REJECT or
# BOUNDARY. A file that kills the process (an abort, not a raised error) has
# no verdict: see ABORTS: below.
#
# Each parser has an allowlist, `allowlists/<parser>.txt`, one file per line:
#
#     <file name> <reason>
#
# Blank lines and lines starting with `#` are comments. A reason is required.
# A line lists one of:
#   - a y_ or n_ file the parser gets wrong: a reason starting with the
#     wrong verdict it gives, ACCEPTED:, REJECTED:, BOUNDARY: or MISREAD:
#     (a y_ file can be REJECTED:, BOUNDARY: or MISREAD:; an n_ file
#     ACCEPTED: or MISREAD:), then why. The verdict is gated as an i_ record
#     is: a file listed MISREAD: that the parser now ACCEPTs is STALE, and
#     one it now REJECTs (or misreads differently in kind) is a CHANGED
#     VERDICT, so a list entry excuses one wrong verdict, not any;
#   - an i_ file with the verdict the parser gives it: a reason starting
#     ACCEPTS:, REJECTS:, BOUNDARY: or MISREADS:. The suite allows either
#     answer on an i_ file, but each is a choice the parser made (komira_json
#     refuses a lone surrogate escape, for instance), so a change must be a
#     reviewed edit of the line. A REJECTS: record starts with the error's
#     class (its text up to the first ": "), so a change of the layer that
#     refuses the file is a change too;
#   - any file that aborts the parser: a reason `ABORTS: <text> | <note>`.
#     The runner does not feed that file to the parser (one abort ends the
#     whole test); it runs it in a child process instead, which must die by a
#     signal with <text> in its output (AbortCheck).
#
# A crash-only parser (testees.mojo: one that by contract validates nothing,
# so its verdicts mean nothing) lists ABORTS: lines only; its verdicts are
# printed and not gated.
#
# The gate is shrink-only. It refuses:
#   - a y_ file not ACCEPTed, or an n_ file ACCEPTed or MISREAD, that is not
#     listed (a NEW WRONG VERDICT);
#   - a listed y_ or n_ file the parser now gets right (a STALE entry: the fix
#     must remove the line, or the list would keep excusing a regression);
#   - a listed y_ or n_ file the parser still gets wrong, but with another
#     verdict than its line records (a CHANGED VERDICT), and a y_ or n_ line
#     whose reason starts with no wrong-verdict mark its prefix allows;
#   - an ABORTS: file whose child exited normally (a STALE ABORTS ENTRY), or
#     died without the recorded text (an ABORTS TEXT CHANGED);
#   - an i_ file whose verdict is not recorded or differs from the record (a
#     CHANGED i_ VERDICT), and an i_ line with none of the verdict marks;
#   - a listed name that is not a suite file, a line without a reason, a file
#     listed twice, and on a crash-only parser any line that is not ABORTS:;
#   - a run that did not account for exactly the pinned suite's files (run in
#     process, or listed as ABORTS: and run in a child).
# Every problem is returned, not only the first, so one red run shows them
# all.
# =============================================================================

from komira_json_conformance.suite import (
    KIND_I,
    KIND_N,
    KIND_Y,
    SUITE_FILES,
    kind_name,
)

comptime ABORTS_MARK = "ABORTS:"
comptime ACCEPTS_MARK = "ACCEPTS:"
comptime REJECTS_MARK = "REJECTS:"
comptime BOUNDARY_MARK = "BOUNDARY:"
comptime MISREADS_MARK = "MISREADS:"
# The wrong-verdict marks of a y_ or n_ line (past tense, so none is a prefix
# of an i_ mark: "MISREAD:" does not match "MISREADS:").
comptime ACCEPTED_MARK = "ACCEPTED:"
comptime REJECTED_MARK = "REJECTED:"
comptime MISREAD_MARK = "MISREAD:"

comptime V_ACCEPT: UInt8 = 0
comptime V_REJECT: UInt8 = 1
comptime V_BOUNDARY: UInt8 = 2
comptime V_MISREAD: UInt8 = 3


def verdict_name(v: UInt8) -> String:
    if v == V_ACCEPT:
        return String("ACCEPT")
    if v == V_REJECT:
        return String("REJECT")
    if v == V_BOUNDARY:
        return String("BOUNDARY")
    return String("MISREAD")


def _verdict_mark(v: UInt8) -> String:
    """The i_ record mark for verdict `v`."""
    if v == V_ACCEPT:
        return String(ACCEPTS_MARK)
    if v == V_REJECT:
        return String(REJECTS_MARK)
    if v == V_BOUNDARY:
        return String(BOUNDARY_MARK)
    return String(MISREADS_MARK)


def _wrong_mark(v: UInt8) -> String:
    """The y_/n_ record mark for wrong verdict `v`."""
    if v == V_ACCEPT:
        return String(ACCEPTED_MARK)
    if v == V_REJECT:
        return String(REJECTED_MARK)
    if v == V_BOUNDARY:
        return String(BOUNDARY_MARK)
    return String(MISREAD_MARK)


def _wrong_marked(name: String, reason: String) -> Bool:
    """`reason` starts with a wrong verdict the prefix of `name` allows: for
    a y_ file anything but ACCEPTED:, for an n_ file ACCEPTED: or MISREAD:."""
    if name.startswith("y_"):
        return (
            reason.startswith(REJECTED_MARK)
            or reason.startswith(BOUNDARY_MARK)
            or reason.startswith(MISREAD_MARK)
        )
    return reason.startswith(ACCEPTED_MARK) or reason.startswith(MISREAD_MARK)


def error_class(detail: String) -> String:
    """An error's class: its text up to the first ": " (all of it if none)."""
    var at = detail.find(": ")
    if at < 0:
        return detail.copy()
    return String(detail[byte=0:at])


@fieldwise_init
struct AllowEntry(Copyable, Movable):
    var name: String
    var reason: String
    var line: Int

    def aborts(self) -> Bool:
        return self.reason.startswith(ABORTS_MARK)

    def abort_text(self) -> String:
        """For an ABORTS: line, the text its child's output must contain: the
        reason after the mark, up to ` | `."""
        var rest = String(self.reason[byte = String(ABORTS_MARK).byte_length() :])
        var bar = rest.find(" | ")
        var end = bar if bar >= 0 else rest.byte_length()
        var text = String(rest[byte=0:end])
        return String(text.strip())


@fieldwise_init
struct FileResult(Copyable, Movable):
    """What one parser did with one suite file."""

    var name: String
    var kind: UInt8
    var verdict: UInt8
    # The error when the verdict is not ACCEPT; empty otherwise.
    var detail: String

    def right(self) -> Bool:
        """The verdict agrees with the suite (always, for an i_ file)."""
        if self.kind == KIND_Y:
            return self.verdict == V_ACCEPT
        if self.kind == KIND_N:
            return self.verdict == V_REJECT or self.verdict == V_BOUNDARY
        return True

    def describe(self) -> String:
        var line = kind_name(self.kind) + " " + verdict_name(self.verdict) + " " + self.name
        if self.verdict != V_ACCEPT:
            line += " : " + self.detail.replace("\n", " | ")
        return line^


@fieldwise_init
struct AbortCheck(Copyable, Movable):
    """An ABORTS: file run alone in a child process."""

    var name: String
    # The child died by a signal (an abort), rather than exiting.
    var died: Bool
    # How it ended, for the log: `signal N` or `exit N`.
    var how: String
    # Its stdout and stderr (Mojo prints an ABORT on stdout).
    var output: String


def parse_allowlist(text: String) raises -> List[AllowEntry]:
    """The entries of an allowlist file. Raises on a line with no reason and
    on a file listed twice, naming the line."""
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
        var name = String(line[byte=0:sp])
        var reason = String(String(line[byte = sp + 1 :]).strip())
        if reason.byte_length() == 0:
            raise Error("allowlist line " + String(n) + ": '" + name + "' has no reason")
        for ref e in out:
            if e.name == name:
                raise Error(
                    "allowlist line " + String(n) + ": " + name
                    + " is already listed on line " + String(e.line)
                )
        out.append(AllowEntry(name=name, reason=reason, line=n))
    return out^


def _entry_at(entries: List[AllowEntry], name: String) -> Int:
    for i in range(len(entries)):
        if entries[i].name == name:
            return i
    return -1


def aborting_files(entries: List[AllowEntry]) -> List[String]:
    """The files the runner must not feed to the parser in process."""
    var out = List[String]()
    for ref e in entries:
        if e.aborts():
            out.append(e.name)
    return out^


def _i_marked(reason: String) -> Bool:
    return (
        reason.startswith(ACCEPTS_MARK)
        or reason.startswith(REJECTS_MARK)
        or reason.startswith(BOUNDARY_MARK)
        or reason.startswith(MISREADS_MARK)
        or reason.startswith(ABORTS_MARK)
    )


def _check_entries(
    parser: String,
    crash_only: Bool,
    entries: List[AllowEntry],
    suite_names: List[String],
    mut problems: List[String],
):
    """The allowlist's own rules: known names, i_ marks, the ABORTS: form, and
    ABORTS: only on a crash-only parser."""
    for ref e in entries:
        var at = "(line " + String(e.line) + ")"
        var known = False
        for ref s in suite_names:
            if s == e.name:
                known = True
                break
        if not known:
            problems.append(
                "UNKNOWN ALLOWLIST ENTRY " + e.name + " " + at + ": no suite file has that name"
            )
        elif e.aborts():
            if e.abort_text().byte_length() == 0:
                problems.append(
                    "ALLOWLIST ENTRY " + e.name + " " + at
                    + ": an ABORTS: line names the text the abort prints"
                )
        elif crash_only:
            problems.append(
                "ALLOWLIST ENTRY " + e.name + " " + at + ": " + parser
                + " is crash-only; its allowlist lists ABORTS: lines only"
            )
        elif e.name.startswith("i_") and not _i_marked(e.reason):
            problems.append(
                "ALLOWLIST ENTRY " + e.name + " " + at + ": an i_ line records a verdict: "
                + "its reason starts with ACCEPTS:, REJECTS:, BOUNDARY:, MISREADS: or ABORTS:"
            )
        elif not e.name.startswith("i_") and not _wrong_marked(e.name, e.reason):
            var marks = String("REJECTED:, BOUNDARY:, MISREAD:") if e.name.startswith(
                "y_"
            ) else String("ACCEPTED:, MISREAD:")
            problems.append(
                "ALLOWLIST ENTRY " + e.name + " " + at + ": a " + String(e.name[byte=0:2])
                + " line records the wrong verdict: its reason starts with " + marks + " or ABORTS:"
            )


def _check_aborts(
    parser: String, entries: List[AllowEntry], aborts: List[AbortCheck], mut problems: List[String]
):
    """Each ABORTS: line against its child run."""
    for ref e in entries:
        if not e.aborts():
            continue
        var found = -1
        for i in range(len(aborts)):
            if aborts[i].name == e.name:
                found = i
                break
        var at = "(line " + String(e.line) + ")"
        if found < 0:
            problems.append("UNCHECKED ABORTS ENTRY " + e.name + " " + at + ": no child ran it")
        elif not aborts[found].died:
            problems.append(
                "STALE ABORTS ENTRY " + e.name + " " + at + ": " + parser + " no longer aborts on it ("
                + aborts[found].how + ": "
                + aborts[found].output.replace("\n", " | ") + "); remove the line"
            )
        elif e.abort_text() not in aborts[found].output:
            problems.append(
                "ABORTS TEXT CHANGED " + e.name + " " + at + ": the child died ("
                + aborts[found].how + ") without printing '" + e.abort_text() + "': "
                + aborts[found].output.replace("\n", " | ")
            )


def gate(
    parser: String,
    crash_only: Bool,
    results: List[FileResult],
    entries: List[AllowEntry],
    aborts: List[AbortCheck],
    suite_names: List[String],
) -> List[String]:
    """Every reason `parser`'s run fails the shrink-only gate; empty when it
    passes. `suite_names` is every file of the pinned suite; `aborts` is the
    child run of every ABORTS: line."""
    var problems = List[String]()
    if len(suite_names) != SUITE_FILES:
        problems.append(
            "the suite has " + String(len(suite_names)) + " files; the pinned suite has "
            + String(SUITE_FILES)
        )
    _check_entries(parser, crash_only, entries, suite_names, problems)
    _check_aborts(parser, entries, aborts, problems)
    var skipped = len(aborting_files(entries))
    if len(results) + skipped != SUITE_FILES:
        problems.append(
            parser + " ran " + String(len(results)) + " files and " + String(skipped)
            + " ABORTS: files in children; the pinned suite has " + String(SUITE_FILES)
        )
    for ref r in results:
        var at = _entry_at(entries, r.name)
        if at >= 0 and entries[at].aborts():
            problems.append(
                "ALLOWLIST ENTRY " + r.name + " (line " + String(entries[at].line)
                + "): listed as ABORTS: but it was run in process"
            )
        elif crash_only:
            continue
        elif r.kind == KIND_I:
            if at < 0:
                problems.append(
                    "UNRECORDED i_ VERDICT " + parser + ": " + r.describe()
                    + " (record it with " + _verdict_mark(r.verdict) + ")"
                )
                continue
            ref reason = entries[at].reason
            var record = "(line " + String(entries[at].line) + " records '" + reason + "')"
            if not _i_marked(reason):
                continue  # reported by _check_entries
            if not reason.startswith(_verdict_mark(r.verdict)):
                problems.append(
                    "CHANGED i_ VERDICT " + parser + " " + record + ": " + r.describe()
                )
            elif r.verdict == V_REJECT and not String(
                reason[byte = String(REJECTS_MARK).byte_length() :]
            ).strip().startswith(error_class(r.detail)):
                problems.append(
                    "CHANGED i_ REJECTION " + parser + " " + record + ": now '"
                    + error_class(r.detail) + "': " + r.describe()
                )
        elif not r.right() and at < 0:
            var what = String("did not accept a y_ file") if r.kind == KIND_Y else String(
                "did not reject an n_ file"
            )
            problems.append("NEW WRONG VERDICT " + parser + " " + what + ": " + r.describe())
        elif r.right() and at >= 0:
            problems.append(
                "STALE ALLOWLIST ENTRY " + r.name + " (line " + String(entries[at].line)
                + "): " + parser + " gets it right now (" + r.describe() + "); remove the line"
            )
        elif at >= 0 and _wrong_marked(r.name, entries[at].reason) and not entries[
            at
        ].reason.startswith(_wrong_mark(r.verdict)):
            problems.append(
                "CHANGED VERDICT " + parser + " (line " + String(entries[at].line) + " records '"
                + entries[at].reason + "'): " + r.describe() + " (record it with "
                + _wrong_mark(r.verdict) + ")"
            )
    return problems^
