# =============================================================================
# src/kci_cli/dispatch.mojo -- `kci run --stage S`, kci's one command: from
#   the parsed command line to the steps, the result document, the job
#   summary and the exit number.
# =============================================================================
#
# `kci run --stage S`:
#
#   0. every `--only` parsed (args.mojo `selectors_of`): a malformed or
#      repeated selector is KCI-E-SELECTOR, exit 2, before anything is read.
#      `--affected-by <base>` makes the run SELECTIVE and records
#      `affected_by` (its base) from the first record on; each BUILD step
#      gets the base and runs the per-change check (kci_build affected.mojo:
#      the units the change reaches, the verdict and the units recorded by
#      the step);
#   1. read the machine file (`--machine`, or args.mojo's default): a path
#      that names no file is a usage error (KCI-E-USAGE, exit 2); a file
#      whose schema_version this kci does not read is REFUSED
#      (KCI-E-FORMAT-VERSION); any other refusal of the file is REFUSED
#      (KCI-E-FORMAT), and so is a file holding a step that writes into a
#      cell (a DEPLOY step, or a PUBLISH step into a cell), which this kci
#      parses and does not run;
#   2. resolve S: an unknown stage is REFUSED (KCI-E-STAGE-UNKNOWN, the
#      message lists the stages); then the selection (kci_release_machine
#      `resolve_selection`): a selector that matches nothing in S is
#      REFUSED (KCI-E-SELECTOR-NO-MATCH, exit 3, naming S's steps and
#      validations); then the flags the SELECTED steps' kinds take, and
#      `--scratch-dir` exactly when a validation is selected (args.mojo
#      `require_stage_flags`, exit 2); `--channel` (a local channel, the
#      pre-publish mode) is refused, exit 2, when the platform-set
#      `GITHUB_ACTIONS` is "true": a workflow validates only what was
#      published;
#   3. (no longer a refusal: validations run, step 6);
#   4. THE WORKFLOW CHECK, when the platform-set `GITHUB_ACTIONS` is "true":
#      the workflow file running this job is the one `GITHUB_WORKFLOW_REF`
#      names (`<GITHUB_REPOSITORY>/<path>@<ref>`, the path under
#      .github/workflows/), read as it was COMMITTED at `GITHUB_WORKFLOW_SHA`
#      (`git show <sha>:<path>`; the checkout may be another revision), and
#      held to the machine file by kci_workflow_check's `check_running_workflow`
#      with every channels file the machine file names: a run of the
#      PULL_REQUEST stage is held to the pull request's workflow (pr.yml, the
#      PULL_REQUEST stage alone), a run of any other stage to the release
#      workflow (kci.yml). Any finding is
#      REFUSED (KCI-E-WORKFLOW-MISMATCH, exit 3), every finding printed and
#      no step run. A variable that is unset or malformed, a `git show` that
#      fails, a channels file or a workflow that cannot be read is
#      INDETERMINATE (KCI-E-CANNOT-TELL, exit 5), never a pass. Not under
#      GitHub Actions nothing is checked and the result says so
#      (`workflow.checked` false, reason "not under GitHub Actions");
#   4a. THE REF CHECK, under GitHub Actions, for a PUSH stage (continuous
#      auto-promotion; the PULL_REQUEST stage is R6's): the platform-set
#      `GITHUB_REF`, `GITHUB_SHA` and `GITHUB_EVENT_NAME` are read (unset or
#      malformed: INDETERMINATE, exit 5). Refs compare BYTE FOR BYTE (GitHub's
#      expressions and concurrency groups ignore case; kci does not), and a
#      `GITHUB_REF` that is `refs/heads/main` in another case is REFUSED
#      (KCI-E-NOT-ON-MAIN) for every stage. A RELEASE run is a `push` to
#      `refs/heads/main`, and is never `--plan` (REFUSED,
#      KCI-E-PLAN-ON-RELEASE, exit 3: kci on a push is built from main, so
#      no workflow edit can make a release a dry run); any other run is
#      BREAK-GLASS. A stage WITHOUT the
#      machine file's `break_glass` runs only on a release run, whose
#      revision is `GITHUB_SHA` itself and on `refs/remotes/origin/main`'s
#      history (a full refname: a tag named `origin/main` does not answer),
#      else REFUSED (KCI-E-NOT-ON-MAIN, exit 3). A break_glass stage on a
#      release run is held the same way; on a break-glass run its revision is
#      `GITHUB_SHA` itself unless the run is `--plan` (then on `GITHUB_SHA`'s
#      history), else REFUSED (KCI-E-BREAK-GLASS-REVISION), and
#      `--context reason=` is given, non-empty once trimmed and at most 200
#      bytes, else REFUSED (KCI-E-BREAK-GLASS-REASON), and
#      each PUBLISH step runs as break-glass (kci_publish: the stage's
#      `break_glass_environment` and the channel's
#      `break_glass_push_identity`). History git cannot read (a shallow
#      clone, no `refs/remotes/origin/main`, an unknown commit) is
#      INDETERMINATE, never a pass. A break-glass run's summary and stderr
#      start `BREAK-GLASS: <ref> <revision> by <actor>: <reason>`;
#   4b. THE SET HASH, for a run that selects a PUBLISH step or a
#      validation: with `--release-set-hash`, the release directory's set
#      is recomputed (`steps.release_set_hash`) and another hash, or one
#      that cannot be recomputed, is REFUSED (KCI-E-SET-HASH, exit 3); the
#      result's `set_hash` is then the recomputed one, but NOT on a `--plan`
#      run, and, for a run that selects validations, only when every one of
#      them VALIDATED and SUCCEEDED (checked at the run's end): kci.yml hands
#      the validate job's on to prod, and prod refuses an empty one. Under
#      GitHub Actions the flag is required (KCI-E-USAGE, exit 2);
#   5. the RUNNING record (`recorder.begin`) BEFORE the first effect. A
#      record that cannot be written stops the run FAILED
#      (KCI-E-RESULT-FILE), nothing done;
#   6. every SELECTED step of S, in file order: a BUILD step through
#      `steps.build`, a PUBLISH step through `steps.publish`, each given its
#      name, the stage and its GitHub environment, the revision, the
#      platform, the run identity, `--plan` and its own inputs. Each step adds
#      its row, artifacts, new names and first error to the result; a step
#      `--only` did not select gets a row with `selected: false` and no
#      outcome. Right after a step's row come its SELECTED validations
#      (kci_release_machine `resolve_selection`: all of them in a FULL run; in a
#      selective one only those `--only validation:<name>` names, whether or
#      not the step itself ran, since a validation checks what the step
#      published, now or in an earlier run), each through `steps.validate`
#      (kci_validate), each adding its `validations[]` row and printing each
#      of its checks. The run stops at the first step that does not end
#      SUCCEEDED or NOOP and at the first validation that does not end
#      SUCCEEDED (VALIDATION_FAILED, KCI-E-VALIDATION, exit 7; a
#      CONDA_INSTALL_ENV validation that found no network at all is
#      INDETERMINATE with a skip_reason, exit 5, never a pass, its reason the
#      run's error message); a selected validation after that point gets a
#      NOT_REACHED row. Under `--plan` a validation runs nothing and its row
#      is WOULD_VALIDATE;
#   7. NEW NAMES AHEAD: when the run ended SUCCEEDED or NOOP, every PUBLISH
#      step of each stage whose `after` is S is read through `steps.lookahead`
#      (anonymous reads of that stage's channel, kci_publish
#      `lookahead_new_names`), so the names a later, approval-gated stage
#      would publish for the first time are in THIS run's result
#      (`new_names[]` rows naming that stage) and summary before anyone
#      approves it. A channel that was not read says so, never "none".
#      A run given no `--release-version` (the validation-only job, which
#      selects no PUBLISH step) cannot name a later stage's files, so it
#      reads nothing and each report says `lookahead skipped: no release
#      version (plan-only or validation-only run)`, not an error about an
#      empty path;
#   8. the run's outcome is its worst step's (kci_api's `worst_outcome`),
#      and PARTIAL when a step fails after an earlier PUBLISH step changed
#      the channel; the FINISHED record, then the exit number
#      (kci_api's exit table), which is the return value;
#   9. `--summary-file`: a markdown block APPENDED to that file on every exit
#      path after the command line parsed (summary.mojo; a break-glass run's
#      BREAK-GLASS line first, and a main-only stage's publish ends with its
#      `promoted to <stage>: ...` line, `promotion_line`): the
#      outcome and exit number, the scope, the revision and set hash, the
#      workflow check, the steps, the validations with each failed row's
#      finding and each check's first passing row, and each NEW NAMES block (this stage's
#      PUBLISH steps, then the stages after it). A file that cannot be
#      written is said on stderr; the exit number stands;
#  10. the LAST stderr line is the run's evidence (kci_api
#      `run_evidence_line`): `kci: FULL run of stage S: <OUTCOME>`, or
#      `kci: SELECTIVE run of stage S (<only>): <OUTCOME> -- not a full run`
#      (`(affected-by <base>)` for the per-change check). When a PUBLISH
#      step recorded its credential probe NOT_UNDER_CI, the line says
#      `credential probe NOT RUN (not under GitHub Actions)` right after the
#      outcome, and so do the summary's heading and that step's row: a green
#      dry run outside CI never exchanged a token, so it is never read as
#      covering the OIDC mint.
#      The result document says the same in `scope` and `only`. A selective
#      success exits 0 like a full one, so the scope, never the number, is
#      what tells them apart. A run refused before its selectors parse (a
#      usage error) prints no evidence line: nothing was selected.
#
# Every refusal the command line itself earns (args.mojo) is recorded too,
# in the file `--result-file` names when it can be found, and summarized in
# the file `--summary-file` names (`kci_main_with`).
#
# Everything a run does outside this process goes through the `StageSteps`
# seam: the steps, the lookahead reads, the platform-set variables and the
# committed workflow. `LibrarySteps` (library_verbs.mojo) is the real one;
# the welded tests drive a recording fake. Human text goes to stderr; stdout
# carries nothing.
#
# Encapsulation: owned values and a generic seam; no pointer, no wildcard
# origin.
# =============================================================================

from std.os.path import isfile
from std.pathlib import Path

from std.time import perf_counter_ns

from komira_clock import now_unix_ms

from kci_build import BuildRequest
from kci_workflow_check import ChannelsFile, channels_paths, check_running_workflow
from kci_api import (
    CREDENTIAL_PROBE_NOT_RUN_NOTE,
    CREDENTIAL_PROBE_NOT_UNDER_CI,
    VALIDATION_NOT_REACHED,
    credential_probe_note,
    ERROR_CANNOT_TELL,
    ERROR_CHANNEL,
    ERROR_FORMAT,
    ERROR_FORMAT_VERSION,
    ERROR_INTERNAL,
    ERROR_RESULT_FILE,
    ERROR_SELECTOR,
    ERROR_SELECTOR_NO_MATCH,
    ERROR_STAGE_UNKNOWN,
    ERROR_USAGE,
    ERROR_VALIDATION,
    ERROR_WORKFLOW_MISMATCH,
    ERROR_BREAK_GLASS_REASON,
    ERROR_NOT_ON_MAIN,
    ERROR_SET_HASH,
    EXIT_INTERNAL,
    EXIT_OK,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    VERB_RUN,
    SCOPE_SELECTIVE,
    WORKFLOW_PATH_PREFIX,
    ResultNewName,
    ResultStep,
    ResultValidation,
    Selector,
    is_full_commit_id,
    release_platform_dir,
    run_evidence_line,
    worst_outcome,
)
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest, new_names_markdown
from kci_validate import ValidateRequest
from kci_release_set.member import file_sha256_hex
from kci_release_machine import (
    Selection,
    Stage,
    ReleaseMachine,
    StageStep,
    StageValidation,
    machine_schema_version,
    parse_machine_file,
    resolve_selection,
)

from .args import (
    CLI_VERB_HELP,
    KCI_USAGE,
    KciCommand,
    SecretStoreChoice,
    find_result_file,
    find_summary_file,
    parse_kci_args,
    require_stage_flags,
    selectors_of,
)
from .recorder import CliRecorder
from .seam import StageSteps, StepEnd
from .start_checks import (
    GITHUB_ACTIONS,
    GITHUB_ACTOR,
    GITHUB_REF,
    GITHUB_REPOSITORY,
    GITHUB_SHA,
    GITHUB_WORKFLOW_REF,
    GITHUB_WORKFLOW_SHA,
    NOT_UNDER_GITHUB_ACTIONS,
    StartVerdict,
    check_ref_at_start,
    check_set_hash_at_start,
    check_workflow_at_start,
    keep_set_hash_only_if_validated,
    workflow_path_of,
)
from .summary import append_summary, promotion_line, run_summary_markdown

comptime _STDERR: FileDescriptor = FileDescriptor(2)

def _say(line: String):
    print(line, file=_STDERR)


def _now() -> Int:
    return Int(now_unix_ms())


def _finish(mut result: KciRunResult, mut recorder: CliRecorder, outcome: String, retry: String = String("")) -> Int:
    """Write the FINISHED record with `outcome`; return its exit number. A
    record that cannot be made or written is said on stderr; the number
    stands."""
    var rec: KciRunResult
    try:
        rec = result.finish_record(outcome.copy(), _now(), retry.copy())
    except e:
        _say(String("kci: the result could not be recorded: ") + String(e))
        result.outcome = outcome.copy()
        result.exit_code = EXIT_INTERNAL
        return EXIT_INTERNAL
    # the summary (file header, 9) reads the run's end from `result`
    result.outcome = rec.outcome.copy()
    result.exit_code = rec.exit_code
    try:
        recorder.finish(rec)
    except e:
        _say(String("kci: the result file could not be written: ") + String(e))
    _say(
        String("kci: ") + rec.outcome + String(" (exit ") + String(rec.exit_code) + String(")")
        + (String(" stage ") + rec.stage if rec.stage.byte_length() > 0 else String(""))
    )
    return rec.exit_code


def _stop(
    mut result: KciRunResult, mut recorder: CliRecorder, outcome: String, error_id: String, message: String
) -> Int:
    """End the run with `outcome` and the error `error_id` (file header)."""
    _say(String("kci: ") + message)
    try:
        result.set_error(error_id.copy(), message.copy())
    except e:
        _say(String("kci: ") + String(e))
    return _finish(result, recorder, outcome)


def _read(path: String) raises -> String:
    return Path(path).read_text()


def _load_graph(cmd: KciCommand, mut result: KciRunResult) raises -> ReleaseMachine:
    """Step 1 of the file header; raises `<error id>\\n<message>`."""
    if not isfile(cmd.machine):
        raise Error(
            String(ERROR_USAGE) + String("\nthe machine file '") + cmd.machine
            + String("' is not a file (--machine, default release/machine.textproto)")
        )
    var text = _read(cmd.machine)
    try:
        _ = machine_schema_version(text, cmd.machine)
    except e:
        raise Error(String(ERROR_FORMAT_VERSION) + String("\n") + String(e))
    var g: ReleaseMachine
    try:
        g = parse_machine_file(text, cmd.machine)
    except e:
        raise Error(String(ERROR_FORMAT) + String("\n") + String(e))
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            ref step = g.stages[i].steps[k]
            if step.writes_cell():
                raise Error(
                    String(ERROR_FORMAT) + String("\n") + cmd.machine + String(": line ") + String(step.line)
                    + String(": step '") + step.name + String("' of stage '") + g.stages[i].name
                    + String("' writes into cell '") + step.cell
                    + String("': that needs a newer kci (this kci runs BUILD steps and PUBLISH steps to a channel)")
                )
    result.machine_path = cmd.machine.copy()
    result.machine_sha256 = file_sha256_hex(cmd.machine)
    return g^


def _split(e: Error) -> Tuple[String, String]:
    var s = String(e)
    var nl = s.find(String("\n"))
    if nl < 0:
        return (String(ERROR_INTERNAL), s^)
    return (String(s[byte = 0:nl]), String(s[byte = nl + 1 :]))


def evidence_line_of(result: KciRunResult, outcome: String) raises -> String:
    """The run's last stderr line (file header, 10), the credential probe's
    note next to the outcome when a step recorded it NOT_UNDER_CI."""
    var base = result.affected_base.copy() if result.has_affected_by else String("")
    return run_evidence_line(result.scope, result.stage, result.only, outcome, base, credential_probe_note(result.steps))


def _evidence(result: KciRunResult, outcome: String, rc: Int) -> Int:
    """Say the run's last line (file header, 10); return `rc`."""
    try:
        _say(evidence_line_of(result, outcome))
    except e:
        _say(String("kci: ") + String(e))
    return rc


def _end_run(mut result: KciRunResult, mut recorder: CliRecorder, outcome: String, retry: String = String("")) -> Int:
    var rc = _finish(result, recorder, outcome, retry)
    return _evidence(result, outcome, rc)


def _stop_run(
    mut result: KciRunResult, mut recorder: CliRecorder, outcome: String, error_id: String, message: String
) -> Int:
    var rc = _stop(result, recorder, outcome, error_id, message)
    return _evidence(result, outcome, rc)


def _build_request(cmd: KciCommand, step: StageStep) raises -> BuildRequest:
    var req = BuildRequest(cmd.run_identity())
    req.step_name = step.name.copy()
    req.plan = cmd.plan
    req.artifacts_file = step.artifacts.copy()
    req.work_dir = cmd.work_dir.copy()
    req.release_dir = cmd.release_dir.copy()
    req.log_dir = cmd.log_dir.copy()
    req.revision_id = cmd.revision_id.copy()
    req.platform = step.platform.copy()
    if cmd.build_timeout_s > 0:
        req.build_timeout_s = cmd.build_timeout_s
    req.build_budget_s = cmd.build_budget_s
    if cmd.build_budget_s > 0:
        # the budget counts from kci's start (`kci_main_with`), on the
        # monotonic clock the BUILD step's runner reads (ProcessRunner.now_ns)
        req.build_deadline_ns = cmd.started_ns + cmd.build_budget_s * 1_000_000_000
    req.affected_by = cmd.affected_by.copy()
    return req^


def _publish_request(cmd: KciCommand, stage: Stage, step: StageStep, break_glass: Bool) raises -> PublishRequest:
    var req = PublishRequest(cmd.run_identity())
    req.step_name = step.name.copy()
    req.artifacts_file = step.artifacts.copy()
    req.release_dir = cmd.release_dir.copy()
    req.platform = step.platform.copy()
    req.revision_id = cmd.revision_id.copy()
    req.stage = stage.name.copy()
    req.environment = stage.environment.copy()
    # a break-glass run publishes from the stage's break-glass environment
    # (kci_publish refuses one without it on an OIDC channel)
    req.break_glass = break_glass
    if break_glass and stage.break_glass_environment.byte_length() > 0:
        req.environment = stage.break_glass_environment.copy()
    req.channels_file = step.channels.copy()
    req.channel = step.channel.copy()
    req.release_version_file = cmd.release_version.copy()
    if cmd.concurrency > 0:
        req.concurrency = cmd.concurrency
    # a main-only stage never publishes a lower build number than its
    # channel lists (kci_publish run.mojo, KCI-E-SUPERSEDED)
    req.never_backward = not stage.break_glass
    req.plan = cmd.plan
    return req^




def _validate_request(cmd: KciCommand, stage: Stage, step: StageStep, v: StageValidation) -> ValidateRequest:
    var req = ValidateRequest(v.copy())
    req.stage = stage.name.copy()
    req.step_name = step.name.copy()
    req.artifacts_file = step.artifacts.copy()
    req.channels_file = step.channels.copy()
    req.channel = step.channel.copy()
    req.release_dir = cmd.release_dir.copy()
    req.platform = step.platform.copy()
    req.revision_id = cmd.revision_id.copy()
    req.scratch_dir = cmd.scratch_dir.copy()
    req.repo_root = String(".")
    req.plan = cmd.plan
    req.pixi = cmd.pixi.copy()
    req.pixi_sha256 = cmd.pixi_sha256.copy()
    req.channel_override = cmd.channel.copy()
    return req^


def _selected(sel: Selection, name: String) -> Bool:
    for i in range(len(sel.validations)):
        if sel.validations[i] == name:
            return True
    return False


def validation_failure_message(row: ResultValidation) -> String:
    """The run's error message for a failed validation: its name and each
    failed check's finding."""
    if row.skip_reason.byte_length() > 0:
        return (
            String("validation '") + row.name + String("' of step '") + row.step + String("' could not run (")
            + row.outcome + String(", never a pass): ") + row.skip_reason
        )
    var s = String("validation '") + row.name + String("' of step '") + row.step + String("' failed:")
    for i in range(len(row.checks)):
        if not row.checks[i].ok:
            s += String("\n") + row.checks[i].got
    return s^


def _lookahead[S: StageSteps](
    cmd: KciCommand, g: ReleaseMachine, stage: Stage, mut steps: S, mut result: KciRunResult
) -> List[NewNamesReport]:
    """File header, 7: every PUBLISH step of each stage whose `after` is
    `stage`; read names go into `result.new_names` under that stage."""
    var out = List[NewNamesReport]()
    for i in range(len(g.stages)):
        ref later = g.stages[i]
        if later.after != stage.name:
            continue
        for k in range(len(later.steps)):
            ref step = later.steps[k]
            if not step.is_publish():
                continue
            var r: NewNamesReport
            if cmd.release_version.byte_length() == 0:
                r = NewNamesReport(later.name.copy(), step.name.copy(), step.channel.copy())
                r.detail = String("lookahead skipped: no release version (plan-only or validation-only run)")
                out.append(r^)
                continue
            try:
                r = steps.lookahead(_publish_request(cmd, later, step, False))
            except e:
                r = NewNamesReport(later.name.copy(), step.name.copy(), step.channel.copy())
                r.detail = String("not read: ") + String(e)
            if r.read:
                for n in range(len(r.names)):
                    result.new_names.append(
                        ResultNewName(later.name.copy(), step.name.copy(), step.channel.copy(), r.names[n].copy())
                    )
            out.append(r^)
    return out^


def _run_step[S: StageSteps](
    cmd: KciCommand,
    stage: Stage,
    step: StageStep,
    mut steps: S,
    mut recorder: CliRecorder,
    mut result: KciRunResult,
    mut step_blocks: List[String],
    break_glass: Bool,
) -> StepEnd:
    """One selected step (file header, 6): run it, print its lines, keep its
    summary block. `break_glass`: the run is break-glass (4a)."""
    _say(String("kci: stage ") + stage.name + String(", step ") + step.name + String(" (") + step.kind + String(")"))
    var end: StepEnd
    try:
        if step.is_build():
            end = steps.build(_build_request(cmd, step), result, recorder)
        else:
            end = steps.publish(_publish_request(cmd, stage, step, break_glass), result, recorder, cmd.store)
            # the run's dry-run flag is the command line's: a step refused
            # before it read its request records `plan` false
            result.plan = cmd.plan
    except e:
        end = StepEnd(String(OUTCOME_INDETERMINATE), String(ERROR_INTERNAL), String(e))
    for k in range(len(end.lines)):
        _say(end.lines[k])
    if end.message.byte_length() > 0 and not end.ok():
        _say(end.message)
    if end.summary.byte_length() > 0:
        step_blocks.append(end.summary.copy())
    return end^


def _run_stage[S: StageSteps](
    cmd: KciCommand,
    mut steps: S,
    mut recorder: CliRecorder,
    mut result: KciRunResult,
    mut step_blocks: List[String],
    mut ahead: List[NewNamesReport],
    mut banner: String,
    mut main_only: Bool,
) -> Int:
    """File header, 0 to 8 and 10. Returns the exit number. `banner` gets a
    break-glass run's first line; `main_only` says the stage has no
    `break_glass`."""
    try:
        result.set_run(cmd.run_identity())
    except e:
        return _stop(result, recorder, String(OUTCOME_REFUSED), String(ERROR_USAGE), String(e))
    # 0. the selectors, before anything is read
    var selectors: List[Selector]
    try:
        selectors = selectors_of(cmd)
    except e:
        return _stop(result, recorder, String(OUTCOME_REFUSED), String(ERROR_SELECTOR), String(e))
    for i in range(len(selectors)):
        result.only.append(selectors[i].canonical())
    if len(selectors) > 0:
        result.scope = String(SCOPE_SELECTIVE)
    if cmd.affected_by.byte_length() > 0:
        result.scope = String(SCOPE_SELECTIVE)
        result.has_affected_by = True
        result.affected_base = cmd.affected_by.copy()
    var g: ReleaseMachine
    try:
        g = _load_graph(cmd, result)
    except e:
        var p = _split(e)
        return _stop_run(result, recorder, String(OUTCOME_REFUSED), p[0], p[1])
    var stage: Stage
    try:
        stage = g.stage(cmd.stage)
    except e:
        return _stop_run(result, recorder, String(OUTCOME_REFUSED), String(ERROR_STAGE_UNKNOWN), String(e))
    main_only = not stage.break_glass and not stage.is_pull_request()
    result.stage_step_kinds = stage.step_kinds()
    result.platform = stage.steps[0].platform.copy()
    var sel: Selection
    try:
        sel = resolve_selection(stage, selectors)
    except e:
        return _stop_run(result, recorder, String(OUTCOME_REFUSED), String(ERROR_SELECTOR_NO_MATCH), String(e))
    result.scope = sel.scope.copy()
    if result.has_affected_by:
        result.scope = String(SCOPE_SELECTIVE)
    try:
        require_stage_flags(cmd, stage, sel)
    except e:
        return _stop_run(result, recorder, String(OUTCOME_REFUSED), String(ERROR_USAGE), String(e))
    if cmd.given(String("--channel")) and steps.platform_env(String(GITHUB_ACTIONS)) == String("true"):
        return _stop_run(
            result, recorder, String(OUTCOME_REFUSED), String(ERROR_USAGE),
            String("--channel names a local channel, and ") + String(GITHUB_ACTIONS)
            + String(" is true: a workflow validates only what was published, from the step's channel"),
        )
    # 4. the workflow this job runs under, held to the machine file
    var verdict = check_workflow_at_start(cmd, g, steps, result)
    if verdict.outcome.byte_length() > 0:
        return _stop_run(result, recorder, verdict.outcome, verdict.error_id, verdict.message)
    # 4a. the ref this run is on; 4b. the set it was handed
    var break_glass = False
    var ref_verdict = check_ref_at_start(cmd, stage, steps, banner, break_glass)
    if ref_verdict.outcome.byte_length() > 0:
        return _stop_run(result, recorder, ref_verdict.outcome, ref_verdict.error_id, ref_verdict.message)
    var hash_verdict = check_set_hash_at_start(cmd, stage, sel, steps, result)
    if hash_verdict.outcome.byte_length() > 0:
        return _stop_run(result, recorder, hash_verdict.outcome, hash_verdict.error_id, hash_verdict.message)
    for i in range(len(stage.steps)):
        var validated = False
        for m in range(len(stage.steps[i].validations)):
            if _selected(sel, stage.steps[i].validations[m].name):
                validated = True
        if (sel.steps[i] or validated) and stage.steps[i].is_publish():
            result.channel = stage.steps[i].channel.copy()
            break
    try:
        recorder.begin(result.begin_record())
    except e:
        return _stop_run(
            result, recorder, String(OUTCOME_FAILED), String(ERROR_RESULT_FILE),
            String("the RUNNING record could not be written, so nothing was run: ") + String(e),
        )
    var outcome = String(OUTCOME_NOOP)
    var retry = String("")
    var changed_outside = False
    var stopped = False
    for i in range(len(stage.steps)):
        ref step = stage.steps[i]
        # a step after the one that stopped the run has no row, and neither
        # have its validations (a validation row names a step of steps[])
        var has_row = not stopped
        if stopped:
            pass
        elif not sel.steps[i]:
            _say(String("kci: stage ") + stage.name + String(", step ") + step.name + String(": not selected (--only)"))
            result.steps.append(ResultStep.unselected(step.name.copy(), step.kind.copy(), step.platform.copy()))
        else:
            var end = _run_step(cmd, stage, step, steps, recorder, result, step_blocks, break_glass)
            try:
                outcome = worst_outcome(outcome, end.outcome)
            except e:
                outcome = String(OUTCOME_INDETERMINATE)
            if end.retry.byte_length() > 0:
                retry = end.retry.copy()
            if not end.ok():
                if changed_outside and (end.outcome == OUTCOME_REFUSED or end.outcome == OUTCOME_FAILED):
                    outcome = String(OUTCOME_PARTIAL)
                    retry = String("")
                stopped = True
            if end.changed_outside:
                changed_outside = True
        # the step's selected validations, right after it
        for m in range(len(step.validations)):
            ref v = step.validations[m]
            if not _selected(sel, v.name) or not has_row:
                continue
            if stopped:
                result.validations.append(
                    ResultValidation(v.name.copy(), step.name.copy(), v.kind.copy(), String(VALIDATION_NOT_REACHED), String(""))
                )
                _say(String("kci: validation ") + v.name + String(": not reached"))
                continue
            _say(String("kci: stage ") + stage.name + String(", validation ") + v.name + String(" (") + v.kind + String(") of step ") + step.name)
            var row = steps.validate(_validate_request(cmd, stage, step, v))
            for k in range(len(row.checks)):
                ref c = row.checks[k]
                _say(String("kci: ") + (String("ok    ") if c.ok else String("FAIL  ")) + c.got)
            if row.effect == String(VALIDATION_NOT_REACHED) or row.outcome.byte_length() == 0:
                _say(String("kci: validation ") + v.name + String(": ") + row.effect)
            else:
                _say(String("kci: validation ") + v.name + String(": ") + row.outcome)
                try:
                    outcome = worst_outcome(outcome, row.outcome)
                except e:
                    outcome = String(OUTCOME_INDETERMINATE)
                if row.outcome != String(OUTCOME_SUCCEEDED):
                    try:
                        result.set_error(String(ERROR_VALIDATION), validation_failure_message(row))
                    except e:
                        _say(String("kci: ") + String(e))
                    stopped = True
            result.validations.append(row^)
    # 4b, at the end: only a validated set is handed on
    keep_set_hash_only_if_validated(sel, result)
    # 7. the stages after this one: their new names, before their approval
    if outcome == OUTCOME_SUCCEEDED or outcome == OUTCOME_NOOP:
        ahead = _lookahead(cmd, g, stage, steps, result)
        for i in range(len(ahead)):
            ref r = ahead[i]
            if not r.read:
                _say(String("kci: NEW NAMES of stage ") + r.stage + String(" on ") + r.where() + String(": ") + r.detail)
            elif len(r.names) == 0:
                _say(String("kci: NEW NAMES of stage ") + r.stage + String(" on ") + r.where() + String(": none"))
            else:
                for n in range(len(r.names)):
                    _say(String("kci: NEW NAME of stage ") + r.stage + String(" on ") + r.where() + String(": ") + r.names[n])
    return _end_run(result, recorder, outcome, retry)


def run_stage_with[S: StageSteps](cmd: KciCommand, mut steps: S, mut recorder: CliRecorder) -> Int:
    """`kci run --stage S` (file header). Returns the exit number; the
    summary goes to `--summary-file` on every path."""
    var result = KciRunResult(String(VERB_RUN), String("run"))
    result.started_at_ms = _now()
    result.stage = cmd.stage.copy()
    result.revision = cmd.revision_id.copy()
    result.plan = cmd.plan
    var step_blocks = List[String]()
    var ahead = List[NewNamesReport]()
    var banner = String("")
    var main_only = False
    var rc = _run_stage(cmd, steps, recorder, result, step_blocks, ahead, banner, main_only)
    var text = String("")
    if banner.byte_length() > 0:
        text += String("### ") + banner + String("\n\n")
    text += run_summary_markdown(result, step_blocks, ahead)
    var line = promotion_line(result, cmd.stage, main_only)
    if line.byte_length() > 0:
        text += String("### ") + line + String("\n\n")
        _say(line)
    append_summary(cmd.summary_file, text)
    return rc


def kci_main_with[S: StageSteps](args: List[String], mut steps: S, mut recorder: CliRecorder) -> Int:
    """`kci <args>`: parse; print the usage; or `kci run`. A refused command
    line is exit 2, recorded in the file `--result-file` names and summarized
    in the file `--summary-file` names, when it names them. Returns the exit
    number. Its first act reads the monotonic clock: kci's start, from which
    `--build-budget-s` counts."""
    var started_ns = Int(perf_counter_ns())
    var cmd: KciCommand
    try:
        cmd = parse_kci_args(args)
    except e:
        var typed = String("run")
        if len(args) > 0:
            typed = args[0].copy()
        var result = KciRunResult(String(VERB_RUN), typed^)
        result.started_at_ms = _now()
        _say(String(KCI_USAGE))
        var rc = _stop(result, recorder, String(OUTCOME_REFUSED), String(ERROR_USAGE), String(e))
        append_summary(
            find_summary_file(args),
            String("## kci: REFUSED (exit ") + String(rc) + String(")\n\nThe command line was refused: ")
            + String(e) + String("\n\n"),
        )
        return rc
    if cmd.verb == String(CLI_VERB_HELP):
        _say(String(KCI_USAGE))
        return EXIT_OK
    cmd.started_ns = started_ns
    return run_stage_with(cmd, steps, recorder)


def recorder_for(args: List[String]) -> CliRecorder:
    """The recorder for this command line: the file `--result-file` names,
    found even in a command line that is otherwise refused."""
    return CliRecorder(find_result_file(args))
