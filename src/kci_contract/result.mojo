# =============================================================================
# src/kci_contract/result.mojo -- the ONE result document every kci verb
#   writes with `--result-file`, rendered and parsed.
# =============================================================================
#
# Format `kci.result`, schema_version 1 (formats.mojo). Compact JSON, every
# object's keys sorted bytewise, one trailing newline. Keys:
#
#   actions[]           {kind, outcome, platform}: each action of the stage,
#                       in machine-file order
#   artifacts[]         {action, artifact_type, build, file, indexed, name,
#                       platform, revision, sha256, state_after,
#                       state_before, subdir, version}: build writes one row
#                       per member (action BUILT); publish one per file
#   attempt             --attempt (0 when the command line had none)
#   channel             publish: the channel's name; else ""
#   context{}           every --context, in the order given (keys unique)
#   dry_run             publish --dry-run
#   error               {id, message}: the first refusal or failure; ABSENT
#                       when there is none. The message never holds a secret
#   exit_code           the exit number (exit_codes.mojo)
#   expect_set_hash     publish: the approved set hash; else ""
#   finished_at_ms      0 while RUNNING
#   format              "kci.result"
#   invoked_as          the verb as typed (an alias, or `run`)
#   kci_version         this kci's version
#   machine             {path, sha256} of the machine file; "" for a verb
#                       that reads none
#   outcome, retry      outcome.mojo
#   platform            the stage's platform; "" when unknown
#   release_produced_by publish: {attempt, run_id} copied from release.json;
#                       ABSENT otherwise
#   revision            --revision-id (full commit id) or ""
#   run_id              --run-id or "" (a usage error can precede it)
#   schema_version      1
#   set_hash            build: computed; publish: recomputed; else ""
#   stage               the stage run; "" when unknown
#   stage_action_kinds  the kinds of the stage's actions, in order
#   started_at_ms
#   status              RUNNING or FINISHED
#   verb                run / build / publish / stages / ci-check: the verb
#                       actually run (an alias runs `run`'s code, but its
#                       own name is kept here)
#
# The CLI writes the file TWICE: status RUNNING after resolving the command
# line and BEFORE the first effect, then FINISHED on every exit path. A
# RUNNING record says outcome INTERRUPTED, exit 6, retry UNSAFE, so a file a
# killed kci left behind reads as interrupted without a special case.
#
# Readers ignore unknown keys inside major 1 (formats.mojo); `parse_result`
# records them in `ignored_keys`. These names are RESERVED for the deploy
# side and added inside major 1 when it lands; nothing emits them yet:
#   landed[] pending[] failed outputs[] plan_hash validations[]
#   security_relevant_changes[]
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
from kci_contract.outcome import OUTCOME_INTERRUPTED, RETRY_UNSAFE, require_outcome
from kci_contract.platform import platform_row
from kci_contract.revision import is_full_commit_id
from kci_contract.run_identity import ContextEntry, RunIdentity
from kci_contract.verbs import require_action_kind, require_verb

comptime KCI_VERSION: String = "0.0.0-unreleased"
"""This kci's version, until kci itself is released."""

comptime STATUS_RUNNING: String = "RUNNING"
comptime STATUS_FINISHED: String = "FINISHED"

comptime ARTIFACT_BUILT: String = "BUILT"
comptime ARTIFACT_UPLOADED: String = "UPLOADED"
comptime ARTIFACT_ALREADY_PRESENT: String = "ALREADY_PRESENT"
comptime ARTIFACT_WOULD_UPLOAD: String = "WOULD_UPLOAD"
comptime ARTIFACT_NOT_REACHED: String = "NOT_REACHED"


def all_artifact_actions() -> List[String]:
    var out = List[String]()
    out.append(String(ARTIFACT_BUILT))
    out.append(String(ARTIFACT_UPLOADED))
    out.append(String(ARTIFACT_ALREADY_PRESENT))
    out.append(String(ARTIFACT_WOULD_UPLOAD))
    out.append(String(ARTIFACT_NOT_REACHED))
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
    out.append(String("validations"))
    return out^


struct ResultError(Copyable, Movable):
    """`error`: a stable id (errors.mojo) and a message for people.

    Layout: owned Strings. No pointer field."""

    var id: String
    var message: String

    def __init__(out self, var id: String, var message: String):
        self.id = id^
        self.message = message^


struct ResultAction(Copyable, Movable):
    """One action of the stage and its outcome.

    Layout: owned Strings. No pointer field."""

    var kind: String
    var platform: String
    var outcome: String

    def __init__(out self, var kind: String, var platform: String, var outcome: String):
        self.kind = kind^
        self.platform = platform^
        self.outcome = outcome^


struct ResultArtifact(Copyable, Movable):
    """One artifact row (file header).

    Layout: owned Strings and a Bool. No pointer field."""

    var action: String
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
        self.action = String("")
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
    var stage_action_kinds: List[String]
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
    var actions: List[ResultAction]
    var dry_run: Bool
    var channel: String
    var set_hash: String
    var expect_set_hash: String
    var has_release_produced_by: Bool
    var release_produced_by_run_id: String
    var release_produced_by_attempt: Int
    var artifacts: List[ResultArtifact]
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
        self.stage_action_kinds = List[String]()
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
        self.actions = List[ResultAction]()
        self.dry_run = False
        self.channel = String("")
        self.set_hash = String("")
        self.expect_set_hash = String("")
        self.has_release_produced_by = False
        self.release_produced_by_run_id = String("")
        self.release_produced_by_attempt = 0
        self.artifacts = List[ResultArtifact]()
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
    for i in range(len(r.stage_action_kinds)):
        require_action_kind(r.stage_action_kinds[i])
    for i in range(len(r.actions)):
        require_action_kind(r.actions[i].kind)
        require_outcome(r.actions[i].outcome)
    var acts = all_artifact_actions()
    for i in range(len(r.artifacts)):
        var ok = False
        for j in range(len(acts)):
            if acts[j] == r.artifacts[i].action:
                ok = True
        if not ok:
            raise Error(
                String("result: artifacts[") + String(i) + String("]: action '")
                + r.artifacts[i].action + String("' is not one of BUILT UPLOADED")
                + String(" ALREADY_PRESENT WOULD_UPLOAD NOT_REACHED")
            )
    for i in range(len(r.context)):
        for j in range(i):
            if r.context[j].key == r.context[i].key:
                raise Error(String("result: context key '") + r.context[i].key + String("' is given twice"))


def render_result(r: RunResult) raises -> String:
    """`r` as the result document's text (file header). Refuses a result the
    parser would refuse."""
    _check(r)
    var top = _Obj()
    var actions = JsonValue.empty_array()
    for i in range(len(r.actions)):
        ref a = r.actions[i]
        var o = _Obj()
        o.put_str(String("kind"), a.kind)
        o.put_str(String("outcome"), a.outcome)
        o.put_str(String("platform"), a.platform)
        actions.push(o.build())
    top.put(String("actions"), actions^)
    var arts = JsonValue.empty_array()
    for i in range(len(r.artifacts)):
        ref a = r.artifacts[i]
        var o = _Obj()
        o.put_str(String("action"), a.action)
        o.put_str(String("artifact_type"), a.artifact_type)
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
    top.put(String("dry_run"), JsonValue.from_bool(r.dry_run))
    if r.has_error:
        var e = _Obj()
        e.put_str(String("id"), r.error.id)
        e.put_str(String("message"), r.error.message)
        top.put(String("error"), e.build())
    top.put_int(String("exit_code"), r.exit_code)
    top.put_str(String("expect_set_hash"), r.expect_set_hash)
    top.put_int(String("finished_at_ms"), r.finished_at_ms)
    top.put_str(String("format"), String(FORMAT_RESULT))
    top.put_str(String("invoked_as"), r.invoked_as)
    top.put_str(String("kci_version"), r.kci_version)
    var m = _Obj()
    m.put_str(String("path"), r.machine_path)
    m.put_str(String("sha256"), r.machine_sha256)
    top.put(String("machine"), m.build())
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
    top.put_str(String("set_hash"), r.set_hash)
    top.put_str(String("stage"), r.stage)
    top.put(String("stage_action_kinds"), _str_array(r.stage_action_kinds))
    top.put_int(String("started_at_ms"), r.started_at_ms)
    top.put_str(String("status"), r.status)
    top.put_str(String("verb"), r.verb)
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
            String("actions artifacts attempt channel context dry_run error exit_code")
            + String(" expect_set_hash finished_at_ms format invoked_as kci_version machine")
            + String(" outcome platform release_produced_by retry revision run_id schema_version")
            + String(" set_hash stage stage_action_kinds started_at_ms status verb")
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
    var kinds = _need(doc, String("stage_action_kinds"), JSON_ARRAY, source, String(""))
    for i in range(kinds.array_len()):
        var k = kinds.element_at(i)
        if k.kind_tag() != JSON_STRING:
            _refuse(source, String("stage_action_kinds[") + String(i) + String("] is not a string"))
        r.stage_action_kinds.append(k.as_string())
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
    var acts = _need(doc, String("actions"), JSON_ARRAY, source, String(""))
    for i in range(acts.array_len()):
        var where = String("actions[") + String(i) + String("]: ")
        var a = acts.element_at(i)
        if a.kind_tag() != JSON_OBJECT:
            _refuse(source, where + String("not an object"))
        _no_dup_keys(a, source, where)
        _note_unknown(a, _keys(String("kind outcome platform")), String("actions[") + String(i) + String("]."), r.ignored_keys)
        r.actions.append(
            ResultAction(
                _s(a, String("kind"), source, where),
                _s(a, String("platform"), source, where),
                _s(a, String("outcome"), source, where),
            )
        )
    r.dry_run = _b(doc, String("dry_run"), source)
    r.channel = _s(doc, String("channel"), source)
    r.set_hash = _s(doc, String("set_hash"), source)
    r.expect_set_hash = _s(doc, String("expect_set_hash"), source)
    if doc.has(String("release_produced_by")):
        var p = _need(doc, String("release_produced_by"), JSON_OBJECT, source, String(""))
        _no_dup_keys(p, source, String("release_produced_by: "))
        _note_unknown(p, _keys(String("attempt run_id")), String("release_produced_by."), r.ignored_keys)
        r.has_release_produced_by = True
        r.release_produced_by_attempt = _i(p, String("attempt"), source, String("release_produced_by: "))
        r.release_produced_by_run_id = _s(p, String("run_id"), source, String("release_produced_by: "))
    var arts = _need(doc, String("artifacts"), JSON_ARRAY, source, String(""))
    var art_keys = _keys(
        String("action artifact_type build file indexed name platform revision sha256")
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
        row.action = _s(a, String("action"), source, where)
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
    try:
        _check(r)
    except e:
        _refuse(source, String(e))
    return r^
