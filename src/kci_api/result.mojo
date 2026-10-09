# =============================================================================
# src/kci_api/result.mojo -- the ONE result document `kci run` writes
#   with `--result-file`, rendered and parsed.
# =============================================================================
#
# Format `kci.result`, schema_version 1 (formats.mojo). Compact JSON, every
# object's keys sorted bytewise, one trailing newline. Keys:
#
#   affected_by         {base, reason, units[], verdict}: `kci run
#                       --affected-by <base>` (the per-change check); ABSENT
#                       otherwise. verdict is AFFECTED or WIDENED once every
#                       build system answered, "" before; reason is WIDENED's
#                       and "" otherwise; units[] the units the run builds
#                       (or would, under --plan), in build order. Such a run
#                       is SELECTIVE, whatever it builds
#   artifacts[]         {artifact_type, build, effect, file, indexed, name,
#                       platform, revision, sha256, state_after,
#                       state_before, subdir, version}: a BUILD step writes
#                       one row per member (effect BUILT, or WOULD_BUILD under
#                       --plan); a PUBLISH step one per file
#   attempt             --attempt (0 when the command line had none)
#   channel             publish: the channel's name; else ""
#   context{}           every --context, in the order given (keys unique)
#   error               {id, message}: the first refusal or failure; ABSENT
#                       when there is none. The message never holds a secret
#   exit_code           the exit number (exit_codes.mojo)
#   finished_at_ms      0 while RUNNING
#   format              "kci.result"
#   invoked_as          the verb as typed, unvalidated (a refused `build`
#                       is recorded as typed)
#   kci_version         this kci's version
#   machine             {path, sha256} of the machine file; "" before it
#                       is read
#   new_names[]         {channel, name, stage, step}: for each PUBLISH step
#                       of this stage and of the stages directly after it,
#                       every declared name the step's channel holds no file
#                       of yet. A report, never a refusal: the approver of a
#                       later stage reads it before approving
#   only[]              every --only selector, canonical (`step:<name>`), in
#                       the order given; empty for a FULL run
#   outcome, retry      outcome.mojo
#   plan                --plan: a dry run (nothing built, nothing sent)
#   platform            the stage's platform; "" when unknown
#   release_produced_by publish: {attempt, run_id} copied from release.json;
#                       ABSENT otherwise
#   revision            --revision-id (full commit id) or ""
#   run_id              --run-id or "" (a usage error can precede it)
#   schema_version      1
#   scope               FULL or SELECTIVE (selection.mojo): SELECTIVE
#                       whenever any --only, or --affected-by, is given
#   set_hash            build: computed; publish or validation:
#                       recomputed, never under --plan, and for a run
#                       that selects validations only when every one
#                       VALIDATED and SUCCEEDED; else ""
#   stage               the stage run; "" when unknown
#   stage_step_kinds    the kinds of the stage's steps, in order
#   started_at_ms
#   status              RUNNING or FINISHED
#   steps[]             {credential_probe, kind, name, outcome, platform,
#                       selected}: the steps of the stage, in machine-file
#                       order. An unselected step has selected false and
#                       outcome ""; a selected one has its outcome once it
#                       ran. credential_probe is a PUBLISH step's --plan
#                       probe of its publishing credential: MINTED (the token
#                       was exchanged and discarded, nothing written),
#                       NOT_UNDER_CI (no CI token to exchange; never a pass),
#                       NOT_OIDC (the channel's credential is not exchanged),
#                       or "" (no probe: not a plan, or not a PUBLISH step).
#                       A step that names a cell also holds the deploy keys
#                       (result_deploy.mojo): cell, cloud, landed[]
#                       {node, verb}, pending[], failed {fault_domain,
#                       message, node, verb}, outputs[] {output, resource,
#                       value}, plan_hash, leftover[], left_behind[],
#                       released[]. They were added inside major 1 and are
#                       ABSENT from a row whose cell is "" (a reader takes
#                       an absent one as empty)
#   validations[]       {channel_url, checks[], effect, environment, kind,
#                       name, outcome, pixi_sha256, skip_reason, step}: the
#                       validations of the selected steps, in machine-file
#                       order. effect VALIDATED (it ran; outcome is its
#                       verdict), WOULD_VALIDATE (--plan: it did not run, so
#                       it has no outcome and no checks and can never read as
#                       a pass) or NOT_REACHED (the run stopped before it).
#                       checks[] rows are {check, expected, got, ok}; a
#                       SUCCEEDED validation holds at least one check and
#                       every check ok. environment is where it ran: ENV
#                       (this machine, no container) or CONTAINER, "" when
#                       it did not run; pixi_sha256 the sha256 of the pixi
#                       an ENV validation ran ("" otherwise); channel_url
#                       the step's channel location it installed from ("" when
#                       not known); skip_reason why it could not run at all
#                       (no network: no declared host answered), only on an
#                       INDETERMINATE outcome, "" otherwise. The last four
#                       were added inside major 1: a reader takes an absent
#                       one as ""
#   verb                run: the one verb
#   workflow            {checked, path, reason, sha}: the start-up check of
#                       the CI workflow running kci against the machine file.
#                       checked true: path (under .github/workflows/) and sha
#                       (the workflow's commit) name what was checked, reason
#                       is "". checked false: reason says why ("not under
#                       GitHub Actions", or what could not be read)
#
# A FULL record with an unselected step or an `affected_by`, and a SELECTIVE
# record with an empty `only` and no `affected_by`, are refused by the
# renderer and the parser alike: a selective run can never read as a full
# one. The outcome and exit number do not say
# which it was (a selective success is exit 0); `scope` does, and so does the
# CLI's last stderr line (selection.mojo `run_evidence_line`).
#
# Nothing has been released under major 1, so the v1.3 vocabulary pass
# (actions -> steps, action -> effect, dry_run -> plan) renamed keys inside
# it rather than bumping the major, and the one-command pass added
# new_names, validations, workflow and steps[].credential_probe and dropped
# expect_set_hash the same way (a document still holding it reads it as an
# ignored key).
#
# The CLI writes the file TWICE: status RUNNING after resolving the command
# line and BEFORE the first effect, then FINISHED on every exit path. A
# RUNNING record says outcome INTERRUPTED, exit 6, retry UNSAFE, so a file a
# killed kci left behind reads as interrupted without a special case.
#
# Readers ignore unknown keys inside major 1 (formats.mojo); `parse_result`
# records them in `ignored_keys`, with one exception: a deploy key of a step
# row (`deploy_step_keys`) at the TOP level is refused, never ignored. A stage
# can deploy into several cells, and a top-level `landed` cannot say which
# cell a node is in, so a reader that skipped it would lose what landed.
# `security_relevant_changes[]` stays RESERVED for the deploy side and is
# not emitted: an always-empty list would claim a check that has no code.
#
# `RunRecorder` is the seam a verb records through: `begin` before the first
# effect, `finish` at the end. Writing a file is the CLI's recorder; tests
# use `MemoryRecorder`.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_json import JSON_ARRAY, JSON_OBJECT, JSON_STRING, JsonValue, parse_json_value

from kci_api.errors import require_error_id
from kci_api.exit_codes import EXIT_PARTIAL, default_retry, exit_code_of, require_retry_for
from kci_api.formats import FORMAT_RESULT, current_major, produced_header
from kci_api.outcome import OUTCOME_INDETERMINATE, OUTCOME_INTERRUPTED, OUTCOME_SUCCEEDED, RETRY_UNSAFE, require_outcome
from kci_api.platform import platform_row
from kci_api.revision import is_full_commit_id
from kci_api.run_identity import ContextEntry, RunIdentity
from kci_api.selection import (
    AFFECTED_VERDICT_AFFECTED,
    AFFECTED_VERDICT_WIDENED,
    SCOPE_FULL,
    SCOPE_SELECTIVE,
    parse_selector,
    require_scope,
)
from kci_api.verbs import STEP_KIND_PUBLISH, require_step_kind, require_validation_kind, require_verb
from kci_api.result_deploy import (
    check_deploy_row,
    deploy_step_keys,
    parse_deploy_keys,
    put_deploy_keys,
    refuse_top_level_deploy_keys,
)
from kci_api.result_json import (
    _b,
    _i,
    _is_sha256_hex,
    _keys,
    _member,
    _need,
    _no_dup_keys,
    _note_unknown,
    _Obj,
    _refuse,
    _s,
    _s_absent_empty,
    _str_array,
)
from kci_api.result_rows import (
    VALIDATION_ENVIRONMENT_CONTAINER,
    VALIDATION_ENVIRONMENT_ENV,
    VALIDATION_NOT_REACHED,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    WORKFLOW_NOT_REACHED,
    WORKFLOW_PATH_PREFIX,
    ResultArtifact,
    ResultError,
    ResultNewName,
    ResultStep,
    ResultValidation,
    ResultValidationCheck,
    all_artifact_effects,
    all_credential_probes,
)

comptime KCI_VERSION: String = "0.0.0-unreleased"
"""This kci's version, until kci itself is released."""

comptime STATUS_RUNNING: String = "RUNNING"
comptime STATUS_FINISHED: String = "FINISHED"

struct RunResult(Copyable, Movable):
    """The result document (file header). Start one with `RunResult(verb,
    invoked_as)`; `begin_record` and `finish_record` give the two records the
    CLI writes.

    Layout: owned values only. No pointer field."""

    var status: String
    var kci_version: String
    var verb: String
    var invoked_as: String
    var machine_path: String
    var machine_sha256: String
    var stage: String
    var stage_step_kinds: List[String]
    var revision: String
    var platform: String
    var run_id: String
    var attempt: Int
    var context: List[ContextEntry]
    var started_at_ms: Int
    var finished_at_ms: Int
    var outcome: String
    var exit_code: Int
    var retry: String
    var has_error: Bool
    var error: ResultError
    var steps: List[ResultStep]
    var plan: Bool
    var scope: String
    var only: List[String]
    var channel: String
    var set_hash: String
    var has_release_produced_by: Bool
    var release_produced_by_run_id: String
    var release_produced_by_attempt: Int
    var artifacts: List[ResultArtifact]
    var validations: List[ResultValidation]
    var new_names: List[ResultNewName]
    var workflow_checked: Bool
    var workflow_path: String
    var workflow_sha: String
    var workflow_reason: String
    var has_affected_by: Bool
    var affected_base: String
    var affected_verdict: String
    var affected_reason: String
    var affected_units: List[String]
    # Set by `parse_result` only: the keys it ignored (file header). Never
    # rendered.
    var ignored_keys: List[String]

    def __init__(out self, var verb: String, var invoked_as: String):
        self.status = String(STATUS_RUNNING)
        self.kci_version = String(KCI_VERSION)
        self.verb = verb^
        self.invoked_as = invoked_as^
        self.machine_path = String("")
        self.machine_sha256 = String("")
        self.stage = String("")
        self.stage_step_kinds = List[String]()
        self.revision = String("")
        self.platform = String("")
        self.run_id = String("")
        self.attempt = 0
        self.context = List[ContextEntry]()
        self.started_at_ms = 0
        self.finished_at_ms = 0
        self.outcome = String(OUTCOME_INTERRUPTED)
        self.exit_code = EXIT_PARTIAL
        self.retry = String(RETRY_UNSAFE)
        self.has_error = False
        self.error = ResultError(String(""), String(""))
        self.steps = List[ResultStep]()
        self.plan = False
        self.scope = String(SCOPE_FULL)
        self.only = List[String]()
        self.channel = String("")
        self.set_hash = String("")
        self.has_release_produced_by = False
        self.release_produced_by_run_id = String("")
        self.release_produced_by_attempt = 0
        self.artifacts = List[ResultArtifact]()
        self.validations = List[ResultValidation]()
        self.new_names = List[ResultNewName]()
        self.workflow_checked = False
        self.workflow_path = String("")
        self.workflow_sha = String("")
        self.workflow_reason = String(WORKFLOW_NOT_REACHED)
        self.has_affected_by = False
        self.affected_base = String("")
        self.affected_verdict = String("")
        self.affected_reason = String("")
        self.affected_units = List[String]()
        self.ignored_keys = List[String]()

    def set_run(mut self, run: RunIdentity):
        """Copy `--run-id`, `--attempt` and every `--context`."""
        self.run_id = run.run_id.copy()
        self.attempt = run.attempt
        self.context = run.context.copy()

    def set_error(mut self, var id: String, var message: String) raises:
        """Record the first error; a later one does not replace it."""
        require_error_id(id)
        if self.has_error:
            return
        self.has_error = True
        self.error = ResultError(id^, message^)

    def begin_record(self) -> RunResult:
        """The RUNNING record: this result as it stands, marked RUNNING and
        INTERRUPTED (file header)."""
        var r = self.copy()
        r.status = String(STATUS_RUNNING)
        r.outcome = String(OUTCOME_INTERRUPTED)
        r.exit_code = EXIT_PARTIAL
        r.retry = String(RETRY_UNSAFE)
        r.finished_at_ms = 0
        return r^

    def finish_record(self, var outcome: String, finished_at_ms: Int, var retry: String = String("")) raises -> RunResult:
        """The FINISHED record with `outcome`: its exit number follows from
        the outcome and the recorded error's id; `retry` defaults to the
        number's advice and may only be stronger (exit_codes.mojo)."""
        require_outcome(outcome)
        var r = self.copy()
        r.status = String(STATUS_FINISHED)
        var id = String("")
        if r.has_error:
            id = r.error.id.copy()
        r.exit_code = exit_code_of(outcome, id)
        r.outcome = outcome^
        if retry.byte_length() == 0:
            r.retry = default_retry(r.exit_code)
        else:
            require_retry_for(r.exit_code, retry)
            r.retry = retry^
        r.finished_at_ms = finished_at_ms
        return r^


trait RunRecorder(Movable):
    """Where a verb records its result: `begin` once, before its first
    effect; `finish` once, last. A recorder that cannot record RAISES: the
    verb stops before any effect when `begin` raises."""

    def begin(mut self, r: RunResult) raises:
        ...

    def finish(mut self, r: RunResult) raises:
        ...


struct MemoryRecorder(RunRecorder, Copyable, Movable):
    """A recorder that keeps every record in memory, rendered, in order: for
    tests. `fail_begin` makes `begin` raise.

    Layout: owned values only. No pointer field."""

    var records: List[String]
    var statuses: List[String]
    var fail_begin: Bool

    def __init__(out self):
        self.records = List[String]()
        self.statuses = List[String]()
        self.fail_begin = False

    def begin(mut self, r: RunResult) raises:
        if self.fail_begin:
            raise Error(String("MemoryRecorder: begin refused (fail_begin)"))
        self.records.append(render_result(r))
        self.statuses.append(r.status.copy())

    def finish(mut self, r: RunResult) raises:
        self.records.append(render_result(r))
        self.statuses.append(r.status.copy())


# ---- rendering ---------------------------------------------------------------


def _check(r: RunResult) raises:
    """What a result must satisfy, for the renderer and the parser alike."""
    require_verb(r.verb)
    if r.invoked_as.byte_length() == 0:
        raise Error(String("result: 'invoked_as' is EMPTY"))
    if r.status != STATUS_RUNNING and r.status != STATUS_FINISHED:
        raise Error(String("result: status '") + r.status + String("' is not RUNNING or FINISHED"))
    require_outcome(r.outcome)
    if r.status == STATUS_RUNNING:
        if r.outcome != OUTCOME_INTERRUPTED or r.exit_code != EXIT_PARTIAL or r.retry != RETRY_UNSAFE:
            raise Error(String("result: a RUNNING record says INTERRUPTED, exit 6, retry UNSAFE"))
    var id = String("")
    if r.has_error:
        require_error_id(r.error.id)
        id = r.error.id.copy()
    if r.status == STATUS_FINISHED:
        var want = exit_code_of(r.outcome, id)
        if r.exit_code != want:
            raise Error(
                String("result: exit_code ") + String(r.exit_code) + String(" is not ")
                + String(want) + String(", the number of outcome ") + r.outcome
            )
        require_retry_for(r.exit_code, r.retry)
    if r.revision.byte_length() > 0 and not is_full_commit_id(r.revision):
        raise Error(String("result: revision '") + r.revision + String("' is not a full commit id"))
    if r.platform.byte_length() > 0:
        _ = platform_row(r.platform)
    for i in range(len(r.stage_step_kinds)):
        require_step_kind(r.stage_step_kinds[i])
    require_scope(r.scope)
    for i in range(len(r.only)):
        var sel = parse_selector(r.only[i])
        if sel.canonical() != r.only[i]:
            raise Error(String("result: only[") + String(i) + String("] '") + r.only[i] + String("' is not canonical"))  # cov: unreachable parse_selector splits at the first ':' and canonical() rejoins it there, so it is the text
        for j in range(i):
            if r.only[j] == r.only[i]:
                raise Error(String("result: only '") + r.only[i] + String("' is given twice"))
    if r.scope == SCOPE_SELECTIVE and len(r.only) == 0 and not r.has_affected_by:
        raise Error(
            String("result: a SELECTIVE run names its --only selectors or its --affected-by")
            + String(" (only is EMPTY and affected_by ABSENT)")
        )
    if r.scope == SCOPE_FULL and len(r.only) > 0:
        raise Error(String("result: a FULL run has no --only selectors"))
    _check_affected_by(r)
    for i in range(len(r.steps)):
        ref st = r.steps[i]
        var where = String("result: steps[") + String(i) + String("] '") + st.name + String("': ")
        if st.name.byte_length() == 0:
            raise Error(String("result: steps[") + String(i) + String("] has no name"))
        require_step_kind(st.kind)
        check_deploy_row(st.deploy, st.outcome, where)
        if st.credential_probe.byte_length() > 0:
            if not _member(all_credential_probes(), st.credential_probe):
                raise Error(
                    where + String("credential_probe '") + st.credential_probe
                    + String("' is not one of MINTED NOT_UNDER_CI NOT_OIDC")
                )
            if st.kind != STEP_KIND_PUBLISH:
                raise Error(where + String("only a PUBLISH step probes its credential"))
            if not r.plan:
                raise Error(where + String("a credential probe is made by a --plan run only"))
        if not st.selected:
            if r.scope == SCOPE_FULL:
                raise Error(where + String("a FULL run selects every step; this one is unselected"))
            if st.outcome.byte_length() > 0:
                raise Error(where + String("an unselected step has no outcome"))
            if st.credential_probe.byte_length() > 0:
                raise Error(where + String("an unselected step probes no credential"))
            continue
        require_outcome(st.outcome)
    _check_validations(r)
    _check_new_names(r)
    _check_workflow(r)
    var effects = all_artifact_effects()
    for i in range(len(r.artifacts)):
        var ok = False
        for j in range(len(effects)):
            if effects[j] == r.artifacts[i].effect:
                ok = True
        if not ok:
            raise Error(
                String("result: artifacts[") + String(i) + String("]: effect '")
                + r.artifacts[i].effect + String("' is not one of BUILT WOULD_BUILD UPLOADED")
                + String(" ALREADY_PRESENT WOULD_UPLOAD NOT_REACHED")
            )
    for i in range(len(r.context)):
        for j in range(i):
            if r.context[j].key == r.context[i].key:
                raise Error(String("result: context key '") + r.context[i].key + String("' is given twice"))


def _check_affected_by(r: RunResult) raises:
    """`affected_by` (file header): only on a SELECTIVE run, a full base
    commit, a known verdict, a reason exactly with WIDENED, units only once
    answered and never twice."""
    if not r.has_affected_by:
        return
    var where = String("result: affected_by: ")
    if r.scope != SCOPE_SELECTIVE:
        raise Error(where + String("a FULL run has no --affected-by"))
    if not is_full_commit_id(r.affected_base):
        raise Error(where + String("base '") + r.affected_base + String("' is not a full commit id"))
    var v = r.affected_verdict.copy()
    if v.byte_length() > 0 and v != AFFECTED_VERDICT_AFFECTED and v != AFFECTED_VERDICT_WIDENED:
        raise Error(where + String("verdict '") + v + String("' is not AFFECTED, WIDENED or \"\""))
    if (v == AFFECTED_VERDICT_WIDENED) != (r.affected_reason.byte_length() > 0):
        raise Error(where + String("a reason comes with WIDENED, and only with it"))
    if v.byte_length() == 0 and len(r.affected_units) > 0:
        raise Error(where + String("units before any answer"))
    for i in range(len(r.affected_units)):
        if r.affected_units[i].byte_length() == 0:
            raise Error(where + String("units[") + String(i) + String("] is empty"))
        for j in range(i):
            if r.affected_units[j] == r.affected_units[i]:
                raise Error(where + String("unit '") + r.affected_units[i] + String("' is listed twice"))


def _check_validations(r: RunResult) raises:
    for i in range(len(r.validations)):
        ref v = r.validations[i]
        if v.name.byte_length() == 0:
            raise Error(String("result: validations[") + String(i) + String("] has no name"))
        var where = String("result: validations[") + String(i) + String("] '") + v.name + String("': ")
        for j in range(i):
            if r.validations[j].name == v.name:
                raise Error(where + String("is given twice"))
        require_validation_kind(v.kind)
        if (
            v.environment.byte_length() > 0
            and v.environment != VALIDATION_ENVIRONMENT_ENV
            and v.environment != VALIDATION_ENVIRONMENT_CONTAINER
        ):
            raise Error(where + String("environment '") + v.environment + String("' is not ENV or CONTAINER"))
        if v.pixi_sha256.byte_length() > 0 and not _is_sha256_hex(v.pixi_sha256):
            raise Error(where + String("pixi_sha256 '") + v.pixi_sha256 + String("' is not 64 lowercase hex characters"))
        if v.skip_reason.byte_length() > 0 and (v.effect != VALIDATION_VALIDATED or v.outcome != OUTCOME_INDETERMINATE):
            raise Error(where + String("a skip_reason belongs to a validation that ran and is INDETERMINATE"))
        if v.effect != VALIDATION_VALIDATED and (v.environment.byte_length() > 0 or v.pixi_sha256.byte_length() > 0):
            raise Error(where + String("a validation that did not run has no environment and no pixi_sha256"))
        var found = False
        for j in range(len(r.steps)):
            if r.steps[j].name == v.step:
                found = True
        if not found:
            raise Error(where + String("names step '") + v.step + String("', which is not in steps[]"))
        if v.effect == VALIDATION_WOULD_VALIDATE:
            if v.outcome.byte_length() > 0:
                raise Error(where + String("a validation that did not run (WOULD_VALIDATE) has no outcome"))
            if len(v.checks) > 0:
                raise Error(where + String("a validation that did not run (WOULD_VALIDATE) has no checks"))
            if not r.plan:
                raise Error(where + String("WOULD_VALIDATE belongs to a --plan run"))
        elif v.effect == VALIDATION_NOT_REACHED:
            if v.outcome.byte_length() > 0 or len(v.checks) > 0:
                raise Error(where + String("a validation that was not reached has no outcome and no checks"))
        elif v.effect == VALIDATION_VALIDATED:
            if r.plan:
                raise Error(where + String("a --plan run validates nothing (VALIDATED)"))
            require_outcome(v.outcome)
            var all_ok = True
            for k in range(len(v.checks)):
                if v.checks[k].check.byte_length() == 0:
                    raise Error(where + String("checks[") + String(k) + String("] has no name"))
                if not v.checks[k].ok:
                    all_ok = False
            if v.outcome == OUTCOME_SUCCEEDED and (len(v.checks) == 0 or not all_ok):
                raise Error(where + String("a SUCCEEDED validation holds at least one check and every check ok"))
        else:
            raise Error(
                where + String("effect '") + v.effect
                + String("' is not one of VALIDATED WOULD_VALIDATE NOT_REACHED")
            )


def _check_new_names(r: RunResult) raises:
    for i in range(len(r.new_names)):
        ref n = r.new_names[i]
        var where = String("result: new_names[") + String(i) + String("]: ")
        if (
            n.stage.byte_length() == 0
            or n.step.byte_length() == 0
            or n.channel.byte_length() == 0
            or n.name.byte_length() == 0
        ):
            raise Error(where + String("stage, step, channel and name are each non-empty"))
        for j in range(i):
            ref m = r.new_names[j]
            if m.stage == n.stage and m.step == n.step and m.channel == n.channel and m.name == n.name:
                raise Error(where + String("'") + n.name + String("' is given twice"))


def _check_workflow(r: RunResult) raises:
    if r.workflow_path.byte_length() > 0:
        if not r.workflow_path.startswith(String(WORKFLOW_PATH_PREFIX)) or r.workflow_path.find(String("..")) >= 0:
            raise Error(
                String("result: workflow.path '") + r.workflow_path
                + String("' is not a file under ") + String(WORKFLOW_PATH_PREFIX)
            )
    if r.workflow_sha.byte_length() > 0 and not is_full_commit_id(r.workflow_sha):
        raise Error(String("result: workflow.sha '") + r.workflow_sha + String("' is not a full commit id"))
    if r.workflow_checked:
        if r.workflow_path.byte_length() == 0 or r.workflow_sha.byte_length() == 0:
            raise Error(String("result: a checked workflow names its path and sha"))
        if r.workflow_reason.byte_length() > 0:
            raise Error(String("result: a checked workflow has no reason"))
    elif r.workflow_reason.byte_length() == 0:
        raise Error(String("result: a workflow that was not checked says why (reason is EMPTY)"))


def render_result(r: RunResult) raises -> String:
    """`r` as the result document's text (file header). Refuses a result the
    parser would refuse."""
    _check(r)
    var top = _Obj()
    var steps = JsonValue.empty_array()
    for i in range(len(r.steps)):
        ref a = r.steps[i]
        var o = _Obj()
        o.put_str(String("credential_probe"), a.credential_probe)
        o.put_str(String("kind"), a.kind)
        o.put_str(String("name"), a.name)
        o.put_str(String("outcome"), a.outcome)
        o.put_str(String("platform"), a.platform)
        o.put(String("selected"), JsonValue.from_bool(a.selected))
        put_deploy_keys(o, a.deploy)
        steps.push(o.build())
    top.put(String("steps"), steps^)
    var arts = JsonValue.empty_array()
    for i in range(len(r.artifacts)):
        ref a = r.artifacts[i]
        var o = _Obj()
        o.put_str(String("artifact_type"), a.artifact_type)
        o.put_str(String("effect"), a.effect)
        o.put_str(String("build"), a.build)
        o.put_str(String("file"), a.file)
        o.put(String("indexed"), JsonValue.from_bool(a.indexed))
        o.put_str(String("name"), a.name)
        o.put_str(String("platform"), a.platform)
        o.put_str(String("revision"), a.revision)
        o.put_str(String("sha256"), a.sha256)
        o.put_str(String("state_after"), a.state_after)
        o.put_str(String("state_before"), a.state_before)
        o.put_str(String("subdir"), a.subdir)
        o.put_str(String("version"), a.version)
        arts.push(o.build())
    top.put(String("artifacts"), arts^)
    if r.has_affected_by:
        var ab = _Obj()
        ab.put_str(String("base"), r.affected_base)
        ab.put_str(String("reason"), r.affected_reason)
        ab.put(String("units"), _str_array(r.affected_units))
        ab.put_str(String("verdict"), r.affected_verdict)
        top.put(String("affected_by"), ab.build())
    top.put_int(String("attempt"), r.attempt)
    top.put_str(String("channel"), r.channel)
    var ctx = JsonValue.empty_object()
    for i in range(len(r.context)):
        ctx.set_member(r.context[i].key.copy(), JsonValue.from_string(r.context[i].value.copy()))
    top.put(String("context"), ctx^)
    top.put(String("plan"), JsonValue.from_bool(r.plan))
    if r.has_error:
        var e = _Obj()
        e.put_str(String("id"), r.error.id)
        e.put_str(String("message"), r.error.message)
        top.put(String("error"), e.build())
    top.put_int(String("exit_code"), r.exit_code)
    top.put_int(String("finished_at_ms"), r.finished_at_ms)
    top.put_str(String("format"), String(FORMAT_RESULT))
    top.put_str(String("invoked_as"), r.invoked_as)
    top.put_str(String("kci_version"), r.kci_version)
    var m = _Obj()
    m.put_str(String("path"), r.machine_path)
    m.put_str(String("sha256"), r.machine_sha256)
    top.put(String("machine"), m.build())
    var names = JsonValue.empty_array()
    for i in range(len(r.new_names)):
        ref n = r.new_names[i]
        var o = _Obj()
        o.put_str(String("channel"), n.channel)
        o.put_str(String("name"), n.name)
        o.put_str(String("stage"), n.stage)
        o.put_str(String("step"), n.step)
        names.push(o.build())
    top.put(String("new_names"), names^)
    top.put(String("only"), _str_array(r.only))
    top.put_str(String("outcome"), r.outcome)
    top.put_str(String("platform"), r.platform)
    if r.has_release_produced_by:
        var p = _Obj()
        p.put_int(String("attempt"), r.release_produced_by_attempt)
        p.put_str(String("run_id"), r.release_produced_by_run_id)
        top.put(String("release_produced_by"), p.build())
    top.put_str(String("retry"), r.retry)
    top.put_str(String("revision"), r.revision)
    top.put_str(String("run_id"), r.run_id)
    top.put_int(String("schema_version"), current_major(String(FORMAT_RESULT)))
    top.put_str(String("scope"), r.scope)
    top.put_str(String("set_hash"), r.set_hash)
    top.put_str(String("stage"), r.stage)
    top.put(String("stage_step_kinds"), _str_array(r.stage_step_kinds))
    top.put_int(String("started_at_ms"), r.started_at_ms)
    top.put_str(String("status"), r.status)
    var vals = JsonValue.empty_array()
    for i in range(len(r.validations)):
        ref v = r.validations[i]
        var checks = JsonValue.empty_array()
        for k in range(len(v.checks)):
            var c = _Obj()
            c.put_str(String("check"), v.checks[k].check)
            c.put_str(String("expected"), v.checks[k].expected)
            c.put_str(String("got"), v.checks[k].got)
            c.put(String("ok"), JsonValue.from_bool(v.checks[k].ok))
            checks.push(c.build())
        var o = _Obj()
        o.put_str(String("channel_url"), v.channel_url)
        o.put(String("checks"), checks^)
        o.put_str(String("effect"), v.effect)
        o.put_str(String("environment"), v.environment)
        o.put_str(String("kind"), v.kind)
        o.put_str(String("name"), v.name)
        o.put_str(String("outcome"), v.outcome)
        o.put_str(String("pixi_sha256"), v.pixi_sha256)
        o.put_str(String("skip_reason"), v.skip_reason)
        o.put_str(String("step"), v.step)
        vals.push(o.build())
    top.put(String("validations"), vals^)
    top.put_str(String("verb"), r.verb)
    var w = _Obj()
    w.put(String("checked"), JsonValue.from_bool(r.workflow_checked))
    w.put_str(String("path"), r.workflow_path)
    w.put_str(String("reason"), r.workflow_reason)
    w.put_str(String("sha"), r.workflow_sha)
    top.put(String("workflow"), w.build())
    var text = top.build().serialize() + String("\n")
    _ = parse_result(text, String("<rendered result>"))
    return text^


# ---- parsing -----------------------------------------------------------------


def parse_result(text: String, source: String) raises -> RunResult:
    """Parse a result document (file header); `source` names it. Unknown keys
    are ignored and listed in `ignored_keys`."""
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except e:
        _refuse(source, String("not JSON: ") + String(e))
        return RunResult(String(""), String(""))  # cov: unreachable _refuse always raises; the return only satisfies the compiler
    if not doc.is_object():
        _refuse(source, String("not a JSON object"))
    _no_dup_keys(doc, source, String(""))
    _ = produced_header(doc, String(FORMAT_RESULT), source)
    refuse_top_level_deploy_keys(doc, source)
    var r = RunResult(_s(doc, String("verb"), source), _s(doc, String("invoked_as"), source))
    _note_unknown(
        doc,
        _keys(
            String("affected_by artifacts attempt channel context error exit_code")
            + String(" finished_at_ms format invoked_as kci_version machine new_names")
            + String(" only outcome plan platform release_produced_by retry revision run_id")
            + String(" schema_version scope set_hash stage stage_step_kinds started_at_ms status")
            + String(" steps validations verb workflow")
        ),
        String(""),
        r.ignored_keys,
    )
    r.status = _s(doc, String("status"), source)
    r.kci_version = _s(doc, String("kci_version"), source)
    var m = _need(doc, String("machine"), JSON_OBJECT, source, String(""))
    _no_dup_keys(m, source, String("machine: "))
    _note_unknown(m, _keys(String("path sha256")), String("machine."), r.ignored_keys)
    r.machine_path = _s(m, String("path"), source, String("machine: "))
    r.machine_sha256 = _s(m, String("sha256"), source, String("machine: "))
    r.stage = _s(doc, String("stage"), source)
    var kinds = _need(doc, String("stage_step_kinds"), JSON_ARRAY, source, String(""))
    for i in range(kinds.array_len()):
        var k = kinds.element_at(i)
        if k.kind_tag() != JSON_STRING:
            _refuse(source, String("stage_step_kinds[") + String(i) + String("] is not a string"))
        r.stage_step_kinds.append(k.as_string())
    r.scope = _s(doc, String("scope"), source)
    var only = _need(doc, String("only"), JSON_ARRAY, source, String(""))
    for i in range(only.array_len()):
        var o = only.element_at(i)
        if o.kind_tag() != JSON_STRING:
            _refuse(source, String("only[") + String(i) + String("] is not a string"))
        r.only.append(o.as_string())
    r.revision = _s(doc, String("revision"), source)
    r.platform = _s(doc, String("platform"), source)
    r.run_id = _s(doc, String("run_id"), source)
    r.attempt = _i(doc, String("attempt"), source)
    var ctx = _need(doc, String("context"), JSON_OBJECT, source, String(""))
    for i in range(ctx.num_members()):
        var v = ctx.value_at(i)
        if v.kind_tag() != JSON_STRING:
            _refuse(source, String("context '") + ctx.key_at(i) + String("' is not a string"))
        r.context.append(ContextEntry(ctx.key_at(i), v.as_string()))
    r.started_at_ms = _i(doc, String("started_at_ms"), source)
    r.finished_at_ms = _i(doc, String("finished_at_ms"), source)
    r.outcome = _s(doc, String("outcome"), source)
    r.exit_code = _i(doc, String("exit_code"), source)
    r.retry = _s(doc, String("retry"), source)
    if doc.has(String("error")):
        var e = _need(doc, String("error"), JSON_OBJECT, source, String(""))
        _no_dup_keys(e, source, String("error: "))
        _note_unknown(e, _keys(String("id message")), String("error."), r.ignored_keys)
        r.has_error = True
        r.error = ResultError(_s(e, String("id"), source, String("error: ")), _s(e, String("message"), source, String("error: ")))
    var steps = _need(doc, String("steps"), JSON_ARRAY, source, String(""))
    for i in range(steps.array_len()):
        var where = String("steps[") + String(i) + String("]: ")
        var a = steps.element_at(i)
        if a.kind_tag() != JSON_OBJECT:
            _refuse(source, where + String("not an object"))
        _no_dup_keys(a, source, where)
        var known = _keys(String("credential_probe kind name outcome platform selected"))
        known.extend(deploy_step_keys())
        var path = String("steps[") + String(i) + String("].")
        _note_unknown(a, known, path, r.ignored_keys)
        var st = ResultStep(
            _s(a, String("name"), source, where),
            _s(a, String("kind"), source, where),
            _s(a, String("platform"), source, where),
            _s(a, String("outcome"), source, where),
        )
        st.selected = _b(a, String("selected"), source, where)
        st.credential_probe = _s(a, String("credential_probe"), source, where)
        st.deploy = parse_deploy_keys(a, source, where, path, r.ignored_keys)
        r.steps.append(st^)
    r.plan = _b(doc, String("plan"), source)
    r.channel = _s(doc, String("channel"), source)
    r.set_hash = _s(doc, String("set_hash"), source)
    if doc.has(String("release_produced_by")):
        var p = _need(doc, String("release_produced_by"), JSON_OBJECT, source, String(""))
        _no_dup_keys(p, source, String("release_produced_by: "))
        _note_unknown(p, _keys(String("attempt run_id")), String("release_produced_by."), r.ignored_keys)
        r.has_release_produced_by = True
        r.release_produced_by_attempt = _i(p, String("attempt"), source, String("release_produced_by: "))
        r.release_produced_by_run_id = _s(p, String("run_id"), source, String("release_produced_by: "))
    if doc.has(String("affected_by")):
        var ab = _need(doc, String("affected_by"), JSON_OBJECT, source, String(""))
        var where = String("affected_by: ")
        _no_dup_keys(ab, source, where)
        _note_unknown(ab, _keys(String("base reason units verdict")), String("affected_by."), r.ignored_keys)
        r.has_affected_by = True
        r.affected_base = _s(ab, String("base"), source, where)
        r.affected_reason = _s(ab, String("reason"), source, where)
        r.affected_verdict = _s(ab, String("verdict"), source, where)
        var units = _need(ab, String("units"), JSON_ARRAY, source, where)
        for i in range(units.array_len()):
            var u = units.element_at(i)
            if u.kind_tag() != JSON_STRING:
                _refuse(source, where + String("units[") + String(i) + String("] is not a string"))
            r.affected_units.append(u.as_string())
    var arts = _need(doc, String("artifacts"), JSON_ARRAY, source, String(""))
    var art_keys = _keys(
        String("artifact_type build effect file indexed name platform revision sha256")
        + String(" state_after state_before subdir version")
    )
    for i in range(arts.array_len()):
        var where = String("artifacts[") + String(i) + String("]: ")
        var a = arts.element_at(i)
        if a.kind_tag() != JSON_OBJECT:
            _refuse(source, where + String("not an object"))
        _no_dup_keys(a, source, where)
        _note_unknown(a, art_keys, String("artifacts[") + String(i) + String("]."), r.ignored_keys)
        var row = ResultArtifact()
        row.effect = _s(a, String("effect"), source, where)
        row.artifact_type = _s(a, String("artifact_type"), source, where)
        row.build = _s(a, String("build"), source, where)
        row.file = _s(a, String("file"), source, where)
        row.indexed = _b(a, String("indexed"), source, where)
        row.name = _s(a, String("name"), source, where)
        row.platform = _s(a, String("platform"), source, where)
        row.revision = _s(a, String("revision"), source, where)
        row.sha256 = _s(a, String("sha256"), source, where)
        row.state_after = _s(a, String("state_after"), source, where)
        row.state_before = _s(a, String("state_before"), source, where)
        row.subdir = _s(a, String("subdir"), source, where)
        row.version = _s(a, String("version"), source, where)
        r.artifacts.append(row^)
    var vals = _need(doc, String("validations"), JSON_ARRAY, source, String(""))
    for i in range(vals.array_len()):
        var where = String("validations[") + String(i) + String("]: ")
        var a = vals.element_at(i)
        if a.kind_tag() != JSON_OBJECT:
            _refuse(source, where + String("not an object"))
        _no_dup_keys(a, source, where)
        _note_unknown(
            a,
            _keys(String("channel_url checks effect environment kind name outcome pixi_sha256 skip_reason step")),
            String("validations[") + String(i) + String("]."),
            r.ignored_keys,
        )
        var v = ResultValidation(
            _s(a, String("name"), source, where),
            _s(a, String("step"), source, where),
            _s(a, String("kind"), source, where),
            _s(a, String("effect"), source, where),
            _s(a, String("outcome"), source, where),
        )
        v.environment = _s_absent_empty(a, String("environment"), source, where)
        v.pixi_sha256 = _s_absent_empty(a, String("pixi_sha256"), source, where)
        v.channel_url = _s_absent_empty(a, String("channel_url"), source, where)
        v.skip_reason = _s_absent_empty(a, String("skip_reason"), source, where)
        var checks = _need(a, String("checks"), JSON_ARRAY, source, where)
        for k in range(checks.array_len()):
            var cw = where + String("checks[") + String(k) + String("]: ")
            var c = checks.element_at(k)
            if c.kind_tag() != JSON_OBJECT:
                _refuse(source, cw + String("not an object"))
            _no_dup_keys(c, source, cw)
            _note_unknown(
                c,
                _keys(String("check expected got ok")),
                String("validations[") + String(i) + String("].checks[") + String(k) + String("]."),
                r.ignored_keys,
            )
            v.checks.append(
                ResultValidationCheck(
                    _s(c, String("check"), source, cw),
                    _s(c, String("expected"), source, cw),
                    _s(c, String("got"), source, cw),
                    _b(c, String("ok"), source, cw),
                )
            )
        r.validations.append(v^)
    var names = _need(doc, String("new_names"), JSON_ARRAY, source, String(""))
    for i in range(names.array_len()):
        var where = String("new_names[") + String(i) + String("]: ")
        var a = names.element_at(i)
        if a.kind_tag() != JSON_OBJECT:
            _refuse(source, where + String("not an object"))
        _no_dup_keys(a, source, where)
        _note_unknown(a, _keys(String("channel name stage step")), String("new_names[") + String(i) + String("]."), r.ignored_keys)
        r.new_names.append(
            ResultNewName(
                _s(a, String("stage"), source, where),
                _s(a, String("step"), source, where),
                _s(a, String("channel"), source, where),
                _s(a, String("name"), source, where),
            )
        )
    var w = _need(doc, String("workflow"), JSON_OBJECT, source, String(""))
    _no_dup_keys(w, source, String("workflow: "))
    _note_unknown(w, _keys(String("checked path reason sha")), String("workflow."), r.ignored_keys)
    r.workflow_checked = _b(w, String("checked"), source, String("workflow: "))
    r.workflow_path = _s(w, String("path"), source, String("workflow: "))
    r.workflow_reason = _s(w, String("reason"), source, String("workflow: "))
    r.workflow_sha = _s(w, String("sha"), source, String("workflow: "))
    try:
        _check(r)
    except e:
        _refuse(source, String(e))
    return r^
