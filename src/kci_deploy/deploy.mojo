# =============================================================================
# kci_deploy/deploy.mojo -- the DEPLOY LIBRARY FACADE: the one library boundary
#   all deploy mechanics live behind.
# =============================================================================
#
# The public entrypoints wrap the `kci_iac` reconcile verbs with the library's
# two frontend seams (Creds and Reporter) and the environment-governance gate:
#   * deploy_plan(graph, env_binding, creds, reporter) -> DeployPlanOutcome
#     -- the read-only dry run: `plan_graph` over the graph, reporting each
#        planned ChangeAction. `has_changes()` drives a CLI's diff-present exit
#        code.
#   * deploy_apply(graph, env_binding, creds, store, reporter) -> DeployApplyOutcome
#     -- the forward apply: the governance gate (a direct apply to a
#        PIPELINE_ONLY environment is refused), then `apply_graph` over the graph
#        and a write-ahead StateStore, reporting each AppliedNode.
#   * deploy_destroy(graph, env_binding, creds, store, reporter, force_delete_data)
#     -> DeployDestroyOutcome -- the symmetric inverse of deploy_apply: the same
#        governance gate, then `destroy_graph` in reverse topological order,
#        honouring each node's retention().
#   * deploy_rollback / deploy_status -- a digest rollback (two fail-loud edges,
#     then a governed re-apply) and a read-only status mapping.
#
# WHY A THIN FACADE. All reconcile intelligence lives in `kci_iac` (topological
# order, plan / apply, the write-ahead intent ledger). This facade adds only:
# (a) the two frontend seams (the frontend resolves `Creds`; the facade takes
# them resolved), (b) the governance gate, (c) event reporting, and (d) a
# value-typed OUTCOME a frontend maps to an exit code or a result ledger. The
# graph is built by the frontend; the facade does not care how.
#
# GENERIC, NOT ERASED. The reporter is chosen once per invocation, so the facade
# is generic over `R: Reporter` and a frontend binds its conformer with no
# library change. `apply` is also generic over `S: StateStore`, because
# `apply_graph` is. Each is a single flat trait bound.
#
# ENCAPSULATION: `mut ResourceGraph`, `EnvBinding`, `Creds`, `mut R` (and
# `mut S`) in, value outcomes out, `raises` for a governance refusal or a
# backend fault. No pointer crosses the boundary.
# =============================================================================

from kci_iac import (
    ResourceGraph,
    plan_graph,
    apply_graph,
    apply_graph_tracked,
    destroy_graph,
    undeletable_report_lines,
    Creds,
    ChangeAction,
    AppliedNode,
    ResourceStatus,
    StateStore,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_NOOP,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RES_PRESENT_DRIFTED,
    RES_CONVERGING,
    RES_FAILED,
    RETAIN_KEEP,
)

from kci_deploy.env_binding import EnvBinding
from kci_deploy.reporter import Reporter


@fieldwise_init
struct DeployPlanOutcome(Copyable, Movable, Deinitable):
    """The result of a `deploy_plan`: the planned ChangeActions in topological
    order and the environment name. `has_changes()` (any non-noop action) is a
    CLI's diff-present verdict."""

    var env: String
    var actions: List[ChangeAction]

    def has_changes(self) -> Bool:
        """True iff ANY planned action is not a no-op (a create / update /
        replace / delete)."""
        for i in range(len(self.actions)):
            if not self.actions[i].is_noop():
                return True
        return False

    def action_count(self) -> Int:
        """The number of planned actions (the graph's node count)."""
        return len(self.actions)

    def change_count(self) -> Int:
        """The number of non-noop planned actions."""
        var n = 0
        for i in range(len(self.actions)):
            if not self.actions[i].is_noop():
                n += 1
        return n


@fieldwise_init
struct DeployApplyOutcome(Copyable, Movable, Deinitable):
    """The result of a `deploy_apply`: the AppliedNodes in apply order and the
    environment name, with the create / update / noop counts a frontend renders or
    records.

    `served_endpoint` is the served URL of the deploy's served node, taken from the
    applied node's own live read. It is present on every path where a served node
    resolved, including a no-op re-apply where the service already serves the same
    image. A fresh CREATE leaves it EMPTY (the pre-create live read was ABSENT); a
    caller that needs the URL then runs a bounded health poll through
    `deploy_status` and sets this field itself."""

    var env: String
    var applied: List[AppliedNode]
    var served_endpoint: String
    var ingress_endpoint: String
    var ingress_origin: String
    var datastore_created: Bool

    def node_count(self) -> Int:
        """The number of applied nodes (the graph's node count)."""
        return len(self.applied)

    def created_count(self) -> Int:
        """How many nodes were CREATED."""
        return self._count(VERB_CREATE)

    def updated_count(self) -> Int:
        """How many nodes were UPDATED in place."""
        return self._count(VERB_UPDATE)

    def noop_count(self) -> Int:
        """How many nodes were a no-op (matched or adopted)."""
        return self._count(VERB_NOOP)

    def _count(self, verb: Int) -> Int:
        var n = 0
        for i in range(len(self.applied)):
            if self.applied[i].verb == verb:
                n += 1
        return n


def deploy_plan[
    R: Reporter
](
    mut graph: ResourceGraph,
    env_binding: EnvBinding,
    creds: Creds,
    mut reporter: R,
) raises -> DeployPlanOutcome:
    """The dry run: `plan_graph` over `graph` as `creds`, reporting each planned
    ChangeAction through `reporter`. Read-only: the engine issues only live reads.
    Raises on a dangling dependency or cycle, or a backend read fault."""
    reporter.begin(String("plan"), env_binding.name.copy())
    var actions = plan_graph(graph, creds)
    for i in range(len(actions)):
        reporter.plan_action(actions[i].copy())
    var outcome = DeployPlanOutcome(env_binding.name.copy(), actions^)
    var summary = (
        String("plan: ")
        + String(outcome.change_count())
        + String(" change(s), ")
        + String(outcome.action_count())
        + String(" node(s) [env: ")
        + env_binding.name
        + String("]")
    )
    reporter.finish(summary)
    return outcome^


def _verb_word(v: Int) -> StaticString:
    """The VERB_* an apply issued, as the word an operator reads. `?` for an
    unknown value rather than a guess: a wrong verb in a failure report is worse
    than an unnamed one."""
    if v == VERB_CREATE:
        return "created"
    if v == VERB_UPDATE:
        return "updated"
    if v == VERB_NOOP:
        return "adopted"
    return "?"


def partial_apply_report(
    landed: List[AppliedNode], pending: List[String], cause: String
) -> String:
    """THE PARTIAL-APPLY REPORT: exactly which nodes landed and which did not.

    An apply is NOT atomic across its nodes and there is NO rollback, so a graph
    that aborts halfway leaves the environment half-configured: for example a
    service converged on a new revision while the access grants ordered after the
    failing node never landed, so the service comes up and is refused on its first
    dependency read. Without this report nothing in the deploy's output says so.

    The first `pending` entry is the FAILING node, and it is labelled as such
    rather than lumped in with the untouched remainder. It was reached: its
    write-ahead intent exists, and depending on which verb raised, a partial
    mutation may exist too. "Not applied" would be a claim the engine cannot make
    about it; "did not complete" is what it knows.

    THE REMEDY IS RE-RUN, NOT REPAIR. These graphs are level-triggered: every node
    re-reads live state and adopts what already matches, so the same command after
    the cause is fixed converges the remainder. The report says so because an
    operator's instinct on a half-applied environment is to delete things by
    hand."""
    var out = String("\n  PARTIAL APPLY — this deploy MUTATED the environment and")
    out += String(" then stopped. There is NO rollback.\n")
    out += String("  CAUSE: ") + cause + String("\n")
    out += String("  LANDED (") + String(len(landed)) + String(" node(s), live now):\n")
    if len(landed) == 0:
        out += String("    (none — the failure was on the first node)\n")
    for i in range(len(landed)):
        out += (
            String("    ✓ ")
            + landed[i].logical_id
            + String(" [")
            + _verb_word(landed[i].verb)
            + String("]\n")
        )
    if len(pending) > 0:
        out += (
            String("  DID NOT COMPLETE: ")
            + pending[0]
            + String(" (reached; its write-ahead intent exists)\n")
        )
    var untouched = len(pending) - 1 if len(pending) > 0 else 0
    out += String("  NOT APPLIED (") + String(untouched) + String(" node(s)):\n")
    if untouched <= 0:
        out += String("    (none — the failure was on the last node)\n")
    for i in range(1, len(pending)):
        out += String("    ✗ ") + pending[i] + String("\n")
    out += String(
        "  RECOVERY: fix the cause and RE-RUN the same deploy. The graph is"
        " level-triggered — every node re-reads live state and adopts what"
        " already matches, so the re-run converges the remainder. Do NOT delete"
        " the landed resources by hand."
    )
    return out^


def deploy_apply[
    R: Reporter, S: StateStore
](
    mut graph: ResourceGraph,
    env_binding: EnvBinding,
    creds: Creds,
    mut store: S,
    mut reporter: R,
    pipeline_run: Bool = False,
) raises -> DeployApplyOutcome:
    """The forward apply. FIRST the governance gate: a direct (non-pipeline)
    apply to a PIPELINE_ONLY (or UNSPECIFIED, fail-safe) environment is refused
    with a precise error, so the policy lives in the environment registry rather
    than in tribal knowledge. THEN `apply_graph` over `graph` and the write-ahead
    `store` as `creds`, reporting each AppliedNode. Raises on the governance
    refusal, a non-steady live phase, or a backend fault; an apply fault carries
    `partial_apply_report`.

    `pipeline_run`: when True this apply is a pipeline-driven run, which is
    exactly the authorized mutation path for a governed environment, so the gate
    is `pipeline_run or allows_direct_apply()`. The default (False) keeps a direct
    apply against a PIPELINE_ONLY environment refused. The registry stays the
    single source of the standing policy (`direct_apply`), and the run-context
    authorization is threaded separately so the two never conflate."""
    if not (pipeline_run or env_binding.allows_direct_apply()):
        raise Error(
            String("deploy_apply: environment '")
            + env_binding.name
            + String("' is PIPELINE_ONLY — a direct apply is refused. Only")
            + String(" a pipeline run may mutate it. Use a dev/personal env whose")
            + String(" registry entry declares direct_apply: DIRECT_APPLY_ALLOWED,")
            + String(" or drive this env through a pipeline run.")
        )
    reporter.begin(String("apply"), env_binding.name.copy())
    var landed = List[AppliedNode]()
    var pending = List[String]()
    var applied: List[AppliedNode]
    try:
        applied = apply_graph_tracked(graph, creds, store, landed, pending)
    except ae:
        raise Error(
            String(ae)
            + partial_apply_report(landed, pending, String(ae))
        )
    for i in range(len(applied)):
        reporter.applied_node(applied[i].copy())
    var served = String("")
    for i in range(len(applied)):
        if applied[i].served_endpoint.byte_length() > 0:
            served = applied[i].served_endpoint.copy()
            break
    var outcome = DeployApplyOutcome(
        env_binding.name.copy(),
        applied^,
        served^,
        String(""),
        String(""),
        False,
    )
    var summary = (
        String("apply: ")
        + String(outcome.created_count())
        + String(" created, ")
        + String(outcome.updated_count())
        + String(" updated, ")
        + String(outcome.noop_count())
        + String(" noop [env: ")
        + env_binding.name
        + String("]")
    )
    reporter.finish(summary)
    return outcome^


def deploy_rollback[
    R: Reporter, S: StateStore
](
    mut graph: ResourceGraph,
    prior_digest: String,
    current_digest: String,
    env_binding: EnvBinding,
    creds: Creds,
    mut store: S,
    mut reporter: R,
    pipeline_run: Bool = False,
) raises -> DeployApplyOutcome:
    """Roll a deployment back to a PRIOR good digest, phrased as an in-place
    re-apply of the prior image. Two fail-loud edges, then a re-drive of
    `deploy_apply` over `graph` (the caller composes `graph` at the prior digest;
    the facade does not reach inside the erased graph nodes):

      * `prior_digest` EMPTY (a first deploy): nothing prior to restore. Raise; the
        caller fails the promotion and tears down the faulted deploy.
      * `prior_digest` == `current_digest`: a rollback of a rollback with nothing
        lower to fall to. Raise; do not recurse.

    Otherwise the same governance-gated forward apply runs, threading
    `pipeline_run`, so a pipeline-driven rollback proceeds against a PIPELINE_ONLY
    environment while a direct rollback of a governed environment stays refused."""
    if prior_digest.byte_length() == 0:
        raise Error(
            String("deploy_rollback: no prior_digest [env: ")
            + env_binding.name
            + String(
                "] — a first deploy has no prior good serving state to restore"
                ". The caller must fail the promotion + tear down the"
                " faulted deploy; the facade does not re-apply-nothing."
            )
        )
    if prior_digest == current_digest:
        raise Error(
            String("deploy_rollback: prior_digest == the current digest [env: ")
            + env_binding.name
            + String(
                "] — nothing lower to roll back to (a rollback-of-rollback /"
                " self-rollback). Fail loud; do not recurse."
            )
        )
    reporter.info(
        String("rollback: restoring prior digest '")
        + prior_digest
        + String("' (from '")
        + current_digest
        + String("') [env: ")
        + env_binding.name
        + String("]")
    )
    return deploy_apply(
        graph, env_binding, creds, store, reporter, pipeline_run=pipeline_run
    )


comptime DEPLOY_STATUS_CONVERGING: Int = 0
"""The resource is reconciling toward the desired spec (the engine's
RES_PRESENT_DRIFTED / RES_CONVERGING)."""
comptime DEPLOY_STATUS_HEALTHY: Int = 1
"""The resource is serving and matches the desired spec (the engine's
RES_PRESENT_MATCHED)."""
comptime DEPLOY_STATUS_FAILED: Int = 2
"""The apply failed or the resource went unhealthy (the engine's
RES_FAILED)."""
comptime DEPLOY_STATUS_NOTFOUND: Int = 3
"""No such resource (deleted out of band or never created: the engine's
RES_ABSENT, or a name that is not a graph node)."""


@fieldwise_init
struct DeploymentStatus(Copyable, Movable, Deinitable):
    """The observed state of an applied deployment. `phase` is one of the
    DEPLOY_STATUS_* constants; `endpoint` is the served URL once healthy (empty
    otherwise); `message` carries a failure reason on FAILED; `live_image` is the
    image the live resource runs (a last-good-digest record keys on it)."""

    var phase: Int
    var endpoint: String
    var message: String
    var live_image: String

    def is_healthy(self) -> Bool:
        return self.phase == DEPLOY_STATUS_HEALTHY

    def is_failed(self) -> Bool:
        return self.phase == DEPLOY_STATUS_FAILED

    def is_not_found(self) -> Bool:
        return self.phase == DEPLOY_STATUS_NOTFOUND

    @staticmethod
    def converging() -> DeploymentStatus:
        return DeploymentStatus(
            DEPLOY_STATUS_CONVERGING, String(""), String(""), String("")
        )

    @staticmethod
    def healthy(endpoint: String, live_image: String) -> DeploymentStatus:
        return DeploymentStatus(
            DEPLOY_STATUS_HEALTHY, endpoint, String(""), live_image
        )

    @staticmethod
    def failed(message: String) -> DeploymentStatus:
        return DeploymentStatus(
            DEPLOY_STATUS_FAILED, String(""), message, String("")
        )

    @staticmethod
    def not_found() -> DeploymentStatus:
        return DeploymentStatus(
            DEPLOY_STATUS_NOTFOUND, String(""), String(""), String("")
        )


comptime APPLY_CREATED: Int = 0
"""No live resource: a create was issued."""
comptime APPLY_UPDATED: Int = 1
"""A live resource with a DIFFERENT digest: an in-place update was issued."""
comptime APPLY_NOOP: Int = 2
"""A live resource whose digest already matches: no update issued (the
declarative no-op of a same-digest re-apply)."""


@fieldwise_init
struct ApplyOutcome(Copyable, Movable, Deinitable):
    """The outcome of an apply: `kind` is one of APPLY_CREATED / APPLY_UPDATED /
    APPLY_NOOP; `applied_digest` is the digest the deploy converged the resource
    to (for a rollback, the prior digest)."""

    var kind: Int
    var applied_digest: String

    def is_noop(self) -> Bool:
        return self.kind == APPLY_NOOP

    def is_update(self) -> Bool:
        return self.kind == APPLY_UPDATED

    def is_create(self) -> Bool:
        return self.kind == APPLY_CREATED

    def kind_name(self) -> StaticString:
        if self.kind == APPLY_CREATED:
            return "created"
        if self.kind == APPLY_UPDATED:
            return "updated"
        return "noop"


def deploy_status[
    R: Reporter
](
    mut graph: ResourceGraph,
    name: String,
    creds: Creds,
    mut reporter: R,
) raises -> DeploymentStatus:
    """Read the live status of the served node keyed by `name` as `creds` and
    map its `ResourceStatus.phase` onto a `DeploymentStatus`, carrying the node's
    `endpoint` and `live_image` through:

      * RES_PRESENT_MATCHED                  -> DEPLOY_STATUS_HEALTHY
      * RES_PRESENT_DRIFTED / RES_CONVERGING -> DEPLOY_STATUS_CONVERGING
      * RES_FAILED                           -> DEPLOY_STATUS_FAILED
      * RES_ABSENT (or `name` is not a node) -> DEPLOY_STATUS_NOTFOUND

    Read-only. A `name` that is not a graph node maps to NOTFOUND rather than
    raising (the same semantic as an absent live read). Raises only on a backend
    read fault from the node's `read_status`."""
    reporter.begin(String("status"), name.copy())
    var idx = graph.index_of(name)
    if idx < 0:
        reporter.finish(
            String("status: '") + name + String("' NOTFOUND (no such node)")
        )
        return DeploymentStatus.not_found()
    var live = graph.node(idx).read_status(creds)
    var status = _map_resource_status(live)
    var summary = (
        String("status: '")
        + name
        + String("' -> ")
        + _deploy_status_label(status.phase)
    )
    reporter.finish(summary)
    return status^


def _map_resource_status(live: ResourceStatus) -> DeploymentStatus:
    """Map a served node's live `ResourceStatus` onto a `DeploymentStatus`: the
    single point of the RES_* -> DEPLOY_* remap."""
    if live.phase == RES_PRESENT_MATCHED:
        return DeploymentStatus.healthy(
            live.endpoint.copy(), live.live_image.copy()
        )
    if live.phase == RES_FAILED:
        var msg = live.message.copy()
        if msg.byte_length() == 0:
            msg = String("resource is in a FAILED live phase")
        return DeploymentStatus.failed(msg^)
    if live.phase == RES_ABSENT:
        return DeploymentStatus.not_found()
    return DeploymentStatus(
        DEPLOY_STATUS_CONVERGING,
        live.endpoint.copy(),
        String(""),
        live.live_image.copy(),
    )


def _deploy_status_label(phase: Int) -> StaticString:
    if phase == DEPLOY_STATUS_HEALTHY:
        return "HEALTHY"
    if phase == DEPLOY_STATUS_FAILED:
        return "FAILED"
    if phase == DEPLOY_STATUS_NOTFOUND:
        return "NOTFOUND"
    return "CONVERGING"


@fieldwise_init
struct DeployDestroyOutcome(Copyable, Movable, Deinitable):
    """The result of a `deploy_destroy`: the environment name and the graph's
    node count (the reverse walk covered every node). `force_delete_data` records
    whether the retention override was in force."""

    var env: String
    var node_count: Int
    var force_delete_data: Bool


def _retained_logical_ids(mut graph: ResourceGraph) -> List[String]:
    """The `logical_id` of every node whose authored retention is RETAIN_KEEP:
    the set a retention-override teardown deletes and must name. Read from
    `retention()` alone (a declared property, no cloud call), in graph order."""
    var out = List[String]()
    for i in range(graph.num_nodes()):
        if graph.node(i).retention() == RETAIN_KEEP:
            out.append(graph.node(i).logical_id())
    return out^


def deploy_destroy[
    R: Reporter, S: StateStore
](
    mut graph: ResourceGraph,
    env_binding: EnvBinding,
    creds: Creds,
    mut store: S,
    mut reporter: R,
    force_delete_data: Bool = False,
    pipeline_run: Bool = False,
) raises -> DeployDestroyOutcome:
    """The symmetric inverse of `deploy_apply`: the teardown. FIRST the same
    governance gate (a destroy is at least as governed as an apply), THEN
    `destroy_graph` in reverse topological order over `graph` and the write-ahead
    `store` as `creds`. Each node's `retention()` decides skip versus reap:
      * RETAIN_KEEP is skipped (never delete a shared or standing resource) unless
        `force_delete_data` lifts the skip, and every retained node it deletes is
        logged by name before and after;
      * RETAIN_DELETE is live-read then deleted (idempotent: an already-absent
        resource is a logged no-op);
      * RETAIN_UNDELETABLE is skipped unconditionally: no delete path exists for
        it, so `force_delete_data` cannot reach it (a flag lifts a policy; it
        cannot make a capability exist). Every such node is named in this verb's
        report with the conformer's reason, because a teardown that exits cleanly
        having left resources standing reads as an empty environment.
    Raises on the governance refusal or a backend fault; a delete fault stops the
    reverse walk, and the surviving intents let a re-drive resume.

    `pipeline_run` is symmetric with `deploy_apply`: when True the gate is
    satisfied against a PIPELINE_ONLY environment."""
    if not (pipeline_run or env_binding.allows_direct_apply()):
        raise Error(
            String("deploy_destroy: environment '")
            + env_binding.name
            + String("' is PIPELINE_ONLY — a direct destroy is refused (a destroy is")
            + String(" at least as governed as an apply). Only a pipeline run")
            + String(" may mutate it. Use a dev/personal env whose registry entry")
            + String(" declares direct_apply: DIRECT_APPLY_ALLOWED, or drive this env")
            + String(" through a pipeline run.")
        )
    reporter.begin(String("delete"), env_binding.name.copy())
    var n = graph.num_nodes()
    var retained = (
        _retained_logical_ids(graph) if force_delete_data else List[String]()
    )
    for ri in range(len(retained)):
        reporter.info(
            String("delete: WILL DELETE RETAINED resource '")
            + retained[ri]
            + String("' (RETAIN_KEEP; the retention override is IN FORCE)")
        )
    var undeletable = destroy_graph(
        graph, creds, store, force_delete_data=force_delete_data
    )
    for ri in range(len(retained)):
        reporter.info(
            String("delete: DELETED RETAINED resource '")
            + retained[ri]
            + String("' (RETAIN_KEEP; confirmed gone)")
        )
    var undeletable_lines = undeletable_report_lines(undeletable)
    for li in range(len(undeletable_lines)):
        reporter.info(undeletable_lines[li].copy())
    var summary = (
        String("delete: ")
        + String(n)
        + String(" node(s) reverse-walked, retention() honored")
        + (
            String(" (RETAIN_KEEP override IN FORCE: ")
            + String(len(retained))
            + String(" RETAINED node(s) deleted, each logged above)")
            if force_delete_data
            else String("")
        )
        + (
            String(", ")
            + String(len(undeletable))
            + String(" UNDELETABLE node(s) skipped (see above)")
            if len(undeletable) > 0
            else String("")
        )
        + String(" [env: ")
        + env_binding.name
        + String("]")
    )
    reporter.finish(summary)
    return DeployDestroyOutcome(
        env_binding.name.copy(), n, force_delete_data
    )
