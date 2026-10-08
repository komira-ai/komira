# =============================================================================
# komira_plan_expr.fs_bindings — the HANDLE-LESS `node_id -> FS scheme` table
#   the LOGICAL PLAN carries (the FS analog of `komira_secret_registry.secret_bindings`).
# =============================================================================
#
# WHAT IT IS. The logical plan names the exact source each scan reads: the
# scan node's `FsDescriptorPod` carries the scheme code, and this table maps
# each cloud-bound scan node's `node_id` to that same code, so a carrier can
# answer "is this node cloud-bound, and to which scheme" without walking the
# plan. A surface picks the code from the source URL's prefix before it
# builds the plan (komira_source_url's `source_scheme_for_url`). The table
# holds codes only: no file system, no handle, no client, so a logical plan
# that opens no socket takes on no cloud package.
#
# It conforms to the core `FsResolver` trait (`num_entries` is its own,
# `has_binding` and `resolve_scheme` the trait's): the FS-erased questions
# the plan tier asks, and nothing else.
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

from komira_plan_expr.fs_resolver import FsResolver
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_FILE


# =============================================================================
# §1 — FsBindingEntry — one `(node_id, scheme)` binding.
# =============================================================================
struct FsBindingEntry(Copyable, Movable, Deinitable):
    """One `(node_id, scheme)` binding in the plan-carried FS table. A FLAT
    value: an `Int` node_id + the `FS_SCHEME_*` code. NO handle, NO
    filesystem: the plan names its source and carries no live file system."""

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
    cannot open a file, and it names no filesystem type.

    Empty by default, so a pure-local query pays nothing."""

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
        invariant `SecretBindings.merge_from` relies on, so entries are
        appended verbatim with no collision check.

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
        if unbound (the local default)."""
        var idx = self._index_for(node_id)
        if idx < 0:
            return FS_SCHEME_FILE
        return self._entries[idx].scheme

    def has_binding(self, node_id: Int) -> Bool:
        """True iff `node_id` carries an explicit FS binding in this table."""
        return self._index_for(node_id) >= 0
