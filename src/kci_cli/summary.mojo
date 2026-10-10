# =============================================================================
# src/kci_cli/summary.mojo -- the `--summary-file` block of a run (dispatch.mojo's
#   header, 9), and the lines continuous auto-promotion adds to it.
# =============================================================================
#
#   run_summary_markdown  the outcome and exit number, the scope, the
#                         revision and set hash, the workflow check, the
#                         steps, the validations (each failed row, each
#                         check's first passing row), the NEW NAMES blocks
#   promotion_line        the one plain line a run of a main-only stage that
#                         publishes says about its channel (`promoted to
#                         <stage>: ...`, `nothing new`, `PLAN ONLY`), "" for
#                         any other run
#   superseded_line       `superseded: <stage> did nothing for <revision>:
#                         <why>`, the line of a run that ended SUPERSEDED
#                         (exit 0: something newer is ahead), "" for any
#                         other run
#   break_glass_line      `BREAK-GLASS: <ref> <revision> by <actor>:
#                         <reason>`, the first line of every break-glass
#                         run's summary
#   carried_markdown      what a never-backward (main-only) publish CARRIES:
#                         main's first-parent commits after the channel's
#                         previous build of this version, so a run that was
#                         replaced while pending (or never started) is
#                         reported by the run that released its commit
#   append_summary        appends to the file, never truncates
#
# Pure functions over owned values (append_summary writes the one file it is
# given); no pointer, no wildcard origin.
# =============================================================================

from kci_api import (
    CREDENTIAL_PROBE_NOT_RUN_NOTE,
    CREDENTIAL_PROBE_NOT_UNDER_CI,
    OUTCOME_NOOP,
    OUTCOME_SUCCEEDED,
    OUTCOME_SUPERSEDED,
    SCOPE_SELECTIVE,
    STEP_KIND_PUBLISH,
    credential_probe_note,
)
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, new_names_markdown

comptime _STDERR: FileDescriptor = FileDescriptor(2)


def _say(line: String):
    print(line, file=_STDERR)


def run_summary_markdown(result: KciRunResult, step_blocks: List[String], ahead: List[NewNamesReport]) -> String:
    """The `--summary-file` block of a finished run (file header, 9)."""
    var note = credential_probe_note(result.steps)
    var s = String("## kci run --stage ") + result.stage + String(": ") + result.outcome
    if note.byte_length() > 0:
        s += String(", ") + note
    s += String(" (exit ") + String(result.exit_code) + String(")\n\n")
    if result.scope == SCOPE_SELECTIVE:
        var only = String("")
        for i in range(len(result.only)):
            if i > 0:
                only += String(" ")
            only += result.only[i]
        if result.has_affected_by:
            only += String("affected-by ") + result.affected_base
        s += String("SELECTIVE run (") + only + String("): not a full run.")
    else:
        s += String("FULL run.")
    if result.plan:
        s += String(" Dry run (--plan): nothing built, nothing written to a channel.")
    s += String("\n\n")
    s += String("- revision: `") + result.revision + String("`\n")
    if result.set_hash.byte_length() > 0:
        s += String("- set hash: `") + result.set_hash + String("`\n")
    if result.channel.byte_length() > 0:
        s += String("- channel: `") + result.channel + String("`\n")
    if result.has_affected_by:
        if result.affected_verdict.byte_length() == 0:
            s += String("- affected: no answer\n")
        else:
            s += String("- affected: ") + result.affected_verdict
            if result.affected_reason.byte_length() > 0:
                s += String(" (") + result.affected_reason + String(")")
            s += String(", ") + String(len(result.affected_units)) + String(" unit(s):")
            for i in range(len(result.affected_units)):
                s += String(" `") + result.affected_units[i] + String("`")
            s += String("\n")
    if result.workflow_checked:
        s += (
            String("- workflow: `") + result.workflow_path + String("` at `") + result.workflow_sha
            + String("` agrees with the machine file\n")
        )
    else:
        s += String("- workflow: not checked (") + result.workflow_reason + String(")\n")
    if result.has_error:
        var first = result.error.message.copy()
        var nl = result.error.message.find(String("\n"))
        if nl >= 0:
            first = String(result.error.message[byte = 0:nl])
        s += String("- error: `") + result.error.id + String("`: ") + first + String("\n")
    if len(result.steps) > 0:
        s += String("\n| step | kind | outcome |\n|---|---|---|\n")
        for i in range(len(result.steps)):
            ref st = result.steps[i]
            var o = st.outcome.copy()
            if not st.selected:
                o = String("not selected")
            elif o.byte_length() == 0:
                o = String("not reached")
            elif st.credential_probe == CREDENTIAL_PROBE_NOT_UNDER_CI:
                o += String(", ") + String(CREDENTIAL_PROBE_NOT_RUN_NOTE)
            s += String("| ") + st.name + String(" | ") + st.kind + String(" | ") + o + String(" |\n")
    if len(result.validations) > 0:
        s += String("\n| validation | step | outcome |\n|---|---|---|\n")
        for i in range(len(result.validations)):
            ref v = result.validations[i]
            var o = v.outcome.copy() if v.outcome.byte_length() > 0 else v.effect.copy()
            s += String("| ") + v.name + String(" | ") + v.step + String(" | ") + o + String(" |\n")
            # every failed row; and each check's first row when it passed
            # (what was found, e.g. how long the channel's index was waited
            # for), so a pass states its findings too
            var shown = List[String]()
            for k in range(len(v.checks)):
                ref c = v.checks[k]
                if not c.ok:
                    s += String("| | | `") + c.got + String("` |\n")
                    shown.append(c.check.copy())
                    continue
                var seen = False
                for j in range(len(shown)):
                    if shown[j] == c.check:
                        seen = True
                if not seen:
                    s += String("| | | ok: `") + c.got + String("` |\n")
                    shown.append(c.check.copy())
    s += String("\n")
    for i in range(len(step_blocks)):
        s += step_blocks[i]
    for i in range(len(ahead)):
        s += new_names_markdown(ahead[i])
    return s^


def append_summary(path: String, text: String):
    """Append `text` to `path` ("" appends nothing). Never truncates; a file
    that cannot be written is said on stderr."""
    if path.byte_length() == 0:
        return
    try:
        var f = open(path, "a")
        f.write(text)
        f.close()
    except e:
        _say(String("kci: the summary file '") + path + String("' could not be written: ") + String(e))


def _build_of(file: String) -> String:
    """The build string of a conda file name `<name>-<version>-<build>.conda`
    ("" when it is not one)."""
    var tail = String(".conda")
    if not file.endswith(tail):
        return String("")
    var stem = String(file[byte = 0 : file.byte_length() - tail.byte_length()])
    var at = stem.rfind(String("-"))
    if at < 0:
        return String("")
    return String(stem[byte = at + 1 :])


def promotion_line(result: KciRunResult, stage: String, main_only: Bool) -> String:
    """The file header's `promotion_line`: for a run of a main-only stage
    (`main_only`, the machine file's stage without `break_glass`) that ran a
    PUBLISH step and ended SUCCEEDED or NOOP: `<stage>: PLAN ONLY (dry
    run)` for a dry run; else `promoted to <stage>: <names> <build>` when
    something was written, `promoted to <stage>: nothing new (<build>
    already there)` when every file was there. "" for any other run (a
    failure is the workflow's own line, which reads the job's status)."""
    if not main_only:
        return String("")
    var published = False
    for i in range(len(result.steps)):
        if result.steps[i].selected and result.steps[i].kind == STEP_KIND_PUBLISH:
            published = True
    if not published or (result.outcome != OUTCOME_SUCCEEDED and result.outcome != OUTCOME_NOOP):
        return String("")
    if result.plan:
        return stage + String(": PLAN ONLY (dry run)")
    var names = List[String]()
    var build = String("")
    for i in range(len(result.artifacts)):
        ref a = result.artifacts[i]
        var seen = False
        for k in range(len(names)):
            if names[k] == a.name:
                seen = True
        if not seen and a.name.byte_length() > 0:
            names.append(a.name.copy())
        if build.byte_length() == 0:
            build = a.build.copy() if a.build.byte_length() > 0 else _build_of(a.file)
    if result.outcome == OUTCOME_NOOP:
        return String("promoted to ") + stage + String(": nothing new (") + build + String(" already there)")
    return String("promoted to ") + stage + String(": ") + String(" ").join(names) + String(" ") + build


def superseded_line(result: KciRunResult, stage: String, why: String) -> String:
    """The file header's `superseded_line`."""
    if result.outcome != OUTCOME_SUPERSEDED:
        return String("")
    var rev = result.revision
    var short = String(rev[byte = 0 : 8]) if rev.byte_length() >= 8 else rev.copy()
    return String("superseded: ") + stage + String(" did nothing for ") + short + String(": ") + why


def break_glass_line(ref_value: String, revision: String, actor: String, reason: String) -> String:
    """The first line of a break-glass run's summary (file header)."""
    var short = String(revision[byte = 0 : 8]) if revision.byte_length() >= 8 else revision.copy()
    return String("BREAK-GLASS: ") + ref_value + String(" ") + short + String(" by ") + actor + String(": ") + reason


comptime CARRIED_SHOWN_MAX: Int = 40
"""At most this many carried commits are listed one by one."""


def carried_markdown(stage: String, previous: Int, ours: Int, first_parent: List[String]) -> String:
    """The file header's `carried_markdown`. `first_parent` is `git rev-list
    --first-parent --reverse <revision>` (oldest first, so entry i is the
    commit whose first-parent count, a build number, is i + 1); `previous`
    is the channel's highest earlier build of this version (-1 for none),
    `ours` this release's. "" when `ours` is not read."""
    if ours < 0:
        return String("")
    var head = String("#### carried to ") + stage + String("\n\n")
    if previous < 0:
        return head + String("The channel lists no earlier build of this version: build ") + String(ours) + String(
            " is its first.\n\n"
        )
    if previous >= len(first_parent):
        return head + String("The channel's previous build is ") + String(previous) + String(
            ", past this revision's first-parent history: the carried commits cannot be listed.\n\n"
        )
    var n = len(first_parent) - previous
    var s = head + String(n) + String(" commit(s) of main ride in build ") + String(ours) + String(
        " (after build "
    ) + String(previous) + String(
        ", the channel's last of this version). A commit here that is not this run's own revision was released by"
    ) + String(" no run of its own: that run was replaced while pending, or never started.\n\n")
    var shown = 0
    for i in range(previous, len(first_parent)):
        if shown == CARRIED_SHOWN_MAX:
            s += String("- ... and ") + String(n - shown) + String(" more\n")
            break
        s += String("- `") + first_parent[i] + String("`\n")
        shown += 1
    return s + String("\n")
