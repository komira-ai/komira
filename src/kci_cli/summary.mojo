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
#   break_glass_line      `BREAK-GLASS: <ref> <revision> by <actor>:
#                         <reason>`, the first line of every break-glass
#                         run's summary
#   carried_markdown      what a never-backward (main-only) publish CARRIES:
#                         main's first-parent commits after the channel's
#                         previous build of this version, so a run that was
#                         replaced while pending (or never started) is
#                         reported by the run that released its commit
#   deploy_markdown       a DEPLOY step's block: its cell and cloud, the
#                         outcome, the plan (or what the apply did) and the
#                         deploy keys; leftover and left behind are listed,
#                         never deleted; and the two v1 limits (no cell
#                         lease, no destroy verb)
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
    SCOPE_SELECTIVE,
    STEP_KIND_PUBLISH,
    credential_probe_note,
)
from kci_api import ResultDeploy
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
        s += String(" Dry run (--plan): nothing built, nothing written to a channel or a cell.")
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


comptime DEPLOY_NO_LEASE_LINE: String = (
    "- v1 has no cell lease: only pushes to main deploy, one run at a time; an apply run by hand outside CI is"
    " serialized with nothing"
)
"""The first of a DEPLOY block's v1 limits (deploy_step.md, "What v1 does not do")."""

comptime DEPLOY_NO_DESTROY_LINE: String = (
    "- v1 has no destroy verb: a resource removed from the file is left standing as leftover; teardown is a"
    " human step"
)
"""The second of a DEPLOY block's v1 limits."""


def _ids_line(label: String, ids: List[String]) -> String:
    var s = String("- ") + label + String(":")
    for i in range(len(ids)):
        s += (String(" `") if i == 0 else String(", `")) + ids[i] + String("`")
    return s + String("\n")


def deploy_markdown(
    step: String, d: ResultDeploy, outcome: String, plan: Bool, plan_text: String, message: String
) -> String:
    """A DEPLOY step's block (deploy_step.mojo's header, 6): the cell and its
    cloud, the outcome, the plan (or what the apply did), and its deploy
    keys. `leftover` and `left_behind` are listed, and kci never deletes
    them."""
    var s = String("### DEPLOY step `") + step + String("`")
    if d.cell.byte_length() > 0:
        s += String(" into cell `") + d.cell + String("` (cloud `") + d.cloud + String("`)")
    s += String(": ") + outcome + String("\n\n")
    if message.byte_length() > 0:
        s += message + String("\n\n")
    if plan:
        s += String("Dry run (--plan): nothing was written to the cell or its store.")
        if d.plan_hash.byte_length() > 0:
            s += String(" plan_hash `") + d.plan_hash + String("`")
        s += String("\n\n")
    if plan_text.byte_length() > 0:
        s += String("```\n") + plan_text + String("\n```\n\n")
    if len(d.landed) > 0:
        s += String("- landed (live in the cell):")
        for i in range(len(d.landed)):
            s += (String(" `") if i == 0 else String(", `")) + d.landed[i].node + String("` (") + d.landed[i].verb + String(")")
        s += String("\n")
    if len(d.pending) > 0:
        s += _ids_line(String("pending (in apply order; the first is where the apply stopped)"), d.pending)
    if d.has_failed:
        s += (
            String("- failed: `") + d.failed.node + String("` ") + d.failed.verb + String(" (fault ")
            + d.failed.fault_domain + String("): ") + d.failed.message + String("\n")
        )
    if len(d.leftover) > 0:
        s += _ids_line(String("leftover (owned by resources the file no longer names; kci does not delete them)"), d.leftover)
    if len(d.left_behind) > 0:
        s += _ids_line(String("left behind (retained objects the file no longer lowers; kci does not delete them)"), d.left_behind)
    if len(d.released) > 0:
        s += _ids_line(String("would release") if plan else String("released"), d.released)
    if d.cell.byte_length() > 0:
        s += String(DEPLOY_NO_LEASE_LINE) + String("\n") + String(DEPLOY_NO_DESTROY_LINE) + String("\n")
    return s + String("\n")
