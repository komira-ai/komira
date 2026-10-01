# =============================================================================
# komira_placement/pod_manager.mojo — the PodManager PLACEMENT seam + a fake.
# =============================================================================
#
# The control-plane job-manager loops (scheduler / reconciler) need exactly
# THREE placement operations: create, get_status, delete. They sit behind a
# `PodManager` trait so the loops can run against a fake in unit tests and
# against a real backend in production.
#
# The seam speaks a PLACEMENT-NEUTRAL currency (`PlacementSpec` /
# `PlacementStatus`, placement_types.mojo) so a conformer is "given a
# PlacementSpec, place it; report PlacementStatus" REGARDLESS of backend — a
# k8s pod (K8sPodManager), a local process, or a VM supervisor. The seam does
# not speak the k8s-pod-shaped PodCreateSpec/PodPhase; those remain
# komira_k8s's INTERNAL currency, bridged losslessly at the K8sPodManager
# boundary via PlacementSpec.to_pod_spec() / PlacementStatus.from_pod_phase().
#
# The PLACE_* tags are numerically identical to the POD_* tags and the
# single-container round-trip is lossless, so a k8s conformer behaves
# identically through the neutral seam.
#
# K8sPodClient (komira_k8s) keeps its native PodCreateSpec/PodPhase signatures
# (it IS the k8s wire client); K8sPodManager is the thin adapter that conforms
# the neutral seam by translating at the boundary. Single k8s calls use the
# BlockingRuntime / single-shot K8sPodClient (one fresh TLS conn per request),
# which is what K8sPodManager holds.
#
# The `FakePodManager` here is the test double: it RECORDS create/delete calls
# and returns SCRIPTED get_status results, so the loops test in-process with NO
# cluster. Because the trait methods take `self` (read) — to match K8sPodClient,
# whose ops do not mutate the client — the fake records through an
# `ArcPointer[_FakeState]` interior (the same `self._p[].mutate()` interior-
# mutation shape `komira_async` uses).
#
# ENCAPSULATION: the trait surface is typed values only — PlacementSpec /
# PlacementStatus / String in and out, `raises` for errors. ZERO UnsafePointer
# crosses the boundary. The fake's internal `ArcPointer` is a shared heap handle
# for interior mutation through the self-read trait methods (gap6-clean: no
# wildcard origin, no byte-slab; a test double, not concurrent state under a
# parallelize barrier).
# =============================================================================

from std.memory import ArcPointer

from komira_k8s.k8s_client import K8sPodClient
from komira_k8s.k8s_types import PodDeletionAck, PodLiveness

from komira_placement.placement_types import (
    PlacementSpec,
    PlacementStatus,
    PLACE_NOTFOUND,
    PLACE_UNKNOWN,
)


# =============================================================================
# PodManager — the 3-verb PLACEMENT seam the loops drive (placement-neutral).
# =============================================================================
trait PodManager(Movable, Deinitable):
    """The placement-lifecycle operations the scheduler + reconciler call — the
    THREE verbs the loops use, placement-NEUTRAL. `K8sPodManager` conforms (the
    real, in-cluster path — bridges to PodCreateSpec/PodPhase at the k8s
    boundary); a local process runner conforms (real local subprocesses);
    `FakePodManager` conforms (the in-process test double); each cloud bridge's
    VM / serverless managers conform — all over the SAME
    PlacementSpec/PlacementStatus currency.

    The (namespace, name) pair is the placement HANDLE: a k8s pod addresses by
    (namespace, name); a local process records by name; a VM supervisor uses
    name as the instance name + namespace as a grouping label. The handle is
    backend-neutral — the conformer interprets it.

    All methods take `self` (read): a placement op does not mutate the manager
    (each K8sPodClient call opens a fresh TLS connection and re-reads the SA
    token). Errors surface via `raises` (a typed K8sError message for the real
    path)."""

    def create(self, spec: PlacementSpec) raises:
        """Place a unit from a placement-neutral spec (one or more containers,
        co-located). Idempotent — if the unit already exists (k8s HTTP 409 /
        a live local process for the name) the implementation SWALLOWS it and
        returns Ok. Other failures raise."""
        ...

    def get_status(
        self, namespace: String, name: String
    ) raises -> PlacementStatus:
        """Read a unit's status -> a `PlacementStatus` the reconciler matches on
        (the PLACE_* tag space). A missing unit (k8s HTTP 404 / unknown local
        name) maps to `PlacementStatus.not_found()` (idempotency). Transport /
        backend errors raise."""
        ...

    def delete(self, namespace: String, name: String) raises:
        """Delete a unit by handle. Idempotent — a missing unit (k8s HTTP 404 /
        unknown local name) is SWALLOWED and returns Ok. Other failures raise."""
        ...

    # =========================================================================
    # rollback_create — THE VERIFIED-REVERT VERB.
    # =========================================================================
    #
    # THE INVARIANT:
    #
    #   A placement backend may report a create as reverted only when it has
    #   OBSERVED the absence of the resource through the same live API it
    #   created it with. An unobserved absence is not an absence.
    #
    # WHY. A compensation that, when a placement's `create` failed, reverts the
    #   DATABASE ROW and does nothing in the cloud makes no claim about the
    #   world and yet reads as a successful revert. On GCP that is provably not
    #   a revert, because create is TWO mutations: `insert_instance` then an
    #   operation poll, which raises on a DONE-with-error and on budget exceed.
    #   So `create` raising is fully consistent with a live, billing GCE
    #   instance.
    #
    #   Such an orphan is UNREACHABLE, by construction: the next claim mints a
    #   fresh name suffix so its name is never asked for again; a write-ahead
    #   intent row left PROVISIONING is not the reaper's to touch; and a
    #   registry that adopts the materialized instance ACTIVE never promotes it
    #   to ORPHANED. GCE bills by the hour and does not self-terminate.
    #
    # ⛔ WHY IT RETURNS `PlacementStatus` AND NOT `Bool`. Confirmed-gone /
    #   still-present / could-not-observe are THREE answers. A `Bool` makes "I
    #   got a 500 from EC2" and "it is still running" the same byte — the swallow
    #   this verb exists to ban. `PLACE_NOTFOUND` == CONFIRMED GONE;
    #   `PLACE_UNKNOWN` == COULD NOT OBSERVE; anything else == STILL THERE.
    #
    # ⛔ WHY IT IS ADDRESSED BY `(namespace, name)` AND NOT BY `PlacementSpec`.
    #   THERE IS NO `PlacementSpec` ON THE FAILURE PATH. A scheduler declares
    #   `var spec` INSIDE the `try`, deliberately, because building the spec
    #   itself raises on an empty agent image / heartbeat URL — so one whole
    #   failure class is "the spec was never built", and Mojo rejects an
    #   `except`-block use of it as not definitely-initialized. `(namespace,
    #   pod_name)` is what the scheduler actually owns, and it is exactly how
    #   the scheduler's own stop path addresses the same units.
    #
    # ⛔ WHY IT IS NOT JUST `delete`. `delete` is IDEMPOTENT BY CONTRACT — an
    #   unknown name is a no-op — so "I did not find it" and "I confirmed it is
    #   gone" are the same bytes to it. It also returns nothing, so it cannot
    #   carry the observation. The verified revert is delete-AND-CONFIRM, and the
    #   confirmation is the whole point.
    # =========================================================================
    def rollback_create(
        self, namespace: String, name: String
    ) raises -> PlacementStatus:
        """VERIFIED REVERT of a FAILED `create`: tear the unit down and then
        CONFIRM its absence THROUGH THE SAME LIVE API `create` used. Returns
        `PLACE_NOTFOUND` only when the absence was OBSERVED; `PLACE_UNKNOWN`
        when it could not be observed; the observed status when the unit is
        still there.

        ⛔ THE CONFIRMING RE-READ MUST NOT CONSULT A CACHE. A conformer that
        holds a placement record, or a tombstone its own `delete` just wrote,
        will answer NOTFOUND without asking the cloud — which is precisely the
        unobserved absence this verb exists to refuse. `Ec2VmPodManager` is the
        worked example: its `get_status` short-circuits on the tombstone
        `delete` writes, so its `rollback_create` re-reads through
        `describe_by_placement` and not through `get_status`.

        DEFAULTED to `PlacementStatus.unknown(...)`, so existing `PodManager`
        conformers (production and test doubles alike) keep compiling without
        an edit when the verb is added.

        ⚠ STATE THE CONSEQUENCE RATHER THAN DISCOVERING IT: an UNMIGRATED
        conformer conservatively answers COULD-NOT-CONFIRM, so a scheduler
        create-failure routed to one does NOT report a clean revert. That is the
        CORRECT direction (an unobserved absence is not an absence), and a
        caller's test should assert it directly instead of leaving it to be
        found in production."""
        return PlacementStatus.unknown(
            String(
                "rollback_create: this PodManager conformer has NOT implemented"
                " the verified-revert verb, so the absence of unit '"
            )
            + name
            + String(
                "' could not be OBSERVED. This is the conservative default, not"
                " a failure: an unobserved absence is not an absence. Implement"
                " `rollback_create` on the conformer (delete, then re-read"
                " through the SAME live API `create` used) to make a clean"
                " revert reportable."
            )
        )

    # =========================================================================
    # expects_heartbeat — THE SUPERVISION POSTURE VERB.
    # =========================================================================
    def expects_heartbeat(self) -> Bool:
        """Does a unit this backend places BEAT? True iff OUR supervisor is the
        liveness channel for it — i.e. the workload sends a heartbeat every ~10s
        and the ABSENCE of a beat is evidence that may be acted on.

        The job manager calls this AT THE PLACEMENT SITE and stamps the answer
        onto `jobs.supervision` (`SELF_SUPERVISED` / `PLATFORM_SUPERVISED`). The
        value is then a fact about a decision WE made, recorded by the party
        that made it — never something a client asserted (`CreateJobRequest` has
        no `supervision` field, deliberately: a client claiming PLATFORM on a
        workload we then place on a GCE VM would switch off that workload's only
        liveness signal, silently and forever).

        ⛔⛔ THE DEFAULT BODY IS THE POINT, AND IT RETURNS **True**. Two reasons,
        and they are independent:

        1. A trait widening with NO default is a compatibility event across
           every existing conformer and every one added later. The
           `rollback_create` default directly above follows the same rule, and
           it is what makes adding this verb zero-conformer-edits.
        2. `True` is the SAFE direction. An unrecognised or not-yet-migrated
           backend keeps being WATCHED. The worst case of that is a spurious
           stale-sweep adoption — loud and recoverable. The worst case of the
           other direction is a workload nobody is watching: its row is never
           expected to beat, so it never goes stale, so it is never reconciled
           by anything, forever, with NO error anywhere. Silent and permanent.

        ⛔ DO NOT OVERRIDE THIS WITHOUT MEASURING THE CONFORMER'S OWN STATUS
        PATH. A conformer whose status path nobody has read stays on the `True`
        default, because "probably serverless, so probably False" is exactly
        the guess that costs a workload its supervision. Overriding is a claim
        that the PLATFORM observes health and that the absence of a beat
        therefore means nothing — make it only from the conformer's
        `get_status`.

        ⚠ AND IT IS NOT DERIVABLE FROM `Job.placement`. That column is authored
        by several services for different reasons, is overridable, and defaults
        to `"VM"` — so a defaulted value meaning "self-supervised" is
        indistinguishable from a value nobody set. The BACKEND states its own
        posture; nothing infers it."""
        return True


# =============================================================================
# K8sPodManager — the PRODUCTION PodManager conformer (wraps K8sPodClient).
# =============================================================================
#
# Mojo requires EXPLICIT trait conformance (a struct must list the trait in its
# declaration). `K8sPodClient` lives in komira_k8s and declares only `Movable` —
# and komira_k8s cannot depend on komira_placement (that would be a cycle), so
# K8sPodClient cannot itself declare `PodManager`. The shape is a thin wrapper
# HERE that owns the `K8sPodClient` and explicitly conforms.
#
# The wrapper is the PLACEMENT-NEUTRAL adapter. K8sPodClient keeps its native
# PodCreateSpec/PodPhase signatures (it is the k8s wire client); the
# K8sPodManager methods take the neutral PlacementSpec/return PlacementStatus and
# BRIDGE at this boundary — `spec.to_pod_spec()` lowers the (single-container)
# placement spec to the k8s currency on the way in, `PlacementStatus.from_pod_phase`
# lifts the pod status on the way out. For the single-container supervisor pod
# (the only k8s shape) this bridge is exactly lossless. A k8s rendering of the
# multi-container shape would render `spec.containers` natively here (the bridge
# is the single-container fast path, not a ceiling on the conformer).
#
# ENCAPSULATION: owns the client by value (moved in); no pointer crosses the
# boundary. The delegations are `self`-read (matching the client).
#
# =============================================================================
# k8s_rollback_verdict — THE PUBLISHED CONTRACT FOR "IS THE POD GONE".
# =============================================================================
#
# ⭐⭐ THIS FUNCTION IS THE SPECIFICATION, AND IT IS PURE ON PURPOSE. A
#   self-hoster reads `K8sPodManager` to learn what `rollback_create` MEANS on
#   Kubernetes; the meaning is a decision over two observations, and a decision
#   buried inside a method that needs a live apiserver to exercise is a decision
#   nothing can falsify. Split out, every row below is drivable from a JSON
#   string in a hermetic test — which is why the mutants a future reader will be
#   tempted by (below) can each be PROVEN red rather than argued about.
#
# ⛔⛔ WHY KUBERNETES IS DIFFERENT FROM EVERY OTHER CONFORMER.
#   On EC2 / GCE / Cloud Run the hazard is an orphan NOTHING is reclaiming. On
#   k8s, a `DELETE` that returns 200 has not removed anything — it wrote
#   `metadata.deletionTimestamp` into etcd and started a grace period, and the
#   apiserver removes the object only after the kubelet confirms the containers
#   stopped. **A pod on an unreachable node stays `Terminating` INDEFINITELY,
#   WITH ITS CONTAINERS STILL RUNNING.** So the question is not "is it gone" but
#   "is it certain to go, and is anything still running in the meantime" — and
#   the answer to the second half is NOT always no.
#
# ⛔⛔ AND THAT IS WHY THE TEMPTING ANSWER IS A CORRECTNESS BUG, NOT A BILLING
#   ONE. Report `PLACE_NOTFOUND` the moment a `deletionTimestamp` appears and
#   the job manager's requeue clears `pod_name` and a SECOND pod is placed for
#   the same job — while the first is still running on the unreachable node.
#   The job manager accepts heartbeats keyed on `job_id` ALONE (its heartbeat
#   handler checks the job's phase and the FSM transition, never that the
#   beating supervisor is the CURRENT placement, and a beat may stamp
#   `pod_name`). ⇒ TWO LIVE SUPERVISORS DRIVING ONE JOB'S PHASE, both writing
#   its outputs. That is the strongest single argument for this shape.
#
# ⛔ THINGS THAT ARE **NOT** IN THIS DESIGN, AND MUST NOT BE ADDED:
#   * **No wait inside the verb.** A bounded poll here reproduces a congestive
#     collapse: the job manager's k8s calls are synchronous single-shot
#     (`BlockingRuntime`), and on the scale-to-zero arm the reconcile ticks run
#     INLINE ON THE ONE REACTOR THAT ALSO SERVES REQUESTS. A grace-period wait
#     is 30 s by default and author-settable upward without limit. THE
#     RECONCILER'S 10 s TICK IS THE WAIT — already bounded, already loud,
#     already asynchronous. The verb reports honestly each time.
#   * **No force-delete** (`?gracePeriodSeconds=0`). It MANUFACTURES the absence
#     instead of observing it: the object is dropped without waiting for
#     confirmation that the container stopped, so the 404 is true of the
#     apiserver and false of the world. It also converts the *observable*
#     stuck-Terminating case into an invisible one.
#   * **No new `PLACE_*` tag.** The caller is binary (`reclaim.tag !=
#     PLACE_NOTFOUND`), so a tag buys documentation, not behaviour — and it
#     obliges every conformer author in a published tag space to learn it.
#     `PLACE_PREEMPTED`'s own comment concedes the same trap. `raw` carries the
#     distinction for free. Revisit only when a consumer would genuinely act
#     differently.
#
# THE FOUR OPERATOR SITUATIONS, WHICH IS WHY `raw` IS CONTRACT AND NOT PROSE.
# The job manager prints `reclaim.raw` verbatim in its held-restart log, and
# it is the ONLY thing that separates:
#   (1) 404                          -> gone. Re-place.
#   (2) present + mark, inside grace -> wait, this is normal.
#   (3) present + mark, far past it  -> your node is unreachable; a human must
#                                       force-delete.
#   (4) present, NO mark             -> a finalizer or an admission webhook is
#                                       holding it (or a different pod now
#                                       holds the name); this will not resolve
#                                       on its own.
# Collapsing (2)/(3)/(4) into one string is what makes a held restart
# unactionable — which is the whole cost this design is paying ticks to avoid.
# =============================================================================
def k8s_rollback_verdict(
    name: String, ack: PodDeletionAck, live: PodLiveness
) -> PlacementStatus:
    """Decide the verified-revert answer for a k8s pod from the DELETE's
    acknowledgement and a FRESH read.

        live read           | answer                    | meaning
        --------------------+---------------------------+-----------------------
        GET 404             | PLACE_NOTFOUND            | OBSERVED ABSENCE
        200, mark present   | the observed phase        | STILL THERE, terminating
        200, mark absent    | the observed phase        | STILL THERE, delete did
                            |                           | not stick
        GET raised          | (never reaches here)      | caller -> PLACE_UNKNOWN

    ⛔ `ack` MAY NOT DECIDE THE TAG. It says a deletion was ACCEPTED and durable
    in etcd; it says NOTHING about whether anything stopped. Only `live` decides
    presence. What `ack` contributes is the DEADLINE — see the join below."""
    # =====================================================================
    # ROW 1 — the GET 404'd. THE ONLY ABSENCE THIS FUNCTION WILL REPORT.
    # =====================================================================
    if not live.present:
        var gone = PlacementStatus.not_found()
        gone.raw = (
            String("k8s: GET 404 — pod '")
            + name
            + "' is gone from the apiserver (OBSERVED absence)"
        )
        if ack.already_gone:
            gone.raw += (
                "; the DELETE also answered 404, so there was nothing to delete"
            )
        elif ack.is_marked():
            gone.raw += "; " + ack.deadline_phrase() + " — the grace period completed"
        return gone^

    # =====================================================================
    # ROWS 2 & 3 — the object read back. IT IS STILL THERE.
    # =====================================================================
    var st = PlacementStatus.from_pod_phase(live.phase)
    # ⛔ A PRESENT OBJECT IS NEVER REPORTED ABSENT, AND THIS GUARD IS NOT
    #   DEFENSIVE PADDING. `derive_pod_phase` cannot produce `POD_NOTFOUND`
    #   today, but it is a function in another package that a later change could
    #   teach to — and the single byte it would take to turn a still-running pod
    #   into "confirmed gone" is the byte that re-places a job on top of a live
    #   supervisor. Presence is decided HERE, from the wire outcome, and nothing
    #   downstream may overturn it. `PLACE_UNKNOWN` is the right fallback: the
    #   two observations disagree, so we genuinely could not read a coherent
    #   phase — and the caller's binary check (`!= PLACE_NOTFOUND`) still HOLDS
    #   the restart, which is the safe direction.
    if st.tag == PLACE_NOTFOUND:
        st.tag = PLACE_UNKNOWN

    if live.is_terminating():
        # ---- ROW 2: TERMINATING. Situations (2) and (3). ----
        #
        # ⭐ THE DEADLINE IS JOINED FROM BOTH OBSERVATIONS, AND THE DELETE'S
        #   COPY IS THE AUTHORITATIVE ONE. `metadata.deletionGracePeriodSeconds`
        #   is OPTIONAL on a read — an apiserver, a proxy or a stale watch-cache
        #   serve may omit it — while the DELETE response is where the apiserver
        #   states the deadline it just started. Dropping the ack here leaves an
        #   operator with "terminating, grace UNSTATED", which cannot separate
        #   situation (2) from situation (3): a pod 4 s into a 30 s grace and a
        #   pod stuck for forty minutes read identically.
        var grace = live.grace_period_seconds
        if grace < 0:
            grace = ack.grace_period_seconds
        var ts = live.deletion_timestamp
        if ts.byte_length() == 0:
            ts = ack.deletion_timestamp
        st.raw = (
            String("k8s: pod '")
            + name
            + "' is STILL PRESENT (phase "
            + String(live.phase.tag_name())
            + ") and TERMINATING — terminating since "
            + ts
        )
        if grace >= 0:
            st.raw += ", grace " + String(grace) + "s"
        else:
            st.raw += ", grace UNSTATED"
        if ack.is_marked():
            st.raw += "; " + ack.deadline_phrase()
        st.raw += (
            ". NOT an absence: the apiserver removes the object only after the"
            " kubelet confirms the containers stopped, so a pod on an"
            " unreachable node stays here indefinitely WITH ITS CONTAINERS"
            " RUNNING. Inside the grace period this is normal and the next"
            " reconcile tick re-reads; far past it, the node is unreachable and"
            " a human must force-delete."
        )
        return st^

    # ---- ROW 3: PRESENT WITH NO DELETION MARK. Situation (4). ----
    #
    # ⭐ THE ACK SPLITS THIS ROW INTO TWO DIFFERENT OPERATOR ACTIONS, and it is
    #   the only thing that can. "Our DELETE was accepted and stamped a
    #   timestamp, yet the object now under this name carries none" means a
    #   DIFFERENT pod holds the name (or a webhook cleared the mark). "The
    #   DELETE was accepted and the object carries no mark either" means the
    #   deletion never took. Same tag, different human action.
    st.raw = (
        String("k8s: pod '")
        + name
        + "' is STILL PRESENT (phase "
        + String(live.phase.tag_name())
        + ") with NO deletionTimestamp"
    )
    if ack.already_gone:
        st.raw += (
            " — and the DELETE answered 404 (nothing to delete), so this name"
            " was (re)created between the two calls. It is not the unit we"
            " tried to reclaim."
        )
    elif ack.is_marked():
        st.raw += (
            " — but "
            + ack.deadline_phrase()
            + ". The object now under this name is NOT the one we marked:"
            " either a different pod was created under it, or an admission"
            " webhook cleared the mark."
        )
    else:
        st.raw += (
            " after a 2xx DELETE — THE DELETION DID NOT STICK. A finalizer or"
            " an admission webhook is holding it; this will not resolve on its"
            " own."
        )
    return st^


struct K8sPodManager(Movable, PodManager):
    """Production `PodManager`: a thin wrapper owning a `K8sPodClient`, conforming
    explicitly to the placement-neutral trait (Mojo needs the explicit
    declaration; the client's own package can't declare it without a dep cycle).
    Each method bridges the neutral currency to the k8s client's PodCreateSpec/
    PodPhase (lossless for the single-container supervisor pod) and delegates to
    the client (which carries the idempotency swallows)."""

    var _client: K8sPodClient

    def __init__(out self, var client: K8sPodClient):
        self._client = client^

    def create(self, spec: PlacementSpec) raises:
        # Bridge the placement-neutral spec to the k8s PodCreateSpec at the
        # boundary, then delegate (the client swallows the 409 idempotency).
        self._client.create_pod(spec.to_pod_spec())

    def get_status(
        self, namespace: String, name: String
    ) raises -> PlacementStatus:
        # Delegate to the k8s client, then lift the PodPhase into the neutral
        # status (tag/exit_code/message/raw carried verbatim).
        return PlacementStatus.from_pod_phase(
            self._client.get_pod_status(namespace, name)
        )

    def delete(self, namespace: String, name: String) raises:
        # ⚠ THE ACK IS DISCARDED **HERE AND ONLY HERE**. `delete` is the
        #   FIRE-AND-FORGET verb by contract — idempotent, returns nothing, and
        #   its callers are teardown paths that make no claim about the world.
        #   `rollback_create` is the verb that makes a claim, and it keeps the
        #   ack (see below). Do not "tidy" this by making `delete_pod` stop
        #   returning it.
        _ = self._client.delete_pod(namespace, name)

    # ---- the VERIFIED-REVERT surface ----

    def rollback_create(
        self, namespace: String, name: String
    ) raises -> PlacementStatus:
        """VERIFIED REVERT on Kubernetes — DELETE the pod, keep what the
        apiserver said about that deletion, then CONFIRM with a FRESH LIVE READ.
        Answers `PLACE_NOTFOUND` **only** on a GET that 404s.

        ⭐ THE WHOLE DECISION LIVES IN `k8s_rollback_verdict`, WHICH IS PURE AND
        DOCUMENTED AS THE CONTRACT — read it, not this method, to learn what the
        verb means. This body is deliberately three steps and no branching: it
        is the plumbing, and the plumbing is where a shortcut would hide.

        ⛔ THE THREE STEPS ARE NOT INTERCHANGEABLE AND NONE MAY BE DROPPED.
          1. `delete_pod` — idempotent (404 swallowed). Sends NO query string:
             `?gracePeriodSeconds=0` would MANUFACTURE the 404 that step 3 must
             OBSERVE.
          2. keep the ACK. It is the apiserver's own statement of the deadline
             it just started, and `deletionGracePeriodSeconds` is OPTIONAL on a
             read — so this is the one place it is guaranteed. Without it an
             operator cannot tell a pod 4 s into its grace from one stuck for
             forty minutes.
          3. `get_pod_liveness` — the FRESH LIVE READ, and the only source of
             the absence. ⛔ NOT `get_status`: today `K8sPodManager` holds no
             cache, so the composition would happen to be honest NOW and would
             silently become a lie the day anyone adds one. Conformers that do
             cache carry the same warning (`Ec2VmPodManager`'s tombstone, a
             local process runner's cached terminal).

        ⛔ AND IT DOES NOT WAIT. A bounded poll here is the congestive-collapse
        shape — a blocking call inside a single-threaded reconciler's ~10 s tick
        IS the wait; this verb reports honestly on each one. An ordinary k8s
        restart therefore holds ~30-40 s (3-4 ticks) and then re-places; a pod
        stuck Terminating holds forever, loudly, which is the case where holding
        is correct."""
        var ack = self._client.delete_pod(namespace, name)
        var live = self._client.get_pod_liveness(namespace, name)
        return k8s_rollback_verdict(name, ack, live)


# =============================================================================
# _FakeState — the fake's recorded interactions + scripted responses.
# =============================================================================
#
# Heap-held behind an ArcPointer so the self-read trait methods can RECORD into
# it (interior mutation through a read borrow — the ArcPointer pointee's origin
# is the shared heap allocation, not `self`; `arc[].field = ...` is a mutable
# lvalue, the same shape `komira_async`'s channels and mutex use). ArcPointer
# (not OwnedPointer) because OwnedPointer's `[]` does not yield a mutable lvalue
# through a read-self borrow. This is a TEST DOUBLE, not concurrent state under a
# parallelize barrier, so the ArcPointer use is in-bounds. Plain owned fields:
# List[String] of recorded names + a scripted PlacementStatus queue. gap6-clean
# (not stored in any byte-slab; no wildcard).
struct _FakeState(Movable):
    """The fake's mutable interior: a log of created/deleted unit names + a FIFO
    of scripted `get_status` results per unit name + a default fallback +
    optional create-failure scripting."""

    var created: List[String]  # unit names passed to create, in order
    # ⛔⛔ THE CAPACITY THE PLACEMENT ACTUALLY ASKED FOR — parallel to `created`.
    #
    # A double that records only `spec.name` and discards the rest of the spec
    # makes every OTHER field of a placement request UNASSERTABLE by any test.
    # The same defect class appears in any mock that records a resource NAME
    # but discards the request BODY: nothing can ask what a create ASKED FOR,
    # and a body the real API refuses survives every hermetic test.
    #
    # "the job manager routed a create" and "the job manager routed a create
    # ASKING FOR INTERRUPTIBLE CAPACITY" are different claims, and only the
    # second is the one that decides whether a customer's job runs on capacity
    # the cloud can take back. A count cannot distinguish them.
    #
    # ⇒ **ASSERT ON THE REQUEST BODY, NOT ON THE FACT THAT A REQUEST HAPPENED.**
    var created_capacity: List[Int]
    # ⛔ THE COMPUTE SHAPE THE PLACEMENT ASKED FOR — parallel to `created`, and
    # here for the SAME reason `created_capacity` is: "the job manager routed a
    # create" and "the job manager routed a create that STATES IT IS A VM" are
    # different claims. Without it, `PlacementSpec.compute_type` would be a
    # field a test could observe only by its side effects, which is how a spec
    # field ends up dropped on the floor with a green suite.
    var created_compute_type: List[Int]
    # ⛔⛔ THE OWNERSHIP CORRELATOR THE PLACEMENT CARRIED — parallel to `created`,
    # and here for the same argument again. "the job manager routed a create"
    # and "the job manager routed a create that a later cleanup can PROVE it
    # made" are different claims, and only the second decides whether an
    # unattended cleanup may DELETE the resulting resource. Without it,
    # `PlacementSpec.validation_run_id` is observable only by its side effects —
    # which are, by construction, in ANOTHER PROCESS, HOURS LATER (the run's own
    # terminal leak check). That is the least observable side effect there is,
    # so it is exactly the field a double must not discard.
    var created_validation_run_id: List[String]
    var deleted: List[String]  # unit names passed to delete, in order
    var status_keys: List[String]  # parallel arrays: name -> scripted status
    var status_vals: List[PlacementStatus]
    var status_cursor: List[Int]  # per-key cursor into a repeated-last script
    var default_status: PlacementStatus  # returned when no script matches
    var fail_create_for: List[String]  # unit names whose create should raise
    var fail_all_creates: Bool  # if True, EVERY create raises (name-agnostic)
    # If True, EVERY get_status raises (name-agnostic) — models a persistently-
    # unresolvable poll (e.g. the Cloud Run pod manager's WIF/STS HTTP-400 on a
    # stale job) that a reconciler MUST NOT loop on forever.
    var fail_all_gets: Bool
    var create_calls: Int  # total create invocations (incl. failures)
    var get_calls: Int  # total get_status invocations
    # ==== THE VERIFIED-REVERT SURFACE ====
    #
    # ⛔⛔ `live` IS THIS DOUBLE'S **LIVE API**, AND `status_keys`/`default_status`
    # ARE ITS **SCRIPT**. Keeping them separate is the whole point: the verified
    # revert must be asserted by driving the double's own live view, never the
    # manager's cached record, and a double whose only view is a script cannot
    # tell those two apart — a mutant that re-reads the CACHE instead of the API
    # is GREEN against it. So `create` records into `live`, a teardown removes
    # from `live`, and `rollback_create` confirms against `live` — while
    # `get_status` keeps returning the SCRIPT.
    var live: List[String]  # unit names this double believes EXIST right now
    # ⛔ THE TOMBSTONE — modelled deliberately, because the production conformer
    # has one. `Ec2VmPodManager.delete` tombstones a name and its `get_status`
    # then answers NOTFOUND *WITHOUT ASKING EC2*. A falsifier for "consult the
    # cache instead of the live API" that does not model that will pass over the
    # exact mutant it is meant to catch, so this double carries the same shape.
    var cache_gone: List[String]
    var rolled_back: List[String]  # names passed to rollback_create, in order
    # ⛔⛔ ONE ORDERED LOG ACROSS ALL THREE VERBS — because DELETE-BEFORE-REPLACE
    # IS AN ORDER, AND `created` / `deleted` ARE TWO SEPARATE LISTS THAT CANNOT
    # EXPRESS ONE. A restart is *supposed* to produce two creates and one delete;
    # what makes it safe rather than a leak is that the delete of placement #1
    # happens BEFORE the create of placement #2. Counted separately those two
    # orderings are byte-identical, so a double with only per-verb lists is green
    # against a job manager that re-places first and tears down afterwards — which is a
    # leak whenever the second step does not run. Entries are
    # `create:<name>` / `delete:<name>` / `rollback:<name>` in call order.
    var ops: List[String]
    # If True, `create` RECORDS the instance into `live` and THEN raises — the
    # verified revert's positive-control precondition ("a double whose create
    # raises AFTER recording an instance"). This is the GCP shape:
    # `insert_instance` succeeded and the operation poll raised.
    var create_fails_after_record: Bool
    # If True, `rollback_create`'s teardown SILENTLY does nothing (the unit stays
    # in `live`) — the verified revert's NEGATIVE control. An absence is only
    # evidence if something proves the code got that far.
    var rollback_teardown_silently_fails: Bool
    # If True, `rollback_create` RAISES (a transport fault on the compensation
    # path) — the router must map that to COULD-NOT-OBSERVE, never to success.
    var rollback_raises: Bool

    def __init__(out self):
        self.created = List[String]()
        self.created_capacity = List[Int]()
        self.created_compute_type = List[Int]()
        self.created_validation_run_id = List[String]()
        self.deleted = List[String]()
        self.status_keys = List[String]()
        self.status_vals = List[PlacementStatus]()
        self.status_cursor = List[Int]()
        self.default_status = PlacementStatus.not_found()
        self.fail_create_for = List[String]()
        self.fail_all_creates = False
        self.fail_all_gets = False
        self.create_calls = 0
        self.get_calls = 0
        self.live = List[String]()
        self.cache_gone = List[String]()
        self.rolled_back = List[String]()
        self.ops = List[String]()
        self.create_fails_after_record = False
        self.rollback_teardown_silently_fails = False
        self.rollback_raises = False


# =============================================================================
# FakePodManager — the in-process test double (conforms to PodManager).
# =============================================================================
struct FakePodManager(Movable, PodManager):
    """Records create/delete calls and returns scripted `get_status` results, so
    the scheduler/reconciler loops test WITHOUT a cluster. The recorded
    interactions live behind an `ArcPointer[_FakeState]` so the self-read trait
    methods can mutate them (interior mutation through a read borrow — the
    established `self._p[].field = ...` shape).

    Scripting API (called by the test BEFORE driving the loop):
      * `script_status(name, status)` — enqueue a PlacementStatus for `name`.
        Multiple calls for the same name form a FIFO; the LAST scripted status
        repeats once the FIFO is drained (so a single `script_status` is
        "always this").
      * `set_default_status(status)` — the status for any unscripted name.
      * `fail_create(name)` — make `create` RAISE for `name` (drives the
        create-failure -> revert-to-Pending path).

    Inspection API (called AFTER):
      * `created_names()` / `deleted_names()` — the recorded call logs.
      * `create_call_count()` / `get_call_count()` — total invocations."""

    var _p: ArcPointer[_FakeState]

    def __init__(out self):
        self._p = ArcPointer[_FakeState](_FakeState())

    def share(self) -> FakePodManager:
        """Return a SECOND `FakePodManager` handle that SHARES this one's
        `_FakeState` (the ArcPointer is copied — the same heap pointee, not a
        clone of the contents). Both handles record into ONE `_FakeState`, so a
        test can hand a distinct handle to each of N job managers and then read
        the AGGREGATE create/delete log + counts off ANY handle. A
        tick-singularity test uses this to assert that across N serving-worker
        services + 1 tick-owner service, the TOTAL pods created equals exactly
        the number of scheduled jobs (one pod per job).

        SAFETY: ArcPointer is reference-counted shared ownership; both handles
        keep the `_FakeState` alive until the last drops. A TEST DOUBLE shared
        across services that run on ONE thread in the test loop (NOT concurrent
        state under a parallelize barrier)."""
        return FakePodManager(_share=ArcPointer[_FakeState](copy=self._p))

    def __init__(out self, *, var _share: ArcPointer[_FakeState]):
        """Private ctor for `share()` — adopt an existing (copied) ArcPointer
        handle so two FakePodManagers point at ONE `_FakeState`."""
        self._p = _share^

    # ---- scripting (test setup) ----

    def set_default_status(self, var status: PlacementStatus):
        """The status returned by `get_status` for any name with no script."""
        self._p[].default_status = status^

    def script_status(self, name: String, var status: PlacementStatus):
        """Enqueue a scripted `get_status` result for `name`. The LAST scripted
        status for a name repeats once earlier ones are consumed."""
        self._p[].status_keys.append(name)
        self._p[].status_vals.append(status^)
        self._p[].status_cursor.append(0)

    def fail_create(self, name: String):
        """Make `create` RAISE when called for `name` (the create-failure path
        the scheduler reverts on)."""
        self._p[].fail_create_for.append(name)

    def set_fail_all(self, on: Bool):
        """Make EVERY `create` RAISE regardless of unit name — the simplest
        deterministic way to exercise the scheduler's revert-to-PENDING
        compensation when the claim mints a fresh random pod_name per tick."""
        self._p[].fail_all_creates = on

    def set_create_fails_after_record(self, on: Bool):
        """Make `create` RECORD the unit into this double's LIVE view and THEN
        raise — the GCP two-mutation shape (`insert_instance` succeeded, the
        operation poll raised), and the verified revert's positive-control
        precondition. `set_fail_all` raises BEFORE recording, which models the
        easy case where nothing leaked; this models the case that leaks."""
        self._p[].create_fails_after_record = on

    def set_rollback_teardown_silently_fails(self, on: Bool):
        """Make `rollback_create`'s TEARDOWN silently do nothing while the verb
        still returns — the verified revert's NEGATIVE control. The unit stays
        in the live view, so the confirming re-read must report it STILL PRESENT
        and the scheduler must NOT report a clean revert."""
        self._p[].rollback_teardown_silently_fails = on

    def set_rollback_raises(self, on: Bool):
        """Make `rollback_create` RAISE — a transport fault on the compensation
        path. The router must map it to COULD-NOT-OBSERVE (`PLACE_UNKNOWN`) and
        must not let a second failure escape the compensation."""
        self._p[].rollback_raises = on

    def set_fail_all_gets(self, on: Bool):
        """Make EVERY `get_status` RAISE regardless of unit name — models a
        persistently-unresolvable poll (the Cloud Run pod manager's WIF/STS
        HTTP-400 on a stale job) so a test can drive the reconcile SERVICE-path
        TTL backstop (a past-TTL job whose get_status keeps failing is declared
        DEAD, not re-polled forever)."""
        self._p[].fail_all_gets = on

    # ---- inspection (test assertions) ----

    def created_names(self) -> List[String]:
        return self._p[].created.copy()

    def last_created_capacity(self) -> Int:
        """The `CAPACITY_*` ordinal of the MOST RECENT successful `create`, or
        `-1` when nothing has been created.

        ⛔ `-1`, NOT `CAPACITY_UNSPECIFIED` (0), FOR NO CREATE AT ALL. Zero is a
        real answer — "a placement happened and stated no capacity" — and it is
        the answer a conformer REFUSES BY NAME. Returning it for "no placement
        happened" would make a test that asserts the refusal pass over a
        scheduler that placed nothing, which is the vacuous-pass shape this
        double already caused once by recording only the unit name."""
        if len(self._p[].created_capacity) == 0:
            return -1
        return self._p[].created_capacity[len(self._p[].created_capacity) - 1]

    def last_created_compute_type(self) -> Int:
        """The `COMPUTE_TYPE_*` ordinal of the MOST RECENT successful `create`,
        or `-1` when nothing has been created — the same `-1`-not-0 argument as
        `last_created_capacity`: 0 is the real answer "a placement happened and
        stated no compute shape", and returning it for "no placement happened"
        makes a no-regression assertion pass over a scheduler that placed
        nothing."""
        if len(self._p[].created_compute_type) == 0:
            return -1
        return self._p[].created_compute_type[
            len(self._p[].created_compute_type) - 1
        ]

    def last_created_validation_run_id(self) raises -> String:
        """The `validation_run_id` the MOST RECENT successful `create` carried.

        ⛔ RAISES WHEN NOTHING WAS CREATED, and that is not fussiness. The EMPTY
        STRING is a real answer here — "a placement happened and named no run",
        i.e. UNATTRIBUTED — and it is the answer the no-regression assertion
        checks for. Returning "" for "no placement happened" would make that
        assertion pass over a scheduler that placed nothing at all, which is the
        vacuous pass this double already caused once by recording only the unit
        name."""
        if len(self._p[].created_validation_run_id) == 0:
            raise Error(
                String(
                    "FakePodManager.last_created_validation_run_id: NOTHING was"
                    " created. This raises rather than returning \"\", because"
                    " \"\" is the real answer for an UNATTRIBUTED placement --"
                    " so returning it here would let a no-regression assertion"
                    " pass against a scheduler that never placed anything."
                )
            )
        return self._p[].created_validation_run_id[
            len(self._p[].created_validation_run_id) - 1
        ].copy()

    def created_capacity_at(self, i: Int) -> Int:
        """The capacity ordinal recorded for the i-th successful `create`, or
        `-1` if out of range (see `last_created_capacity` for why not 0)."""
        if i < 0 or i >= len(self._p[].created_capacity):
            return -1
        return self._p[].created_capacity[i]

    def deleted_names(self) -> List[String]:
        return self._p[].deleted.copy()

    def rolled_back_names(self) -> List[String]:
        """The unit names `rollback_create` was called for, in order."""
        return self._p[].rolled_back.copy()

    def op_log(self) -> List[String]:
        """★ THE ORDERED, CROSS-VERB CALL LOG (`create:<n>` / `delete:<n>` /
        `rollback:<n>`) — the ONLY surface on this double that can express an
        ORDER between two different verbs. `created_names()` and
        `deleted_names()` cannot: delete-then-create and create-then-delete
        produce identical contents in both."""
        return self._p[].ops.copy()

    def op_index(self, entry: String) -> Int:
        """The index of `entry` in `op_log()`, or -1 when it never happened.

        ⛔ `-1` FOR ABSENT, AND A CALLER MUST TREAT IT AS ABSENT RATHER THAN AS
        "EARLY". `a < b` with a missing `a` is exactly how an ordering assertion
        passes over a step that never ran, so an order test has to assert both
        indices are `>= 0` first."""
        for i in range(len(self._p[].ops)):
            if self._p[].ops[i] == entry:
                return i
        return -1

    def live_names(self) -> List[String]:
        """★ WHAT THIS DOUBLE BELIEVES EXISTS RIGHT NOW — its LIVE view, not its
        script and not its call log. `len(live_names())` is the answer to "how
        many placements are standing", which is the question a leak is."""
        return self._p[].live.copy()

    def live_status(self, name: String) -> PlacementStatus:
        """★ THIS DOUBLE'S **LIVE API** — what actually exists right now, with no
        script and no cache consulted.

        ⛔ IT IS DELIBERATELY NOT `get_status`. `get_status` answers the SCRIPT
        (and, like the production `Ec2VmPodManager`, would answer a TOMBSTONE
        before it asked anything). The verified revert's positive control has
        to be asserted against the live view or a mutant that re-reads the cache
        is green against it. `PLACE_RUNNING` when the unit exists,
        `PLACE_NOTFOUND` when it does not."""
        for i in range(len(self._p[].live)):
            if self._p[].live[i] == name:
                return PlacementStatus.running()
        return PlacementStatus.not_found()

    def cache_says_gone(self, name: String) -> Bool:
        """True iff a teardown has written this double's TOMBSTONE for `name` —
        the cache a mutant would consult instead of the live API. The falsifier
        asserts against THIS, not only against the instance record."""
        for i in range(len(self._p[].cache_gone)):
            if self._p[].cache_gone[i] == name:
                return True
        return False

    def create_call_count(self) -> Int:
        return self._p[].create_calls

    def get_call_count(self) -> Int:
        return self._p[].get_calls

    # ---- the PodManager (placement) surface ----

    def create(self, spec: PlacementSpec) raises:
        self._p[].create_calls += 1
        # The ORDERED log records the ATTEMPT — before any scripted failure —
        # because "when was the create API called" is the question an ordering
        # assertion asks, and a create that raised still reached the cloud.
        self._p[].ops.append(String("create:") + spec.name)
        # ⛔ THE TWO-MUTATION SHAPE FIRST — it is the one that LEAKS. GCP's
        # create is `insert_instance` THEN `_poll_op_to_done`, and the second
        # half raising is fully consistent with a live, billing instance. This
        # arm records the unit into the LIVE view and only then raises.
        if self._p[].create_fails_after_record:
            self._untomb(spec.name)
            self._p[].live.append(spec.name)
            raise Error(
                String(
                    "FakePodManager: scripted create failure AFTER the unit was"
                    " recorded (the two-mutation shape) for "
                )
                + spec.name
            )
        # Scripted failure (name-agnostic OR per-name)?
        if self._p[].fail_all_creates:
            raise Error(
                String("FakePodManager: scripted create failure (fail_all) for ")
                + spec.name
            )
        for i in range(len(self._p[].fail_create_for)):
            if self._p[].fail_create_for[i] == spec.name:
                raise Error(
                    String("FakePodManager: scripted create failure for unit ")
                    + spec.name
                )
        self._p[].created.append(spec.name)
        # Placing a name this double previously tore down RESURRECTS it (the
        # `Ec2VmPodManager._untombstone` shape).
        self._untomb(spec.name)
        self._p[].live.append(spec.name)
        # ⛔ RECORD THE CAPACITY THE PLACEMENT ASKED FOR, not just that one
        # happened — see `_FakeState.created_capacity`. A double that keeps only
        # the name makes every other field of the request unassertable.
        self._p[].created_capacity.append(spec.capacity)
        self._p[].created_compute_type.append(spec.compute_type)
        self._p[].created_validation_run_id.append(
            spec.validation_run_id.copy()
        )

    def get_status(
        self, namespace: String, name: String
    ) raises -> PlacementStatus:
        self._p[].get_calls += 1
        # Scripted persistent failure — models the Cloud Run pod manager's
        # WIF/STS HTTP-400 on a stale job (the poll is UNRESOLVABLE; the
        # reconciler must fall to its TTL backstop, not loop forever).
        if self._p[].fail_all_gets:
            raise Error(
                String("FakePodManager: scripted get_status failure (fail_all)")
                + String(" for ")
                + name
            )
        # Find the FIRST scripted key for `name` whose cursor is not yet past
        # its (single) value; the last value repeats. A name may have multiple
        # scripted entries (a FIFO of distinct statuses across reconcile ticks).
        var best_idx = -1
        for i in range(len(self._p[].status_keys)):
            if self._p[].status_keys[i] == name:
                if self._p[].status_cursor[i] == 0:
                    best_idx = i
                    break
                # already consumed; remember as the repeat-last fallback
                best_idx = i
        if best_idx >= 0:
            # Mark this entry consumed (cursor=1) UNLESS it is the only/last
            # remaining for the name (so a lone script repeats).
            var has_unconsumed_after = False
            for j in range(best_idx + 1, len(self._p[].status_keys)):
                if (
                    self._p[].status_keys[j] == name
                    and self._p[].status_cursor[j] == 0
                ):
                    has_unconsumed_after = True
                    break
            if has_unconsumed_after:
                self._p[].status_cursor[best_idx] = 1
            return self._p[].status_vals[best_idx].copy()
        return self._p[].default_status.copy()

    def delete(self, namespace: String, name: String) raises:
        self._p[].deleted.append(name)
        self._p[].ops.append(String("delete:") + name)
        self._teardown(name)

    # ---- the VERIFIED-REVERT surface ----

    def _untomb(self, name: String):
        var i = 0
        while i < len(self._p[].cache_gone):
            if self._p[].cache_gone[i] == name:
                _ = self._p[].cache_gone.pop(i)
            else:
                i += 1

    def _teardown(self, name: String):
        """Remove `name` from the LIVE view and write the TOMBSTONE — the
        `Ec2VmPodManager.delete` shape (terminate, then tombstone so a later
        poll does not re-adopt what was just torn down)."""
        var i = 0
        while i < len(self._p[].live):
            if self._p[].live[i] == name:
                _ = self._p[].live.pop(i)
            else:
                i += 1
        if not self.cache_says_gone(name):
            self._p[].cache_gone.append(name)

    def rollback_create(
        self, namespace: String, name: String
    ) raises -> PlacementStatus:
        """VERIFIED REVERT — tear the unit down, then CONFIRM through this
        double's LIVE view (`live_status`), never through the script and never
        through the tombstone `_teardown` just wrote.

        ⛔ RETURNING `live_status` RATHER THAN `get_status` IS THE ASSERTION
        UNDER TEST, not an implementation detail. `get_status` here answers the
        SCRIPT, exactly as the production `Ec2VmPodManager.get_status` answers
        the TOMBSTONE — so a mutant that swaps this line for `get_status`
        reports CONFIRMED-GONE for a unit that is still running, and a
        falsifier must catch exactly that."""
        self._p[].rolled_back.append(name)
        self._p[].ops.append(String("rollback:") + name)
        if self._p[].rollback_raises:
            raise Error(
                String(
                    "FakePodManager: scripted rollback_create transport fault"
                    " for "
                )
                + name
            )
        if not self._p[].rollback_teardown_silently_fails:
            self._p[].deleted.append(name)
            self._p[].ops.append(String("delete:") + name)
            self._teardown(name)
        # THE CONFIRMING RE-READ, through the LIVE view.
        return self.live_status(name)
