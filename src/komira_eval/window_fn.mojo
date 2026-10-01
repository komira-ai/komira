# =============================================================================
# window_fn.mojo — the typed user-defined custom WINDOW-function trait (WindowFn)
# =============================================================================
#
# A `WindowFn` is the user-extension, FRAME-bearing window function: a custom
# stateful smoothing filter / frame-windowed median / hysteresis detector /
# domain-specific rolling statistic over a
# `PARTITION BY ... ORDER BY ...` partition with a `ROWS BETWEEN ...` frame.
# It is the ONLY window track that exposes a *frame* to a user trait + the
# `invertible` incremental opt.
#
# # SIBLING of `PartitionLocalMapFn` (NOT a conformer)
#
# `WindowFn` REUSES the `PartitionLocalMapFn` SHAPE
# (`partition_local_map_fn.mojo`) — `PART_KEYS` / `ORDER_KEYS` / `init_partition`
# / `Self.State` + the ROW-VIEW arity inversion — but does NOT
# conform to it (its per-row contract is a frame SCAN, not a single-row step).
# It is a sibling trait. The stateless `MapFn.run_row` / `run_scalar` that
# `PartitionLocalMapFn` inherits are NOT carried over — `WindowFn` is
# frame-native end to end. The key/state machinery is borrowed verbatim so the
# two siblings stay adjacent + the engine snapshots their keys identically.
#
# # The ONE-trait shape
#
# ONE `WindowFn` trait + `comptime invertible: Bool` + default bodies; the
# engine dispatches `comptime if F.invertible`. NO two-sub-traits split. The
# default-body story is why ONE trait works:
#   * `compute_frame`     — ABSTRACT (the only required override): recompute the
#                           output for a frame `[lo, hi)` from scratch. The
#                           RECOMPUTE entry point the engine drives.
#   * `prepare_partition` — defaults to `init_partition` (build a fresh
#                           per-partition state; recompute uses the state for
#                           per-partition setup, e.g. caching a partition-wide
#                           constant). Override only if the recompute path needs
#                           a frame-aware partition prep.
#   * `enter_row` / `leave_row` / `emit` — the INVERTIBLE fast-path methods
#                           (default bodies). `enter_row`
#                           / `leave_row` default to no-op; `emit` degrades to
#                           `compute_frame` over the current frame.
#
# # Frame + invertibility
#
#   * `comptime frame: WindowFrameSpec` — the frame, COMPTIME (ROWS-only
#     fence; the window operator comptime-asserts `frame.units == ROWS` at
#     build time — RANGE/GROUPS fail at compile time).
#   * `comptime invertible: Bool = False` — a USER-ASSERTED algebraic-inverse
#     contract; the engine does NOT verify it. Invertible-by-construction:
#     SUM/COUNT/AVG/Welford. Looks-invertible-but-isn't (MUST set False, use
#     recompute): MAX/MIN/MODE/MEDIAN.
#   * `comptime State: Copyable & Movable & Deinitable` — the
#     per-partition POD accumulator, slab-safety-gated (the `partition_local` bound
#     spelling, not `PodState`). The `Deinitable` half is LOAD-BEARING (the
#     per-partition local is dropped on the `raises` drain path).
#
# # Encapsulation invariants
#   - NO UnsafePointer / wildcard origins / unsafe_from_address / take_pointee /
#     ArcPointer / additive parallel API / arity siblings. Pure trait surface
#     (no storage); conformers carry POD captures + a POD per-partition State.
#     The variadic-input need is solved by the ROW-VIEW inversion (`FrameView`),
#     NOT a het-pack — NO new variadic machinery.
# =============================================================================

from komira_eval.schema_descriptor import SchemaDescriptor, _derive_schema
from komira_eval.stateful_contract import KeyList
from komira_eval.frame_view import FrameView
from komira_eval.window_frame_spec import WindowFrameSpec


trait WindowFn(Movable, Copyable, Deinitable):
    """A typed user-defined custom WINDOW function: N input columns over a
    `ROWS` frame -> 1 output column, per `PARTITION BY ... ORDER BY ...`.

    Conformers MUST provide (the `MapFn`-shaped typed-row mechanism, identical
    to `PartitionLocalMapFn`):
      - `InRow`        : a `@fieldwise_init struct` of typed input fields, one
                         per input column this UDF reads (`Copyable & Movable`).
      - `InputSchema`  : a `comptime SchemaDescriptor` matching `InRow` (default
                         auto-derived from `InRow`; override to remap names).
      - `OutputSchema` : a `comptime SchemaDescriptor` naming + typing the (one)
                         output column.
      - `OutType`      : `= OutputSchema.cols[0]`'s dtype as a stdlib `DType`.
      - `UDF_ID`       : a user-declared `comptime UInt32` operator-factory
                         selector.
      - `State`        : the per-partition mutable accumulator type
                         (`Copyable & Movable & Deinitable`).
      - `PART_KEYS`    : the comptime PARTITION BY keys (part of `F`'s identity).
      - `ORDER_KEYS`   : the comptime ORDER BY keys within each partition.
      - `frame`        : the comptime `WindowFrameSpec` (ROWS-only; fenced at
                         operator build).
      - `init_partition` : build a FRESH per-partition state at each boundary.
      - `compute_frame`  : ABSTRACT — recompute the output for the frame
                         `[lo, hi)` exposed by a `FrameView`. The only required
                         override.

    Conformers MAY override the default-body methods:
      - `invertible`       : `comptime Bool` (default `False`).
      - `prepare_partition`: defaults to `init_partition`.
      - `enter_row` / `leave_row` / `emit` : the invertible fast-path (default
                         bodies).
    """

    # ---- the typed-row mechanism (mirrors MapFn / PartitionLocalMapFn) ----
    comptime InRow: Copyable & Movable          # a @fieldwise_init struct of typed input fields
    comptime InputSchema: SchemaDescriptor = _derive_schema[Self.InRow]()
    comptime OutputSchema: SchemaDescriptor     # name+dtype of the (one) output column
    comptime OutType: DType                     # = OutputSchema.cols[0].dtype
    comptime UDF_ID: UInt32                     # the operator-factory selector

    # ---- the per-partition state + keys (mirrors PartitionLocalMapFn) ----
    comptime State: Copyable & Movable & Deinitable
    comptime PART_KEYS: KeyList   # PARTITION BY keys (comptime — part of F's identity)
    comptime ORDER_KEYS: KeyList  # ORDER BY keys within each partition

    # ---- the FRAME + invertibility (what a custom window fn adds) ----
    comptime frame: WindowFrameSpec     # ROWS | RANGE (fenced at operator build)
    comptime invertible: Bool = False   # user-asserted algebraic-inverse contract

    # ---- the order-key dtype ----
    #
    # DEFAULTED (`DType.int64`) so existing ROWS conformers are UNTOUCHED — the
    # ROWS kernel never reads the order-key VALUE (it does row-offset arithmetic),
    # so `KeyEntry` carries no dtype. RANGE frames need the order key's value for
    # the value-bound search (`k - preceding`, `k + following`), read as
    # `Scalar[ORDER_KEY_DT]` via the same comptime DType ladder `FrameView.get`
    # uses. The operator build comptime-asserts orderability
    # (`ORDER_KEY_DT in {int64, int32, float64, float32}`) + a single order key
    # for RANGE frames — ROWS frames ignore this member entirely.
    comptime ORDER_KEY_DT: DType = DType.int64

    # ---- per-partition lifecycle ----
    def init_partition(self) -> Self.State:
        """Build a FRESH per-partition accumulator (reset at each boundary).
        Called once per partition boundary by the frame scan — the per-partition
        reset that isolates state across partitions."""
        ...

    # ---- RECOMPUTE path: the ABSTRACT entry point ----
    def compute_frame[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: FrameView[origin]) raises -> Scalar[
        Self.OutType
    ]:
        """Recompute this output row's value from scratch over the frame
        `[lo, hi)` exposed by `view`. The conformer reads its OWN inputs from
        `view` via `view.get[frame_idx, local_input_idx, dt]()` /
        `view.get_at[local_input_idx, dt](frame_idx)` by comptime input index
        (it knows arity + per-position dtypes from `InputSchema`), iterating
        `for i in range(len(view))` over the frame rows. `mut s` is the
        per-partition state (e.g. a partition-wide constant cached by
        `prepare_partition`); a stateless recompute may ignore it. Generic over
        the view's `origin` so the engine's borrowed sorted batch lifetime is
        tracked end-to-end.

        This is the ONLY required override — the RECOMPUTE path the engine drives. The
        empty-frame case (`len(view) == 0`) is handled by the engine (emits NULL
        WITHOUT calling `compute_frame`), so a conformer never sees an empty
        frame here."""
        ...

    # ---- RECOMPUTE path: per-partition prep (defaults to init_partition) ----
    def prepare_partition(self) -> Self.State:
        """Build the per-partition state the recompute path threads into
        `compute_frame`. Defaults to `init_partition`:
        most recompute conformers reset the same way the invertible path does.
        Override only when the recompute path needs a frame-aware partition prep
        (e.g. caching a partition-wide constant the per-frame recompute reads)."""
        return self.init_partition()

    # ---- INVERTIBLE fast path: default bodies ----
    def enter_row[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: FrameView[origin], frame_idx: Int) raises:
        """INVERTIBLE fast path: fold the `frame_idx`-th frame row
        INTO the running state `s` (the row ENTERING the front of the sliding
        frame). Default no-op; a recompute-only UDF leaves it."""
        pass

    def leave_row[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: FrameView[origin], frame_idx: Int) raises:
        """INVERTIBLE fast path: remove the `frame_idx`-th frame
        row FROM the running state `s` (the row LEAVING the back of the sliding
        frame). Default no-op."""
        pass

    def emit[
        origin: Origin[mut=False]
    ](self, mut s: Self.State, view: FrameView[origin]) raises -> Scalar[
        Self.OutType
    ]:
        """INVERTIBLE fast path: emit the output value from the
        running state `s` after the enter/leave folds for this row. Defaults to
        `compute_frame` over the current frame (the default body — an
        invertible UDF whose emit is just "read the accumulator" still needs to
        override this to read `s` instead of recomputing)."""
        return self.compute_frame(s, view)
