# =============================================================================
# komira_placement/placement_types.mojo — the PLACEMENT-NEUTRAL spec/status
# the PodManager seam speaks.
# =============================================================================
#
# The PodManager seam's currency is not the k8s-pod-shaped `PodCreateSpec` /
# `PodPhase` (komira_k8s) but a PLACEMENT-NEUTRAL pair:
#
#   PlacementSpec    — WHAT to run, backend-agnostic: a named, namespaced
#                      deployment unit holding ONE OR MORE containers
#                      (co-located servers share one pod/box), a
#                      served-endpoint/ports surface, and labels. A conformer
#                      is "given a PlacementSpec, place it" whether the backend
#                      is a k8s pod, a local process, or a VM supervisor.
#   PlacementStatus  — the OBSERVED state of a placed unit, backend-agnostic:
#                      a `phase` tag (the PLACE_* lifecycle the reconciler
#                      matches on — 1:1 with the POD_* tags), an optional
#                      exit_code / message / raw for diagnostics, plus a
#                      placement-neutral `endpoint` (the served host:port once
#                      known) and `health`.
#
# WHY HERE, NOT komira_k8s: komira_k8s is GENUINELY k8s-specific
# (PodCreateSpec/PodPhase are its public surface, used by K8sPodClient
# directly). The neutral types belong with the seam so a VM conformer — which
# does NOT depend on komira_k8s's client — can speak them without pulling in
# k8s placement logic. The lossless conversions to/from the k8s currency live
# here too, so the k8s conformer is a thin adapter.
#
# LOSSLESS: the PLACE_* tags are numerically identical to the POD_* tags, and
# the round-trip PodCreateSpec <-> PlacementSpec / PodPhase <-> PlacementStatus
# is lossless for every field the seam actually uses.
#
# ENCAPSULATION + gap6: ordinary control-plane value structs (not stored in any
# byte-slab). Plain owned fields — String / Int / Optional / List of owned
# structs (ContainerSpec / EnvVar / KeyValue / PortSpec). No UnsafePointer, no
# wildcard origin. Every struct is Copyable + Movable (matching PodCreateSpec /
# PodPhase, which the seam moves + copies freely).
# =============================================================================

from komira_placement.compute_target import ComputeTarget
from komira_placement.heartbeat_credential import HeartbeatCredential
from komira_k8s.k8s_types import (
    PodCreateSpec,
    PodPhase,
    EnvVar,
    KeyValue,
    POD_PENDING,
    POD_RUNNING,
    POD_SUCCEEDED,
    POD_FAILED,
    POD_NOTFOUND,
    POD_UNKNOWN,
)


# -----------------------------------------------------------------------------
# PLACE_* — the placement-neutral lifecycle tags. NUMERICALLY IDENTICAL to the
# POD_* tags (komira_k8s) so the reconciler's `tag == PLACE_SUCCEEDED` style
# matching is unchanged and the PodPhase <-> PlacementStatus round-trip is the
# identity on the tag field. Kept as separate aliases (not re-exported POD_*) so
# the seam's vocabulary is placement-neutral at the source level, but the VALUES
# are pinned equal by a round-trip test.
# -----------------------------------------------------------------------------
comptime PLACE_PENDING: Int = POD_PENDING  # 0 — accepted, not yet running
comptime PLACE_RUNNING: Int = POD_RUNNING  # 1 — at least one container live
comptime PLACE_SUCCEEDED: Int = POD_SUCCEEDED  # 2 — clean terminal exit
comptime PLACE_FAILED: Int = POD_FAILED  # 3 — terminal non-zero / crash
comptime PLACE_NOTFOUND: Int = POD_NOTFOUND  # 4 — no such unit (deleted/evicted)
comptime PLACE_UNKNOWN: Int = POD_UNKNOWN  # 5 — indeterminate
comptime PLACE_PREEMPTED: Int = 6  # terminal — the INFRASTRUCTURE took it back
"""★★ THE ONE TAG WITH NO `POD_*` COUNTERPART, AND THE ONLY ONE THAT IS NOT A
STATEMENT ABOUT THE WORKLOAD.

Every other tag answers "what did the customer's code do". This one answers "we
took the machine away" — reclaimed interruptible capacity, a drained node, a
spot interruption. It is TERMINAL and it is a FAILURE OF THE PLACEMENT, not of
the job.

⛔⛔ IT EXISTS BECAUSE THE ALTERNATIVE IS A WRONG ANSWER, NOT A MISSING ONE.
Reclaimed capacity SIGKILLs the container, so the placement reaches a terminal
state carrying exit code 137 — or none at all — which is byte-for-byte what a
crash and a failed start look like. Folded into `PLACE_FAILED` it is reported to
the customer as THEIR code breaking, and the misreport scales exactly with how
much interruptible capacity we place on.

⛔ IT IS 6, NOT A `POD_*` ALIAS, AND THAT ASYMMETRY IS DELIBERATE. The other six
tags are pinned numerically equal to `komira_k8s`'s `POD_*` so the
`PodPhase <-> PlacementStatus` round-trip is the identity; kubernetes has no
preemption phase to mirror (an evicted pod is `Failed` with a reason), so a
`POD_PREEMPTED` would be an invention on the k8s side rather than a mapping. The
round-trip therefore does NOT carry this tag, and a k8s conformer can never
produce it.

⚠ EVERY EXISTING CONSUMER TREATS IT EXACTLY AS `PLACE_FAILED` TODAY, differing
only in the MESSAGE. That is on purpose: this change makes the reason
DISTINGUISHABLE, and deciding that a preempted job should be re-placed is a
POLICY change (this library performs no automatic retries) that belongs to
whoever makes it — not smuggled in under a vocabulary edit. What this buys today
is that such a policy now has one thing to key on."""


# -----------------------------------------------------------------------------
# The `Job.placement` string-enum values (proto `placement`, default 'VM'). The
# scheduler branches on these to pick the spec builder: SERVERLESS / CLOUD_RUN ->
# a Cloud Run deploy spec; everything else (VM / POD / LOCAL) -> the generic
# agent pod spec. The two SERVERLESS spellings are accepted equivalently
# (CLOUD_RUN is the explicit alias).
# -----------------------------------------------------------------------------
comptime PLACEMENT_VM: StaticString = "VM"
comptime PLACEMENT_POD: StaticString = "POD"
comptime PLACEMENT_LOCAL: StaticString = "LOCAL"
comptime PLACEMENT_SERVERLESS: StaticString = "SERVERLESS"
comptime PLACEMENT_CLOUD_RUN: StaticString = "CLOUD_RUN"


@always_inline
def is_serverless_placement(placement: String) -> Bool:
    """True iff `placement` routes to the Cloud Run serverless deploy path
    (SERVERLESS or its CLOUD_RUN alias). Everything else (VM / POD / LOCAL / any
    unknown) routes to the generic agent pod spec — a fail-safe default that keeps
    rows carrying the default 'VM' on the generic path."""
    return (
        placement == String(PLACEMENT_SERVERLESS)
        or placement == String(PLACEMENT_CLOUD_RUN)
    )


# -----------------------------------------------------------------------------
# reconciler_owns_placement — ⛔ THE `jobs` TABLE MAY BE SHARED, AND THE
#   RECONCILER'S TWO SCANS ARE UNSCOPED. Read this before touching either.
# -----------------------------------------------------------------------------
#
# ⛔ WHY A SCOPE IS NEEDED. Another control-plane process may open the **same**
# database and mint `jobs` rows that it runs IN-PROCESS: it drives the row
# terminal ITSELF, and there is NO pod — the row's `pod_name` is its own
# hyphenated id and its `placement` is `LOCAL`.
#
# Minting such a row ALREADY ASSIGNED keeps the job manager's claim scan off it,
# but moves it straight into the other unscoped scan. The reconciler's PHASE 1
# is `find_stale_jobs`, whose group 1 is
#
#     phase == ASSIGNED  AND  updated_at < now - startup_timeout (120 s)
#
# with NO predicate on placement, pod ownership or origin, and whose premise is
# *"never booted"*. An in-process action can routinely run LONGER than 120 s,
# so an unscoped job manager adopts the other process's STILL-IN-FLIGHT row,
# CASes it ASSIGNED -> RECONCILING, and then can never resolve it: PHASE 2 polls
# for a pod THIS job manager never created, gets a non-terminal answer, and
# LEAVES IT IN RECONCILING — forever.
#
# ⭐⭐ AND AN IMMORTAL ROW IS NOT INERT, IT IS THE RING. PHASE 2's unit is a cloud
# round-trip (~5-10 s) against a wall budget checked BETWEEN units, so the sweep
# can do as little as ONE job per pass ("at least one unit per phase"), and the
# ring cycle over N immortal rows is then N x the serve loop's period. Every
# real job's completion waits behind that ring: the observation latency of a
# short build grows with the number of foreign rows, not with the build.
#
# ── THE PREDICATE, AND WHY IT FAILS SAFE TOWARDS ADOPTION ────────────────────
#
# The job manager's scheduler is the ONLY writer of a row it placed, and it
# stamps the `pod_name` as `<prefix>-<id8>-<rand4>` from its configured
# `pod_name_prefix`. That prefix is ALREADY the ownership marker cloud reap
# sweeps use to name the job manager's units (`komira_aws_reap`'s task-definition
# sweep, for one).
#
# ⚠ BUT "a prefix is never the safety property" when it gates a DELETE. Here it
# gates an ADOPTION, so the directions are opposite and this one is arranged to
# fail towards adopting: it answers True (adopt) for every case it cannot
# positively prove foreign.
#
#   * an EMPTY prefix -> True. No ownership claim can be made, so nothing is
#     narrowed. (This is the inverse of a destructive sweep's empty-prefix
#     guard, which answers False because a destructive sweep must not widen.)
#   * an EMPTY / absent `pod_name` -> True. "A job that never got a pod" is the
#     job manager's OWN terminal case (PHASE 2 fails it, "no pod was ever
#     assigned"); excluding it would strand it instead.
#   * `pod_name` carries the prefix -> True. This job manager's claim minted it —
#     including a claim minted by a PRIOR instance, which is the whole point of
#     the crash-recovery sweep (the prefix is CONFIG, not per-process).
#   * otherwise -> False. POSITIVELY FOREIGN: some other writer put this row here
#     with an address this job manager's `PodManager` cannot resolve.
#
# ⛔ IT IS A SCOPE, NOT A TERMINAL VERDICT. A foreign row is SKIPPED, never failed
# and never deleted — declaring another process's in-flight job dead is the wrong
# answer, not a stricter one. A foreign row already stuck in RECONCILING stays
# there, inert, and leaves the ring; whoever owns it is the only party that can
# resolve it.
# -----------------------------------------------------------------------------
@always_inline
def reconciler_owns_placement(pod_name: String, pod_name_prefix: String) -> Bool:
    """True iff the job manager's reconciler may adopt / poll the row carrying
    `pod_name` — i.e. unless it can be PROVEN to have been placed by some other
    writer. See the block above for each arm and why the unknown case adopts."""
    if pod_name_prefix.byte_length() == 0:
        return True
    if pod_name.byte_length() == 0:
        return True
    return pod_name.startswith(pod_name_prefix)


# -----------------------------------------------------------------------------
# reconcile_scan_blinded — ⛔ WHAT PUTTING `reconciler_owns_placement` ON THE
#   CLIENT SIDE OF A SERVER-SIDE `LIMIT` COSTS.
# -----------------------------------------------------------------------------
#
# ⛔ THE INVARIANT THE SCOPE GATE ABOVE BREAKS. A server-side `LIMIT` is sound on
# the reconcile-driving scans only *because the predicate that SELECTS the rows
# is also server-side*: under a CLIENT-side filter the LIMIT fills with rows the
# filter drops and the rows you actually wanted are starved out of the reply.
# `reconciler_owns_placement` IS such a filter and it DOES drop rows — so that
# precondition is FALSE for some of the scans, and the failure is the SAME CLASS
# as the one the scope gate exists to fix: a scan that silently stops finding
# the work.
#
#   * PHASE 2 (`find_jobs_by_phase(RECONCILING)`) SURVIVES IT. The ring walks
#     every row IN the reply, so a declined row costs a position, never a visit.
#   * ⛔ PHASE 1 (`find_stale_jobs`) DOES NOT. Without an `ORDER BY` (adding one
#     can demand a new composite index on a live collection), a document store
#     such as Firestore answers in `__name__` order, which for a UUIDv7 id is
#     OLDEST FIRST. Once more than `row_limit` undrained foreign rows exist, a
#     NEWER row of THIS job manager's own is not in the reply AT ALL — and a ring
#     cursor cannot fix EXCLUSION FROM a reply, only unfairness WITHIN one. The
#     crash-recovery sweep PHASE 1 exists for then goes dark with nothing
#     anywhere going red.
#
# ⚠ AND THE POPULATION THAT FILLS THAT WINDOW IS THE ONE THIS GATE CREATES.
# Without the gate the job manager DRAINS group 1 by (destructively) adopting
# every abandoned foreign in-process row; with it nothing replaces that drain,
# so a foreign writer that never reaps its own rows lets them accumulate in
# ASSIGNED, and a bounded window fills in proportion to how fast that writer
# produces them.
#
# ── THE ALTERNATIVE — PUSH THE PREDICATE SERVER-SIDE — AND WHY IT IS NOT A
#    DROP-IN AT THIS CALL SITE ────────────────────────────────────────────────
#
# The durable fix is to carry the ownership predicate into the store's filter so
# the LIMIT is only ever spent on candidate rows. That is a separate change, not
# one this gate can make inline:
#
#   1. IT IS A PREFIX MATCH, SO IT IS A SECOND INEQUALITY FIELD. A neutral
#      predicate vocabulary without `startswith` renders a prefix as
#      `pod_name >= p AND pod_name < succ(p)`, ALONGSIDE group 1's existing
#      `updated_at < cutoff`. Firestore serves inequalities on two fields only
#      from a composite index naming both, so the store needs an index carrying
#      `pod_name`.
#   2. THE PREDICATE IS A THREE-ARM **OR**, AND A FLAT filter CANNOT RENDER ONE.
#      `find_stale_jobs` already pays TWO queries to express a single OR;
#      `(prefix range) OR (pod_name absent) OR (no prefix configured)` turns each
#      AND-group into three, each with its own LIMIT, its own index and its own
#      share of the dedup.
#   3. ⛔ AND THE FAIL-SAFE DIRECTION INVERTS WHEN THE FILTER MOVES. The arm that
#      keeps THIS gate safe is "an EMPTY / ABSENT `pod_name` is adopted" — the
#      job manager's OWN never-booted row, which is precisely what PHASE 1 is
#      for. Firestore's `IS NULL` matches an explicitly-null field and NOT an
#      absent one, so a naive server-side range would SILENTLY EXCLUDE that row:
#      the client filter fails towards adopting, the server filter would fail
#      towards stranding. Pushing it down before settling that is a WORSE defect
#      than the one it closes.
#
# Points 1 and 3 rest on Firestore's documented semantics (a two-field
# inequality needs a composite index naming both fields; `IS NULL` does not
# match an ABSENT field). Both are checkable in one query against a scratch
# database — check them before treating this block as the reason the
# server-side form is impossible.
#
# ── SO THE TRUNCATION IS MADE LOUD INSTEAD ───────────────────────────────────
#
# This predicate names the exact blinding condition — a reply the server-side
# LIMIT bound **and** from which the client-side scope gate then dropped a row —
# so the reconcile pass can log it at ERROR and a falsifier can assert on it.
# ⛔ IT IS NOT A REMEDY. It is the difference between a sweep that stopped
# working and a sweep that stopped working SILENTLY.
#
# ⚠ NEITHER HALF ALONE IS THE CONDITION, DELIBERATELY. `declined > 0` alone is
# the gate WORKING, and alarming on it would train a reader to ignore the line;
# `returned >= limit` alone is the ordinary cardinality bound a bounded scan
# accepts. Only their conjunction can hide a row this job manager owns.
#
# ⚠ CALL IT PER **AND-GROUP**, NEVER OVER A UNION. `find_stale_jobs` LIMITs each
# of its two groups independently and returns their UNION, so a union size
# compared against one group's limit is wrong in both directions (it fires when
# two un-truncated groups merely sum past the bound). The groups are separable by
# their own predicates — group 1 is `phase == ASSIGNED`, group 2 is
# `phase == RUNNING`, disjoint by construction — so the caller splits the reply
# before calling this.
#
# ⚠ AND COUNT `declined` OVER THE WHOLE REPLY, NOT OVER THE ROWS THE PASS GOT TO.
# The reconcile pass breaks on its wall budget, so an in-loop tally undercounts
# exactly when the backlog is large — i.e. precisely in the case the alarm exists
# for. Compute it in a separate in-memory pre-pass (byte-prefix compares; no
# cloud call, no CAS) before the ring runs.
# -----------------------------------------------------------------------------
@always_inline
def reconcile_scan_blinded(
    returned: Int, declined: Int, row_limit: UInt32
) -> Bool:
    """True iff this scan's reply may be HIDING rows the reconciler owns: the
    server-side `LIMIT` bound the reply AND the client-side scope gate then
    dropped at least one row from it, so a row that IS this job manager's may
    never have been in the reply. `row_limit == 0` is UNBOUNDED (the harness
    spelling) — no LIMIT can bind, so the answer is False. See the block above
    for why neither half alone is the condition and why it is called per
    AND-group."""
    if row_limit == UInt32(0):
        return False
    if declined <= 0:
        return False
    return returned >= Int(row_limit)


# -----------------------------------------------------------------------------
# PortSpec — one served port a container exposes (the served-endpoint surface).
# An INFINITE job that serves an endpoint (→ app) carries one or more of these;
# a finite batch job carries none. Backend-neutral: a k8s pod renders it as a
# containerPort, a VM supervisor as a firewall/listen port.
# -----------------------------------------------------------------------------
@fieldwise_init
struct PortSpec(Copyable, Movable):
    """A served container port. `name` is the optional symbolic name (e.g.
    "http"), `container_port` the port the process listens on. `PlacementSpec`
    carries the union of served ports across its containers (the served-endpoint
    surface an endpoint registry reads)."""

    var name: String
    var container_port: Int


# -----------------------------------------------------------------------------
# ContainerSpec — ONE container within a placement unit. Multi-container (the
# co-location requirement: co-located servers are containers in one pod) is a
# `List[ContainerSpec]` on the PlacementSpec. Mirrors the per-container
# slice of a k8s PodSpec container (name / image / command / args / env /
# resources / ports) without any k8s typing.
# -----------------------------------------------------------------------------
struct ContainerSpec(Copyable, Movable):
    """One container in a placement unit. `name` identifies it within the unit
    (e.g. "supervisor", "postgres"); `image` is the container image; `command`
    is the optional entrypoint override (empty => image default); `args` the
    container args; `env` the container environment; `cpu`/`memory` the resource
    request==limit (empty => omit); `ports` the served ports this container
    exposes. Plain owned fields (gap6-clean — no byte-slab, no wildcard)."""

    var name: String
    var image: String
    var command: List[String]  # entrypoint override ("" via empty list = default)
    var args: List[String]
    var env: List[EnvVar]
    var cpu: String  # Quantity, e.g. "256m" ("" => omit)
    var memory: String  # Quantity, e.g. "512Mi" ("" => omit)
    var ports: List[PortSpec]
    # The ABSTRACT accelerator TIER this container requests — an ORDINAL
    # (0=UNSPECIFIED, 1=NONE, 2=SMALL, 3=LARGE), carried as `Int32` to match the
    # deploy model's `ContainerSpec.accelerator` int32. DEFAULTS to 0
    # (UNSPECIFIED) in every ctor => no accelerator request. NOT yet consumed by
    # any placement backend — mapping the tier to a per-cloud SKU is the
    # applier's job.
    var accelerator: Int32

    def __init__(out self, name: String, image: String):
        """Minimal container — name + image; the rest default empty. Callers
        append command/args/env/ports and set cpu/memory after construction
        (mirrors the PodCreateSpec append-after-construct ergonomics).
        `accelerator` defaults to 0 (tier UNSPECIFIED — no accelerator)."""
        self.name = name
        self.image = image
        self.command = List[String]()
        self.args = List[String]()
        self.env = List[EnvVar]()
        self.cpu = String("")
        self.memory = String("")
        self.ports = List[PortSpec]()
        self.accelerator = Int32(0)


# -----------------------------------------------------------------------------
# VpcEgressSpec — the placement-neutral "WHICH NETWORK does this unit's traffic
# leave through". Backend-neutral in the same sense `max_retries` and
# `task_timeout_s` are: one attribute, rendered per-backend (Cloud Run
# `TaskTemplate.vpc_access.network_interfaces[0]`; a k8s pod is already IN a
# network and needs no equivalent, so the k8s bridge does not carry it).
# -----------------------------------------------------------------------------
struct VpcEgressSpec(Copyable, Movable):
    """A DIRECT VPC EGRESS attachment for one placed unit — a network +
    subnetwork the unit's interface joins, optional network tags, and which
    destinations take that path.

    ⛔ THE ABSENCE OF THIS IS NOT NEUTRAL, WHICH IS THE WHOLE REASON IT EXISTS.
    A Cloud Run unit with no network configuration egresses over the PUBLIC
    INTERNET. It is not "inside" anything, so a service with
    `internal-and-cloud-load-balancing` ingress refuses it AT THE EDGE — before
    the container, before any application code, with Google's own HTML 404. A
    caller that claims "validated FROM INSIDE the VPC" must be able to point at
    this attachment; without it the claim is false, and a refused health gate
    reads as an app defect when it is a network fact.

    ★ SELECTS, NEVER CREATES. Every value here NAMES an existing resource. No
    conformer, composer or apply path provisions a network, a subnetwork, a
    connector, a Cloud Router or a NAT from it — a name that does not resolve
    fails CLOSED at the backend's create call.

    `all_traffic` vs private-ranges-only is the field that decides whether this
    does anything for a `*.run.app` target: a run.app hostname resolves to a
    PUBLIC address, so under private-ranges-only it does not take the VPC path
    and a private-ingress service refuses the caller exactly as before.
    `all_traffic=True` (the constructor default) is the arm that reaches one —
    and it is also the arm that requires the VPC to be able to route to the
    internet at all (Cloud NAT, or Private Google Access for Google endpoints).

    gap6-clean: plain owned Strings + one owned `List[String]`."""

    # The VPC network the interface attaches to — a bare name (`default`) or a
    # full resource URI. EMPTY renders nothing (see `is_configured`).
    var network: String
    # The subnetwork, IN THE UNIT'S OWN REGION (Direct VPC egress is region-
    # coupled). EMPTY renders nothing.
    var subnetwork: String
    # Network tags on the interface — what selector firewall rules match.
    var network_tags: List[String]
    # True  => ALL traffic (run.app included) leaves through the VPC.
    # False => only RFC-1918 destinations do; public egress stays direct.
    var all_traffic: Bool

    def __init__(
        out self,
        network: String,
        subnetwork: String,
        all_traffic: Bool = True,
    ):
        """Attach to `network`/`subnetwork` with no tags. `all_traffic` defaults
        TRUE because the reason a placed unit asks for VPC egress at all is to
        reach something the public path refuses, and a `*.run.app` target is
        only carried by the ALL_TRAFFIC arm."""
        self.network = network
        self.subnetwork = subnetwork
        self.network_tags = List[String]()
        self.all_traffic = all_traffic

    def is_configured(self) -> Bool:
        """True iff this attachment names BOTH a network and a subnetwork — the
        only shape a backend accepts. A half-filled value is not a partial
        attachment, it is a rejected create; callers render nothing when this is
        False rather than emitting an interface the backend refuses."""
        return self.network.byte_length() > 0 and self.subnetwork.byte_length() > 0


# -----------------------------------------------------------------------------
# PlacementSpec — the placement-neutral "WHAT to run". A named, namespaced unit
# of ONE OR MORE containers, with labels. The seam's create verb takes this.
# -----------------------------------------------------------------------------
struct PlacementSpec(Copyable, Movable):
    """The placement-neutral deployment unit. `name` + `namespace` are the
    placement handle (a k8s pod uses (namespace, name); a VM supervisor uses
    `name` as the instance name + `namespace` as a grouping/project label; a
    local process uses `name` as the recorded key). `containers` is the
    multi-container body (co-location — at least one). `labels` are the
    unit-level metadata (pod<->job correlation).

    SINGLE-CONTAINER round-trip: a PodCreateSpec (one implicit `supervisor`
    container) maps to a PlacementSpec with exactly one ContainerSpec, and back,
    losslessly. MULTI-CONTAINER: append additional ContainerSpecs for the
    co-located servers; `to_pod_spec()` then renders the FIRST (supervisor)
    container as the PodCreateSpec body and is documented to drop the extra
    containers (the single-container k8s currency cannot express them —
    multi-container placement is rendered natively by the backend that
    supports it, never via the PodCreateSpec bridge).

    MULTI-TENANT MINT: `account_ref` is the per-Job customer cloud account ref
    (the `cloudConnectionId`, a NAME never a secret) the scheduler stamps from
    `Job.account_ref` for a SERVERLESS placement. The Cloud Run placement
    conformer resolves it LIVE to the row's WIF handle NAMES and mints a
    per-Job runtime-SA token from THAT handle — so one multi-tenant regional
    job manager serves N customers with a per-Job (per-customer) credential,
    never a single fixed handle. Empty for non-serverless / single-tenant
    placements (the conformer then falls back to its own held handle). Plain
    owned String (gap6-clean — no pointer; only the NAME flows, the token lives
    in the verb frame)."""

    var name: String
    var namespace: String
    var containers: List[ContainerSpec]
    var labels: List[KeyValue]
    # The per-Job customer cloud account ref (the cloudConnectionId; a NAME, never
    # a secret). The serverless placement conformer resolves it to the WIF handle
    # and mints per-Job. Empty => no per-Job credential (single-tenant fallback).
    var account_ref: String
    # The per-task retry budget for a run-to-completion unit (a backend-neutral
    # attribute: Cloud Run's `TaskTemplate.max_retries`, k8s Job's `backoffLimit`).
    # `None` => let the backend apply its default (Cloud Run 3). `Some(0)` => a
    # SINGLE-SHOT unit that terminalizes FAILED on the first failing attempt — a
    # validation GATE wants an immediate verdict, not N retries. The Cloud Run
    # placement path threads it onto the CrJob; the k8s single-container bridge does
    # NOT carry it (defaults None — validate jobs are Cloud Run only).
    var max_retries: Optional[Int]
    # The per-ATTEMPT wall deadline for a run-to-completion unit, in SECONDS (a
    # backend-neutral attribute: Cloud Run's `TaskTemplate.timeout`, k8s Job's
    # `activeDeadlineSeconds`). `None` => let the backend apply its default, which
    # for Cloud Run Jobs is 600s. `Some(n)` => the task is SIGKILLed after n
    # seconds.
    #
    # ★ WHY A GATE MUST SET THIS. A validate job that outlives the backend default
    # is killed MID-RUN — and a SIGKILL runs no in-process cleanup, so the step
    # leaves behind whatever it had already created and reports a bare non-zero
    # exit with no rows and no `VERDICT:` line. That failure is indistinguishable
    # in the report from a product defect. The deadline therefore has to come from
    # the STEP'S OWN DECLARED NEED, never from a constant picked here — see
    # the validate job spec builder in `komira_gcp_bridge`, which reads it off
    # the step's rendered env so the SAME authored number both bounds the Job
    # and is readable by the container that must fit inside it.
    #
    # ⛔⛔ A PLACEMENT PATH THAT DOES NOT WRITE THIS STARVES BOTH VM CONFORMERS.
    # Without it `GcpCloudProvider` renders no `Scheduling.max_run_duration` and
    # the EC2 arm exports an EMPTY `KOMIRA_TASK_TIMEOUT_S`: uncapped at BOTH
    # altitudes on BOTH clouds. The remedy is a derivation over
    # `DEFAULT_JOB_BOUNDED_TASK_TIMEOUT_S` (below) applied by the job manager,
    # which is the only altitude that can tell a finite job from a streaming
    # one.
    var task_timeout_s: Optional[Int]
    # The DIRECT VPC EGRESS attachment for this unit (Cloud Run's
    # `TaskTemplate.vpc_access.network_interfaces[0]`). `None` => NO network
    # configuration on the wire, which for Cloud Run means the unit egresses over
    # the PUBLIC INTERNET.
    #
    # ★ THE ABSENT CASE IS A REACHABILITY FACT, NOT A NEUTRAL DEFAULT. A unit with
    # no attachment cannot reach a Cloud Run service whose ingress is
    # `internal-and-cloud-load-balancing`: the edge refuses it before the
    # container. Anything asserting in-VPC reach must point AT a `Some(...)`
    # here.
    #
    # ⛔ SELECTS, NEVER CREATES — see `VpcEgressSpec`. Setting it provisions no
    # network, subnet, connector, router or NAT; an unresolvable name fails closed
    # at the backend create.
    var vpc_egress: Optional[VpcEgressSpec]
    # ★★ WHICH CAPACITY CLASS THIS UNIT RUNS ON — a `CAPACITY_*` ordinal.
    # Defaults to `CAPACITY_UNSPECIFIED` (0): no conformer that does not read it
    # changes behaviour, and the ones that do read it REFUSE the unspecified
    # value rather than guessing.
    #
    # ⛔⛔ IT IS **PER-PLACEMENT** AND MAY NOT BE CONSTRUCTION STATE ON THE
    # CONFORMER. That is the whole reason this field exists. Both VM capacity
    # classes route to ONE executor (one conformer places both), so **NEITHER
    # construction-time default is safe**:
    #
    #   built interruptible -> an on-demand job lands on RECLAIMABLE capacity and
    #     can be killed by the cloud at any moment, reported as its own failure.
    #   built on-demand     -> an interruptible job runs at several times the
    #     price the operator asked to pay, with nothing about the run saying so.
    #
    # ⛔ AND `CAPACITY_UNSPECIFIED` IS NOT "ON-DEMAND". The two possible readings
    # of an unset value are exactly the two failures above, so a conformer that
    # can select capacity REFUSES it — naming the placement — rather than
    # picking. A conformer that CANNOT select capacity (the k8s bridge, the local
    # process manager) ignores the field entirely, which is correct: there is no
    # capacity axis to get wrong.
    #
    # ⚠ NOT CARRIED BY THE k8s `PodCreateSpec` ROUND-TRIP. `PodCreateSpec` has no
    # representation for it, and inventing one would make the round-trip lossy in
    # the direction of manufacturing an answer.
    var capacity: Int
    # ★★ WHAT COMPUTE SHAPE THIS UNIT WAS ASKED FOR — a `COMPUTE_TYPE_*` ordinal
    # (see the block beside `CAPACITY_*` below for the whole design). Defaults to
    # `COMPUTE_TYPE_UNSPECIFIED` (0), so a placement that does not set it is
    # unaffected.
    #
    # ⛔ IT IS THE **STATEMENT**, NOT THE ROUTE. By the time a conformer holds
    # this spec the routing decision is already made — a VM conformer got this
    # spec BECAUSE the compute type said VM — so no conformer branches on it to
    # decide what to place. It is carried so that (a) the spec is self-describing
    # for a refusal / log line that must name what the operator asked for, and
    # (b) a conformer that CANNOT serve the shape it was handed can say so by
    # name instead of placing something else. Anything that branches on this to
    # SELECT a backend is re-implementing the job manager's backend router in a
    # second place, which is the drift this field exists to end.
    #
    # ⚠ NOT CARRIED BY THE k8s `PodCreateSpec` ROUND-TRIP, for the same reason
    # `capacity` is not: `PodCreateSpec` has no representation for it and
    # inventing one would make the round-trip lossy in the direction of
    # manufacturing an answer.
    var compute_type: Int
    # ★★ WHICH VALIDATION RUN CREATED THIS UNIT — the value stamped under the
    # validation-run tag key as an AWS resource TAG / a GCP resource LABEL by
    # whichever conformer places it. EMPTY => nothing is stamped.
    #
    # ⛔ IT IS THE ONE FACT AN UNATTENDED AUTO-DELETE IS ALLOWED TO ACT ON. A
    # leak-cleanup run that finds an execution with a `startTime` and no
    # `completionTime` is right that it is burning money, and still must not
    # delete a CONCURRENT run's in-flight execution. The missing fact is
    # **whose it is**: a cleanup classifies each billing finding OWN / FOREIGN /
    # UNATTRIBUTED against this value and deletes only OWN.
    #
    # ⛔⛔ IT IS **NOT** `labels`, AND THE TWO MAY NOT BE MERGED. `labels` is
    # server-set precisely because it carries the pod<->job correlation the
    # reconciler matches on, derived from the job id — a caller-supplied entry
    # there could FORGE that correlation. This field forges nothing: it is not a
    # secret, not an authorization and not a namespace, so the two have opposite
    # trust postures and one field cannot hold both.
    #
    # ⚠ PER-RUN, NEVER PER-STEP, NEVER PER-PLACEMENT. The same id is threaded to
    # every unit one validation run creates AND to that run's terminal leak
    # check; an id minted here per placement would be unknowable to the check
    # that has to name it later, which is the whole capability.
    #
    # ⚠ NOT CARRIED BY THE k8s `PodCreateSpec` ROUND-TRIP — `PodCreateSpec` has
    # no representation for it, for the reason `capacity` and `compute_type`
    # state one field up.
    var validation_run_id: String
    # ★★ THE JOB ROW'S OWN ID — its canonical hyphenated UUID text, the value a
    # placed unit's supervisor must stamp on every heartbeat. EMPTY for a
    # placement made on behalf of no job row (a test, a deploy-plane unit).
    #
    # ⛔⛔ IT IS **NOT** `name`, AND CONFUSING THE TWO IS THE DEFECT THIS FIELD
    # PREVENTS. `name` is the PLACEMENT HANDLE — `<pod_name_prefix>-<12 hex>` —
    # and a VM conformer that stamped it as the job id (`GcpCloudProvider.create`
    # -> `META_JOB_ID`, the EC2 boot script -> `KOMIRA_JOB_ID`) would have every
    # beat refused 400 `bad_request` before the FSM is consulted, because the job
    # manager decodes the beat's `job_id` as a hyphenated UUID. See
    # `heartbeat_identity` for the check.
    #
    # ⚠ THE NAME IS NOT INVERTIBLE, which is why this is a field rather than a
    # derivation: the placement name keeps only the id's last 12 hex characters,
    # so the job id cannot be recovered from it. It has to be CARRIED.
    #
    # ⚠ NOT CARRIED BY THE k8s `PodCreateSpec` ROUND-TRIP — the k8s currency
    # carries the id as the job-id LABEL and as the agent's `--job-id` argv; the
    # job manager stamps this field for every placement regardless of which
    # builder rendered the spec.
    var job_id: String
    # ★★ WHERE A JOB-VM PLACEMENT LANDS — the customer project / zone /
    # subnetwork / runtime SA, RESOLVED from the `compute-env/<env>` record.
    # ABSENT => every conformer places where its construction state says.
    #
    # See `ComputeTarget` for why it is resolved and never authored, and why it
    # is NOT the teardown address.
    #
    # ⚠ NOT CARRIED BY THE k8s `PodCreateSpec` ROUND-TRIP — the k8s currency has
    # no customer-project axis, for the reason `capacity` states above.
    var compute_target: Optional[ComputeTarget]
    # ★★ THE PER-JOB HEARTBEAT CREDENTIAL, IN CLEARTEXT, TRANSIENT. The job
    # manager mints it, CAS-writes only its sha256 to the row
    # (`Job.heartbeat_credential_hash`), and hands the cleartext to the
    # conformer through THIS field so `create` can stamp it into the VM's GCE
    # metadata item `komira-heartbeat-token`. EMPTY => no credential.
    #
    # ⛔⛔ A SECRET. It is never logged, never rendered into an error, never put
    # on argv or in container env, and never persisted anywhere but the VM's
    # metadata. A `create` that fails must not echo it. This struct is
    # `Copyable` for the placement pipeline's own reasons; no copy of it may
    # outlive the placement call.
    #
    # ★ THE COMPILER HOLDS THE NO-PRINT HALF: `HeartbeatCredential` is not
    # `Writable` (Mojo 1.0's one formatting trait), so printing it or
    # formatting it into an error is a compile error, and its one read is the
    # named `cleartext_for_metadata_stamp()`.
    #
    # ⚠ NOT CARRIED BY THE k8s `PodCreateSpec` ROUND-TRIP.
    var heartbeat_credential: HeartbeatCredential

    def __init__(out self, name: String, namespace: String):
        """An EMPTY unit — name + namespace; no containers yet. Callers append
        ContainerSpecs + labels. A well-formed spec has >= 1 container.
        `max_retries` defaults to None (the backend's default retry budget),
        `task_timeout_s` to None (the backend's default task deadline), and
        `vpc_egress` to None (NO network configuration — for Cloud Run, egress
        over the public internet, which cannot reach a private-ingress peer)."""
        self.name = name
        self.namespace = namespace
        self.containers = List[ContainerSpec]()
        self.labels = List[KeyValue]()
        self.account_ref = String("")
        self.max_retries = None
        self.task_timeout_s = None
        self.vpc_egress = None
        self.capacity = CAPACITY_UNSPECIFIED
        self.compute_type = COMPUTE_TYPE_UNSPECIFIED
        # EMPTY => no ownership tag on the wire => a leak-cleanup run classifies
        # the resulting resource UNATTRIBUTED and HOLDS the delete. That is the
        # safe direction and it is the default on purpose: a placement nobody
        # said anything about must never be auto-deleted by a run that cannot
        # prove it made it.
        self.validation_run_id = String("")
        # EMPTY => no job row. A conformer whose placed unit HEARTBEATS REFUSES
        # it (`heartbeat_identity.heartbeat_job_id_for`) rather than stamping
        # something else.
        self.job_id = String("")
        # ABSENT => place where the conformer's construction state says.
        self.compute_target = None
        # EMPTY => no credential.
        self.heartbeat_credential = HeartbeatCredential()

    def container_count(self) -> Int:
        """How many containers this unit places. >= 2 means the multi-container
        co-location shape (a supervisor + co-located servers)."""
        return len(self.containers)

    def served_ports(self) -> List[PortSpec]:
        """The UNION of served ports across all containers — the served-endpoint
        surface (the ports an INFINITE app job exposes). Empty for a finite
        batch job. An endpoint registry reads this."""
        var out = List[PortSpec]()
        for i in range(len(self.containers)):
            for j in range(len(self.containers[i].ports)):
                out.append(self.containers[i].ports[j].copy())
        return out^

    # ---- lossless bridge to/from the k8s-pod currency (komira_k8s) ----

    @staticmethod
    def from_pod_spec(spec: PodCreateSpec) -> PlacementSpec:
        """Lift a k8s `PodCreateSpec` (the single implicit `supervisor`
        container) into the placement-neutral shape. The pod's image/args/env/
        cpu/memory become the ONE container; the pod's name/namespace/labels
        become the unit's. Lossless — `to_pod_spec()` reconstructs the original
        PodCreateSpec byte-for-byte (the round-trip contract)."""
        var ps = PlacementSpec(spec.name, spec.namespace)
        var c = ContainerSpec(String("supervisor"), spec.image)
        for i in range(len(spec.args)):
            c.args.append(spec.args[i])
        for i in range(len(spec.env)):
            c.env.append(spec.env[i].copy())
        c.cpu = spec.cpu
        c.memory = spec.memory
        ps.containers.append(c^)
        for i in range(len(spec.labels)):
            ps.labels.append(spec.labels[i].copy())
        return ps^

    def to_pod_spec(self) -> PodCreateSpec:
        """Lower this unit back to a k8s `PodCreateSpec` — the inverse of
        `from_pod_spec`. Uses the FIRST container as the pod body (the k8s
        single-container currency). EXTRA containers (the multi-container
        case) are NOT expressible in a PodCreateSpec and are dropped here BY
        DESIGN — the multi-container k8s rendering is the native conformer's job
        (a k8s Pod with N containers), never this single-container bridge. For
        the single-container round-trip this is exactly lossless."""
        var image = String("")
        if len(self.containers) > 0:
            image = self.containers[0].image
        var spec = PodCreateSpec(self.name, self.namespace, image)
        if len(self.containers) > 0:
            ref c = self.containers[0]
            for i in range(len(c.args)):
                spec.args.append(c.args[i])
            for i in range(len(c.env)):
                spec.env.append(c.env[i].copy())
            spec.cpu = c.cpu
            spec.memory = c.memory
        for i in range(len(self.labels)):
            spec.labels.append(self.labels[i].copy())
        return spec^


# -----------------------------------------------------------------------------
# PlacementStatus — the placement-neutral "OBSERVED state". The seam's status
# verb returns this. `phase` is a PLACE_* tag (== the POD_* tag space). Adds the
# backend-neutral served `endpoint` (host:port once the unit serves) + `health`.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# CAPACITY_* — WHICH CAPACITY CLASS a placed unit runs on. A backend-neutral
# per-unit attribute in exactly the sense `max_retries` / `task_timeout_s` /
# `vpc_egress` are: one value, rendered per-backend by whichever conformer can
# express it (ECS `capacityProviderStrategy: FARGATE_SPOT`; EC2
# `InstanceMarketOptions.MarketType=spot`; GCE
# `scheduling.provisioningModel: SPOT`).
# -----------------------------------------------------------------------------
comptime CAPACITY_UNSPECIFIED: Int = 0
"""The placement did not say. ⛔ THIS IS NOT "ON-DEMAND" AND A CONFORMER MUST NOT
READ IT AS ONE — see `PlacementSpec.capacity`."""

comptime CAPACITY_ON_DEMAND: Int = 1
"""Reserved capacity. The cloud does not take it back."""

comptime CAPACITY_INTERRUPTIBLE: Int = 2
"""Reclaimable capacity — Fargate Spot, EC2 Spot, GCE Spot. A large discount, in
exchange for the placement being able to END FOR A REASON THAT IS NOT THE
CUSTOMER'S. Any conformer that can select this MUST also be able to produce
`PLACE_PREEMPTED`; selecting it without the verdict reports every reclaim as the
customer's code failing."""


@always_inline
def capacity_name(capacity: Int) -> StaticString:
    """The capacity ordinal's name, for a refusal message that must state which
    value it saw rather than merely that it was wrong."""
    if capacity == CAPACITY_ON_DEMAND:
        return "ON_DEMAND"
    if capacity == CAPACITY_INTERRUPTIBLE:
        return "INTERRUPTIBLE"
    return "UNSPECIFIED"


# -----------------------------------------------------------------------------
# THE DEFAULT RUN CAP for a JOB-BOUNDED placement — a CEILING ON THE BILL.
# -----------------------------------------------------------------------------
#
# ⛔⛔ IT EXISTS BECAUSE `PlacementSpec.task_timeout_s` IS OPTIONAL, AND A VM
#   CONFORMER THAT IS NEVER HANDED ONE IS UNCAPPED. `GcpCloudProvider.create`
#   renders `Scheduling.max_run_duration` and stamps the in-guest
#   `KOMIRA_TASK_TIMEOUT_S`; `Ec2VmPodManager` exports the same variable. Both
#   read `spec.task_timeout_s`, so a placement path that never writes it leaves
#   every VM it places uncapped at BOTH altitudes, platform and in-guest, on
#   BOTH clouds — and a VM can outlive the job that placed it.
#
# ★ WHY THE NUMBER IS 21600 (6h), AND WHY IT IS NOT AN SLA. This is a CEILING ON
#   THE BILL, not a deadline anyone should ever reach, so it has to sit far above
#   the longest legitimate job-bounded VM run:
#     * the sibling finite backend's own default is 600s (Cloud Run Jobs) and a
#       validate step runs in minutes — 6h is ~36x that, so it cannot plausibly
#       kill real work;
#     * it bounds ONE leaked VM at about a working day instead of forever. At
#       fleet scale the COST IS THE CLASS, not the instance;
#     * it stays well inside GCE's 7-day `maxRunDuration` ceiling, so it is a
#       legal value on every arm rather than one that fails closed on some.
#
# ⛔ IT IS A **DERIVATION** DEFAULT, NOT A FIELD DEFAULT, AND THE DIFFERENCE IS
#   LOAD-BEARING. `PlacementSpec.__init__` leaves `task_timeout_s` None and MUST
#   keep doing so: the field is backend-NEUTRAL, so a non-None default here would
#   silently re-time every Cloud Run Job (whose own backend default is 600s),
#   every k8s `activeDeadlineSeconds` and every ECS task — re-timing three
#   backends to fix two. Only the caller that knows the placement is job-bounded
#   may apply this.
#
# ⛔ AND IT MAY ONLY BE APPLIED TO A **JOB-BOUNDED** PLACEMENT. A SERVICE
#   outlives the job row that placed it, and a deadline invented for one restarts
#   a served app on a timer. Only the job manager, which knows the job's
#   lifetime, can tell them apart; nothing in a CONFORMER can, because
#   `PlacementSpec.served_ports()` is empty for every VM placement and is
#   therefore a vacuous discriminator there.
#
# ⚠ THE READER IS THE CALLER. This file deliberately holds NO config keys and
#   NO `Dict` reads; the job manager's placement-spec derivation applies the
#   default and stamps `task_timeout_s`.
# -----------------------------------------------------------------------------
comptime DEFAULT_JOB_BOUNDED_TASK_TIMEOUT_S: Int = 21600
"""6 hours, in seconds — the default wall cap for a placement whose lifetime IS
its job's. A ceiling on the bill, never a promise about latency.

⚠ OVERRIDABLE AT THREE ALTITUDES, and the most specific wins: per placement (the
job's own declared runtime), per environment (a conformer's construction-time
floor, e.g. `GcpCloudProvider(default_task_timeout_s=...)`), and OFF by an
EXPLICIT zero — which a streaming job must STATE rather than have inferred for
it, because absent and 'deliberately unbounded' are different claims."""


# -----------------------------------------------------------------------------
# COMPUTE_TYPE_* — WHAT COMPUTE SHAPE a job asks to be placed on. THE SELECTOR.
# -----------------------------------------------------------------------------
#
# ⛔⛔ THIS EXISTS BECAUSE A BUILD-BACKEND SELECTOR IS A DIFFERENT QUESTION
#   WEARING THE RIGHT WORDS. A build backend is a BUILD-TRUST ISOLATION POSTURE
#   — "how isolated must this untrusted external build code be" — whose
#   vocabulary is ON_FARM_K8S / CLOUD_RUN_JOB / SPOT_VM / CLOUD_BUILD. It has no
#   `CONTAINER` value and no `VM` value, its `SPOT_VM` member means "the
#   strongest isolation we offer" rather than "reclaimable capacity", and its
#   whole fail-safe cascade is written about TRUST (a trusted build must never
#   strand). Asking it "what shape of compute should this query worker run on"
#   gets an answer to a question nobody asked. So this is a genuine, dedicated
#   field — NOT a rename of the build-trust ordinal, which keeps its own meaning
#   for its own readers.
#
# ★★★ THE VOCABULARY IS THE **DEPLOY PLANE'S**, TOKEN FOR TOKEN. The deploy
#   tool's placement arms carry the cloud-agnostic shapes — `container` /
#   `spot_container` / `vm` / `spot_vm` (+ `serverless_function`, which is a
#   DEPLOY-time shape with no run-time placement analogue: nothing places a
#   Lambda per job). An operator who writes `spot_vm` on a bundle and `SPOT_VM`
#   on a job is saying the same word about the same thing, and that is the
#   whole reason to spell it the same way. The casing differs because these are
#   CONFIG-MAP values whose siblings are `CONTAINER_JOB` / `ON_DEMAND` /
#   `INTERRUPTIBLE`, not command-line tokens.
#
# ★★ HOW THIS RELATES TO `PlacementSpec.capacity` — ONE AUTHORED AXIS, TWO
#   DERIVED FACTS, AND NEITHER IS AUTHORED TWICE.
#
#   The four values are not two orthogonal fields collapsed into one. They are
#   ONE operator statement that DECOMPOSES, totally, into exactly the two facts
#   the two planes below already need:
#
#     compute_type_is_vm(ct)         -> WHICH EXECUTOR places it (routing).
#     capacity_for_compute_type(ct)  -> `PlacementSpec.capacity` (the rendered
#                                       per-placement attribute a conformer
#                                       reads).
#
#   ⛔ `PlacementSpec.capacity` IS NOT MADE REDUNDANT BY THIS AND MUST NOT BE
#   DELETED. It is the BACKEND-NEUTRAL RENDERING, and it is what the conformer
#   reads — a `PodManager` conformer must not import a job-config vocabulary to
#   learn which capacity class it is placing on, exactly as it does not import
#   one to learn its retry budget or its task deadline (`max_retries`,
#   `task_timeout_s`, `vpc_egress` are the same shape). The fail-closed refusal
#   for `CAPACITY_UNSPECIFIED` stays where it is, in the conformer, because that
#   is the one place that can name BOTH legal values AND both failure modes.
#
#   ⇒ The rejected alternative was "`ComputeType` carries only the SHAPE
#   (VM vs CONTAINER) and capacity stays an independent authored axis". It is
#   rejected because it makes `spot_vm` UNSAYABLE as one word in the plane where
#   `spot_vm` is already one word, and because two authored axes for one
#   operator intent is the second-spelling-drifts failure this file's own
#   `capacity` comment was written about. What survives of that alternative is
#   the part that was right: capacity remains a real field, DERIVED here rather
#   than restated by an operator.
#
# ⚠ AND THE OTHER DIRECTION HOLDS: both VM capacity classes route to ONE
#   executor, since one conformer places both. So the shape/capacity split is
#   not a design choice this file is making — it is the shape the executor
#   registry and the VM conformers already have.
#
# ⛔⛔ `COMPUTE_TYPE_UNSPECIFIED` (0) IS THE DEFAULT AND IT MUST STAY BEHAVIOURAL
#   ZERO. A job row that carries no compute type must resolve to whatever routing
#   already happens (Cloud Run Job / ECS Fargate container placement),
#   UNCHANGED. That is not a nicety: the sibling field `Job.placement` DEFAULTS
#   to the string `"VM"`, and routing THAT would turn every existing build and
#   validate step into a real billable EC2/GCE instance with no teardown. The
#   compute type is a SEPARATE key with a NON-DEFAULT positive stamp for exactly
#   that reason — see `compute_type_of`'s own block on the `"VM"` string
#   collision.
# -----------------------------------------------------------------------------
comptime COMPUTE_TYPE_UNSPECIFIED: Int = 0
"""The job did not say. ⛔ ROUTES EXACTLY AS IF THIS FIELD DID NOT EXIST — never
to a VM, never through a new code path. A job that states nothing is this."""

comptime COMPUTE_TYPE_CONTAINER: Int = 1
"""A container on RESERVED capacity — a Cloud Run Job / an ECS Fargate task."""

comptime COMPUTE_TYPE_SPOT_CONTAINER: Int = 2
"""A container on RECLAIMABLE capacity — `FARGATE_SPOT`. ⚠ GCP has no Cloud Run
spot; a GCP placement asking for it is a refusal at the conformer, not here."""

comptime COMPUTE_TYPE_VM: Int = 3
"""A whole VM on RESERVED capacity — an EC2 on-demand instance / a GCE instance
with `provisioningModel: STANDARD`."""

comptime COMPUTE_TYPE_SPOT_VM: Int = 4
"""A whole VM on RECLAIMABLE capacity — an EC2 Spot instance / a GCE instance
with `provisioningModel: SPOT`. The cheap arm, and the one whose placement can
END FOR A REASON THAT IS NOT THE CUSTOMER'S (`PLACE_PREEMPTED`)."""

comptime COMPUTE_TYPE_AUTO: Int = 5
"""⛔⛔ RESERVED. NOT IMPLEMENTED, NOT SPELLABLE, AND DELIBERATELY LAST.

An automatic chooser may come later. The ORDINAL is reserved now so that the
day it lands it does not renumber the four values a stored job row may already
carry; the BEHAVIOUR is not built, and there is **no string in
`compute_type_of`'s vocabulary that produces it**, so no job can select it.

⛔ IT IS LAST, AFTER the four, on purpose. Placing it at 1 (or anywhere inside
the run) would have made the four real values' ordinals a function of a decision
nobody has taken yet.

⛔ AND ANY ROUTER THAT MEETS IT MUST **REFUSE BY NAME**, never fall through to
the container default. "We have not implemented the chooser" and "we chose
container" are different statements, and only the second is safe to make
silently. The refusal is unreachable by construction — it is the tripwire for
whoever adds the spelling without adding the chooser."""


@always_inline
def compute_type_name(compute_type: Int) -> StaticString:
    """The compute-type ordinal's name, for a refusal that must state which value
    it saw rather than merely that it was wrong (the `capacity_name` idiom)."""
    if compute_type == COMPUTE_TYPE_CONTAINER:
        return "CONTAINER"
    if compute_type == COMPUTE_TYPE_SPOT_CONTAINER:
        return "SPOT_CONTAINER"
    if compute_type == COMPUTE_TYPE_VM:
        return "VM"
    if compute_type == COMPUTE_TYPE_SPOT_VM:
        return "SPOT_VM"
    if compute_type == COMPUTE_TYPE_AUTO:
        return "AUTO"
    return "UNSPECIFIED"


@always_inline
def compute_type_is_vm(compute_type: Int) -> Bool:
    """True iff this compute type places a WHOLE VM (either capacity class) — the
    ROUTING half of the decomposition. False for UNSPECIFIED, for both container
    types, for AUTO, and for any ordinal this vocabulary does not contain.

    ⛔ FALSE IS THE ANSWER FOR EVERY UNKNOWN VALUE, AND THAT DIRECTION IS THE
    LOAD-BEARING ONE. A predicate whose unknown case answered True would route an
    unrecognised ordinal onto real billable hardware; answering False leaves it on
    the path it was already on, where a caller that cares (`placement_backend_of`)
    refuses it explicitly instead."""
    return (
        compute_type == COMPUTE_TYPE_VM or compute_type == COMPUTE_TYPE_SPOT_VM
    )


@always_inline
def capacity_for_compute_type(compute_type: Int) -> Int:
    """The `CAPACITY_*` ordinal a compute type implies — the CAPACITY half of the
    decomposition, and the ONLY function that derives one from the other.

        CONTAINER  / VM      -> CAPACITY_ON_DEMAND
        SPOT_CONTAINER / SPOT_VM -> CAPACITY_INTERRUPTIBLE
        UNSPECIFIED / AUTO / anything else -> CAPACITY_UNSPECIFIED

    ⛔ UNSPECIFIED IN, UNSPECIFIED OUT. A job that said nothing about its compute
    shape has said nothing about its capacity class either, and manufacturing
    ON_DEMAND here would be exactly the "absence is agreement" reading that
    `CAPACITY_UNSPECIFIED`'s own docstring refuses. The conformer keeps its
    refusal; this function never removes a decision from it."""
    if (
        compute_type == COMPUTE_TYPE_CONTAINER
        or compute_type == COMPUTE_TYPE_VM
    ):
        return CAPACITY_ON_DEMAND
    if (
        compute_type == COMPUTE_TYPE_SPOT_CONTAINER
        or compute_type == COMPUTE_TYPE_SPOT_VM
    ):
        return CAPACITY_INTERRUPTIBLE
    return CAPACITY_UNSPECIFIED


comptime HEALTH_UNKNOWN: Int = 0  # not yet probed / indeterminate
comptime HEALTH_HEALTHY: Int = 1  # serving + healthy
comptime HEALTH_UNHEALTHY: Int = 2  # running but failing health checks


struct PlacementStatus(Copyable, Movable):
    """The observed state of a placed unit. `tag` is a PLACE_* constant (the
    reconciler matches on it exactly as it would on PodPhase.tag); `exit_code`
    is set only for FAILED; `message` carries the failure reason; `raw` the
    underlying backend phase/reason for diagnostics. `endpoint` is the served
    host:port once known (empty until the unit serves — only INFINITE app jobs
    ever set it); `health` is a HEALTH_* ordinal (an endpoint registry reports
    it).

    The `tag` field is the SAME VALUE a PodPhase carries, so the
    PodPhase <-> PlacementStatus round-trip is the identity on `tag` /
    `exit_code` / `message` / `raw`; `endpoint` / `health` are additive
    (default empty / UNKNOWN) and are not populated by the lossless k8s bridge
    (k8s status carries neither)."""

    var tag: Int
    var exit_code: Optional[Int]
    var message: String
    var raw: String
    var endpoint: String  # served host:port (empty => not serving / unknown)
    var health: Int  # HEALTH_* ordinal

    def __init__(out self, tag: Int):
        self.tag = tag
        self.exit_code = None
        self.message = String("")
        self.raw = String("")
        self.endpoint = String("")
        self.health = HEALTH_UNKNOWN

    @staticmethod
    def pending(raw: String = String("Pending")) -> PlacementStatus:
        var p = PlacementStatus(PLACE_PENDING)
        p.raw = raw
        return p^

    @staticmethod
    def running(raw: String = String("Running")) -> PlacementStatus:
        var p = PlacementStatus(PLACE_RUNNING)
        p.raw = raw
        return p^

    @staticmethod
    def succeeded(raw: String = String("Succeeded")) -> PlacementStatus:
        var p = PlacementStatus(PLACE_SUCCEEDED)
        p.exit_code = Optional[Int](0)
        p.raw = raw
        return p^

    @staticmethod
    def failed(exit_code: Int, message: String, raw: String) -> PlacementStatus:
        var p = PlacementStatus(PLACE_FAILED)
        p.exit_code = Optional[Int](exit_code)
        p.message = message
        p.raw = raw
        return p^

    @staticmethod
    def preempted(exit_code: Int, message: String, raw: String) -> PlacementStatus:
        """The INFRASTRUCTURE ended this placement. See `PLACE_PREEMPTED`.

        ⚠ IT STILL CARRIES AN EXIT CODE, and the code is usually 137 (SIGKILL)
        or absent (-1). Carrying it is not an endorsement of it as a verdict —
        it is the only observation there is, and dropping it would leave an
        operator with strictly less than they have today."""
        var p = PlacementStatus(PLACE_PREEMPTED)
        p.exit_code = Optional[Int](exit_code)
        p.message = message
        p.raw = raw
        return p^

    @staticmethod
    def not_found() -> PlacementStatus:
        var p = PlacementStatus(PLACE_NOTFOUND)
        p.raw = String("NotFound")
        return p^

    @staticmethod
    def unknown(raw: String) -> PlacementStatus:
        var p = PlacementStatus(PLACE_UNKNOWN)
        p.raw = raw
        return p^

    def is_terminal(self) -> Bool:
        """True if the unit reached a terminal state (Succeeded / Failed /
        NotFound / Preempted) — the reconciler stops polling on terminal.

        ⛔ `PLACE_PREEMPTED` IS TERMINAL AND OMITTING IT HERE WOULD BE A HANG,
        not a conservative default: a reclaimed placement no longer exists, so a
        reconciler that kept polling would poll a task ECS has already reaped —
        forever, or until a timeout invented a different wrong answer. Every
        producer of this tag has already observed the terminal state."""
        return (
            self.tag == PLACE_SUCCEEDED
            or self.tag == PLACE_FAILED
            or self.tag == PLACE_NOTFOUND
            or self.tag == PLACE_PREEMPTED
        )

    def tag_name(self) -> StaticString:
        if self.tag == PLACE_PENDING:
            return "Pending"
        if self.tag == PLACE_RUNNING:
            return "Running"
        if self.tag == PLACE_SUCCEEDED:
            return "Succeeded"
        if self.tag == PLACE_FAILED:
            return "Failed"
        if self.tag == PLACE_PREEMPTED:
            return "Preempted"
        if self.tag == PLACE_NOTFOUND:
            return "NotFound"
        return "Unknown"

    # ---- lossless bridge to/from the k8s-pod currency (komira_k8s) ----

    @staticmethod
    def from_pod_phase(phase: PodPhase) -> PlacementStatus:
        """Lift a k8s `PodPhase` into the placement-neutral status. The tag is
        carried verbatim (PLACE_* == POD_*), as are exit_code / message / raw.
        `endpoint` / `health` default empty / UNKNOWN (k8s PodPhase carries
        neither). Lossless — `to_pod_phase()` reconstructs the PodPhase."""
        var s = PlacementStatus(phase.tag)
        s.exit_code = phase.exit_code
        s.message = phase.message
        s.raw = phase.raw
        return s^

    def to_pod_phase(self) -> PodPhase:
        """Lower this status back to a k8s `PodPhase` — the inverse of
        `from_pod_phase`. Carries tag / exit_code / message / raw verbatim; the
        neutral `endpoint` / `health` have no PodPhase representation and are
        dropped (k8s status does not model them). Lossless for the fields the
        reconciler reads."""
        var p = PodPhase(self.tag)
        p.exit_code = self.exit_code
        p.message = self.message
        p.raw = self.raw
        return p^
