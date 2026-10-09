# =============================================================================
# src/kci_cli/deploy_step.mojo -- what `kci run` does for a DEPLOY step: from
#   the step's request to the cell's plan or apply, the step row's deploy
#   keys, its outcome and its exit (dispatch.mojo's header, 6).
# =============================================================================
#
# A DEPLOY step deploys a resource list into one CELL (kci_cell): one cloud,
# one place, owned by one machine. `deploy_step` is generic over the cloud
# adapter and the state store (`[S: CloudAdapter, St: StateStore]`); a binary
# lists the adapters it was built with as a `CellDeploys` (dispatch.mojo's
# seam for DEPLOY steps). `CloudDeploys[S, St]` is one built-in cloud, its
# store and its credentials; `NoCloudBuilt` is a kci built with no cloud, and
# that is the kci binary until a real adapter lands: every DEPLOY step it runs
# is REFUSED at step 1 ("this kci was not built with that cloud"). The welded
# tests drive `CloudDeploys[FakeCloud, InMemoryStateStore]`.
#
#   1. LOAD. The cells file (`cells`, kci_cell's parser), the step's `cell`
#      in it, then the cell's `cloud` through `Clouds.resolve`: a cloud this
#      kci was not built with is REFUSED (KCI-E-CLOUD) before the resource
#      list is read. Then the resource list (`resources`, proto3 JSON, read
#      relative to the directory kci runs in), the definitions kci ships
#      (kci_composites, always passed) and each `definitions` file (proto3
#      JSON); a file that redefines a name kci ships is refused. A file
#      that cannot be read or decoded is REFUSED (KCI-E-FORMAT). A
#      definition kci ships that cannot be read is FAILED, NEEDS_HUMAN: the
#      binary was packaged without it.
#   2. THE RELEASE SET. `check_deploy_set_hash`, at start-up with the other
#      start checks (dispatch.mojo, 4b): a selected DEPLOY step requires
#      `--release-set-hash` (args.mojo) and the release directory is
#      recomputed under the artifacts file of the machine file's first BUILD
#      step for linux-x86_64 (images are linux/amd64 only); another hash, or
#      one that cannot be recomputed, is REFUSED (KCI-E-SET-HASH). The
#      result's `set_hash` is the recomputed one, but not on `--plan`.
#   3. THE CONTEXT. Scope machine = the machine file's `name`, scope cell =
#      the cell's name, `Provenance(--run-id, --revision-id)`, no validation
#      run id (a long-lived cell is never stamped with one), the cell's
#      settings and bootstrap level. The release set's images are not yet
#      resolved into it (`artifacts` is empty until the image work lands).
#   4. CREDENTIALS. `configure(ctx)` first (the adapter learns the cell's
#      settings), then `whoami` and `trust_check`. A configure or trust
#      finding is REFUSED (KCI-E-CLOUD); a `whoami` or `trust_check` that
#      raises is FAILED, exit 4, retry SAFE: nothing was written.
#   5. PLAN OR APPLY (kci_cloud). With `--plan`, `plan_report`: it writes
#      nothing to the store or the cloud; the row gets `plan_hash`,
#      `leftover`, `left_behind` and `released` (what an apply would
#      release). Without it, `apply_resources`. The outcome (deploy_step.md,
#      "Outcome and exit"):
#        * the typed refusal (`Refusal`, raised or returned), on either
#          verb: REFUSED, exit 3, `landed` empty;
#        * a raise that is not a refusal: FAILED, exit 4. When re-running
#          the adapter's lowering (`lower_data`) or its `realize` on the
#          same input raises too, it is a defect of kci or the adapter, not
#          of the input or the cloud: retry NEEDS_HUMAN. Otherwise a read
#          failed before the engine was called (a `list_owned`, an
#          adoption read, the plan's presence read): retry SAFE;
#        * any error from the engine's apply that is not a refusal, even
#          with `landed` empty (the failing node's own call may have
#          landed): PARTIAL, exit 6, UNSAFE, with `landed`, `pending` (the
#          failing node first) and `failed`. A failed release of an adopted
#          object: PARTIAL too, `failed` naming it with verb `release`;
#        * an apply where every node was a no-op and nothing was released:
#          NOOP; any other apply, and every `--plan`: SUCCEEDED.
#   6. REPORT. The plan (`render_plan` under `--plan`; `group_plan` of what
#      the apply did otherwise) is printed to STDOUT and goes into the
#      step's summary block (summary.mojo `deploy_markdown`) with the deploy
#      keys; `leftover` and `left_behind` are listed and never deleted.
#      `outputs` stays empty: the engine does not hand its recorded outputs
#      back to kci yet.
#
# `--rollback-on-failure`, and emptying `set_hash` when a DEPLOY step fails,
# are not here.
#
# Encapsulation: owned values and generic parameters; no pointer, no
# wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_crypto import hex_lower_array_32, sha256
from komira_json import write_json_string
from komira_proto_codec import decode_json

from kci_reconciler import (
    AppliedNode,
    CellScope,
    ChangeAction,
    Creds,
    Provenance,
    StateStore,
    VERB_NOOP,
    fault_domain_of_error,
    fault_domain_word,
    fault_message_of_error,
)
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    CloudAdapter,
    CloudId,
    Clouds,
    Finding,
    LoweredNode,
    PlanReport,
    Refusal,
    Setting,
    apply_resources,
    describe,
    group_plan,
    lower_data,
    owner_of_node,
    plan_report,
    realize_graph,
    refusal_text,
    render_plan,
    valid_expansion,
)
from kci_cell import Cell, CellSetting, find_cell, parse_cells_file
from kci_composites import read_kci_definitions
from kci_api import (
    ERROR_CLOUD,
    ERROR_DEPLOY,
    ERROR_FORMAT,
    ERROR_SET_HASH,
    OUTCOME_FAILED,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    PLATFORM_LINUX_X86_64,
    RETRY_NEEDS_HUMAN,
    STEP_KIND_DEPLOY,
    ResultFailedNode,
    ResultLanded,
    ResultStep,
    release_platform_dir,
)
from kci_api import RunResult as KciRunResult
from kci_release_machine import ReleaseMachine, Selection, Stage, StageStep
from kci_release_set import bytewise_less

from .args import KciCommand
from .seam import StageSteps, StepEnd
from .start_checks import StartVerdict
from .summary import deploy_markdown

comptime NOT_BUILT_WITH: String = "this kci was not built with that cloud"
"""The refusal of a cell whose cloud is not built into this kci (step 1)."""


struct DeployRequest(Copyable, Movable):
    """One DEPLOY step of a run (file header): the step, the machine file's
    `name`, the cells file and the cell, the resource list and the
    definition files, the run's provenance and `--plan`.

    Layout: owned values only. No pointer field."""

    var stage: String
    var step_name: String
    var machine: String
    var cells_file: String
    var cell: String
    var resources_file: String
    var definitions: List[String]
    var run_id: String
    var revision_id: String
    var plan: Bool

    def __init__(out self):
        self.stage = String("")
        self.step_name = String("")
        self.machine = String("")
        self.cells_file = String("")
        self.cell = String("")
        self.resources_file = String("")
        self.definitions = List[String]()
        self.run_id = String("")
        self.revision_id = String("")
        self.plan = False


def deploy_request(cmd: KciCommand, machine: String, stage: Stage, step: StageStep) -> DeployRequest:
    """The request for DEPLOY step `step` of `stage`; `machine` is the
    machine file's `name`."""
    var req = DeployRequest()
    req.stage = stage.name.copy()
    req.step_name = step.name.copy()
    req.machine = machine.copy()
    req.cells_file = step.cells.copy()
    req.cell = step.cell.copy()
    req.resources_file = step.resources.copy()
    req.definitions = step.definitions.copy()
    req.run_id = cmd.run_id.copy()
    req.revision_id = cmd.revision_id.copy()
    req.plan = cmd.plan
    return req^


trait CellDeploys:
    """The clouds a kci binary was built with, as dispatch.mojo's seam for
    DEPLOY steps: one step's request in, how it ended out. It adds the
    step's row (with its deploy keys) and first error to `result`."""

    def deploy(mut self, req: DeployRequest, mut result: KciRunResult) -> StepEnd:
        ...


struct _Stop(Movable):
    """Why the step stops before plan or apply: an outcome, an error id, a
    message and retry advice stronger than the number's ("" for none)."""

    var outcome: String
    var error_id: String
    var message: String
    var retry: String

    def __init__(out self):
        self.outcome = String("")
        self.error_id = String("")
        self.message = String("")
        self.retry = String("")

    def set(mut self, outcome: String, error_id: String, message: String, retry: String = String("")):
        self.outcome = outcome.copy()
        self.error_id = error_id.copy()
        self.message = message.copy()
        self.retry = retry.copy()


struct _Loaded(Movable):
    """Step 1's inputs: the cell, its resolved cloud, the resource list and
    every definition (kci's, then the step's)."""

    var cell: Cell
    var cloud: CloudId
    var resources: List[Resource]
    var definitions: List[CompositeDefinition]

    def __init__(out self):
        self.cell = Cell(String(""), String(""), List[CellSetting](), 0)
        self.cloud = CloudId(String(""))
        self.resources = List[Resource]()
        self.definitions = List[CompositeDefinition]()


def _read(path: String) raises -> String:
    return Path(path).read_text()


def _load(req: DeployRequest, clouds: Clouds, mut loaded: _Loaded, mut stop: _Stop) -> Bool:
    """Step 1 (file header). False with `stop` set when the step stops."""
    var cells: List[Cell]
    try:
        cells = parse_cells_file(_read(req.cells_file))
    except e:
        stop.set(OUTCOME_REFUSED, ERROR_FORMAT, String("the cells file '") + req.cells_file + String("': ") + String(e))
        return False
    try:
        loaded.cell = find_cell(cells, req.cell)
    except e:
        stop.set(OUTCOME_REFUSED, ERROR_FORMAT, String("the cells file '") + req.cells_file + String("': ") + String(e))
        return False
    try:
        loaded.cloud = clouds.resolve(loaded.cell.cloud)
    except e:
        stop.set(
            OUTCOME_REFUSED, ERROR_CLOUD,
            String(NOT_BUILT_WITH) + String(": cell '") + loaded.cell.name + String("' names cloud '") + loaded.cell.cloud
            + String("' (") + String(e) + String(")"),
        )
        return False
    try:
        loaded.resources = decode_json[ResourceList](_read(req.resources_file)).resource.copy()
    except e:
        stop.set(
            OUTCOME_REFUSED, ERROR_FORMAT, String("the resource list '") + req.resources_file + String("': ") + String(e)
        )
        return False
    try:
        loaded.definitions = read_kci_definitions()
    except e:
        stop.set(
            OUTCOME_FAILED, ERROR_DEPLOY,
            String("the definitions kci ships cannot be read, so this kci was packaged without them: ") + String(e),
            String(RETRY_NEEDS_HUMAN),
        )
        return False
    var shipped = len(loaded.definitions)
    for i in range(len(req.definitions)):
        ref path = req.definitions[i]
        var d: CompositeDefinition
        try:
            d = decode_json[CompositeDefinition](_read(path))
        except e:
            stop.set(OUTCOME_REFUSED, ERROR_FORMAT, String("the definitions file '") + path + String("': ") + String(e))
            return False
        for k in range(shipped):
            if loaded.definitions[k].name == d.name:
                stop.set(
                    OUTCOME_REFUSED, ERROR_FORMAT,
                    String("the definitions file '") + path + String("' redefines '") + d.name
                    + String("', a definition kci ships"),
                )
                return False
        loaded.definitions.append(d^)
    return True


def _context(req: DeployRequest, cell: Cell) -> CellContext:
    """Step 3 (file header)."""
    var settings = List[Setting]()
    for i in range(len(cell.settings)):
        settings.append(Setting(cell.settings[i].key.copy(), cell.settings[i].value.copy()))
    var scope = CellScope(req.machine, cell.name, Provenance(req.run_id, req.revision_id))
    return CellContext(scope^, settings^, bootstrap_level=cell.bootstrap_level)


def _verb_word(verb: Int) -> String:
    return String(ChangeAction(String(""), verb, String(""), 0).verb_name())


def _actions_of(nodes: List[AppliedNode]) -> List[ChangeAction]:
    """What an apply did, as change actions under their owners, for
    `group_plan`."""
    var out = List[ChangeAction]()
    for i in range(len(nodes)):
        ref n = nodes[i]
        out.append(ChangeAction(n.logical_id, n.verb, String(""), n.retention, owner_of_node(n.logical_id)))
    return out^


def _put(mut buf: List[UInt8], s: String):
    var b = s.as_bytes()
    for i in range(len(b)):
        buf.append(b[i])


def plan_hash_of(actions: List[ChangeAction]) -> String:
    """`plan_hash`: the sha256 hex of the canonical JSON of `actions`, sorted
    by node id bytewise: `[{"node":..,"owner":..,"verb":..},...]`, keys in
    that order, no space."""
    var order = List[Int]()
    for i in range(len(actions)):
        var at = len(order)
        while at > 0 and bytewise_less(actions[i].logical_id, actions[order[at - 1]].logical_id):
            at -= 1
        order.insert(at, i)
    var buf = List[UInt8]()
    buf.append(UInt8(ord("[")))
    for k in range(len(order)):
        ref a = actions[order[k]]
        if k > 0:
            buf.append(UInt8(ord(",")))
        _put(buf, String('{"node":'))
        write_json_string(buf, a.logical_id)
        _put(buf, String(',"owner":'))
        write_json_string(buf, a.owner)
        _put(buf, String(',"verb":'))
        write_json_string(buf, String(a.verb_name()))
        buf.append(UInt8(ord("}")))
    buf.append(UInt8(ord("]")))
    return hex_lower_array_32(sha256(Span(buf)))


def _defect[
    S: CloudAdapter
](clouds: Clouds, mut cloud: S, ctx: CellContext, resources: List[Resource], defs: List[CompositeDefinition]) -> String:
    """Whether the adapter's lowering or its `realize` raises on this input
    (file header, 5): the message, or "" when neither does (a graph that
    does not validate is the typed refusal's, not a defect). Lowering and
    realizing are pure, so the answer is the one the verb met."""
    var expanded: List[Resource]
    try:
        expanded = valid_expansion(clouds, cloud, ctx, resources, True, defs)
    except:
        return String("")
    var nodes: List[LoweredNode]
    try:
        nodes = lower_data(cloud, expanded)
    except e:
        return String("lower_data raised: ") + String(e)
    try:
        _ = realize_graph(cloud, nodes)
    except e:
        return String("realize_graph raised: ") + String(e)
    return String("")


def _failed_node(node: String, verb: String, error: String) -> ResultFailedNode:
    return ResultFailedNode(
        node.copy(), verb.copy(), fault_domain_word(fault_domain_of_error(error)), fault_message_of_error(error)
    )


def _engine_verb(node: String, error: String) -> String:
    """The verb of the engine's `apply node '<node>' verb=<v> failed:` error,
    or "" when `error` is not that error (a pre-flight read, say)."""
    var head = String("apply node '") + node + String("' verb=")
    var at = error.find(head)
    if at < 0:
        return String("")
    var start = at + head.byte_length()
    var end = error.find(String(" "), start)
    if end < 0:
        return String("")
    return String(error[byte=start:end])


def _end(
    var row: ResultStep, mut result: KciRunResult, var outcome: String, error_id: String, message: String,
    retry: String = String(""), plan_text: String = String(""), changed: Bool = False,
) -> StepEnd:
    """The step's end: its row (outcome set) and first error into `result`,
    the plan to stdout, and its summary block."""
    row.outcome = outcome.copy()
    var end = StepEnd(outcome.copy(), error_id.copy(), message.copy())
    end.retry = retry.copy()
    end.changed_outside = changed
    if plan_text.byte_length() > 0:
        print(plan_text)
    end.summary = deploy_markdown(row.name, row.deploy, outcome, result.plan, plan_text, message)
    if error_id.byte_length() > 0:
        try:
            result.set_error(error_id.copy(), message.copy())
        except e:
            end.lines.append(String("kci: ") + String(e))
    result.steps.append(row^)
    return end^


def _stopped(var row: ResultStep, mut result: KciRunResult, stop: _Stop) -> StepEnd:
    return _end(row^, result, stop.outcome.copy(), stop.error_id, stop.message, stop.retry)


def deploy_step[
    S: CloudAdapter, St: StateStore
](
    req: DeployRequest, clouds: Clouds, mut cloud: S, mut store: St, creds: Creds, mut result: KciRunResult
) -> StepEnd:
    """One DEPLOY step on the built-in cloud `cloud` (one of `clouds`), its
    store and `creds` (file header, 1 and 3 to 6). Never raises."""
    var row = ResultStep(req.step_name.copy(), String(STEP_KIND_DEPLOY), String(""), String(""))
    var stop = _Stop()
    var ld = _Loaded()
    if not _load(req, clouds, ld, stop):
        if ld.cell.name.byte_length() > 0:
            row.deploy.cell = ld.cell.name.copy()
            row.deploy.cloud = ld.cell.cloud.copy()
        return _stopped(row^, result, stop)
    row.deploy.cell = ld.cell.name.copy()
    row.deploy.cloud = ld.cell.cloud.copy()
    if ld.cloud != cloud.cloud_id():
        stop.set(
            OUTCOME_REFUSED, ERROR_CLOUD,
            String(NOT_BUILT_WITH) + String(": cell '") + ld.cell.name + String("' names cloud '") + ld.cell.cloud
            + String("', and this step runs on '") + cloud.cloud_id().text() + String("'"),
        )
        return _stopped(row^, result, stop)
    # 3. the context; 4. the credentials
    var ctx = _context(req, ld.cell)
    var found = cloud.configure(ctx)
    if len(found) > 0:
        stop.set(OUTCOME_REFUSED, ERROR_CLOUD, refusal_text(cloud.cloud_id(), found))
        return _stopped(row^, result, stop)
    try:
        _ = cloud.whoami(creds)
    except e:
        stop.set(OUTCOME_FAILED, ERROR_CLOUD, String("whoami raised before anything was written: ") + String(e))
        return _stopped(row^, result, stop)
    var trust: List[Finding]
    try:
        trust = cloud.trust_check(creds, ctx.scope)
    except e:
        stop.set(OUTCOME_FAILED, ERROR_CLOUD, String("trust_check raised before anything was written: ") + String(e))
        return _stopped(row^, result, stop)
    if len(trust) > 0:
        stop.set(OUTCOME_REFUSED, ERROR_CLOUD, refusal_text(cloud.cloud_id(), trust))
        return _stopped(row^, result, stop)
    # 5. plan or apply
    var refusal = Optional[Refusal](None)
    if req.plan:
        var report: PlanReport
        try:
            report = plan_report(clouds, cloud, ctx, ld.resources, creds, store, ld.definitions, refusal)
        except e:
            return _raised(row^, result, String(e), refusal, clouds, cloud, ctx, ld)
        row.deploy.plan_hash = plan_hash_of(report.actions)
        row.deploy.leftover = report.leftover.copy()
        row.deploy.left_behind = report.left_behind.copy()
        row.deploy.released = report.released.copy()
        return _end(row^, result, String(OUTCOME_SUCCEEDED), String(""), String(""), plan_text=render_plan(report))
    var done: ApplyOutcome
    try:
        done = apply_resources(clouds, cloud, ctx, ld.resources, creds, store, ld.definitions, refusal)
    except e:
        return _raised(row^, result, String(e), refusal, clouds, cloud, ctx, ld)
    row.deploy.leftover = done.leftover.copy()
    row.deploy.left_behind = done.left_behind.copy()
    row.deploy.released = done.released.copy()
    if done.refused():
        return _end(row^, result, String(OUTCOME_REFUSED), String(ERROR_DEPLOY), done.refusal.value().text)
    for i in range(len(done.landed)):
        row.deploy.landed.append(ResultLanded(done.landed[i].logical_id.copy(), _verb_word(done.landed[i].verb)))
    row.deploy.pending = done.pending.copy()
    var did = group_plan(_actions_of(done.landed), List[String](), done.released)
    if done.error:
        var error = done.error.value().copy()
        if done.release_failed():
            row.deploy.failed = _failed_node(done.failed_release, String("release"), error)
        else:
            var node = String("")
            if len(done.pending) > 0:
                node = done.pending[0].copy()
            row.deploy.failed = _failed_node(node, _engine_verb(node, error), error)
        row.deploy.has_failed = True
        return _end(
            row^, result, String(OUTCOME_PARTIAL), String(ERROR_DEPLOY),
            String("the apply into cell '") + ld.cell.name + String("' stopped part-way: ") + fault_message_of_error(error),
            plan_text=did, changed=True,
        )
    var changed = len(done.released) > 0
    for i in range(len(done.applied)):
        if done.applied[i].verb != VERB_NOOP:
            changed = True
    var outcome = String(OUTCOME_SUCCEEDED) if changed else String(OUTCOME_NOOP)
    return _end(row^, result, outcome^, String(""), String(""), plan_text=did, changed=changed)


def _raised[
    S: CloudAdapter
](
    var row: ResultStep, mut result: KciRunResult, error: String, refusal: Optional[Refusal], clouds: Clouds,
    mut cloud: S, ctx: CellContext, ld: _Loaded,
) -> StepEnd:
    """A verb raised (file header, 5): the typed refusal is REFUSED; any
    other raise is FAILED, NEEDS_HUMAN when it is a lowering or `realize`
    defect, SAFE (the number's advice) otherwise."""
    if refusal:
        return _end(row^, result, String(OUTCOME_REFUSED), String(ERROR_DEPLOY), refusal.value().text)
    var defect = _defect(clouds, cloud, ctx, ld.resources, ld.definitions)
    if defect.byte_length() > 0:
        return _end(
            row^, result, String(OUTCOME_FAILED), String(ERROR_DEPLOY),
            String("a defect of kci or the cloud adapter, before anything was written: ") + defect
            + String(" (the verb raised: ") + error + String(")"),
            String(RETRY_NEEDS_HUMAN),
        )
    return _end(
        row^, result, String(OUTCOME_FAILED), String(ERROR_DEPLOY),
        String("a read failed before anything was written: ") + error,
    )


struct CloudDeploys[S: CloudAdapter & Deinitable, St: StateStore](CellDeploys, Movable):
    """One built-in cloud (`cloud`, the only entry of `clouds`), the state
    store it deploys through and its credentials (file header).

    Layout: owned values only. No pointer field."""

    var clouds: Clouds
    var cloud: Self.S
    var store: Self.St
    var creds: Creds

    def __init__(out self, var cloud: Self.S, var store: Self.St, creds: Creds) raises:
        self.clouds = Clouds(Catalog.v1())
        self.clouds.add(describe(cloud))
        self.cloud = cloud^
        self.store = store^
        self.creds = creds.copy()

    def deploy(mut self, req: DeployRequest, mut result: KciRunResult) -> StepEnd:
        return deploy_step(req, self.clouds, self.cloud, self.store, self.creds, result)


struct NoCloudBuilt(CellDeploys, Movable):
    """A kci built with no cloud (file header): every DEPLOY step is REFUSED
    at step 1, before its resource list is read."""

    def __init__(out self):
        pass

    def deploy(mut self, req: DeployRequest, mut result: KciRunResult) -> StepEnd:
        var row = ResultStep(req.step_name.copy(), String(STEP_KIND_DEPLOY), String(""), String(""))
        var stop = _Stop()
        var ld = _Loaded()
        var clouds: Clouds
        try:
            clouds = Clouds(Catalog.v1())
        except e:
            stop.set(
                OUTCOME_FAILED, ERROR_DEPLOY, String("kci's catalog cannot be built: ") + String(e),
                String(RETRY_NEEDS_HUMAN),
            )
            return _stopped(row^, result, stop)
        if _load(req, clouds, ld, stop):
            # unreachable: an empty list resolves no cloud
            stop.set(OUTCOME_REFUSED, ERROR_CLOUD, String(NOT_BUILT_WITH))
        if ld.cell.name.byte_length() > 0:
            row.deploy.cell = ld.cell.name.copy()
            row.deploy.cloud = ld.cell.cloud.copy()
        return _stopped(row^, result, stop)


def check_deploy_set_hash[S: StageSteps](
    cmd: KciCommand, g: ReleaseMachine, stage: Stage, sel: Selection, mut steps: S, mut result: KciRunResult
) -> StartVerdict:
    """Step 2 (file header), at start-up: "" outcome when the run may go
    on. The release is the one the machine file's first BUILD step for
    linux-x86_64 makes; this stands until the image work (I4 of
    deploy_step.md) resolves the set through the BUILD step each image's
    `StepOutput` names, which replaces it."""
    var deploying = False
    for i in range(len(stage.steps)):
        if sel.steps[i] and stage.steps[i].is_deploy():
            deploying = True
    if not deploying:
        return StartVerdict()
    var v = StartVerdict()
    v.outcome = String(OUTCOME_REFUSED)
    v.error_id = String(ERROR_SET_HASH)
    var artifacts = String("")
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            ref s = g.stages[i].steps[k]
            if artifacts.byte_length() == 0 and s.is_build() and s.platform == PLATFORM_LINUX_X86_64:
                artifacts = s.artifacts.copy()
    if artifacts.byte_length() == 0:
        v.message = (
            String("a DEPLOY step deploys the release the machine file's BUILD step for ") + String(PLATFORM_LINUX_X86_64)
            + String(" makes, and the machine file has none, so --release-set-hash cannot be held to a release")
        )
        return v^
    var got: String
    try:
        got = steps.release_set_hash(artifacts, release_platform_dir(cmd.release_dir, String(PLATFORM_LINUX_X86_64)))
    except e:
        v.message = (
            String("the release directory's set hash cannot be recomputed, so it cannot be held to --release-set-hash ")
            + cmd.release_set_hash + String(": ") + String(e)
        )
        return v^
    if got != cmd.release_set_hash:
        v.message = (
            String("the release directory recomputes to set hash ") + got + String(", not ") + cmd.release_set_hash
            + String(" (the set this run was handed): a DEPLOY step deploys only the bytes that were built")
        )
        return v^
    if not cmd.plan:
        result.set_hash = got^
    return StartVerdict()
