# =============================================================================
# src/kci_cli/dispatch.mojo -- `kci run --stage S` and `kci ci check`: from
#   the parsed command line to the steps, the result document and the exit
#   number.
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
#      message lists the stages); then the selection (kci_stage_graph
#      `resolve_selection`): a selector that matches nothing in S is
#      REFUSED (KCI-E-SELECTOR-NO-MATCH, exit 3, naming S's steps and
#      validations); then the flags the SELECTED steps' kinds take
#      (args.mojo `require_stage_flags`, exit 2);
#   3. the RUNNING record (`recorder.begin`) BEFORE the first effect. A
#      record that cannot be written stops the run FAILED
#      (KCI-E-RESULT-FILE), nothing done;
#   4. every SELECTED step of S, in file order: a BUILD step through
#      `steps.build`, a PUBLISH step through `steps.publish`, each given its
#      name, the stage, the revision, the platform, the run identity, `--plan`
#      and its own inputs. Each step adds its row, artifacts and first error
#      to the result; a step `--only` did not select gets a row with
#      `selected: false` and no outcome. The run stops at the first step
#      that does not end SUCCEEDED or NOOP;
#   5. the run's outcome is its worst step's (kci_contract's `worst_outcome`),
#      and PARTIAL when a step fails after an earlier PUBLISH step changed
#      the channel; the FINISHED record, then the exit number
#      (kci_contract's exit table), which is the return value.
#   6. the LAST stderr line is the run's evidence (kci_contract
#      `run_evidence_line`): `kci: FULL run of stage S: <OUTCOME>`, or
#      `kci: SELECTIVE run of stage S (<only>): <OUTCOME> -- not a full run`.
#      The result document says the same in `scope` and `only`. A selective
#      success exits 0 like a full one, so the scope, never the number, is
#      what tells them apart. A run refused before its selectors parse (a
#      usage error) prints no evidence line: nothing was selected.
#
# `kci ci check`: the machine file as in 1; the workflow (`--workflow`; a
# path that names no file is a usage error); every channels file a PUBLISH
# step names (refused: KCI-E-CHANNEL); then kci_ci_check. A workflow the
# restricted reader cannot read is INDETERMINATE (KCI-E-CANNOT-TELL, exit
# 5), never a pass; disagreements are REFUSED (KCI-E-FORMAT, exit 3), each
# printed; agreement is NOOP (exit 0). It changes nothing.
#
# Every refusal the command line itself earns (args.mojo) is recorded too,
# in the file `--result-file` names when it can be found (`kci_main_with`).
#
# The steps run behind the `StageSteps` seam: `LibrarySteps`
# (library_verbs.mojo) calls kci_build and kci_publish; the welded tests drive
# a recording fake. Human text goes to stderr; stdout carries nothing.
#
# Encapsulation: owned values and a generic seam; no pointer, no wildcard
# origin.
# =============================================================================

from std.os.path import exists, isfile
from std.pathlib import Path

from komira_clock import now_unix_ms

from kci_build import BuildRequest
from kci_ci_check import CANNOT_TELL, ChannelsFile, channels_paths, check_workflow, id_token_stages
from kci_contract import (
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
    EXIT_INTERNAL,
    EXIT_OK,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    VERB_CI_CHECK,
    VERB_RUN,
    SCOPE_SELECTIVE,
    ResultStep,
    Selector,
    run_evidence_line,
    worst_outcome,
)
from kci_contract import RunResult as KciRunResult
from kci_publish import PublishRequest
from kci_release_set.member import file_sha256_hex
from kci_stage_graph import (
    Selection,
    Stage,
    StageGraph,
    StageStep,
    machine_schema_version,
    parse_machine_file,
    resolve_selection,
)

from .args import (
    CLI_VERB_CI_CHECK,
    CLI_VERB_HELP,
    KCI_USAGE,
    KciCommand,
    SecretStoreChoice,
    find_result_file,
    parse_kci_args,
    require_stage_flags,
    selectors_of,
)
from .recorder import CliRecorder

comptime _STDERR: FileDescriptor = FileDescriptor(2)


struct StepEnd(Copyable, Movable):
    """How one step ended: its outcome and first error id (kci_contract),
    the lines to print, retry advice stronger than the exit number's ("" for
    the default), and whether it changed something outside this machine.

    Layout: owned values only. No pointer field."""

    var outcome: String
    var error_id: String
    var message: String
    var lines: List[String]
    var retry: String
    var changed_outside: Bool

    def __init__(out self, var outcome: String, var error_id: String, var message: String):
        self.outcome = outcome^
        self.error_id = error_id^
        self.message = message^
        self.lines = List[String]()
        self.retry = String("")
        self.changed_outside = False

    def ok(self) -> Bool:
        return self.outcome == OUTCOME_SUCCEEDED or self.outcome == OUTCOME_NOOP


trait StageSteps:
    """One method per step kind: the step's request in, how it ended out.
    Each adds its own row, artifacts and first error to `result`, and may
    call `recorder.begin` again before its own first effect."""

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        ...

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
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
        return EXIT_INTERNAL
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


def _load_graph(cmd: KciCommand, mut result: KciRunResult) raises -> StageGraph:
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
    var g: StageGraph
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
    req.declarations_file = step.declarations.copy()
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
    req.declarations_file = step.declarations.copy()
    req.release_dir = cmd.release_dir.copy()
    req.platform = step.platform.copy()
    req.revision_id = cmd.revision_id.copy()
    req.stage = stage.name.copy()
    req.channels_file = step.channels.copy()
    req.channel = step.channel.copy()
    req.release_version_file = cmd.release_version.copy()
    req.expect_set_hash = cmd.expect_set_hash.copy()
    req.claims = cmd.claims.copy()
    if cmd.concurrency > 0:
        req.concurrency = cmd.concurrency
    req.plan = cmd.plan
    return req^


def run_stage_with[S: StageSteps](cmd: KciCommand, mut steps: S, mut recorder: CliRecorder) -> Int:
    """`kci run --stage S` (file header). Returns the exit number."""
    var result = KciRunResult(String(VERB_RUN), String("run"))
    result.started_at_ms = _now()
    result.stage = cmd.stage.copy()
    result.revision = cmd.revision_id.copy()
    result.plan = cmd.plan
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
    var g: StageGraph
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
    for i in range(len(stage.steps)):
        if sel.steps[i] and stage.steps[i].is_publish():
            result.expect_set_hash = cmd.expect_set_hash.copy()
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
    for i in range(len(stage.steps)):
        ref step = stage.steps[i]
        if not sel.steps[i]:
            _say(String("kci: stage ") + stage.name + String(", step ") + step.name + String(": not selected (--only)"))
            result.steps.append(ResultStep.unselected(step.name.copy(), step.kind.copy(), step.platform.copy()))
            continue
        _say(String("kci: stage ") + stage.name + String(", step ") + step.name + String(" (") + step.kind + String(")"))
        var end: StepEnd
        try:
            if step.is_build():
                end = steps.build(_build_request(cmd, step), result, recorder)
            else:
                end = steps.publish(_publish_request(cmd, stage, step), result, recorder, cmd.store)
        except e:
            end = StepEnd(String(OUTCOME_INDETERMINATE), String(ERROR_INTERNAL), String(e))
        for k in range(len(end.lines)):
            _say(end.lines[k])
        if end.message.byte_length() > 0 and not end.ok():
            _say(end.message)
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
            break
        if end.changed_outside:
            changed_outside = True
    return _end_run(result, recorder, outcome, retry)


def ci_check_with(cmd: KciCommand, mut recorder: CliRecorder) -> Int:
    """`kci ci check` (file header). Returns the exit number."""
    var result = KciRunResult(String(VERB_CI_CHECK), String("ci check"))
    result.started_at_ms = _now()
    var g: StageGraph
    try:
        g = _load_graph(cmd, result)
    except e:
        var p = _split(e)
        return _stop(result, recorder, String(OUTCOME_REFUSED), p[0], p[1])
    if not isfile(cmd.workflow):
        return _stop(
            result, recorder, String(OUTCOME_REFUSED), String(ERROR_USAGE),
            String("the workflow '") + cmd.workflow + String("' is not a file (--workflow)"),
        )
    try:
        recorder.begin(result.begin_record())
    except e:
        return _stop(
            result, recorder, String(OUTCOME_FAILED), String(ERROR_RESULT_FILE),
            String("the RUNNING record could not be written: ") + String(e),
        )
    var tokens: List[String]
    try:
        var files = List[ChannelsFile]()
        var paths = channels_paths(g)
        for i in range(len(paths)):
            files.append(ChannelsFile(paths[i].copy(), _read(paths[i])))
        tokens = id_token_stages(g, files)
    except e:
        return _stop(result, recorder, String(OUTCOME_REFUSED), String(ERROR_CHANNEL), String(e))
    var findings: List[String]
    try:
        findings = check_workflow(_read(cmd.workflow), g, tokens, cmd.machine)
    except e:
        var m = String(e)
        if m.startswith(String(CANNOT_TELL)):
            return _stop(
                result, recorder, String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
                cmd.workflow + String(": ") + m,
            )
        return _stop(result, recorder, String(OUTCOME_INDETERMINATE), String(ERROR_INTERNAL), m)
    if len(findings) > 0:
        for i in range(len(findings)):
            _say(cmd.workflow + String(": ") + findings[i])
        return _stop(
            result, recorder, String(OUTCOME_REFUSED), String(ERROR_FORMAT),
            cmd.workflow + String(" disagrees with ") + cmd.machine + String(" in ") + String(len(findings))
            + String(" place(s); the machine file owns the stages, edit both together"),
        )
    _say(cmd.workflow + String(" agrees with ") + cmd.machine)
    return _finish(result, recorder, String(OUTCOME_NOOP))


def kci_main_with[S: StageSteps](args: List[String], mut steps: S, mut recorder: CliRecorder) -> Int:
    """`kci <args>`: parse; print the usage; or run `run` / `ci check`. A
    refused command line is exit 2 and is recorded in the file
    `--result-file` names, when it names one. Returns the exit number."""
    var cmd: KciCommand
    try:
        cmd = parse_kci_args(args)
    except e:
        var verb = String(VERB_RUN)
        var typed = String("run")
        if len(args) > 0:
            typed = args[0].copy()
            if args[0] == String("ci"):
                verb = String(VERB_CI_CHECK)
                typed = String("ci check")
        var result = KciRunResult(verb^, typed^)
        result.started_at_ms = _now()
        _say(String(KCI_USAGE))
        return _stop(result, recorder, String(OUTCOME_REFUSED), String(ERROR_USAGE), String(e))
    if cmd.verb == String(CLI_VERB_HELP):
        _say(String(KCI_USAGE))
        return EXIT_OK
    if cmd.verb == String(CLI_VERB_CI_CHECK):
        return ci_check_with(cmd, recorder)
    return run_stage_with(cmd, steps, recorder)


def recorder_for(args: List[String]) -> CliRecorder:
    """The recorder for this command line: the file `--result-file` names,
    found even in a command line that is otherwise refused."""
    return CliRecorder(find_result_file(args))
