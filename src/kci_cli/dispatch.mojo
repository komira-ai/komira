# =============================================================================
# src/kci_cli/dispatch.mojo -- `kci run --stage S`, kci's one command: from
#   the parsed command line to the steps, the result document, the job
#   summary and the exit number.
# =============================================================================
#
# `kci run --stage S`:
#
#   0. every `--only` parsed (args.mojo `selectors_of`): a malformed or
#      repeated selector is KCI-E-SELECTOR, exit 2, before anything is read;
#   1. read the machine file (`--machine`, or args.mojo's default): a path
#      that names no file is a usage error (KCI-E-USAGE, exit 2); a file
#      whose schema_version this kci does not read is REFUSED
#      (KCI-E-FORMAT-VERSION); any other refusal of the file is REFUSED
#      (KCI-E-FORMAT);
#   2. resolve S: an unknown stage is REFUSED (KCI-E-STAGE-UNKNOWN, the
#      message lists the stages); then the selection (kci_release_machine
#      `resolve_selection`): a selector that matches nothing in S is
#      REFUSED (KCI-E-SELECTOR-NO-MATCH, exit 3, naming S's steps and
#      validations); then the flags the SELECTED steps' kinds take, and
#      `--scratch-dir` exactly when a validation is selected (args.mojo
#      `require_stage_flags`, exit 2);
#   3. (no longer a refusal: validations run, step 6);
#   4. THE WORKFLOW CHECK, when the platform-set `GITHUB_ACTIONS` is "true":
#      the workflow file running this job is the one `GITHUB_WORKFLOW_REF`
#      names (`<GITHUB_REPOSITORY>/<path>@<ref>`, the path under
#      .github/workflows/), read as it was COMMITTED at `GITHUB_WORKFLOW_SHA`
#      (`git show <sha>:<path>`; the checkout may be another revision), and
#      held to the machine file by kci_ci_check's `check_running_workflow`
#      with every channels file the machine file names. Any finding is
#      REFUSED (KCI-E-WORKFLOW-MISMATCH, exit 3), every finding printed and
#      no step run. A variable that is unset or malformed, a `git show` that
#      fails, a channels file or a workflow that cannot be read is
#      INDETERMINATE (KCI-E-CANNOT-TELL, exit 5), never a pass. Not under
#      GitHub Actions nothing is checked and the result says so
#      (`workflow.checked` false, reason "not under GitHub Actions");
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
#      SUCCEEDED (VALIDATION_FAILED, KCI-E-VALIDATION, exit 7); a selected
#      validation after that point gets a NOT_REACHED row. Under `--plan` a
#      validation runs nothing and its row is WOULD_VALIDATE;
#   7. NEW NAMES AHEAD: when the run ended SUCCEEDED or NOOP, every PUBLISH
#      step of each stage whose `after` is S is read through `steps.lookahead`
#      (anonymous reads of that stage's channel, kci_publish
#      `lookahead_new_names`), so the names a later, approval-gated stage
#      would publish for the first time are in THIS run's result
#      (`new_names[]` rows naming that stage) and summary before anyone
#      approves it. A channel that was not read says so, never "none";
#   8. the run's outcome is its worst step's (kci_api's `worst_outcome`),
#      and PARTIAL when a step fails after an earlier PUBLISH step changed
#      the channel; the FINISHED record, then the exit number
#      (kci_api's exit table), which is the return value;
#   9. `--summary-file`: a markdown block APPENDED to that file on every exit
#      path after the command line parsed (`run_summary_markdown`): the
#      outcome and exit number, the scope, the revision and set hash, the
#      workflow check, the steps, the validations with each failed check's
#      finding, and each NEW NAMES block (this stage's
#      PUBLISH steps, then the stages after it). A file that cannot be
#      written is said on stderr; the exit number stands;
#  10. the LAST stderr line is the run's evidence (kci_api
#      `run_evidence_line`): `kci: FULL run of stage S: <OUTCOME>`, or
#      `kci: SELECTIVE run of stage S (<only>): <OUTCOME> -- not a full run`.
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

from komira_clock import now_unix_ms

from kci_build import BuildRequest
from kci_ci_check import ChannelsFile, channels_paths, check_running_workflow
from kci_api import (
    VALIDATION_NOT_REACHED,
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

comptime _STDERR: FileDescriptor = FileDescriptor(2)

# The platform-set variables the workflow check reads (file header, 4): the
# runner sets them, nothing else does (the mode-discriminator carve-out).
comptime GITHUB_ACTIONS: String = "GITHUB_ACTIONS"
comptime GITHUB_WORKFLOW_REF: String = "GITHUB_WORKFLOW_REF"
comptime GITHUB_WORKFLOW_SHA: String = "GITHUB_WORKFLOW_SHA"
comptime GITHUB_REPOSITORY: String = "GITHUB_REPOSITORY"
comptime NOT_UNDER_GITHUB_ACTIONS: String = "not under GitHub Actions"


struct StepEnd(Copyable, Movable):
    """How one step ended: its outcome and first error id (kci_api),
    the lines to print, retry advice stronger than the exit number's ("" for
    the default), whether it changed something outside this machine, and
    its markdown for the job summary ("" for none; a PUBLISH step's NEW
    NAMES block).

    Layout: owned values only. No pointer field."""

    var outcome: String
    var error_id: String
    var message: String
    var lines: List[String]
    var retry: String
    var changed_outside: Bool
    var summary: String

    def __init__(out self, var outcome: String, var error_id: String, var message: String):
        self.outcome = outcome^
        self.error_id = error_id^
        self.message = message^
        self.lines = List[String]()
        self.retry = String("")
        self.changed_outside = False
        self.summary = String("")

    def ok(self) -> Bool:
        return self.outcome == OUTCOME_SUCCEEDED or self.outcome == OUTCOME_NOOP


trait StageSteps:
    """Everything a run does outside this process (file header). One method
    per step kind: the step's request in, how it ended out; each adds its
    own row, artifacts, new names and first error to `result`, and may call
    `recorder.begin` again before its own first effect. Then the reads the
    run makes around its steps: a later stage's NEW NAMES, a platform-set
    variable, and the committed workflow file."""

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        ...

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        ...

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        """One validation of a step (file header, 6): its row, VALIDATED
        with an outcome and its checks, or WOULD_VALIDATE under --plan.
        Never raises: a validation that cannot run is a failed check."""
        ...

    def lookahead(mut self, req: PublishRequest) -> NewNamesReport:
        """The NEW NAMES of a later stage's PUBLISH step `req` (file header,
        7): reads only, never raises; a channel not read says why."""
        ...

    def platform_env(mut self, name: String) -> String:
        """A platform-set variable's value, "" when unset (file header, 4)."""
        ...

    def committed_file(mut self, commit: String, path: String) raises -> String:
        """The text of `path` as committed at `commit` (`git show
        <commit>:<path>` in the directory kci runs in). Raises when it
        cannot be read."""
        ...


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
    result.machine_path = cmd.machine.copy()
    result.machine_sha256 = file_sha256_hex(cmd.machine)
    return g^


def _split(e: Error) -> Tuple[String, String]:
    var s = String(e)
    var nl = s.find(String("\n"))
    if nl < 0:
        return (String(ERROR_INTERNAL), s^)
    return (String(s[byte = 0:nl]), String(s[byte = nl + 1 :]))


def _evidence(result: KciRunResult, outcome: String, rc: Int) -> Int:
    """Say the run's last line (file header, 6); return `rc`."""
    try:
        _say(run_evidence_line(result.scope, result.stage, result.only, outcome))
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
    return req^


def _publish_request(cmd: KciCommand, stage: Stage, step: StageStep) raises -> PublishRequest:
    var req = PublishRequest(cmd.run_identity())
    req.step_name = step.name.copy()
    req.artifacts_file = step.artifacts.copy()
    req.release_dir = cmd.release_dir.copy()
    req.platform = step.platform.copy()
    req.revision_id = cmd.revision_id.copy()
    req.stage = stage.name.copy()
    req.environment = stage.environment.copy()
    req.channels_file = step.channels.copy()
    req.channel = step.channel.copy()
    req.release_version_file = cmd.release_version.copy()
    if cmd.concurrency > 0:
        req.concurrency = cmd.concurrency
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
    return req^


def _selected(sel: Selection, name: String) -> Bool:
    for i in range(len(sel.validations)):
        if sel.validations[i] == name:
            return True
    return False


def validation_failure_message(row: ResultValidation) -> String:
    """The run's error message for a failed validation: its name and each
    failed check's finding."""
    var s = String("validation '") + row.name + String("' of step '") + row.step + String("' failed:")
    for i in range(len(row.checks)):
        if not row.checks[i].ok:
            s += String("\n") + row.checks[i].got
    return s^


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


struct _WorkflowVerdict(Copyable, Movable):
    """The start-up workflow check's verdict (file header, 4): `outcome` ""
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
    def cannot_tell(var message: String) -> _WorkflowVerdict:
        var v = _WorkflowVerdict()
        v.outcome = String(OUTCOME_INDETERMINATE)
        v.error_id = String(ERROR_CANNOT_TELL)
        v.message = String("the workflow check cannot tell, so nothing is run: ") + message
        return v^


def _check_workflow_at_start[S: StageSteps](
    cmd: KciCommand, g: ReleaseMachine, mut steps: S, mut result: KciRunResult
) -> _WorkflowVerdict:
    """File header, 4. Records `workflow` in `result`."""
    if steps.platform_env(String(GITHUB_ACTIONS)) != String("true"):
        result.workflow_checked = False
        result.workflow_reason = String(NOT_UNDER_GITHUB_ACTIONS)
        return _WorkflowVerdict()
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
            return _WorkflowVerdict.cannot_tell(
                String(GITHUB_ACTIONS) + String(" is true and ") + needed[i] + String(" is not set")
            )
    if not is_full_commit_id(sha):
        result.workflow_reason = String(GITHUB_WORKFLOW_SHA) + String(" is not a full commit id")
        return _WorkflowVerdict.cannot_tell(
            String(GITHUB_WORKFLOW_SHA) + String(" '") + sha + String("' is not a full commit id")
        )
    var path: String
    try:
        path = workflow_path_of(ref_value, repository)
    except e:
        result.workflow_reason = String(GITHUB_WORKFLOW_REF) + String(" names no workflow file")
        return _WorkflowVerdict.cannot_tell(String(e))
    result.workflow_path = path.copy()
    result.workflow_sha = sha.copy()
    var text: String
    try:
        text = steps.committed_file(sha, path)
    except e:
        result.workflow_reason = String("the workflow could not be read at its commit")
        return _WorkflowVerdict.cannot_tell(
            String("`git show ") + sha + String(":") + path + String("` failed: ") + String(e)
        )
    var files = List[ChannelsFile]()
    var paths = channels_paths(g)
    for i in range(len(paths)):
        try:
            files.append(ChannelsFile(paths[i].copy(), _read(paths[i])))
        except e:
            result.workflow_reason = String("a channels file could not be read")
            return _WorkflowVerdict.cannot_tell(
                String("the channels file '") + paths[i] + String("' cannot be read: ") + String(e)
            )
    var findings: List[String]
    try:
        findings = check_running_workflow(g, files, text, cmd.machine)
    except e:
        result.workflow_reason = String("the workflow could not be checked")
        return _WorkflowVerdict.cannot_tell(path + String(" at ") + sha + String(": ") + String(e))
    if len(findings) > 0:
        result.workflow_reason = String("the workflow does not match the machine file")
        var v = _WorkflowVerdict()
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
    return _WorkflowVerdict()


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
            try:
                r = steps.lookahead(_publish_request(cmd, later, step))
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


def run_summary_markdown(result: KciRunResult, step_blocks: List[String], ahead: List[NewNamesReport]) -> String:
    """The `--summary-file` block of a finished run (file header, 9)."""
    var s = String("## kci run --stage ") + result.stage + String(": ") + result.outcome
    s += String(" (exit ") + String(result.exit_code) + String(")\n\n")
    if result.scope == SCOPE_SELECTIVE:
        var only = String("")
        for i in range(len(result.only)):
            if i > 0:
                only += String(" ")
            only += result.only[i]
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
            s += String("| ") + st.name + String(" | ") + st.kind + String(" | ") + o + String(" |\n")
    if len(result.validations) > 0:
        s += String("\n| validation | step | outcome |\n|---|---|---|\n")
        for i in range(len(result.validations)):
            ref v = result.validations[i]
            var o = v.outcome.copy() if v.outcome.byte_length() > 0 else v.effect.copy()
            s += String("| ") + v.name + String(" | ") + v.step + String(" | ") + o + String(" |\n")
            for k in range(len(v.checks)):
                if not v.checks[k].ok:
                    s += String("| | | `") + v.checks[k].got + String("` |\n")
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


def _run_step[S: StageSteps](
    cmd: KciCommand,
    stage: Stage,
    step: StageStep,
    mut steps: S,
    mut recorder: CliRecorder,
    mut result: KciRunResult,
    mut step_blocks: List[String],
) -> StepEnd:
    """One selected step (file header, 6): run it, print its lines, keep its
    summary block."""
    _say(String("kci: stage ") + stage.name + String(", step ") + step.name + String(" (") + step.kind + String(")"))
    var end: StepEnd
    try:
        if step.is_build():
            end = steps.build(_build_request(cmd, step), result, recorder)
        else:
            end = steps.publish(_publish_request(cmd, stage, step), result, recorder, cmd.store)
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
) -> Int:
    """File header, 0 to 8 and 10. Returns the exit number."""
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
    result.stage_step_kinds = stage.step_kinds()
    result.platform = stage.steps[0].platform.copy()
    var sel: Selection
    try:
        sel = resolve_selection(stage, selectors)
    except e:
        return _stop_run(result, recorder, String(OUTCOME_REFUSED), String(ERROR_SELECTOR_NO_MATCH), String(e))
    result.scope = sel.scope.copy()
    try:
        require_stage_flags(cmd, stage, sel)
    except e:
        return _stop_run(result, recorder, String(OUTCOME_REFUSED), String(ERROR_USAGE), String(e))
    # 4. the workflow this job runs under, held to the machine file
    var verdict = _check_workflow_at_start(cmd, g, steps, result)
    if verdict.outcome.byte_length() > 0:
        return _stop_run(result, recorder, verdict.outcome, verdict.error_id, verdict.message)
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
            var end = _run_step(cmd, stage, step, steps, recorder, result, step_blocks)
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
    var rc = _run_stage(cmd, steps, recorder, result, step_blocks, ahead)
    append_summary(cmd.summary_file, run_summary_markdown(result, step_blocks, ahead))
    return rc


def kci_main_with[S: StageSteps](args: List[String], mut steps: S, mut recorder: CliRecorder) -> Int:
    """`kci <args>`: parse; print the usage; or `kci run`. A refused command
    line is exit 2, recorded in the file `--result-file` names and summarized
    in the file `--summary-file` names, when it names them. Returns the exit
    number."""
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
    return run_stage_with(cmd, steps, recorder)


def recorder_for(args: List[String]) -> CliRecorder:
    """The recorder for this command line: the file `--result-file` names,
    found even in a command line that is otherwise refused."""
    return CliRecorder(find_result_file(args))
