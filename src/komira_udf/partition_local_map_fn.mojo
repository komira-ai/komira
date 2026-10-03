# =============================================================================
# partition_local_map_fn.mojo — the production `partition_local` MapFn surface
# =============================================================================
#
# A `PartitionLocalMapFn` is a `MapFn` that additionally declares an explicit
# per-partition STATE and the within-partition row step that threads it:
# SQL `f(...) OVER (PARTITION BY part_keys ORDER BY order_keys)`. The engine
# sorts the input by `(PART_KEYS ++ ORDER_KEYS)`, detects partition boundaries,
# builds a FRESH state at each boundary via `init_partition`, and threads it
# forward across the rows of that partition via `run_partition_row`. State does
# NOT bleed across partitions (the isolation contract).
#
# # Explicit `init_partition` + `Self.State`
#
# Mirrors `AggFn`'s `Self.State` and the custom window-fn's `init_partition`
# (they share this shape). Cleaner separation of
# "config" (the UDF VALUE — its fields are the captures) vs "per-partition
# mutable state" than re-instantiating the Copyable UDF value per partition.
#
# `State` is bound `Copyable & Movable & Deinitable`. The
# `Deinitable` half is LOAD-BEARING: the
# per-partition local state is dropped on the `raises` drain path, so the
# compiler requires explicit destructibility on the bound.
#
# # How the partition / order keys are carried
#
# `StatefulContract.partition_keys` / `order_keys` (`stateful_contract.mojo`)
# are NON-PARAMETRIC comptime members defaulting to empty `KeyList()` — they
# are associated constants, NOT settable per-UDF via the value ctor. So the
# per-UDF partition / order keys CANNOT ride on `F.parallelism.partition_keys`.
# The lighter answer (vs parametrizing `StatefulContract[part, order]`):
# `PART_KEYS` / `ORDER_KEYS` comptime members live directly to the `partition_local` MapFn surface (here). The runtime engine
# snapshots them to `List[String]` at factory-construction time
# (`PartitionUdfStageFactory.make_state`). `stateful_contract.mojo`'s
# tag / `KeyList` / `KeyEntry` IR is otherwise unaffected.
#
# The conformer still declares `comptime parallelism = StatefulContract(
# tag=CONTRACT_PARTITION_LOCAL)` so the tag is reachable for the dispatch gate;
# the keys ride on `PART_KEYS` / `ORDER_KEYS` (NOT on `parallelism`).
#
# # Encapsulation invariants
#   - NO UnsafePointer / wildcard origins / unsafe_from_address / take_pointee /
#     ArcPointer / additive parallel API. This is a pure trait surface (no
#     storage); conformers carry POD captures + a POD per-partition State.
# =============================================================================

from komira_udf.map_fn import MapFn
from komira_udf.stateful_contract import KeyList
from komira_udf.partition_row_view import PartitionRowView


trait PartitionLocalMapFn(MapFn):
    """A `partition_local` MapFn with explicit per-partition state.

    Adds to `MapFn`:
      - `State`             : the per-partition mutable accumulator type
                              (`Copyable & Movable & Deinitable` —
                              the `Deinitable` half is load-bearing:
                              the per-partition local is dropped on the `raises`
                              drain path).
      - `PART_KEYS`         : the comptime PARTITION BY keys (part of `F`'s
                              identity — the key-carry fix; see module header).
      - `ORDER_KEYS`        : the comptime ORDER BY keys within each partition.
      - `init_partition`    : build a FRESH per-partition state at each boundary
                              (the per-partition reset — state does NOT bleed
                              across partitions).
      - `run_partition_row` : the per-row step threading `mut s: Self.State`
                              forward, reading the UDF's OWN inputs from a
                              `PartitionRowView` (the ROW-VIEW INVERSION). The
                              engine hands the UDF a MONOMORPHIC accessor over
                              `(sorted batch, row)`; the UDF reads each of its N
                              inputs via `view.get[local_idx, dt]()` by comptime
                              column index (it knows its arity + per-position
                              dtypes from `InputSchema`). This INVERTS the prior
                              positional-het-pack form: the engine never
                              assembles a het-pack (Mojo 1.0.0b1 cannot drive
                              that generically — tuple-splat crashes
                              `ParamInf::inferForCall`, het-Tuple assembly is
                              rejected, opaque `InRow` has no generic ctor), and
                              the per-arity unrolling moves to the UDF. The
                              engine drives ONE arity-agnostic loop with no
                              `comptime if n_in == N` ladder.

    The stateless `MapFn.run_row` / `MapFn.run_scalar` remain REQUIRED (the
    trait inherits them) — they are the stateless oracle; the partition driver
    uses `run_partition_row` instead.
    """

    comptime State: Copyable & Movable & Deinitable
    comptime PART_KEYS: KeyList   # PARTITION BY keys (comptime — part of F's identity)
    comptime ORDER_KEYS: KeyList  # ORDER BY keys within each partition

    def init_partition(self) -> Self.State:
        """Build a FRESH per-partition accumulator (reset at each boundary).
        Called once per partition by the partition scan — the per-partition
        reset that isolates state across partitions."""
        ...

    def run_partition_row[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: PartitionRowView[origin]) raises -> Scalar[
        Self.OutType
    ]:
        """The per-partition row step (ROW-VIEW form): thread `mut s` (the
        running state) forward and return this row's output value. The conformer
        reads its OWN inputs from `view` via `view.get[local_idx, dt]()` by
        comptime column index (it knows its arity + per-position dtypes from
        `InputSchema` — `view.get[0, DType.int64]()`, `view.get[1, ...]()`,
        ...). Generic over the view's `origin` so the engine's borrowed sorted
        batch lifetime is tracked end-to-end."""
        ...
