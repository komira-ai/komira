# =============================================================================
# kci_reconciler/resource.mojo — the provider-neutral RESOURCE abstraction of the
#   resource-graph deploy engine (open-core; no cloud, provider or deployment
#   coupling).
# =============================================================================
#
# THE THESIS. A deploy is a GRAPH of desired resources reconciled against LIVE
# actual state. Each node is a `Resource`: a deterministic `logical_id` (the
# graph-stable key), its `depends_on` edges (this IS the graph), a `retention`
# policy, and the reconcile verbs (read-status / plan / create / update / delete /
# converge_mode). The engine (engine.mojo) topo-sorts the graph and drives the
# verbs; the graph (graph.mojo) holds the erased nodes; the state store (state.mojo)
# is the write-ahead intent ledger. This file is the neutral CONTRACT they share.
#
# WHY NEUTRAL (no provider knowledge here). `Resource` never names a cloud, a
# transport, a proto, or a DB. A GCP CloudRunService conformer, an AWS Lambda
# conformer, an on-prem systemd-unit conformer all implement the SAME trait; the
# engine reconciles any of them identically. Credentials arrive as an opaque
# `Creds` value the CALLER supplies per-call — the engine never mints, owns, or
# inspects a credential (custody stays with the caller). For tests `Creds` is a
# trivial struct.
#
# ENCAPSULATION. Every surface is value-typed: `String` / `List[String]`
# / `Int` / `ResourceStatus` / `ChangeAction` / `Creds` in and out, `raises` for a
# backend fault. ZERO `UnsafePointer` crosses any boundary; NO wildcard origin; NO
# `unsafe_from_address`. The status/action structs are flat value PODs
# (`String` + `Int` fields only, no nested heap-owning struct in a byte-slab),
# so no stale-pointer hazard across destroy and recreate. Mojo 1.0.0b2 (def-only).
# =============================================================================


# The trait's `fault_domain` default. Importing ONE constant from a leaf module
# that imports nothing keeps this file's dependency surface at zero cycles.
from kci_reconciler.fault_domain import FAULT_UNSET
from kci_reconciler.outputs import InputRef, Outputs, ResolvedInputs
from kci_reconciler.ownership import OwnerStamp


# =============================================================================
# §0 — the resource PHASE codes (read_status / plan discriminants). A resource's
#      LIVE phase relative to the desired spec: absent (create), present-matched
#      (no-op), present-drifted (update-or-replace), converging, failed.
# =============================================================================
comptime RES_ABSENT: Int = 0
"""The live-read found nothing (a 404) -> the resource must be CREATED."""
comptime RES_PRESENT_MATCHED: Int = 1
"""The live resource == the desired spec -> a NO-OP (nothing to converge)."""
comptime RES_PRESENT_DRIFTED: Int = 2
"""The live resource != the desired spec -> UPDATE (or, when the diff needs a
replace, a v1-unsupported REPLACE — see CONVERGE_REPLACE)."""
comptime RES_CONVERGING: Int = 3
"""The live resource is reconciling toward the desired spec (not yet settled)."""
comptime RES_FAILED: Int = 4
"""The live resource is in a failed terminal state. It exists and does not run
what the file asks, so apply treats it like a drift: an in-place update (a
fixed image after a bad one) is how it recovers."""


# =============================================================================
# §1 — the RETENTION codes. Whether the engine may DELETE a resource on rollback
#      + destroy. THREE codes on ONE axis, and the axis answers TWO DIFFERENT
#      QUESTIONS:
#
#        * a POLICY question — "should a teardown take this?" — whose answer an
#          operator holding authority is entitled to OVERRIDE (`--delete-data` /
#          `destroy_graph(force_delete_data=True)`); and
#        * a CAPABILITY question — "CAN this graph delete this at all?" — which
#          no flag may override, because the answer is a fact about what this
#          codebase can do, not about what the operator wants.
#
#      RETAIN_DELETE and RETAIN_KEEP are the two POLICY answers.
#      RETAIN_UNDELETABLE is the CAPABILITY answer.
#
#      ⛔ WHY THE THIRD CODE EXISTS AT ALL. `force_delete_data` lifts the
#      RETAIN_KEEP skip. If KEEP carried both meanings, lifting it would reach
#      resources whose conformer has NO delete arm — the AWS ECR repository
#      (`RegistryDescriptor.delete` refuses under ANY retention) and an
#      externally-owned AWS deploy role (`AwsIamRoleConformer.delete` refuses a
#      role created out-of-band). The engine would issue the delete, the
#      conformer would raise, and the reverse walk would STOP — so a
#      whole-project `--delete-data` teardown could never complete on AWS while
#      the GCP peers deleted under the identical flag. The clouds genuinely
#      diverge in delete CAPABILITY; the model must be able to say so.
# =============================================================================
comptime RETAIN_DELETE: Int = 0
"""The engine DELETES this resource on rollback-of-a-create + on destroy (an
app-owned resource — its lifecycle is the deploy's)."""
comptime RETAIN_KEEP: Int = 1
"""KEPT BY POLICY, AND OVERRIDABLE. The engine does not delete this resource in
the ordinary course (a standing / shared resource — the cell-shared
bootstrap bucket, the WIF pool, the VPC — provisioned once and only ever READ by a
deploy), so rollback_create + destroy_graph SKIP it. An operator who has
explicitly opted into destroying data-bearing / shared scope
(`destroy_graph(force_delete_data=True)`, the `--delete-data` whole-project
teardown) LIFTS that skip and the resource IS deleted. That override is the whole
point of this code: it states a decision, and a decision can be reversed."""
comptime RETAIN_UNDELETABLE: Int = 2
"""⛔ NO DELETE CAPABILITY EXISTS FOR THIS RESOURCE IN THIS CODEBASE, AND NO FLAG
OVERRIDES IT. rollback_create + destroy_graph SKIP this node UNCONDITIONALLY —
`force_delete_data` does NOT lift this skip, because it is not a policy to lift.

A conformer returns this when its own `delete` would REFUSE, or when there is no
delete path wired at all: deleting the resource is either impossible for this
graph or provably wrong in a way the graph cannot distinguish from the safe case.
It is a statement about US, not about the resource's value.

⛔ IT IS NOT AUTHORABLE. There is no `Retention` wire ordinal for it and no
`*Spec` accepts it: `full_manifest.proto`'s `Retention` stays at two policy
members on purpose, and the two data-bearing AWS specs that validate their
threaded retention (`S3BucketSpec.of`, `DynamoTableSpec.of`) refuse anything that
is neither RETAIN_KEEP nor RETAIN_DELETE, which is also the enforcement of
this invariant. A capability is DERIVED by the conformer that owns the verb; a
manifest that could declare a resource undeletable would let an author disable a
teardown from a text file.

⛔ SKIPPING IS NOT REAPING. `destroy_graph` does NOT `mark_reaped` an undeletable
node: the physical resource is still live, and retiring its intent would orphan a
billable resource with no record. The intent is LEFT INTACT, exactly as for a
delete that did not converge.

⚠ IT IS NOT SILENT. `destroy_graph` RETURNS one `UndeletableSkip` per skipped
node (its logical id + the conformer's own `undeletable_reason()`), and the
teardown's caller is expected to render them. A resource that survives a teardown
the operator asked for must be NAMED, with the reason, or the operator reads a
clean exit as a clean account."""


# =============================================================================
# §2 — the CONVERGE mode codes. HOW a drifted resource is converged: in-place, or
#      by replace (delete-then-create). v1 supports IN_PLACE; REPLACE is a typed
#      hole (the engine RAISES "unsupported" rather than silently doing the wrong
#      thing — fail-loud, not a surprise teardown).
# =============================================================================
comptime CONVERGE_NOOP: Int = 0
"""No convergence needed (the live resource already matches)."""
comptime CONVERGE_IN_PLACE: Int = 1
"""Converge by an in-place UPDATE (the v1-supported path)."""
comptime CONVERGE_REPLACE: Int = 2
"""Converge by REPLACE (delete-then-create). v1: the engine RAISES "unsupported"
— a typed hole. A resource whose diff genuinely needs a replace declares this from
`converge_mode`, and the engine refuses to guess a destructive teardown in v1."""


# =============================================================================
# §3 — ResourceStatus — the LIVE actual state a `read_status` returns. Flat value
#      POD (Int + String fields; no pointer field, no nested heap-owning struct).
# =============================================================================
struct ResourceStatus(Copyable, Movable, Deinitable):
    """The observed LIVE state of one resource:
      * `phase`       — one of the RES_* codes (absent / present-matched /
                        present-drifted / converging / failed). The ONLY actual-
                        state source is a live read (never a cached attribute).
      * `physical_id` — the provider-assigned identity of the live resource (the
                        full resource name / ARN / uid). Empty when absent.
      * `live_digest` — the digest/identity the live resource currently runs (the
                        idempotence key the diff compares against the desired).
                        Empty when absent.
      * `message`     — a human-readable detail on a failed / converging read
                        (empty otherwise).
      * `endpoint`    — the served URL of a SERVED node once present (the Cloud Run
                        `uri`). Empty for a
                        non-served node / an absent read. The STATUS subsystem
                        (`deploy_status` / the health gate) publishes this.
      * `live_image`  — the image the live resource is running (the
                        last-good-digest advance keys on it). Empty for a
                        non-image node / an absent read. Distinct from `live_digest`
                        (a served node's live_digest IS its live image, but
                        the two are kept separate so a non-image node can still
                        carry a digest without implying a served image).
      * `stamp`       — the ownership IDENTITY the live object carries
                        (`OwnerStamp.identity()`, decoded by the conformer from
                        the object's labels), or empty when it carries none.
                        Read only in an OWNED scope (engine.mojo); never part
                        of `live_digest`.
      * `unmanaged`   — a description of differences on fields kci does NOT
                        model (a console-added label, a field the catalog has
                        no word for). Reported by `plan` beside the verb and
                        NEVER converged: kci owns every field it models and
                        touches no other. Empty when there are none.
    Flat-String value POD (all eight fields are single-level owned Int/String —
    no pointer field; never in a byte-slab)."""

    var phase: Int
    var physical_id: String
    var live_digest: String
    var message: String
    # The two STATUS-subsystem fields (endpoint + live_image). Defaulted
    # EMPTY so the 4-arg construction (the raw ctor + the factories
    # below) needs neither; a served node populates them in `read_status`.
    var endpoint: String
    var live_image: String
    # The ownership and the unmodelled-difference fields, defaulted EMPTY for
    # the same reason (a conformer that does not stamp never sets them).
    var stamp: String
    var unmanaged: String

    def __init__(
        out self,
        phase: Int,
        physical_id: String,
        live_digest: String,
        message: String,
        endpoint: String = String(""),
        live_image: String = String(""),
        stamp: String = String(""),
        unmanaged: String = String(""),
    ):
        """The flat POD ctor. `endpoint` + `live_image` + `stamp` +
        `unmanaged` default EMPTY so a 4-arg call (raw
        `ResourceStatus(phase, pid, digest, msg)` + the factories) needs none
        of them."""
        self.phase = phase
        self.physical_id = physical_id.copy()
        self.live_digest = live_digest.copy()
        self.message = message.copy()
        self.endpoint = endpoint.copy()
        self.live_image = live_image.copy()
        self.stamp = stamp.copy()
        self.unmanaged = unmanaged.copy()

    def is_absent(self) -> Bool:
        return self.phase == RES_ABSENT

    def is_matched(self) -> Bool:
        return self.phase == RES_PRESENT_MATCHED

    def is_drifted(self) -> Bool:
        return self.phase == RES_PRESENT_DRIFTED

    def is_present(self) -> Bool:
        """True iff the live read found a resource (matched / drifted / converging /
        failed) — i.e. NOT absent. The engine's destroy path deletes only present
        resources."""
        return self.phase != RES_ABSENT

    @staticmethod
    def absent() -> ResourceStatus:
        return ResourceStatus(RES_ABSENT, String(""), String(""), String(""))

    @staticmethod
    def matched(
        physical_id: String,
        live_digest: String,
        endpoint: String = String(""),
        live_image: String = String(""),
        stamp: String = String(""),
        unmanaged: String = String(""),
    ) -> ResourceStatus:
        """A present-matched status. `endpoint` + `live_image` default EMPTY
        for a non-served node; a served node passes its live served URL + image so
        the STATUS subsystem can surface them. A stamping conformer passes the
        live `stamp`; any conformer passes `unmanaged` differences."""
        return ResourceStatus(
            RES_PRESENT_MATCHED,
            physical_id,
            live_digest,
            String(""),
            endpoint,
            live_image,
            stamp,
            unmanaged,
        )

    @staticmethod
    def drifted(
        physical_id: String,
        live_digest: String,
        endpoint: String = String(""),
        live_image: String = String(""),
        stamp: String = String(""),
        unmanaged: String = String(""),
    ) -> ResourceStatus:
        """A present-drifted status. `endpoint` + `live_image` default EMPTY
        for a non-served node; a served node passes its live served URL + image.
        `stamp` and `unmanaged` as for `matched`."""
        return ResourceStatus(
            RES_PRESENT_DRIFTED,
            physical_id,
            live_digest,
            String(""),
            endpoint,
            live_image,
            stamp,
            unmanaged,
        )


# =============================================================================
# §4 — ChangeAction — the plan verb a `plan(live)` returns (a PURE diff — no
#      mutation). Flat value POD. The engine's `plan_graph` returns a list of
#      these (a dry-run); `apply_graph` acts on the live re-read, not this.
# =============================================================================
comptime VERB_NOOP: Int = 0
"""The planned action: do nothing (the live resource matches the desired)."""
comptime VERB_CREATE: Int = 1
"""The planned action: create the resource (it is absent)."""
comptime VERB_UPDATE: Int = 2
"""The planned action: update the resource in place (it drifted, IN_PLACE)."""
comptime VERB_REPLACE: Int = 3
"""The planned action: replace the resource (it drifted, needs REPLACE). v1: the
engine RAISES on this at apply time (the typed hole)."""
comptime VERB_DELETE: Int = 4
"""The planned action: delete the resource (destroy / rollback)."""

comptime VERB_KNOWN_AFTER_APPLY: Int = 5
"""A DRY-RUN-ONLY verb: the node consumes a value a producer will only have
after the producer is created or changed, so its desired state cannot be known
yet. `plan_graph` reports it as "may change", never as a no-op, and does not
read the node (its desired digest would be over an unresolved reference).
`apply_graph` never returns it: at apply time the producer runs first."""


struct ChangeAction(Copyable, Movable, Deinitable):
    """One planned change for a resource (the PURE diff `plan` returns):
      * `logical_id` — the graph-stable key of the resource this action targets.
      * `verb`       — one of the VERB_* codes (noop / create / update / replace /
                       delete).
      * `reason`     — a human-readable justification (e.g. "absent -> create",
                       "digest sha256:.. -> sha256:.. drifted -> update").
      * `retention`  — the resource's RETAIN_* policy (so a plan reader can see
                       which nodes a destroy would skip).
      * `owner`      — the id of the authored resource this node was lowered
                       from (`Resource.owner`), so a plan can be grouped under
                       what the author wrote. Empty for a node with no owner.
                       `plan_graph` stamps it; a conformer's `plan` need not.
      * `unmanaged`  — differences on fields kci does not model
                       (`ResourceStatus.unmanaged`), printed beside the verb
                       and never acted on. `plan_graph` copies it.
    Flat-String value POD."""

    var logical_id: String
    var verb: Int
    var reason: String
    var retention: Int
    var owner: String
    var unmanaged: String

    def __init__(
        out self,
        logical_id: String,
        verb: Int,
        reason: String,
        retention: Int,
        owner: String = String(""),
        unmanaged: String = String(""),
    ):
        self.logical_id = logical_id
        self.verb = verb
        self.reason = reason
        self.retention = retention
        self.owner = owner
        self.unmanaged = unmanaged

    def __init__(out self, *, copy: Self):
        self.logical_id = copy.logical_id.copy()
        self.verb = copy.verb
        self.reason = copy.reason.copy()
        self.retention = copy.retention
        self.owner = copy.owner.copy()
        self.unmanaged = copy.unmanaged.copy()

    def is_noop(self) -> Bool:
        return self.verb == VERB_NOOP

    def is_create(self) -> Bool:
        return self.verb == VERB_CREATE

    def is_update(self) -> Bool:
        return self.verb == VERB_UPDATE

    def is_replace(self) -> Bool:
        return self.verb == VERB_REPLACE

    def is_delete(self) -> Bool:
        return self.verb == VERB_DELETE

    def is_known_after_apply(self) -> Bool:
        return self.verb == VERB_KNOWN_AFTER_APPLY

    def verb_name(self) -> StaticString:
        if self.verb == VERB_CREATE:
            return "create"
        if self.verb == VERB_UPDATE:
            return "update"
        if self.verb == VERB_REPLACE:
            return "replace"
        if self.verb == VERB_DELETE:
            return "delete"
        if self.verb == VERB_KNOWN_AFTER_APPLY:
            return "known after apply"
        return "noop"


# =============================================================================
# §5 — Creds — the neutral, opaque per-call credentials value. The engine does NOT
#      mint or own it; the CALLER supplies it per verb (custody stays with the
#      caller). A live conformer carries a short-lived assumed token; a test double
#      carries a label. Value-typed + Copyable (threaded to every verb by value —
#      never a field, never a pointer). Flat-String POD (no pointer field).
# =============================================================================
@fieldwise_init
struct Creds(Copyable, Movable, Deinitable):
    """A neutral, opaque credentials value threaded to every reconcile verb. The
    engine treats it as an opaque token it passes through — it never inspects or
    persists it (custody stays with the caller; the value lives only in the verb
    frame). For a live conformer `token` is a short-lived assumed credential; for a
    test double it is a label. Copyable value POD; NO pointer, NO wildcard."""

    var token: String

    @staticmethod
    def none() -> Creds:
        """The empty credential (the self/local reconcile path — a conformer that
        needs no per-call token, or a test that does not assert the principal)."""
        return Creds(String(""))


# =============================================================================
# §6 — Resource — the provider-neutral reconcile trait. A node of the deploy
#      graph. Value-typed surface only; `raises` for a backend fault. Movable &
#      Deinitable (the graph OWNS its nodes by value, erased).
# =============================================================================
trait Resource(Movable, Deinitable):
    """One provider-neutral resource in the deploy graph. A conformer names a
    concrete provider primitive (a Cloud Run service, a Lambda function, a systemd
    unit) but exposes ONLY this neutral surface, so the engine reconciles any
    conformer identically.

    THE GRAPH IS `depends_on`. `logical_id` is the graph-stable deterministic key
    (the same across re-plans — the intent-ledger adopt key); `depends_on` returns
    the logical_ids this resource depends on (its IN-edges). Together they ARE the
    dependency DAG the engine topo-sorts.

    LIVE IS THE ONLY ACTUAL-STATE SOURCE. `read_status(creds)` reads the live
    provider (it is the ONLY place actual state comes from — never a cached
    attribute on the node). `plan(live)` is a PURE diff over that live status +
    the node's desired state (NO mutation, no I/O). The mutating verbs (`create` /
    `update` / `delete`) act on the live provider AS the caller's `creds`.

    IDEMPOTENCE CONTRACT. `create` returns the physical id; `delete` treats a 404
    as a no-op (idempotent — re-running a converged destroy is safe). `converge_
    mode(live)` returns CONVERGE_IN_PLACE for a v1-updatable drift, or RAISES for a
    drift that genuinely needs a REPLACE (the typed hole — the engine refuses to
    guess a destructive teardown in v1).

    ENCAPSULATION: value-typed in/out only; ZERO UnsafePointer crosses the
    boundary; `raises` for a fault."""

    def logical_id(mut self) -> String:
        """The graph-stable DETERMINISTIC key for this resource (stable across
        re-plans — the intent-ledger adopt key + the topo-sort node identity). Two
        resources with the same logical_id are the SAME graph node.

        NOTE (erasure shape): this + `depends_on` / `retention` / `converge_mode`
        take `mut self` (not `self`). The `ErasedResource` facade must form a
        mutable type-erasure handle to the erased conformer's heap home to invoke
        ANY verb through the fn-ptr vtable (the `ErasedStorageApi` shape — all its
        verbs, reads included, take `mut self`), so the trait's read verbs are
        `mut self` too. A plain (non-erased) conformer implements them trivially
        over `mut self` with no cost; the graph always holds nodes by `mut` ref, so
        no caller is constrained by this."""
        ...

    def depends_on(mut self) -> List[String]:
        """The logical_ids this resource depends on (its IN-edges). Empty for a
        root. THIS is the graph: the engine builds the DAG from every node's
        `depends_on` and topo-sorts it (Kahn). A dependency naming a logical_id not
        in the graph, or a cycle, is a fail-loud error in the engine. `mut self`
        (see `logical_id` for the erasure-shape rationale)."""
        ...

    def retention(mut self) -> Int:
        """★ THE ONE SOURCE OF TRUTH FOR WHETHER A TEARDOWN MAY TAKE THIS NODE —
        one of the THREE RETAIN_* codes (§1), covering two different questions:

          * RETAIN_DELETE   — ours to remove; the engine deletes it on
                              rollback-of-a-create + on destroy.
          * RETAIN_KEEP     — kept BY POLICY (a standing / shared resource — the
                              shared-bucket-retention invariant). destroy_graph
                              skips it, and `force_delete_data` LIFTS that skip.
          * RETAIN_UNDELETABLE — this graph has NO delete capability for the
                              resource. destroy_graph skips it UNCONDITIONALLY;
                              no flag lifts it, and the skip is REPORTED.

        ⛔ THE ENGINE ASKS ONLY THIS FUNCTION. There is no exempt-list, no
        per-kind special case and no second table anywhere: a conformer that
        refuses its own `delete` says so HERE, and the refusal and the retention
        cannot then disagree. A kind added tomorrow is covered by construction.

        `mut self` (see `logical_id` for the erasure-shape rationale)."""
        ...

    def undeletable_reason(mut self) -> String:
        """WHY this node is RETAIN_UNDELETABLE, in the operator's words — read by
        `destroy_graph` when it skips the node, and rendered by the teardown's
        caller. Empty for a node that is not undeletable.

        DEFAULT = EMPTY, which is correct for every RETAIN_DELETE / RETAIN_KEEP
        conformer. A
        conformer that returns RETAIN_UNDELETABLE from `retention()` and leaves
        this empty is a DEFECT in that conformer — the engine substitutes a
        generic sentence that says so rather than dropping the node from the
        report, because a silent survivor is the failure mode this whole axis
        exists to remove.

        ⚠ STATE THE CONSEQUENCE, NOT THE VERB. "no delete path is wired" tells an
        operator nothing they can act on; "deleting this repository deletes every
        image in it and a function pinned to a digest there stops being able to
        cold-start" tells them whether to go do it by hand. This is the same
        prose the conformer's `delete` refusal carries, at the one place the
        engine can read it WITHOUT issuing the delete.

        `mut self` (see `logical_id` for the erasure-shape rationale)."""
        return String("")

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        """Read the LIVE actual state of this resource AS `creds` -> a
        ResourceStatus. This is the ONLY actual-state source (never a cached
        attribute). A 404 -> RES_ABSENT; a live resource whose digest matches the
        desired -> RES_PRESENT_MATCHED; a live resource that differs ->
        RES_PRESENT_DRIFTED; else converging / failed. RAISES on a genuine backend
        fault (NOT on a 404 — a 404 is the ABSENT status, not an error)."""
        ...

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        """A PURE diff: given the live status (from `read_status`), return the
        ChangeAction that would converge this resource — WITHOUT mutating anything
        (no I/O, no side effect). RES_ABSENT -> VERB_CREATE; RES_PRESENT_MATCHED ->
        VERB_NOOP; RES_PRESENT_DRIFTED or RES_FAILED -> VERB_UPDATE (IN_PLACE) or VERB_REPLACE
        (needs replace). The engine's `plan_graph` collects these for a dry-run;
        `apply_graph` re-reads live and acts, it does not replay this."""
        ...

    def create(mut self, creds: Creds) raises -> String:
        """Create the resource on the live provider AS `creds` and return its
        provider-assigned PHYSICAL id (the id the state store confirms the intent
        with). The absent-branch verb. RAISES on a genuine backend fault."""
        ...

    def update(mut self, creds: Creds) raises:
        """Converge the resource IN PLACE on the live provider AS `creds` (the
        drifted-branch verb, CONVERGE_IN_PLACE). RAISES on a genuine backend
        fault."""
        ...

    def delete(mut self, physical_id: String, creds: Creds) raises:
        """Delete the resource `physical_id` on the live provider AS `creds`.
        IDEMPOTENT: a 404 (already gone) is a NO-OP (not an error) — re-running a
        converged destroy / rollback is safe. RAISES on a genuine backend fault."""
        ...

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        """HOW a drift (RES_PRESENT_DRIFTED, or RES_FAILED) is converged: CONVERGE_IN_PLACE (the
        v1-supported update) or a RAISE for a drift that genuinely needs a REPLACE
        (delete-then-create). v1 has NO replace path — a conformer that returns
        CONVERGE_REPLACE, or raises here, makes the engine surface a clear
        "CONVERGE_REPLACE unsupported in v1" error rather than guess a destructive
        teardown. For a matched / absent live this is CONVERGE_NOOP (never
        called on those paths, but well-defined). `mut self` (see `logical_id` for
        the erasure-shape rationale)."""
        ...

    def prune(mut self, creds: Creds) raises:
        """PRUNE older resource VERSIONS this node retains, AS `creds` — the lazy
        retention verb the engine calls (BEST-EFFORT) after a successful create /
        update. This is a DIFFERENT axis from `retention()` (RETAIN_* is may-delete-
        on-teardown; prune bounds how many VERSIONS survive a FORWARD deploy, e.g.
        Cloud Run revisions beyond the newest `keep_last_n`).

        DEFAULT = NO-OP. A non-versioned node (an IamRole / Secret / Config / bucket
        / a RETAIN_KEEP standing resource) has no versions to prune, so the trait
        default does nothing — only a conformer that owns pruneable versions (the
        Cloud Run ServerlessCompute node) OVERRIDES this. NEVER deletes the serving
        version; a not-found on a version delete is treated as already-gone
        (idempotent). RAISES only on a genuine backend fault (the engine SWALLOWS a
        prune fault — a prune must never fail the deploy). `mut self` (the erasure-
        shape rationale — see `logical_id`)."""
        pass

    def fault_domain(mut self, verb: String) raises -> Int:
        """WHOSE FAULT is a failure of `verb` ON THIS NODE — a FAULT_* code
        (`kci_reconciler.fault_domain`). `verb` is the `Resource` verb that raised:
        `read_status` / `create` / `update` / `delete`.

        DEFAULT = `FAULT_UNSET`, WHICH READS AS **OURS**. A conformer that has
        not been considered attributes its failures to US, which is the only safe
        direction: the alternative is filing our own bugs as somebody else's and
        never hearing about them. A conformer refines this by OVERRIDING — there
        is no edit anywhere else and no registry to keep in sync.

        ⛔ NO ERROR TEXT IS PASSED, DELIBERATELY. Vendor prose is not a
        classifier: GCP words a permanent malformed-member fault and a transient
        propagation window identically, and deploy failures that are OURS
        often read, in their own words, like
        somebody else's. Because the text is not available here, an override
        cannot regress into prose-matching — it can only state what it knows
        about its OWN verb.

        ⚠ THIS IS A PER-VERB CLAIM, NOT A PER-ERROR ONE, so it is the WEAKER of
        the two carriers on purpose. A conformer that needs per-raise precision
        (a 403 that means one thing on a grant and another on a project service)
        states it AT THE RAISE with `fault_error(FAULT_USER, "...")`, and the
        engine takes that in preference to this. Use this for what is true of
        EVERY failure of the verb; use `fault_error` for what is true of one.

        A conformer whose verb can fail EITHER way and cannot tell must return
        `FAULT_UNSET` and leave it ours. Guessing `FAULT_USER` to reduce
        noise is the one change this design cannot survive.

        ⚠ `raises` ONLY BECAUSE THE ERASURE VTABLE IS UNIFORMLY RAISING — AN
        OVERRIDE MUST NOT ACTUALLY RAISE. A classifier that fails is a classifier
        that produced no classification, so `engine._node_fault_domain` catches
        anything that comes out of here and returns `FAULT_UNSET`, i.e. OURS.
        That is the fail-safe, not the contract: do not write an override that
        leans on it.

        `mut self` (the erasure-shape rationale — see `logical_id`)."""
        return FAULT_UNSET

    # ---- apply-time value flow (kci_reconciler/outputs.mojo) ----------------
    #
    # ⚠ EVERY ONE OF THESE HAS A DEFAULT, AND EVERY ONE IS FORWARDED BY
    # `ErasedResource`. A defaulted verb that the erased facade does not forward
    # is silently answered by THIS default for every node of a real graph (the
    # graph only holds erased nodes), so a new verb here is a new vtable entry
    # there, pinned by `test_resource_outputs`'s probe.

    def input_refs(mut self) -> List[InputRef]:
        """The values this node CONSUMES from other nodes. Each is a graph edge
        (the producer is ordered first; a producer not in the graph is refused)
        in addition to `depends_on`, so an author never has to keep a
        dependency list and a reference list in step.

        DEFAULT = NONE. `mut self` (the erasure-shape rationale — see
        `logical_id`)."""
        return List[InputRef]()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        """Receive the values of `input_refs`, one per ref, in declared order.
        The engine calls this AFTER every producer has been applied (or, in a
        dry run, read as unchanged) and BEFORE this node's `read_status`, so
        the desired state the node is read and planned against holds real
        values, never a placeholder.

        DEFAULT = NO-OP, correct for a node with no `input_refs`."""
        pass

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        """The named values this node PRODUCES, for the resource `physical_id`,
        reading AS `creds` if it must read (a node created in this run has not
        been read since it was created). Called after every apply of the node,
        whatever the verb, so an adopted node's values are re-derived from its
        latest live read rather than trusted from state (a value that drifted
        in the cloud is seen).

        DEFAULT = NONE."""
        return Outputs()

    def owner(mut self) -> String:
        """The id of the authored resource this node was lowered from (one
        authored resource lowers to several engine nodes). Stamped on every
        `ChangeAction` by `plan_graph`, so a plan groups under what the author
        wrote.

        DEFAULT = EMPTY."""
        return String("")

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        """The live read TEARDOWN uses: is the resource there, and what is its
        physical id. `destroy_graph` calls this, never `read_status`, because
        teardown compares nothing against a desired state, and a consumer's
        desired state may not be computable then: `destroy_graph` binds a
        node's `input_refs` only from the outputs the store persisted, and a
        store that persists none leaves the node unbound, where the digest
        rule makes `desired_digest` raise `UNBOUND`.

        ⛔ THE PHASE IS PRESENT-OR-ABSENT ONLY. An override answers ABSENT
        exactly where `read_status` would (a real not-found, never a transient
        or an AccessDenied) and otherwise a PRESENT phase carrying the physical
        id; the matched/drifted distinction is not computed and must not be
        planned on.

        DEFAULT = `read_status(creds)`, correct for a node with no
        `input_refs`. A node with references overrides it (the descriptor
        driver does)."""
        return self.read_status(creds)

    # ---- ownership and the closed world (kci_reconciler/ownership.mojo) -----
    #
    # ⚠ Same rule as the value-flow verbs: every one has a default and every
    # one is forwarded by `ErasedResource`, pinned by
    # `test_ownership_and_cell_keys`'s probe.

    def stamps_ownership(mut self) -> Bool:
        """True iff this node implements `create_owned` (and `adopt_owned`)
        and reports the live object's identity in `ResourceStatus.stamp`. An
        OWNED apply refuses a graph holding a node that answers False, before
        any change: a node that cannot stamp would create objects nobody can
        later prove are kci's.

        DEFAULT = FALSE."""
        return False

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        """Create the resource AS `creds` CARRYING `stamp` in the same call
        (the identity as labels, or as the description's first line on an
        object that cannot carry labels; the provenance as annotations; the
        stamp's validation run, when it has one, as the cloud's run-id
        label), and return its physical id. The owned scope's create: there is never a
        moment when an object kci made exists without its stamp.

        DEFAULT = REFUSE (the engine checks `stamps_ownership` first, so this
        is reached only by a conformer that answers True and forgot it)."""
        raise Error(
            String("create_owned: node '")
            + self.logical_id()
            + String("' does not stamp ownership")
        )

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        """Stamp the EXISTING unstamped object `physical_id` with `stamp`: the
        explicit `adopt` takeover, and nothing else calls it. The
        stamp's validation run is NOT written: the run did not create the
        object, so it must not be able to claim it.

        DEFAULT = REFUSE."""
        raise Error(
            String("adopt_owned: node '")
            + self.logical_id()
            + String("' cannot adopt an existing object")
        )

    def wanted(mut self) -> Bool:
        """False for a node the file no longer asks for: a role of an authored
        resource that is now off (`public {}` turned `internal {}`, a removed
        schedule or `uses` line). Lowering emits it anyway, so the closed set
        of roles is converged: apply deletes the object if it is present AND
        the store recorded it (and, in an owned scope, it carries this node's
        stamp); a present object the store never recorded is left and
        reported as leftover.

        DEFAULT = TRUE."""
        return True
