# =============================================================================
# src/kci_cli/start_checks.mojo -- what `kci run` checks under GitHub Actions
#   before the RUNNING record (dispatch.mojo's header, 4, 4a, 4b and 4c):
#   the workflow it runs under, the ref it runs on, the release set it was
#   handed, and whether main has moved past it (the admission check).
# =============================================================================
#
# Each check returns a `StartVerdict`: `outcome` "" when the run may go on,
# else the outcome, error id and message the run stops with (nothing run).
# Everything outside this process goes through the `StageSteps` seam
# (seam.mojo).
#
# Encapsulation: owned values and a generic seam; no pointer, no wildcard
# origin.
# =============================================================================

from std.pathlib import Path

from kci_workflow_check import ChannelsFile, channels_paths, check_running_workflow
from kci_api import (
    ERROR_BREAK_GLASS_REASON,
    ERROR_BREAK_GLASS_REVISION,
    ERROR_CANNOT_TELL,
    ERROR_NOT_ON_MAIN,
    ERROR_PLAN_ON_RELEASE,
    ERROR_SET_HASH,
    ERROR_USAGE,
    ERROR_WORKFLOW_MISMATCH,
    OUTCOME_INDETERMINATE,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_SUPERSEDED,
    VALIDATION_VALIDATED,
    parse_attempt,
    WORKFLOW_PATH_PREFIX,
    is_full_commit_id,
    release_platform_dir,
)
from kci_api import RunResult as KciRunResult
from kci_release_machine import ReleaseMachine, Selection, Stage

from .args import KciCommand
from .seam import StageSteps
from .summary import break_glass_line

comptime _STDERR: FileDescriptor = FileDescriptor(2)

# The platform-set variables the workflow check reads (file header, 4): the
# runner sets them, nothing else does (the mode-discriminator carve-out).
comptime GITHUB_ACTIONS: String = "GITHUB_ACTIONS"
comptime GITHUB_WORKFLOW_REF: String = "GITHUB_WORKFLOW_REF"
comptime GITHUB_WORKFLOW_SHA: String = "GITHUB_WORKFLOW_SHA"
comptime GITHUB_REPOSITORY: String = "GITHUB_REPOSITORY"
comptime NOT_UNDER_GITHUB_ACTIONS: String = "not under GitHub Actions"
# The ref check's platform-set variables (file header, 4a).
comptime GITHUB_REF: String = "GITHUB_REF"
comptime GITHUB_SHA: String = "GITHUB_SHA"
comptime GITHUB_ACTOR: String = "GITHUB_ACTOR"
comptime GITHUB_EVENT_NAME: String = "GITHUB_EVENT_NAME"
# The admission check's platform-set variable (file header, 4c).
comptime GITHUB_RUN_ATTEMPT: String = "GITHUB_RUN_ATTEMPT"
comptime PUSH_EVENT: String = "push"
comptime MAIN_REF: String = "refs/heads/main"
# A FULL refname: `origin/main` would resolve a TAG of that name first
# (gitrevisions(7): refs/tags/<name> before refs/remotes/<name>), and a
# checkout with fetch-depth 0 fetches every tag.
comptime MAIN_TRACKING_REF: String = "refs/remotes/origin/main"
comptime REASON_CONTEXT_KEY: String = "reason"
comptime BREAK_GLASS_REASON_MAX_BYTES: Int = 200


def workflow_path_of(ref_value: String, repository: String) raises -> String:
    """The workflow file's path in `GITHUB_WORKFLOW_REF`
    (`<repository>/<path>@<ref>`). Raises unless it is a file under
    .github/workflows/ of `repository`."""
    var prefix = repository + String("/")
    if repository.byte_length() == 0 or not ref_value.startswith(prefix):
        raise Error(
            String(GITHUB_WORKFLOW_REF) + String(" '") + ref_value + String("' does not start with ")
            + String(GITHUB_REPOSITORY) + String(" '") + repository + String("/'")
        )
    var rest = String(ref_value[byte = prefix.byte_length() :])
    var at = rest.find(String("@"))
    if at <= 0:
        raise Error(String(GITHUB_WORKFLOW_REF) + String(" '") + ref_value + String("' names no @<ref>"))
    var path = String(rest[byte = 0:at])
    if not path.startswith(String(WORKFLOW_PATH_PREFIX)) or path.find(String("..")) >= 0:
        raise Error(
            String(GITHUB_WORKFLOW_REF) + String(" '") + ref_value + String("': the path '") + path
            + String("' is not a file under ") + String(WORKFLOW_PATH_PREFIX)
        )
    return path^


struct StartVerdict(Copyable, Movable):
    """A start-up check's verdict (dispatch.mojo's header, 4 to 4b): `outcome` ""
    when the run may go on; else the outcome, error id and message to stop
    with, and `findings` to print.

    Layout: owned values only. No pointer field."""

    var outcome: String
    var error_id: String
    var message: String
    var findings: List[String]

    def __init__(out self):
        self.outcome = String("")
        self.error_id = String("")
        self.message = String("")
        self.findings = List[String]()

    @staticmethod
    def cannot_tell(var message: String) -> StartVerdict:
        var v = StartVerdict()
        v.outcome = String(OUTCOME_INDETERMINATE)
        v.error_id = String(ERROR_CANNOT_TELL)
        v.message = String("the workflow check cannot tell, so nothing is run: ") + message
        return v^


def check_workflow_at_start[S: StageSteps](
    cmd: KciCommand, g: ReleaseMachine, mut steps: S, mut result: KciRunResult
) -> StartVerdict:
    """File header, 4. Records `workflow` in `result`."""
    if steps.platform_env(String(GITHUB_ACTIONS)) != String("true"):
        result.workflow_checked = False
        result.workflow_reason = String(NOT_UNDER_GITHUB_ACTIONS)
        return StartVerdict()
    result.workflow_reason = String("")
    var ref_value = steps.platform_env(String(GITHUB_WORKFLOW_REF))
    var sha = steps.platform_env(String(GITHUB_WORKFLOW_SHA))
    var repository = steps.platform_env(String(GITHUB_REPOSITORY))
    var needed = List[String]()
    needed.append(String(GITHUB_WORKFLOW_REF))
    needed.append(String(GITHUB_WORKFLOW_SHA))
    needed.append(String(GITHUB_REPOSITORY))
    for i in range(len(needed)):
        if steps.platform_env(needed[i]).byte_length() == 0:
            result.workflow_reason = needed[i] + String(" is not set")
            return StartVerdict.cannot_tell(
                String(GITHUB_ACTIONS) + String(" is true and ") + needed[i] + String(" is not set")
            )
    if not is_full_commit_id(sha):
        result.workflow_reason = String(GITHUB_WORKFLOW_SHA) + String(" is not a full commit id")
        return StartVerdict.cannot_tell(
            String(GITHUB_WORKFLOW_SHA) + String(" '") + sha + String("' is not a full commit id")
        )
    var path: String
    try:
        path = workflow_path_of(ref_value, repository)
    except e:
        result.workflow_reason = String(GITHUB_WORKFLOW_REF) + String(" names no workflow file")
        return StartVerdict.cannot_tell(String(e))
    result.workflow_path = path.copy()
    result.workflow_sha = sha.copy()
    var text: String
    try:
        text = steps.committed_file(sha, path)
    except e:
        result.workflow_reason = String("the workflow could not be read at its commit")
        return StartVerdict.cannot_tell(
            String("`git show ") + sha + String(":") + path + String("` failed: ") + String(e)
        )
    var files = List[ChannelsFile]()
    var paths = channels_paths(g)
    for i in range(len(paths)):
        try:
            files.append(ChannelsFile(paths[i].copy(), _read(paths[i])))
        except e:
            result.workflow_reason = String("a channels file could not be read")
            return StartVerdict.cannot_tell(
                String("the channels file '") + paths[i] + String("' cannot be read: ") + String(e)
            )
    # A run of the PULL_REQUEST stage is held to pr.yml's rules (the file it runs
    # under: GITHUB_WORKFLOW_REF), every other stage to the release workflow's.
    var pull_request_file = False
    for i in range(len(g.stages)):
        if g.stages[i].name == cmd.stage and g.stages[i].is_pull_request():
            pull_request_file = True
    var findings: List[String]
    try:
        findings = check_running_workflow(g, files, text, cmd.machine, pull_request_file)
    except e:
        result.workflow_reason = String("the workflow could not be checked")
        return StartVerdict.cannot_tell(path + String(" at ") + sha + String(": ") + String(e))
    if len(findings) > 0:
        result.workflow_reason = String("the workflow does not match the machine file")
        var v = StartVerdict()
        v.outcome = String(OUTCOME_REFUSED)
        v.error_id = String(ERROR_WORKFLOW_MISMATCH)
        v.message = (
            path + String(" (at ") + sha + String(") disagrees with ") + cmd.machine + String(" in ")
            + String(len(findings)) + String(" place(s), so nothing is run; the machine file owns the stages,")
            + String(" edit both together:")
        )
        for i in range(len(findings)):
            v.message += String("\n") + findings[i]
        v.findings = findings^
        return v^
    result.workflow_checked = True
    return StartVerdict()


def _context_value(cmd: KciCommand, key: String) -> String:
    for i in range(len(cmd.context)):
        if cmd.context[i].key == key:
            return cmd.context[i].value.copy()
    return String("")


def _refuse(var outcome: String, var error_id: String, var message: String) -> StartVerdict:
    var v = StartVerdict()
    v.outcome = outcome^
    v.error_id = error_id^
    v.message = message^
    return v^


def check_ref_at_start[S: StageSteps](
    cmd: KciCommand, stage: Stage, mut steps: S, mut banner: String, mut break_glass: Bool, mut release: Bool
) -> StartVerdict:
    """File header, 4a (dispatch.mojo's header). `banner` gets a break-glass
    run's first line, `break_glass` says the run is one, and `release` says
    it is a push to main that passed the check (a RELEASE run)."""
    break_glass = False
    release = False
    if steps.platform_env(String(GITHUB_ACTIONS)) != String("true") or stage.is_pull_request():
        return StartVerdict()
    var ref_value = steps.platform_env(String(GITHUB_REF))
    var sha = steps.platform_env(String(GITHUB_SHA))
    var event = steps.platform_env(String(GITHUB_EVENT_NAME))
    for name in [String(GITHUB_REF), String(GITHUB_EVENT_NAME)]:
        if steps.platform_env(name).byte_length() == 0:
            return _refuse(
                String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
                String(GITHUB_ACTIONS) + String(" is true and ") + name
                + String(" is not set: what this run is cannot be told, so nothing is run"),
            )
    if not is_full_commit_id(sha):
        return _refuse(
            String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
            String(GITHUB_SHA) + String(" '") + sha + String("' is not a full commit id, so nothing is run"),
        )
    var where = String("stage '") + stage.name + String("'")
    if ref_value != String(MAIN_REF) and ref_value.lower() == String(MAIN_REF):
        return _refuse(
            String(OUTCOME_REFUSED), String(ERROR_NOT_ON_MAIN),
            String("this run is on ") + ref_value + String(", main in another case: GitHub compares refs and")
            + String(" concurrency groups ignoring case, so such a ref would pass for main there; kci refuses it")
            + String(" for every stage, so nothing is run"),
        )
    var push_to_main = event == String(PUSH_EVENT) and ref_value == String(MAIN_REF)
    if not stage.break_glass and not push_to_main:
        return _refuse(
            String(OUTCOME_REFUSED), String(ERROR_NOT_ON_MAIN),
            where + String(" runs only on a push to main (the machine file gives it no break_glass), and this run")
            + String(" is a ") + event + String(" of ") + ref_value
            + String(": a manual or break-glass run stops at the last break_glass stage, so nothing is run"),
        )
    if push_to_main:
        # kci on a push is built from main, so nothing a workflow edit does
        # (a GITHUB_ENV write of DRY_RUN, a shell assignment) can make a
        # release a dry run whose set prod would then publish uninstalled
        if cmd.plan:
            return _refuse(
                String(OUTCOME_REFUSED), String(ERROR_PLAN_ON_RELEASE),
                where + String(": a push to main is a release, never a dry run, and this run is --plan (a dry run")
                + String(" is a manual run that asks for one), so nothing is run"),
            )
        if cmd.revision_id != sha:
            return _refuse(
                String(OUTCOME_REFUSED), String(ERROR_NOT_ON_MAIN),
                String("a push to main releases the commit it pushed (") + String(GITHUB_SHA) + String(" ") + sha
                + String("), and this run's revision is ") + cmd.revision_id + String(", so nothing is run"),
            )
        var on_main: Bool
        try:
            on_main = steps.is_ancestor(cmd.revision_id, String(MAIN_TRACKING_REF))
        except e:
            return _refuse(
                String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
                String("whether the revision ") + cmd.revision_id + String(" is on ") + String(MAIN_TRACKING_REF)
                + String("'s history cannot be told (") + String(e) + String("), so nothing is run"),
            )
        if not on_main:
            return _refuse(
                String(OUTCOME_REFUSED), String(ERROR_NOT_ON_MAIN),
                String("the revision ") + cmd.revision_id + String(" is not on main's history (") + String(MAIN_TRACKING_REF)
                + String("): a run of main releases a merged commit only, so nothing is run"),
            )
        release = True
        return StartVerdict()
    break_glass = True
    # a break-glass run that can publish releases the commit it started on:
    # only a dry run may name another revision (kci.yml's revision step
    # holds the same before anything built from the revision runs)
    if not cmd.plan and cmd.revision_id != sha:
        return _refuse(
            String(OUTCOME_REFUSED), String(ERROR_BREAK_GLASS_REVISION),
            String("BREAK-GLASS on ") + ref_value + String(": a run that can publish releases the commit it started on (")
            + String(GITHUB_SHA) + String(" ") + sha + String("), and this run's revision is ") + cmd.revision_id
            + String("; another revision is for a dry run (--plan) only, so nothing is run"),
        )
    var on_history: Bool
    try:
        on_history = steps.is_ancestor(cmd.revision_id, sha)
    except e:
        return _refuse(
            String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
            String("whether the revision ") + cmd.revision_id + String(" is on ") + sha
            + String("'s history cannot be told (") + String(e) + String("), so nothing is run"),
        )
    if not on_history:
        return _refuse(
            String(OUTCOME_REFUSED), String(ERROR_BREAK_GLASS_REVISION),
            String("BREAK-GLASS on ") + ref_value + String(": the revision ") + cmd.revision_id
            + String(" is not on the history of the commit the run was started on (") + sha
            + String("), so nothing is run"),
        )
    # trimmed: a reason of spaces says nothing
    var reason = String(_context_value(cmd, String(REASON_CONTEXT_KEY)).strip())
    if reason.byte_length() == 0 or reason.byte_length() > BREAK_GLASS_REASON_MAX_BYTES:
        return _refuse(
            String(OUTCOME_REFUSED), String(ERROR_BREAK_GLASS_REASON),
            String("BREAK-GLASS on ") + ref_value + String(" (a ") + event + String(", not a push to main) needs --context ")
            + String(REASON_CONTEXT_KEY) + String("=<why>, 1 to ") + String(BREAK_GLASS_REASON_MAX_BYTES)
            + String(" bytes on one line once leading and trailing whitespace is trimmed; it has ")
            + String(reason.byte_length()) + String(" bytes, so nothing is run"),
        )
    banner = break_glass_line(ref_value, cmd.revision_id, steps.platform_env(String(GITHUB_ACTOR)), reason)
    _say(String("kci: ") + banner)
    return StartVerdict()


def check_admission_at_start[S: StageSteps](
    cmd: KciCommand, stage: Stage, release: Bool, mut steps: S
) -> StartVerdict:
    """File header, 4c (dispatch.mojo's header): with `--admission`, on a
    RELEASE run, a re-run (the platform-set GITHUB_RUN_ATTEMPT above 1) at
    any stage, or the first attempt of the FIRST stage (one with no
    `after`: build), whose revision is not main's releasable tip stops
    SUPERSEDED (exit 0) before any effect. A first attempt of a later stage
    is admitted without asking: it is the newest that reached that stage,
    and stopping it would starve the stage while pushes come faster than
    the pipeline. Main moved past only by `docs/**` and `*.md` commits is
    still this revision's releasable tip (`main_tip_past`). An attempt that
    is unset or malformed, or a read git cannot answer, is INDETERMINATE
    (KCI-E-CANNOT-TELL, exit 5), never a pass."""
    if not cmd.admission:
        return StartVerdict()
    var where = String("stage '") + stage.name + String("'")
    if not release:
        _say(String("kci: admission: ") + where + String(": not a push to main, nothing to check"))
        return StartVerdict()
    var raw = steps.platform_env(String(GITHUB_RUN_ATTEMPT))
    var attempt: Int
    try:
        attempt = parse_attempt(raw)
    except e:
        return _refuse(
            String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
            String(GITHUB_RUN_ATTEMPT) + String(" '") + raw + String("' is not a positive integer: whether this run")
            + String(" is a re-run cannot be told, so nothing is run"),
        )
    var first_stage = stage.after.byte_length() == 0
    if attempt == 1 and not first_stage:
        _say(
            String("kci: admission: ") + where + String(", attempt 1: the newest revision to reach this stage runs")
            + String(" whether or not main has moved")
        )
        return StartVerdict()
    var tip: String
    try:
        tip = steps.main_tip_past(cmd.revision_id)
    except e:
        return _refuse(
            String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
            String("whether ") + cmd.revision_id + String(" is main's releasable tip cannot be told (") + String(e)
            + String("), so nothing is run"),
        )
    var which = (
        String("a re-run (attempt ") + String(attempt) + String(")") if attempt > 1
        else String("the first attempt of the first stage")
    )
    if tip.byte_length() == 0:
        _say(String("kci: admission: ") + where + String(", ") + which + String(": ") + cmd.revision_id + String(" is main's releasable tip"))
        return StartVerdict()
    var v = StartVerdict()
    v.outcome = String(OUTCOME_SUPERSEDED)
    v.message = (
        String("SUPERSEDED at ") + where + String(": main is at ") + tip + String(", past ") + cmd.revision_id
        + String(" by a commit a push releases; ") + which + String(" of a revision that is not main's releasable")
        + String(" tip stops here, before anything is run, and the newer commit's run carries it")
    )
    return v^


def check_set_hash_at_start[S: StageSteps](
    cmd: KciCommand, stage: Stage, sel: Selection, mut steps: S, mut result: KciRunResult
) -> StartVerdict:
    """File header, 4b."""
    var at = -1
    for i in range(len(stage.steps)):
        var validated = False
        for m in range(len(stage.steps[i].validations)):
            if _selected(sel, stage.steps[i].validations[m].name):
                validated = True
        if at < 0 and stage.steps[i].is_publish() and (sel.steps[i] or validated):
            at = i
    if at < 0:
        return StartVerdict()
    if cmd.release_set_hash.byte_length() == 0:
        if steps.platform_env(String(GITHUB_ACTIONS)) == String("true"):
            return _refuse(
                String(OUTCOME_REFUSED), String(ERROR_USAGE),
                String("under GitHub Actions a run that publishes or validates is given --release-set-hash (the set")
                + String(" the build made, or the one validate validated): kci holds the release to it"),
            )
        return StartVerdict()
    ref step = stage.steps[at]
    var got: String
    try:
        got = steps.release_set_hash(step.artifacts, release_platform_dir(cmd.release_dir, step.platform))
    except e:
        return _refuse(
            String(OUTCOME_REFUSED), String(ERROR_SET_HASH),
            String("the release directory's set hash cannot be recomputed, so it cannot be held to --release-set-hash ")
            + cmd.release_set_hash + String(": ") + String(e),
        )
    if got != cmd.release_set_hash:
        return _refuse(
            String(OUTCOME_REFUSED), String(ERROR_SET_HASH),
            String("the release directory recomputes to set hash ") + got + String(", not ") + cmd.release_set_hash
            + String(" (the set this run was handed): these are not the bytes that were built and validated"),
        )
    # a dry run hands on no set: nothing was published or installed
    if not cmd.plan:
        result.set_hash = got^
    return StartVerdict()


def keep_set_hash_only_if_validated(sel: Selection, mut result: KciRunResult):
    """File header, 4b, at the run's end: a run that selects validations
    keeps its result's `set_hash` only when every selected validation ran
    (VALIDATED, so not --plan) and SUCCEEDED; else it is "". kci.yml hands
    validate's `set_hash` on to prod, and prod refuses an empty one."""
    if len(sel.validations) == 0:
        return
    var passed = 0
    for i in range(len(result.validations)):
        ref v = result.validations[i]
        if v.effect == String(VALIDATION_VALIDATED) and v.outcome == String(OUTCOME_SUCCEEDED):
            passed += 1
    if passed != len(sel.validations) or len(result.validations) != len(sel.validations):
        result.set_hash = String("")


def _say(line: String):
    print(line, file=_STDERR)


def _read(path: String) raises -> String:
    return Path(path).read_text()


def _selected(sel: Selection, name: String) -> Bool:
    for i in range(len(sel.validations)):
        if sel.validations[i] == name:
            return True
    return False
