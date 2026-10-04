# =============================================================================
# src/kci_contract/result.mojo -- the ONE result document `kci run` writes
#   with `--result-file`, rendered and parsed.
# =============================================================================
#
# Format `kci.result`, schema_version 1 (formats.mojo). Compact JSON, every
# object's keys sorted bytewise, one trailing newline. Keys:
#
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
#                       whenever any --only is given
#   set_hash            build: computed; publish: recomputed; else ""
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
#                       or "" (no probe: not a plan, or not a PUBLISH step)
#   validations[]       {checks[], effect, kind, name, outcome, step}: the
#                       validations of the selected steps, in machine-file
#                       order. effect VALIDATED (it ran; outcome is its
#                       verdict), WOULD_VALIDATE (--plan: it did not run, so
#                       it has no outcome and no checks and can never read as
#                       a pass) or NOT_REACHED (the run stopped before it).
#                       checks[] rows are {check, expected, got, ok}; a
#                       SUCCEEDED validation holds at least one check and
#                       every check ok
#   verb                run: the one verb
#   workflow            {checked, path, reason, sha}: the start-up check of
#                       the CI workflow running kci against the machine file.
#                       checked true: path (under .github/workflows/) and sha
#                       (the workflow's commit) name what was checked, reason
#                       is "". checked false: reason says why ("not under
#                       GitHub Actions", or what could not be read)
#
# A FULL record with an unselected step, and a SELECTIVE record with an
# empty `only`, are refused by the renderer and the parser alike: a selective
# run can never read as a full one. The outcome and exit number do not say
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
# records them in `ignored_keys`. These names are RESERVED for the deploy
# side and added inside major 1 when it lands; nothing emits them yet:
#   landed[] pending[] failed outputs[] plan_hash security_relevant_changes[]
#
# `RunRecorder` is the seam a verb records through: `begin` before the first
# effect, `finish` at the end. Writing a file is the CLI's recorder; tests
# use `MemoryRecorder`.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_json import JSON_ARRAY, JSON_BOOL, JSON_NUMBER, JSON_OBJECT, JSON_STRING, JsonValue, parse_json_value

from kci_contract.errors import require_error_id
from kci_contract.exit_codes import EXIT_PARTIAL, default_retry, exit_code_of, require_retry_for
from kci_contract.formats import FORMAT_RESULT, current_major, produced_header
from kci_contract.outcome import OUTCOME_INTERRUPTED, OUTCOME_SUCCEEDED, RETRY_UNSAFE, require_outcome
from kci_contract.platform import platform_row
from kci_contract.revision import is_full_commit_id
from kci_contract.run_identity import ContextEntry, RunIdentity
from kci_contract.selection import SCOPE_FULL, SCOPE_SELECTIVE, parse_selector, require_scope
from kci_contract.verbs import STEP_KIND_PUBLISH, require_step_kind, require_validation_kind, require_verb

comptime KCI_VERSION: String = "0.0.0-unreleased"
"""This kci's version, until kci itself is released."""

comptime STATUS_RUNNING: String = "RUNNING"
comptime STATUS_FINISHED: String = "FINISHED"

comptime ARTIFACT_BUILT: String = "BUILT"
comptime ARTIFACT_WOULD_BUILD: String = "WOULD_BUILD"
comptime ARTIFACT_UPLOADED: String = "UPLOADED"
comptime ARTIFACT_ALREADY_PRESENT: String = "ALREADY_PRESENT"
comptime ARTIFACT_WOULD_UPLOAD: String = "WOULD_UPLOAD"
comptime ARTIFACT_NOT_REACHED: String = "NOT_REACHED"

comptime VALIDATION_VALIDATED: String = "VALIDATED"
comptime VALIDATION_WOULD_VALIDATE: String = "WOULD_VALIDATE"
comptime VALIDATION_NOT_REACHED: String = "NOT_REACHED"

comptime CREDENTIAL_PROBE_MINTED: String = "MINTED"
comptime CREDENTIAL_PROBE_NOT_UNDER_CI: String = "NOT_UNDER_CI"
comptime CREDENTIAL_PROBE_NOT_OIDC: String = "NOT_OIDC"

comptime WORKFLOW_PATH_PREFIX: String = ".github/workflows/"
comptime WORKFLOW_NOT_REACHED: String = "not reached"
"""`workflow.reason` of a record written before the workflow check ran."""


def all_artifact_effects() -> List[String]:
    """What a step did to an artifact (`artifacts[].effect`)."""
    var out = List[String]()
    out.append(String(ARTIFACT_BUILT))
    out.append(String(ARTIFACT_WOULD_BUILD))
    out.append(String(ARTIFACT_UPLOADED))
    out.append(String(ARTIFACT_ALREADY_PRESENT))
    out.append(String(ARTIFACT_WOULD_UPLOAD))
    out.append(String(ARTIFACT_NOT_REACHED))
    return out^


def all_validation_effects() -> List[String]:
    """What happened to a validation (`validations[].effect`)."""
    var out = List[String]()
    out.append(String(VALIDATION_VALIDATED))
    out.append(String(VALIDATION_WOULD_VALIDATE))
    out.append(String(VALIDATION_NOT_REACHED))
    return out^


def all_credential_probes() -> List[String]:
    """The non-empty values of `steps[].credential_probe`."""
    var out = List[String]()
    out.append(String(CREDENTIAL_PROBE_MINTED))
    out.append(String(CREDENTIAL_PROBE_NOT_UNDER_CI))
    out.append(String(CREDENTIAL_PROBE_NOT_OIDC))
    return out^


def reserved_result_keys() -> List[String]:
    """Names kept for the deploy side (file header); never emitted yet."""
    var out = List[String]()
    out.append(String("failed"))
    out.append(String("landed"))
    out.append(String("outputs"))
    out.append(String("pending"))
    out.append(String("plan_hash"))
    out.append(String("security_relevant_changes"))
    return out^


struct ResultError(Copyable, Movable):
    """`error`: a stable id (errors.mojo) and a message for people.

    Layout: owned Strings. No pointer field."""

    var id: String
    var message: String

    def __init__(out self, var id: String, var message: String):
        self.id = id^
        self.message = message^


struct ResultStep(Copyable, Movable):
    """One step of the stage: whether it was selected, its outcome once it
    ran ("" for an unselected step), and a PUBLISH step's --plan credential
    probe ("" when none was made).

    Layout: owned Strings and a Bool. No pointer field."""

    var name: String
    var kind: String
    var platform: String
    var selected: Bool
    var outcome: String
    var credential_probe: String

    def __init__(out self, var name: String, var kind: String, var platform: String, var outcome: String):
        """A selected step that ran, with its outcome."""
        self.name = name^
        self.kind = kind^
        self.platform = platform^
        self.selected = True
        self.outcome = outcome^
        self.credential_probe = String("")

    @staticmethod
    def unselected(var name: String, var kind: String, var platform: String) -> ResultStep:
        """A step `--only` did not select: no outcome."""
        var s = ResultStep(name^, kind^, platform^, String(""))
        s.selected = False
        return s^


struct ResultValidationCheck(Copyable, Movable):
    """One check a validation made: what it expected, what it got, and
    whether they agree.

    Layout: owned Strings and a Bool. No pointer field."""

    var check: String
    var expected: String
    var got: String
    var ok: Bool

    def __init__(out self, var check: String, var expected: String, var got: String, ok: Bool):
        self.check = check^
        self.expected = expected^
        self.got = got^
        self.ok = ok


struct ResultValidation(Copyable, Movable):
    """One validation of a step (file header).

    Layout: owned Strings and a List of owned rows. No pointer field."""

    var name: String
    var step: String
    var kind: String
    var effect: String
    var outcome: String
    var checks: List[ResultValidationCheck]

    def __init__(out self, var name: String, var step: String, var kind: String, var effect: String, var outcome: String):
        self.name = name^
        self.step = step^
        self.kind = kind^
        self.effect = effect^
        self.outcome = outcome^
        self.checks = List[ResultValidationCheck]()


struct ResultNewName(Copyable, Movable):
    """A declared name a PUBLISH step's channel holds no file of yet.

    Layout: owned Strings. No pointer field."""

    var stage: String
    var step: String
    var channel: String
    var name: String

    def __init__(out self, var stage: String, var step: String, var channel: String, var name: String):
        self.stage = stage^
        self.step = step^
        self.channel = channel^
        self.name = name^


struct ResultArtifact(Copyable, Movable):
    """One artifact row (file header).

    Layout: owned Strings and a Bool. No pointer field."""

    var effect: String
    var artifact_type: String
    var build: String
    var file: String
    var indexed: Bool
    var name: String
    var platform: String
    var revision: String
    var sha256: String
    var state_after: String
    var state_before: String
    var subdir: String
    var version: String

    def __init__(out self):
        self.effect = String("")
        self.artifact_type = String("")
        self.build = String("")
        self.file = String("")
        self.indexed = False
        self.name = String("")
        self.platform = String("")
        self.revision = String("")
        self.sha256 = String("")
        self.state_after = String("")
        self.state_before = String("")
        self.subdir = String("")
        self.version = String("")


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


struct _Obj(Movable):
    """An object under construction whose keys are written sorted."""

    var keys: List[String]
    var values: List[JsonValue]

    def __init__(out self):
        self.keys = List[String]()
        self.values = List[JsonValue]()

    def put(mut self, var key: String, var value: JsonValue):
        self.keys.append(key^)
        self.values.append(value^)

    def put_str(mut self, var key: String, s: String):
        self.put(key^, JsonValue.from_string(s.copy()))

    def put_int(mut self, var key: String, n: Int):
        self.put(key^, JsonValue.from_i64(Int64(n)))

    def build(mut self) raises -> JsonValue:
        var order = List[Int]()
        for i in range(len(self.keys)):
            order.append(i)
        for i in range(1, len(order)):
            var j = i
            while j > 0 and _less(self.keys[order[j]], self.keys[order[j - 1]]):
                var t = order[j]
                order[j] = order[j - 1]
                order[j - 1] = t
                j -= 1
        var doc = JsonValue.empty_object()
        for i in range(len(order)):
            doc.set_member(self.keys[order[i]].copy(), self.values[order[i]].copy())
        return doc^


def _less(a: String, b: String) -> Bool:
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = min(len(x), len(y))
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


def _str_array(items: List[String]) raises -> JsonValue:
    var a = JsonValue.empty_array()
    for i in range(len(items)):
        a.push(JsonValue.from_string(items[i].copy()))
    return a^


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
            raise Error(String("result: only[") + String(i) + String("] '") + r.only[i] + String("' is not canonical"))
        for j in range(i):
            if r.only[j] == r.only[i]:
                raise Error(String("result: only '") + r.only[i] + String("' is given twice"))
    if r.scope == SCOPE_SELECTIVE and len(r.only) == 0:
        raise Error(String("result: a SELECTIVE run names its --only selectors (only is EMPTY)"))
    if r.scope == SCOPE_FULL and len(r.only) > 0:
        raise Error(String("result: a FULL run has no --only selectors"))
    for i in range(len(r.steps)):
        ref st = r.steps[i]
        var where = String("result: steps[") + String(i) + String("] '") + st.name + String("': ")
        if st.name.byte_length() == 0:
            raise Error(String("result: steps[") + String(i) + String("] has no name"))
        require_step_kind(st.kind)
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


def _member(words: List[String], w: String) -> Bool:
    for i in range(len(words)):
        if words[i] == w:
            return True
    return False


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
        o.put(String("checks"), checks^)
        o.put_str(String("effect"), v.effect)
        o.put_str(String("kind"), v.kind)
        o.put_str(String("name"), v.name)
        o.put_str(String("outcome"), v.outcome)
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


def _refuse(source: String, why: String) raises:
    raise Error(String("result '") + source + String("': ") + why)


def _need(doc: JsonValue, key: String, tag: Int, source: String, where: String) raises -> JsonValue:
    if not doc.has(key):
        _refuse(source, where + String("missing '") + key + String("'"))
    var v = doc.get(key)
    if v.kind_tag() != tag:
        _refuse(source, where + String("'") + key + String("' has the wrong JSON type"))
    return v^


def _s(doc: JsonValue, key: String, source: String, where: String = String("")) raises -> String:
    return _need(doc, key, JSON_STRING, source, where).as_string()


def _i(doc: JsonValue, key: String, source: String, where: String = String("")) raises -> Int:
    var v = _need(doc, key, JSON_NUMBER, source, where)
    if not v.is_integral_number():
        _refuse(source, where + String("'") + key + String("' is not an integer"))
    return Int(v.as_int64())


def _b(doc: JsonValue, key: String, source: String, where: String = String("")) raises -> Bool:
    return _need(doc, key, JSON_BOOL, source, where).as_bool()


def _no_dup_keys(doc: JsonValue, source: String, where: String) raises:
    for i in range(doc.num_members()):
        for j in range(i):
            if doc.key_at(j) == doc.key_at(i):
                _refuse(source, where + String("'") + doc.key_at(i) + String("' is given twice"))


def _note_unknown(doc: JsonValue, known: List[String], where: String, mut ignored: List[String]) raises:
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        var ok = False
        for j in range(len(known)):
            if known[j] == key:
                ok = True
        if not ok:
            ignored.append(where + key)


def _keys(names: String) -> List[String]:
    var out = List[String]()
    var parts = names.split(String(" "))
    for i in range(len(parts)):
        out.append(String(parts[i]))
    return out^


def parse_result(text: String, source: String) raises -> RunResult:
    """Parse a result document (file header); `source` names it. Unknown keys
    are ignored and listed in `ignored_keys`."""
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except e:
        _refuse(source, String("not JSON: ") + String(e))
        return RunResult(String(""), String(""))
    if not doc.is_object():
        _refuse(source, String("not a JSON object"))
    _no_dup_keys(doc, source, String(""))
    _ = produced_header(doc, String(FORMAT_RESULT), source)
    var r = RunResult(_s(doc, String("verb"), source), _s(doc, String("invoked_as"), source))
    _note_unknown(
        doc,
        _keys(
            String("artifacts attempt channel context error exit_code")
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
        _note_unknown(
            a,
            _keys(String("credential_probe kind name outcome platform selected")),
            String("steps[") + String(i) + String("]."),
            r.ignored_keys,
        )
        var st = ResultStep(
            _s(a, String("name"), source, where),
            _s(a, String("kind"), source, where),
            _s(a, String("platform"), source, where),
            _s(a, String("outcome"), source, where),
        )
        st.selected = _b(a, String("selected"), source, where)
        st.credential_probe = _s(a, String("credential_probe"), source, where)
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
            a, _keys(String("checks effect kind name outcome step")), String("validations[") + String(i) + String("]."), r.ignored_keys
        )
        var v = ResultValidation(
            _s(a, String("name"), source, where),
            _s(a, String("step"), source, where),
            _s(a, String("kind"), source, where),
            _s(a, String("effect"), source, where),
            _s(a, String("outcome"), source, where),
        )
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
