# =============================================================================
# kci_reconciler/state.mojo — the write-ahead intent STATE seam of the resource-
#   graph deploy engine (provider-neutral; the minimal durable-state contract for
#   partial-apply RECOVERY).
# =============================================================================
#
# THE PARTIAL-APPLY PROBLEM. An `apply_graph` is NOT atomic across its nodes: node
# A can create, then a crash before node B creates. On the next apply the engine
# must NOT re-create A (a double-create) — it must ADOPT A's confirmed intent and
# re-drive only the unconfirmed nodes. The state store is the durable write-ahead
# ledger that makes this recoverable.
#
# THE MINIMAL SEAM (what the engine records). Per node, keyed by
# `ResourceKey (machine, cell, resource)` (kci_reconciler/ownership.mojo): the
# same logical id applied to two cells, or by two release machines, is two
# different records, so one can never adopt the other's intent.
#   * record_or_adopt_intent(key, stamp) -> IntentTicket. THE WRITE-AHEAD HOOK.
#     IDEMPOTENT by the key: a non-terminal intent for that key is ADOPTED (its
#     ticket returned, with `already_confirmed` iff it was already confirmed) —
#     NO second row written (no double-create). Else a fresh PROVISIONING
#     intent is written, carrying the ownership identity (`stamp`, empty in the
#     unowned scope) the create will stamp on the object. Called BEFORE the
#     node's create/update, so a crash after the create leaves a record that
#     names both the key and the identity the orphan object carries.
#   * confirm(ticket, physical_id). Heal the PROVISIONING intent to CONFIRMED with
#     the provider-assigned physical id. Idempotent.
#   * mark_reaped(key). Record that a node was deleted (destroy / rollback /
#     a role the file turned off) — the intent is retired.
#   * physical_id_for(key) -> the confirmed physical id (empty if none). The
#     id-map read the engine uses to adopt a confirmed node's id, and the
#     ledger half of every delete decision.
#
# NO LOCK HERE. Two applies in one cell are kept apart by the cell's lease lock
# (the ledger's), not by this seam. Without it the loser of a race
# fails at the cloud (its create meets the winner's object and the cloud
# refuses it as existing); it never double-creates, and its re-run adopts what
# the winner made (the object carries the same stamp).
#
# WHAT THE STORE HOLDS (and does NOT). ONLY the id-map + the intent status +
# (implicitly, via the ticket) whether a node predated us. It holds NO cached
# resource ATTRIBUTES — the LIVE read (Resource.read_status) is the sole actual-
# state source. The store answers "did we already confirm this node, and what is
# its physical id"; it never answers "what does the resource look like".
#
# ⚠️ THE ATOMICITY CAVEAT (do NOT copy the in-memory double's semantics into a
# durable conformer). `InMemoryStateStore.record_or_adopt_intent` is a NON-ATOMIC
# read-scan-append (scan for a live intent; if none, append). That is a TOCTOU
# hole: two concurrent engines can both scan-and-miss then both append -> a
# double-create. The in-memory store is the OSS-DEFAULT seed + the single-process
# test double; a DURABLE conformer (backed by a DB) MUST close that window with a
# partial-unique index on (machine, cell, resource) WHERE status non-terminal (a racing second
# insert FAILS). The in-memory double does not — do not read its read-scan-append
# as the atomicity contract.
#
# ENCAPSULATION. The seam surface is value-typed: a `ResourceKey` +
# physical_id in, an `IntentTicket` (a flat opaque handle) / `String` out, `raises`
# for a backend fault. ZERO UnsafePointer crosses any boundary; NO wildcard origin;
# NO unsafe_from_address. The in-memory double's interior is flat `List[String]` /
# `List[Bool]` behind an OwnedPointer (no byte-slab, no nested heap-owning struct).
# Mojo 1.0.0b2 (def-only).
# =============================================================================

from std.memory import OwnedPointer
from kci_reconciler.outputs import Outputs
from kci_reconciler.ownership import ResourceKey


# =============================================================================
# §0 — the intent STATUS codes (the write-ahead FSM). A recorded intent is
#      PROVISIONING (the create is in flight / unconfirmed) then CONFIRMED (the
#      create landed) then REAPED (the resource was deleted).
# =============================================================================
comptime INTENT_PROVISIONING: Int = 0
"""A fresh intent whose create has not confirmed yet (the recoverable state)."""
comptime INTENT_CONFIRMED: Int = 1
"""The create/update confirmed — the intent carries the physical id."""
comptime INTENT_REAPED: Int = 2
"""The resource was deleted (destroy / rollback) — the intent is retired."""


# =============================================================================
# §1 — IntentTicket — the opaque handle a recorded/adopted intent returns. Flat
#      value POD (no pointer field). `intent_id` identifies the durable row;
#      `key` echoes the key (so the caller can confirm without re-deriving);
#      `already_confirmed` is True iff the ADOPTED intent was already CONFIRMED (a
#      re-apply of a node whose create already landed — the confirm is a no-op).
# =============================================================================
@fieldwise_init
struct IntentTicket(Copyable, Movable, Deinitable):
    """A recorded/adopted write-ahead intent handle:
      * `intent_id`         — the durable row's stable id (opaque String).
      * `key`               — the `(machine, cell, resource)` this intent
                              tracks.
      * `already_confirmed` — True iff the adopted intent was ALREADY confirmed (so
                              the caller's create + confirm are no-ops — the node
                              predated this apply). The engine's rollback SKIPS an
                              already_confirmed node (it did not create it, so it
                              must not delete it).
    Flat value POD."""

    var intent_id: String
    var key: ResourceKey
    var already_confirmed: Bool


# =============================================================================
# §2 — StateStore — the minimal write-ahead intent seam. A durable conformer
#      persists these to a DB; the in-memory default keeps them in process memory.
# =============================================================================
trait StateStore(Movable, Deinitable):
    """The write-ahead intent ledger the resource-graph engine records into. Four
    verbs (all keyed by `ResourceKey (machine, cell, resource)`):

      * record_or_adopt_intent(key, stamp) -> IntentTicket — IDEMPOTENT by the
        key: a non-terminal intent for that key is ADOPTED (no second row — no
        double-create); else a fresh PROVISIONING intent is written, carrying
        the ownership identity `stamp`. The ticket's `already_confirmed` is
        True iff the adopted intent was already CONFIRMED.
      * confirm(ticket, physical_id) — heal the intent to CONFIRMED with the
        provider-assigned physical id. Idempotent (re-confirming just re-sets it).
      * mark_reaped(key) — retire the intent (the resource was deleted on
        destroy / rollback / a role turned off).
      * physical_id_for(key) -> the CONFIRMED physical id for the key (empty
        if no confirmed intent). The id-map read the engine adopts a node's id
        from.

    No UnsafePointer crosses the boundary; a backend fault RAISES."""

    def record_or_adopt_intent(
        mut self, key: ResourceKey, stamp: String
    ) raises -> IntentTicket:
        ...

    def confirm(mut self, ticket: IntentTicket, physical_id: String) raises:
        ...

    def mark_reaped(mut self, key: ResourceKey) raises:
        """Retire the live record for `key`. Idempotent: retiring a key with
        no live record is a no-op, which a release that is retried relies
        on."""
        ...

    def physical_id_for(mut self, key: ResourceKey) raises -> String:
        ...

    def record_outputs(mut self, key: ResourceKey, outputs: Outputs) raises:
        """Persist the values node `key` produced on its latest apply,
        beside its physical id. The copy kept here is a FALLBACK for a reader
        that cannot read live (an offline dry run); the engine itself
        re-derives outputs from a live read on every apply.

        DEFAULT = NOT PERSISTED. A store that does not override this keeps no
        outputs, and `outputs_for` then answers empty, which a caller must read
        as "unknown", never as "the node produces nothing"."""
        pass

    def outputs_for(mut self, key: ResourceKey) raises -> Outputs:
        """The outputs last recorded for `key`; empty if none were.

        DEFAULT = EMPTY (see `record_outputs`)."""
        return Outputs()


# =============================================================================
# §3 — _InMemoryState — the in-memory store's interior (parallel arrays keyed by
#      `ResourceKey`). Held behind an OwnedPointer so `mut self` verbs mutate through
#      the stable pointee. No pointer field: flat List[String] / List[Int]; no
#      byte-slab.
# =============================================================================
struct _InMemoryState(Movable, Deinitable):
    """The in-memory store's interior. Parallel arrays keyed by `keys[i]` (the
      `(machine, cell, resource)` key); `stamps[i]` -> the identity the intent
      was written with; `intent_ids[i]` -> the intent row id;
      `statuses[i]` -> the INTENT_* FSM state; `physical_ids[i]` -> the confirmed
      physical id (empty until confirmed). A monotonically-increasing `next_id`
      mints intent ids. No pointer field (flat List[String] / List[Int] / Int; no
      byte-slab, no wildcard, no nested heap-owning struct)."""

    var keys: List[ResourceKey]
    var stamps: List[String]
    var intent_ids: List[String]
    var statuses: List[Int]
    var physical_ids: List[String]
    var next_id: Int
    # The last outputs recorded per key (record_outputs).
    var output_keys: List[ResourceKey]
    var outputs: List[Outputs]

    def __init__(out self):
        self.keys = List[ResourceKey]()
        self.stamps = List[String]()
        self.intent_ids = List[String]()
        self.statuses = List[Int]()
        self.physical_ids = List[String]()
        self.next_id = 1
        self.output_keys = List[ResourceKey]()
        self.outputs = List[Outputs]()


# =============================================================================
# §4 — InMemoryStateStore — the OSS-default + single-process test double.
# =============================================================================
struct InMemoryStateStore(StateStore, Movable, Deinitable):
    """An in-memory `StateStore`: the open-core default seed AND the single-process
    test double. Models the write-ahead intent FSM (PROVISIONING -> CONFIRMED ->
    REAPED) in process memory: record_or_adopt is idempotent by key; confirm
    heals; mark_reaped retires; physical_id_for reads the id-map.

    The interior lives behind an `OwnedPointer[_InMemoryState]` (single-owner heap
    pointee with a stable address — Box). The store is a single owned value the
    engine borrows `mut`; it is NOT shared across threads (the engine's
    apply_graph/destroy_graph are a synchronous single-process drive).

    ⚠️ NON-ATOMIC (see the module header): `record_or_adopt_intent` is a read-scan-
    append (TOCTOU). A DURABLE conformer MUST close that with a partial-unique
    index; this in-memory double is single-process only, so the window never opens
    here. Do NOT copy the read-scan-append as the atomicity contract."""

    var _p: OwnedPointer[_InMemoryState]

    def __init__(out self):
        self._p = OwnedPointer[_InMemoryState](_InMemoryState())

    def record_or_adopt_intent(
        mut self, key: ResourceKey, stamp: String
    ) raises -> IntentTicket:
        """ADOPT an existing NON-terminal (PROVISIONING or CONFIRMED) intent for
        `key` (idempotent by key — no double-create), else write a fresh
        PROVISIONING intent carrying `stamp`. A REAPED intent is terminal — a
        re-record after a destroy writes a fresh intent (the resource is being
        re-created)."""
        for i in range(len(self._p[].keys)):
            if self._p[].keys[i].same(key) and (
                self._p[].statuses[i] != INTENT_REAPED
            ):
                return IntentTicket(
                    self._p[].intent_ids[i],
                    key.copy(),
                    self._p[].statuses[i] == INTENT_CONFIRMED,
                )
        # No live intent — write a fresh PROVISIONING row.
        var id = String("intent-") + String(self._p[].next_id)
        self._p[].next_id += 1
        self._p[].keys.append(key.copy())
        self._p[].stamps.append(stamp)
        self._p[].intent_ids.append(id)
        self._p[].statuses.append(INTENT_PROVISIONING)
        self._p[].physical_ids.append(String(""))
        return IntentTicket(id, key.copy(), False)

    def confirm(mut self, ticket: IntentTicket, physical_id: String) raises:
        """Heal the intent `ticket.intent_id` to CONFIRMED with `physical_id`.
        Idempotent (re-confirming re-sets the physical id + status)."""
        for i in range(len(self._p[].intent_ids)):
            if self._p[].intent_ids[i] == ticket.intent_id:
                self._p[].statuses[i] = INTENT_CONFIRMED
                self._p[].physical_ids[i] = physical_id
                return
        raise Error(
            String("InMemoryStateStore.confirm: no intent ")
            + ticket.intent_id
            + String(" for '")
            + ticket.key.text()
            + String("'")
        )

    def mark_reaped(mut self, key: ResourceKey) raises:
        """Retire the (most recent non-reaped) intent for `key` — the resource
        was deleted. Idempotent: no live intent is a no-op (the node was
        already reaped / never recorded)."""
        for i in range(len(self._p[].keys)):
            if self._p[].keys[i].same(key) and (
                self._p[].statuses[i] != INTENT_REAPED
            ):
                self._p[].statuses[i] = INTENT_REAPED
                return

    def physical_id_for(mut self, key: ResourceKey) raises -> String:
        """The CONFIRMED physical id for `key` (empty if no confirmed
        intent)."""
        for i in range(len(self._p[].keys)):
            if self._p[].keys[i].same(key) and (
                self._p[].statuses[i] == INTENT_CONFIRMED
            ):
                return self._p[].physical_ids[i]
        return String("")

    def record_outputs(mut self, key: ResourceKey, outputs: Outputs) raises:
        """Replace the outputs recorded for `key`."""
        for i in range(len(self._p[].output_keys)):
            if self._p[].output_keys[i].same(key):
                self._p[].outputs[i] = outputs.copy()
                return
        self._p[].output_keys.append(key.copy())
        self._p[].outputs.append(outputs.copy())

    def outputs_for(mut self, key: ResourceKey) raises -> Outputs:
        """The outputs last recorded for `key`; empty if none were."""
        for i in range(len(self._p[].output_keys)):
            if self._p[].output_keys[i].same(key):
                return self._p[].outputs[i].copy()
        return Outputs()

    # =========================================================================
    # the UNOWNED-scope forms: the same verbs over `("", "", logical_id)`, the
    # key the engine's unowned scope uses. Convenience for single-cell tests
    # and the engine's older callers; NOT part of the StateStore trait.
    # =========================================================================
    @staticmethod
    def _unowned(logical_id: String) -> ResourceKey:
        return ResourceKey(String(""), String(""), logical_id)

    def record_or_adopt_intent(
        mut self, logical_id: String
    ) raises -> IntentTicket:
        return self.record_or_adopt_intent(Self._unowned(logical_id), String(""))

    def physical_id_for(mut self, logical_id: String) raises -> String:
        return self.physical_id_for(Self._unowned(logical_id))

    def outputs_for(mut self, logical_id: String) raises -> Outputs:
        return self.outputs_for(Self._unowned(logical_id))

    # =========================================================================
    # inspection (test assertions — NOT part of the StateStore trait). Each
    # takes a key; the `String` forms read the unowned scope.
    # =========================================================================
    def _count(self, key: ResourceKey, status: Int) -> Int:
        var n = 0
        for i in range(len(self._p[].keys)):
            if self._p[].keys[i].same(key) and (
                status < 0 or self._p[].statuses[i] == status
            ):
                n += 1
        return n

    def intent_stamp(self, key: ResourceKey) -> String:
        """The identity the latest intent for `key` was written with (empty
        when none, or written in the unowned scope)."""
        var s = String("")
        for i in range(len(self._p[].keys)):
            if self._p[].keys[i].same(key):
                s = self._p[].stamps[i].copy()
        return s^

    def count_provisioning(self, key: ResourceKey) -> Int:
        """PROVISIONING (unconfirmed) intents for `key`: 0 after a converged
        apply (the no-orphan invariant); 1 after a crash mid-apply."""
        return self._count(key, INTENT_PROVISIONING)

    def count_confirmed(self, key: ResourceKey) -> Int:
        """CONFIRMED intents for `key` — exactly ONE after a converged apply."""
        return self._count(key, INTENT_CONFIRMED)

    def count_reaped(self, key: ResourceKey) -> Int:
        """REAPED intents for `key` — a destroyed node's intent was retired."""
        return self._count(key, INTENT_REAPED)

    def total_intents(self, key: ResourceKey) -> Int:
        """Intents of any status for `key` — 1 after a crash+recover (the
        re-apply ADOPTED, did not duplicate)."""
        return self._count(key, -1)

    def count_provisioning(self, logical_id: String) -> Int:
        return self.count_provisioning(Self._unowned(logical_id))

    def count_confirmed(self, logical_id: String) -> Int:
        return self.count_confirmed(Self._unowned(logical_id))

    def count_reaped(self, logical_id: String) -> Int:
        return self.count_reaped(Self._unowned(logical_id))

    def total_intents(self, logical_id: String) -> Int:
        return self.total_intents(Self._unowned(logical_id))
