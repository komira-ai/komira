# =============================================================================
# komira_core.plan.fs_bindings — the HANDLE-LESS `node_id -> FS scheme` table
#   the LOGICAL PLAN carries (the FS analog of `komira_core.plan.secret_bindings`).
# =============================================================================
#
# ⭐ WHY THIS EXISTS. `PlanCarrier` — the UNIVERSAL read survivor every
# `ctx.read_*` returns — must not hold a CONCRETE `komira_fs_registry.FsRegistry`
# field. `FsRegistry` owns live `FsHandle`s, and `FsHandle` is a closed tagged
# union that NAMES all four concrete filesystems, so that ONE field would put
# the entire cloud stack (the S3, GCS and Azure clients and everything under
# them) on the LOGICAL-PLAN tier's `-I` closure, for a LOGICAL PLAN that opens
# no socket.
#
# ⛔ THE COST IS THE `FsHandle` UNION, NOT THE ENGINE METHODS. `FsRegistry` also
# conforms to the EXECUTION trait `MaterializingResolver`, but its engine-side
# deps (`komira_engine_dispatch`, `komira_engine_operators`,
# `komira_engine_runtime`, `komira_morsel`, `komira_parquet`) are ALREADY in
# the plan tier's closure through other imports. Splitting the engine methods
# off `FsRegistry` would buy the plan tier nothing.
#
# ⭐ WHAT THE PLAN TIER ACTUALLY NEEDS: default-construct, move, and three
# probes (`num_entries`, `has_binding`, `resolve_scheme`). It never names
# `FsHandle`, calls `register`, or reaches a materialize method. So the plan
# tier needs the FS-ERASED answer to "is this node cloud-bound, and to which
# scheme", which is exactly the core `FsResolver` trait this struct conforms to.
#
# ⭐ WHY THE HANDLES ARE SUPPLIED AT THE MATERIALIZE BOUNDARY INSTEAD.
#   (a) It is what consumers write: `ctx.materialize_plan_resolved(plan,
#       fs_reg)` and `ctx.materialize_cloud_plan(plan, fs_reg)` both take the
#       registry as an ARGUMENT, built beside the plan and handed in.
#   (b) It is the same shape as secrets one field over: `SecretBindings`
#       (store-less, plan-carried) + `SecretRegistry.from_bindings(store,
#       bindings)` (store-composing, built at the materialize boundary).
#   (c) It is the only shape that respects the FS design's own rule: the
#       registry is a per-execution MOVED VALUE through the spine, dropped after
#       materialize — NEVER a field on a destroy-recreate struct
#       (`EngineContext`, `PipelineExecution`). Parking the live handles on
#       `EngineContext` to get them off the carrier would violate that rule.
#
# ⛔ WHAT WAS DELIBERATELY NOT DONE: parametrizing the carrier as
# `PlanCarrier[REG: FsResolver]`. It reaches the same end state, but the type
# parameter is viral through every carrier method and every dependent of the
# SDK, for no additional property.
#
# CONTAINER (mirrors `SecretBindings`): a plain VALUE
# `List[FsBindingEntry]` of FLAT entries (an `Int` + a `UInt8`). No pointer of
# any kind, no heap-inner-of-heap, no wildcard origin, nothing to reinterpret on
# a destroy-recreate cycle. Copyable + Movable, a per-query value that moves WITH
# the plan.
#
# ⛔ DO NOT ADD AN IMPORT TO THIS FILE beyond the core `FsResolver` trait it
# conforms to. The whole value of this module is that it names no filesystem.
# =============================================================================

from .fs_resolver import FsResolver
from .fs_descriptor_pod import FS_SCHEME_FILE


# =============================================================================
# §1 — FsBindingEntry — one `(node_id, scheme)` binding.
# =============================================================================
struct FsBindingEntry(Copyable, Movable, Deinitable):
    """One `(node_id, scheme)` binding in the plan-carried FS table. A FLAT
    value: an `Int` node_id + the `FS_SCHEME_*` code (byte-identical to
    `FsHandle.tag`). NO handle, NO filesystem — the live `FsHandle` is supplied
    at the materialize boundary, never carried by the plan."""

    var node_id: Int
    var scheme: UInt8

    def __init__(out self, node_id: Int, scheme: UInt8):
        self.node_id = node_id
        self.scheme = scheme


# =============================================================================
# §2 — FsBindings — the handle-less per-query `node_id -> scheme` table.
# =============================================================================
struct FsBindings(FsResolver, Copyable, Movable, Deinitable):
    """The handle-less per-query `node_id -> FS scheme` table the logical plan
    carries, conforming to the core `FsResolver` trait.

    This is what `PlanCarrier` / `GroupedCarrier` / `PartitionedCarrier` /
    `RollingFrame` hold. It answers the FS-ERASED questions the plan tier asks
    (`num_entries` / `has_binding` / `resolve_scheme`) and NOTHING else: it
    cannot open a file, and it names no filesystem type. The live `FsHandle`
    side table (`komira_fs_registry.FsRegistry`) is built where the concrete FS
    is in scope and handed to the materialize entry as an argument.

    Empty by default, so a pure-local query pays nothing and every existing
    `fs_registry_empty()` probe answers exactly as before."""

    var _entries: List[FsBindingEntry]

    def __init__(out self):
        """An empty table (the default a pure-local plan carries)."""
        self._entries = List[FsBindingEntry]()

    def clone(self) -> Self:
        """Explicit deep copy (mirrors `SecretBindings.clone`), for the
        borrow-based copying carrier overloads."""
        return self.copy()

    def bind(mut self, node_id: Int, scheme: UInt8):
        """Bind `node_id -> scheme`. Called by the SDK read builders as each
        cloud-bound scan node is minted. `node_id` MUST be the stable id stamped
        on the matching `ParquetSourceData.fs_descriptor`."""
        self._entries.append(FsBindingEntry(node_id, scheme))

    def merge_from(mut self, var other: Self):
        """Absorb `other`'s bindings into `self` — called by the `.join` /
        `.cross_join` / `.asof_join` builders when two carriers combine, so a
        cross-FS join keeps BOTH legs' scheme bindings. `node_id`s are minted
        QUERY-UNIQUE (a monotonic counter on `EngineContext`), the same
        invariant `FsRegistry.merge_from` and `SecretBindings.merge_from` rely
        on, so entries are appended verbatim with no collision check.

        Consumes `other` by draining it, so this stays non-raising and the
        FS-blind join builders' raise-signatures are unchanged."""
        for i in range(len(other._entries)):
            self._entries.append(other._entries[i].copy())
        other._entries.clear()

    @always_inline
    def num_entries(self) -> Int:
        return len(self._entries)

    def _index_for(self, node_id: Int) -> Int:
        """List index of the entry for `node_id`, or -1 if unbound. Linear scan
        (the table is tiny — one entry per cloud-bound source)."""
        for i in range(len(self._entries)):
            if self._entries[i].node_id == node_id:
                return i
        return -1

    # ---- FsResolver trait conformance (the FS-erased surface) ----

    def resolve_scheme(self, node_id: Int) -> UInt8:
        """Return the `FS_SCHEME_*` code bound to `node_id`, or `FS_SCHEME_FILE`
        if unbound (the local default) — byte-identical to what
        `FsRegistry.resolve_scheme` returned for the same table."""
        var idx = self._index_for(node_id)
        if idx < 0:
            return FS_SCHEME_FILE
        return self._entries[idx].scheme

    def has_binding(self, node_id: Int) -> Bool:
        """True iff `node_id` carries an explicit FS binding in this table."""
        return self._index_for(node_id) >= 0
