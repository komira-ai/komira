# =============================================================================
# kci_reconciler/described_resource.mojo — the RESOURCE DESCRIPTOR and the generic
#   driver that turns one into a `Resource`. The answer to "we cannot autogen the
#   CDK-like layer, so how do we stop hand-writing the same boilerplate for every resource".
# =============================================================================
#
# ── WHAT THIS FILE REMOVES ───────────────────────────────────────────────────
# Inside a set of hand-written `Resource` conformers, normalizing away type
# names and string literals shows the same program written once per conformer:
#
#   * `logical_id`  — one distinct body. `return self._logical_id.copy()`
#   * `depends_on`  — one distinct body. `return self._deps.copy()`
#   * `__init__`    — bodies that differ ONLY in the spec's type name and the
#                     api param letter.
#   * `read_status` — about half is the fixed try / except-is-not-found /
#                     absent / digest / matched-or-drifted envelope.
#   * `plan`        — about half is the fixed ChangeAction scaffolding
#                     (`is_absent -> VERB_CREATE`, `is_matched -> VERB_NOOP`,
#                     else `VERB_UPDATE`).
#   * `delete`      — a fifth is the fixed 404-is-a-no-op idempotence envelope.
#   * the `make_*_node` erase wrapper — the same six statements with a different
#     struct named.
#
# ⇒ The duplication is not AWS-specific: `komira_gcp_bridge`'s conformers carry
#   the identical `logical_id` / `depends_on` / `_is_not_found_error ->
#   ResourceStatus.absent()` shape. That is why this lives in the neutral core
#   and not in an AWS-only helper. The conformer prose that carries the
#   hard-won quirks is NOT duplication — see the escape-hatch section below.
#
# ── ⛔ WHY THE `Resource` TRAIT COULD NOT ABSORB IT ITSELF ────────────────────
# The obvious fix — give `Resource.logical_id` a default body — is IMPOSSIBLE in
# Mojo, and the reason is structural rather than an oversight in `resource.mojo`.
# **A Mojo trait carries no storage.** It can require methods and it can supply a
# default BODY (`Resource.prune` does exactly that), but it cannot require a
# FIELD, so a default `logical_id` has no `self._logical_id` to return.
#
# There is therefore no such thing as an abstract base class with state here, and
# the only construct that can own the fields AND satisfy the trait is a GENERIC
# STRUCT that holds them and delegates the rest. That is `DescribedResource[D]`.
#
# ── THE SPLIT: WHAT THE ENGINE OWNS vs WHAT THE RESOURCE OWNS ────────────────
# `DescribedResource[D]` owns everything that is identical across conformers:
#   the four fields, the constructor, `logical_id`, `depends_on`, the read
#   envelope, the not-found classification, the plan scaffolding, the delete
#   idempotence envelope, and the erase site.
# `D: ResourceDescriptor` owns everything that is genuinely about ONE resource:
#   how to read it, what its digest is, what its verbs do, what its refusals say.
#
# ⚠ NOTE WHAT IS **NOT** ABSORBED, DELIBERATELY. The DRIFT DIGEST (`desired_digest`
# / `live_digest`) stays entirely in the descriptor. It looked like the best
# generator candidate and it is the worst: it encodes which axes the spec CLAIMS,
# and `S3BucketSpec.live_digest`'s comment is the argument — the digest is a
# method on the SPEC, not the VIEW, so an unauthored axis emits the same token on
# both sides and cannot contribute a difference. A generator reading a service
# model knows the fields; it does not know which of them the author meant to
# assert. Same for `Spec.of` validation: every refusal in it
# is a claim about the world, not about the wire.
#
# ── ⛔ THE ESCAPE HATCHES, AND THE QUIRKS THAT MUST SURVIVE THEM ─────────────
# A framework that makes the common case easy and the quirky case IMPOSSIBLE is
# worse than the duplication it removes. These conformers encode quirks that cost
# real hours to find — Route53 accepting `Z04...` but answering
# `/hostedzone/Z04...`; a Route53 DELETE that must echo the live TTL and values
# EXACTLY or it deletes somebody else's records; `UpdateFunctionCode` leaving
# `LastUpdateStatus:InProgress` so the next verb 409s. THREE hatches, in order of
# how much they give up:
#
#   1. **THE VERB BODIES ARE STILL WHOLE FUNCTIONS.** `create` / `update` /
#      `delete` on the descriptor are not field maps — they receive the spec, the
#      physical id and the token and do whatever the resource requires. A delete
#      that must first read the live RRSET and echo its TTL and values writes
#      exactly that. A create that must poll
#      `LastUpdateStatus` until it leaves `InProgress` writes exactly that.
#      Nothing here sequences a verb for you.
#   2. **EVERY DEFAULT IS OVERRIDABLE.** `converge_mode` defaults to
#      `CONVERGE_IN_PLACE` because that is the common answer; a conformer that
#      must raise a resource-specific refusal instead keeps doing so by
#      overriding it. Same for `prune`, `endpoint`, `live_image`.
#   3. **`Resource` IS STILL A TRAIT, AND IMPLEMENTING IT DIRECTLY IS STILL
#      SUPPORTED.** This is the hatch that matters most, and it is why this file
#      adds a type rather than changing one. `AwsDnsRecordConformer` is the live
#      example of a node this shape does NOT fit: its view carries `zone_found`
#      and `exists` as SEPARATE bools (a name no hosted zone covers demands a
#      refusal; a zone that is present without the record demands a create), and
#      its `_refuse_apex` guard runs before three different verbs. It should keep
#      implementing `Resource` by hand. **A descriptor is an OPTION, never a
#      mandate** — the day a resource does not fit, the answer is to not use it,
#      not to widen it until it fits everything and constrains nothing.
#
# ── ⚠ THE ONE NEW TRAP THIS FILE CREATES, STATED RATHER THAN OMITTED ────────
# The delete envelope swallows a not-found so a re-run of a partial teardown
# converges. That means **a descriptor's DELIBERATE `delete` refusal must not
# contain a not-found token.** `RegistryDescriptor.delete` raises "REFUSED to
# delete the container repository ..." — no `NotFound`, no `404` — so it
# propagates. A refusal worded "... repository not-found in the deletable set"
# would be silently swallowed and the teardown would report success. The
# classifier is the descriptor's own `is_not_found`, so a descriptor can always
# tighten it; but the ordering hazard is real and belongs in the reader's head.
#
# ── ENCAPSULATION + DESTROY/RECREATE SAFETY ─────────────────────────────────
# Value-typed surface only; ZERO UnsafePointer crosses any boundary; NO wildcard
# origin; NO unsafe_from_address. Credentials threaded PER-CALL, never a field —
# `DescribedResource` holds the descriptor, the spec, the logical id and the
# deps, and nothing else. Mojo 1.0.0b2 (def-only).
# =============================================================================

from kci_reconciler.resource import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
    RETAIN_DELETE,
    CONVERGE_IN_PLACE,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_reconciler.fault_domain import FAULT_UNSET
from kci_reconciler.erased_resource import ErasedResource
from kci_reconciler.outputs import InputRef, Outputs, ResolvedInputs
from kci_reconciler.ownership import OwnerStamp


# =============================================================================
# §1 — ResourceDescriptor — everything about ONE resource kind that the engine
#      cannot derive. The methods with a default body are the common answer;
#      overriding one is the escape hatch, not an exception.
# =============================================================================
trait ResourceDescriptor(Movable, Deinitable):
    """The per-resource half of a graph node: how to READ it, what its DIGEST is,
    what its VERBS do, and what its REFUSALS say. A descriptor holds its own
    transport seam (for example an `ArcPointer[Api]`) — the
    driver never sees it, which is what keeps `DescribedResource` free of any
    provider type.

    ⛔ THE DESCRIPTOR IS NOT A FIELD MAP AND MUST NOT BECOME ONE. Its verbs are
    whole functions precisely so that a resource whose delete must echo the live
    record's TTL, or whose update must wait out a provider's `InProgress`
    status, can say so in the only place that knows — see the file header's
    escape-hatch section."""

    comptime Spec: Copyable & Movable & Deinitable
    """The desired state this resource is authored with. OWNS its validation
    (`Spec.of`) and its `desired_digest` — neither is the driver's business."""

    comptime View: Copyable & Movable & Deinitable
    """The live read-back. It is expected to represent states the spec CANNOT —
    a drift that could not be represented could not be reported."""

    def read(mut self, spec: Self.Spec, token: String) raises -> Self.View:
        """Read the live resource AS `token`. RAISES a not-found when absent —
        never a silent empty view, which is indistinguishable from a real
        resource with no configuration. The driver catches that raise and
        classifies it with `is_not_found`."""
        ...

    def is_not_found(self, msg: String) -> Bool:
        """True iff `msg` denotes a not-found.

        ⛔ MATCH ON THE ERROR NAME, NEVER A BARE STATUS. A throttle, an expired
        credential and an AccessDenied are all also non-2xx, and laundering an
        AccessDenied into ABSENT makes the engine CREATE over live infrastructure
        it merely could not read. This is per-resource because the NAME is
        per-service (`NoSuchBucket`, `NoSuchEntity`, `RepositoryNotFound`)."""
        ...

    def exists(self, view: Self.View) -> Bool:
        """True iff the live read found a resource."""
        ...

    def physical_id(self, view: Self.View) -> String:
        """The provider-assigned identity carried by the live view (the ARN, the
        URI, the name)."""
        ...

    def desired_digest(self, spec: Self.Spec) raises -> String:
        """The desired state of the AUTHORED axes, in a fixed order.

        ⚠ UNDER KCI'S CATALOG, "AUTHORED" MEANS EVERY MODELLED FIELD: kci
        owns every field the catalog models, its default included, so a
        descriptor for a catalog type fills defaults into the
        spec before it is digested, and a console edit of a modelled field is
        drift. A field the catalog does not model is never in the digest (it
        is reported through `unmanaged`). PROVENANCE (run id, revision) is
        never in it: `ModelledDigest` (digest.mojo) refuses those names."""
        ...

    def live_digest(self, spec: Self.Spec, view: Self.View) raises -> String:
        """The LIVE state of the SAME axes, in the SAME order.

        ⚠ IT TAKES THE SPEC, and that is the whole mechanism rather than a
        convenience: the spec is what knows which axes it AUTHORED, so an
        unauthored axis emits the identical token on both sides and cannot
        contribute a difference. A view-only digest would have to guess, and the
        two functions would drift apart the first time an axis was added."""
        ...

    def retention(self, spec: Self.Spec) -> Int:
        """The RETAIN_* policy. Derived from the spec (ownership, an operator
        flag) rather than threaded separately, so it cannot disagree with the
        refusals the verbs make."""
        ...

    def reason(
        self, spec: Self.Spec, verb: Int, live: ResourceStatus
    ) raises -> String:
        """The human-readable justification the plan entry carries, for the verb
        the driver has already decided.

        ⚠ THIS IS WHERE THE PROSE LIVES, AND IT IS NOT BOILERPLATE. Of a
        conformer's `plan`, the half that is not scaffolding is this: a
        refusal that only says "no" sends an operator to read the source, one
        that names the knob sends them to the knob. The driver decides WHICH verb;
        the descriptor says WHY."""
        ...

    def create(mut self, spec: Self.Spec, token: String) raises -> String:
        """Create the resource AS `token` and return its PHYSICAL id. A whole
        function: a create that must also stamp four configuration axes, or wait
        for a provider to leave a converging status, does that here."""
        ...

    def update(mut self, spec: Self.Spec, token: String) raises:
        """Converge the resource IN PLACE AS `token`.

        ⚠ RE-STAMP EVERY AUTHORED AXIS, not only the one you believe drifted.
        `read_status` reports ONE drifted status for a node with N axes, so an
        update that repaired the axis it guessed would converge part of the node,
        report success, and drift again on the next plan — forever."""
        ...

    def delete(
        mut self, spec: Self.Spec, physical_id: String, token: String
    ) raises:
        """Delete the resource AS `token`.

        ⚠ A DELIBERATE REFUSAL RAISED HERE MUST NOT CONTAIN A NOT-FOUND TOKEN —
        the driver's idempotence envelope classifies this raise with
        `is_not_found` and SWALLOWS a match. See the file header's trap note."""
        ...

    # ---- the overridable defaults: the common answer, not a mandate --------
    def undeletable_reason(self, spec: Self.Spec) -> String:
        """DEFAULT: empty — correct for every descriptor whose `retention` returns
        a POLICY code (RETAIN_DELETE / RETAIN_KEEP). Only a descriptor that
        returns `RETAIN_UNDELETABLE` overrides it, and when it does the prose
        should be the SAME sentence its `delete` refusal carries: the engine reads
        it at the SKIP, so the refusal itself is never reached and its words would
        otherwise never be seen. See `Resource.undeletable_reason`."""
        return String("")

    def converge_mode(mut self, spec: Self.Spec, live: ResourceStatus) raises -> Int:
        """DEFAULT: CONVERGE_IN_PLACE — the common answer. A conformer that must
        raise a resource-specific refusal for a drift v1 must not act on (an
        externally-owned bucket, a user-owned role) OVERRIDES this.
        The default is the common case, never a claim that
        the uncommon one is unsupported."""
        return CONVERGE_IN_PLACE

    def prune(mut self, spec: Self.Spec, token: String) raises:
        """DEFAULT: no-op. Only a resource that owns pruneable VERSIONS overrides
        it (`Resource.prune`'s contract, unchanged)."""
        pass

    def fault_domain(mut self, spec: Self.Spec, verb: String) raises -> Int:
        """DEFAULT: `FAULT_UNSET`, WHICH READS AS **OURS** (`Resource.
        fault_domain`'s contract, unchanged — see it for why the default is ours
        and why no error text is passed).

        The `spec` is here because a descriptor's attribution can legitimately
        depend on WHAT it was asked to build — the same conformer creating a
        resource in OUR project vs the USER's is the case that makes a
        per-verb constant insufficient — and a descriptor that does not need it
        simply ignores it."""
        return FAULT_UNSET

    def endpoint(self, view: Self.View) -> String:
        """DEFAULT: empty — the served URL of a SERVED node, empty otherwise."""
        return String("")

    def live_image(self, view: Self.View) -> String:
        """DEFAULT: empty — the image a live node runs, empty for a non-image
        node."""
        return String("")

    # ---- apply-time value flow (kci_reconciler/outputs.mojo) ----------------

    def input_refs(self, spec: Self.Spec) -> List[InputRef]:
        """DEFAULT: none — the values this spec reads from other nodes."""
        return List[InputRef]()

    def bind_inputs(
        self, mut spec: Self.Spec, resolved: ResolvedInputs
    ) raises:
        """Write the resolved values into `spec`. DEFAULT: no-op.

        ⛔ THE SPEC IS MUTABLE HERE AND NOWHERE ELSE. The driver calls this
        before `read`, so `desired_digest` and `live_digest` are always taken
        over a BOUND spec. A descriptor whose spec can hold a reference must
        make `desired_digest` raise `unbound_error` while one is still
        unresolved, never hash a placeholder (a placeholder digest can never
        equal a live one, so every plan would read as drift)."""
        pass

    def outputs(self, spec: Self.Spec, view: Self.View) -> Outputs:
        """DEFAULT: none — the named values this resource produces, from its
        latest live view."""
        return Outputs()

    # ---- ownership and the closed world (kci_reconciler/ownership.mojo) -----

    def stamps_ownership(self) -> Bool:
        """DEFAULT: False. A descriptor that overrides `create_owned`,
        `adopt_owned` and `stamp_of` answers True."""
        return False

    def create_owned(
        mut self, spec: Self.Spec, stamp: OwnerStamp, token: String
    ) raises -> String:
        """Create AS `token` CARRYING `stamp` in the same call; return the
        physical id. DEFAULT: refuse."""
        raise Error(String("this descriptor does not stamp ownership"))

    def adopt_owned(
        mut self,
        spec: Self.Spec,
        stamp: OwnerStamp,
        physical_id: String,
        token: String,
    ) raises:
        """Stamp the existing object `physical_id` (a resource's explicit `adopt`).
        DEFAULT: refuse."""
        raise Error(String("this descriptor cannot adopt an existing object"))

    def stamp_of(self, view: Self.View) -> String:
        """The identity (`OwnerStamp.identity()`) the live object carries,
        decoded from its labels; empty when none. DEFAULT: empty."""
        return String("")

    def unmanaged(self, spec: Self.Spec, view: Self.View) -> String:
        """Differences on fields the catalog does not model, for `plan` to
        print; never converged. DEFAULT: none."""
        return String("")

    def wanted(self, spec: Self.Spec) -> Bool:
        """False for a role the spec turned off (the closed world).
        DEFAULT: True."""
        return True


# =============================================================================
# §2 — DescribedResource[D] — the generic driver. The half that is identical
#      across conformers, written once.
# =============================================================================
struct DescribedResource[D: ResourceDescriptor](
    Resource, Movable, Deinitable
):
    """A `Resource` graph node assembled from a `ResourceDescriptor`.

    This struct is the reason a descriptor can exist at all: a Mojo trait has no
    storage, so the four fields every conformer re-declares had to move into
    SOMETHING, and a generic struct is the only construct that can hold them and
    satisfy `Resource` at the same time (file header, §"why the trait could not
    absorb it").

    ⚠ MONOMORPHIZATION COST IS UNCHANGED, NOT REDUCED — state it plainly. Today
    each conformer is a distinct struct parameterized on its Api, and
    `ErasedResource.erase[R]` instantiates it once per erase site. With a
    descriptor there is one `DescribedResource[D]` instantiation per descriptor,
    i.e. the SAME count; what shrinks is the SOURCE, not the number of comptime
    instantiations. Anyone expecting a build-time win from this should measure
    before believing it."""

    var _d: Self.D
    var _spec: Self.D.Spec
    var _logical_id: String
    var _deps: List[String]
    # The authored resource this node was lowered from (`Resource.owner`).
    var _owner: String
    # The latest live view `read_status` took, for `outputs`. None until read.
    var _last_view: Optional[Self.D.View]

    def __init__(
        out self,
        var descriptor: Self.D,
        var spec: Self.D.Spec,
        logical_id: String,
        var deps: List[String],
        owner: String = String(""),
    ):
        self._d = descriptor^
        self._spec = spec^
        self._logical_id = logical_id
        self._deps = deps^
        self._owner = owner
        self._last_view = None

    # ---- the two verbs with ONE distinct body across conformers ----------------
    def logical_id(mut self) -> String:
        return self._logical_id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return self._d.retention(self._spec)

    def undeletable_reason(mut self) -> String:
        """FORWARDED to the descriptor. Without this the driver would resolve
        `Resource.undeletable_reason`'s trait default and every DESCRIBED
        conformer's reason would be silently empty — the ECR repository included,
        which is the whole reason this axis exists."""
        return self._d.undeletable_reason(self._spec)

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        """The read envelope that about half of every hand-written `read_status`
        repeats, written once.

        A raise from `read` is classified by the descriptor: a not-found becomes
        RES_ABSENT, anything else PROPAGATES — because the alternative laundered
        an AccessDenied into "absent" and made the engine create over a live
        resource it could not read."""
        var live: Self.D.View
        try:
            live = self._d.read(self._spec, creds.token.copy())
        except e:
            if self._d.is_not_found(String(e)):
                self._last_view = None
                return ResourceStatus.absent()
            raise e^
        if not self._d.exists(live):
            self._last_view = None
            return ResourceStatus.absent()
        self._last_view = live.copy()
        var digest = self._d.live_digest(self._spec, live)
        var pid = self._d.physical_id(live)
        var ep = self._d.endpoint(live)
        var img = self._d.live_image(live)
        var stamp = self._d.stamp_of(live)
        var extra = self._d.unmanaged(self._spec, live)
        if digest == self._d.desired_digest(self._spec):
            return ResourceStatus.matched(pid, digest, ep, img, stamp, extra)
        return ResourceStatus.drifted(pid, digest, ep, img, stamp, extra)

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        """The plan scaffolding that about half of every hand-written `plan`
        repeats, written once. The DRIVER decides the verb (absent ->
        create, matched -> noop, else update); the DESCRIPTOR says why."""
        var verb = VERB_UPDATE
        if live.is_absent():
            verb = VERB_CREATE
        elif live.is_matched():
            verb = VERB_NOOP
        return ChangeAction(
            self._logical_id.copy(),
            verb,
            self._d.reason(self._spec, verb, live),
            self._d.retention(self._spec),
        )

    def create(mut self, creds: Creds) raises -> String:
        # A mutation makes any view taken before it stale: drop it BEFORE the
        # verb runs, so `outputs` re-reads the resource as it is now, whether
        # the verb succeeds or raises half-way.
        self._last_view = None
        return self._d.create(self._spec, creds.token.copy())

    def update(mut self, creds: Creds) raises:
        # ⛔ THE PRE-UPDATE VIEW IS THE OLD RESOURCE. `read_status` cached it
        # when it found the drift; an `outputs` answered from it would record
        # the OLD value and bind it into every consumer, which would then
        # converge only on the NEXT apply. Dropping it makes `outputs` read the
        # updated resource.
        self._last_view = None
        self._d.update(self._spec, creds.token.copy())

    def delete(mut self, physical_id: String, creds: Creds) raises:
        """The IDEMPOTENCE envelope, written once: an already-gone resource is a
        NO-OP so a re-run of a partially-failed teardown converges rather than
        failing on its own success.

        ⚠ See the file header's trap: a descriptor's DELIBERATE refusal must not
        be worded so that `is_not_found` matches it, or the teardown reports
        success over a resource still standing."""
        try:
            self._d.delete(self._spec, physical_id, creds.token.copy())
        except e:
            if self._d.is_not_found(String(e)):
                return
            raise e^

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return self._d.converge_mode(self._spec, live)

    def prune(mut self, creds: Creds) raises:
        self._d.prune(self._spec, creds.token.copy())

    def fault_domain(mut self, verb: String) raises -> Int:
        """FORWARD to the descriptor. Without this the descriptor's override
        would be shadowed by `Resource.fault_domain`'s trait default at this
        wrapper — the same shadowing hazard `ErasedResource.fault_domain`
        documents, one layer down, and the reason both forwards exist."""
        return self._d.fault_domain(self._spec, verb)

    # ---- apply-time value flow: FORWARDED to the descriptor ----------------
    # Same shadowing hazard as `fault_domain`: without these the trait
    # defaults answer at this wrapper and the descriptor's overrides never run.

    def input_refs(mut self) -> List[InputRef]:
        return self._d.input_refs(self._spec)

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        """Bind into the driver's OWN spec, which `read_status` then digests:
        the bind always precedes the digest (the engine binds before it
        reads)."""
        self._d.bind_inputs(self._spec, resolved)

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        """From the latest live view. A node created or updated in this run has
        no view (`create` / `update` drop the one taken before them), so it is
        read once more here: the values a consumer needs are the resource's as
        it is AFTER the mutation, and they are never invented or carried over
        from the pre-mutation read."""
        if not self._last_view:
            var live: Self.D.View
            try:
                live = self._d.read(self._spec, creds.token.copy())
            except e:
                if self._d.is_not_found(String(e)):
                    return Outputs()
                raise e^
            if not self._d.exists(live):
                return Outputs()
            self._last_view = live^
        return self._d.outputs(self._spec, self._last_view.value())

    def owner(mut self) -> String:
        return self._owner.copy()

    # ---- ownership and the closed world: FORWARDED to the descriptor -------

    def stamps_ownership(mut self) -> Bool:
        return self._d.stamps_ownership()

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        # The same stale-view rule as `create`.
        self._last_view = None
        return self._d.create_owned(self._spec, stamp, creds.token.copy())

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        self._last_view = None
        self._d.adopt_owned(self._spec, stamp, physical_id, creds.token.copy())

    def wanted(mut self) -> Bool:
        return self._d.wanted(self._spec)

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        """The teardown read: the SAME read envelope as `read_status` (a
        not-found is ABSENT, anything else propagates) WITHOUT the digest
        comparison. `desired_digest` is never called, so a consumer whose
        references were never bound (teardown binds only from persisted
        outputs) is still found and deleted. `live_digest` is not called
        either (it takes the spec, so it may need the same bound values): the
        present phase is reported as drifted with an EMPTY digest, and
        teardown reads only presence and the physical id."""
        var live: Self.D.View
        try:
            live = self._d.read(self._spec, creds.token.copy())
        except e:
            if self._d.is_not_found(String(e)):
                return ResourceStatus.absent()
            raise e^
        if not self._d.exists(live):
            return ResourceStatus.absent()
        return ResourceStatus.drifted(
            self._d.physical_id(live),
            String(""),
            self._d.endpoint(live),
            self._d.live_image(live),
            self._d.stamp_of(live),
        )


# =============================================================================
# §3 — the erase wrapper. Every hand-written conformer carried its own copy;
#      this is the one that replaces them.
# =============================================================================
def make_described_node[D: ResourceDescriptor](
    var descriptor: D,
    var spec: D.Spec,
    logical_id: String,
    var deps: List[String],
    owner: String = String(""),
) raises -> ErasedResource:
    """Erase a `DescribedResource[D]` into the graph's node type. A conformer
    built on a descriptor needs NO `make_*_node` of its own — it calls this."""
    return ErasedResource.erase(
        DescribedResource[D](descriptor^, spec^, logical_id, deps^, owner)
    )
