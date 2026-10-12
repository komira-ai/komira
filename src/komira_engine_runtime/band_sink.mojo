# =============================================================================
# komira_engine_runtime.band_sink — the BandSink seam (q1 decode vertical spike)
# =============================================================================
#
# The seam for the per-page decompress->decode->aggregate pipeline (the DuckDB
# model): the band producer hands each row-band to the sink as it is decoded.
#
# THE SEAM (mirrors `ScanChunkSink`, minus the RecordBatch). The band PRODUCER
# (`komira_parquet/band_producer.mojo`) decodes each RG into N per-column band
# buffers and, per residency-sized row-band, constructs a `BandView` over the
# REUSED scratch and calls `sink.consume_band(local, band)` — the ONE line that
# replaces `_resolve_flat_*_col + rbb.build + consume_chunk` (the
# re-materialization that keeps both the typed leg-2 path AND the untyped subrg
# substrate byte-stuck). A `BandSink` folds DIRECTLY over the band spans; it
# never builds a fresh Arrow column or a RecordBatch.
#
# HOME (§2.1). This trait lives in `engine_runtime` — NOT parquet — because both
# parquet (`run_band_agg`, the driver generic) AND engine_operators
# (`HashAggBandSink`, the concrete conformer, Half B) depend on `engine_runtime`.
# So neither the producer generic nor the conformer creates a new
# parquet<->engine back-edge (the same "RBE-CUTOVER EDGE 5" discipline the subrg
# executor already respects). Half A creates this file; Half B imports it
# read-only and conforms `HashAggBandSink[KB, *Aggs]` to it.
#
# THE TRAIT SHAPE (mirrors ScanChunkSink's lifecycle):
#   * `comptime WorkerLocal: Movable & Deinitable` — the per-worker
#     PRIVATE partial (agg: a HashAggTable[KB, *Aggs] monomorph). Stored in a
#     per-worker `Slab[Optional[WorkerLocal]]`; each worker owns slot `wid`
#     disjointly. gap6-safe (byte-backed Movable).
#   * `init_worker_state(self) -> Self.WorkerLocal` — build a worker's private
#     partial (disjoint slot).
#   * `consume_band[o](self, mut local, band: BandView[o])` — fold ONE band into
#     `local`. `band` is BORROWED (a `read` parameter): it must NOT be stored;
#     the fold completes synchronously before the producer reuses the scratch for
#     the next band (§1.3 guard 1).
#   * `combine_workers(self, var locals, nw) -> Self.WorkerLocal` — serial
#     post-barrier combine of every worker's partial into one.
#   * `drain(self, var combined, var out_schema) -> Slab[RecordBatch]` — finalize
#     the combined partial to the OUTPUT shape.
#
# Pointer discipline: NO UnsafePointer in any signature here. The
# band arrives as `BandView[o]` (a safe borrowed view; NO raw pointer surface).
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.band_view import BandView
from komira_collections.slab import Slab


# =============================================================================
# The BandSink trait.
#
# Mojo: trait declarations cannot carry parameters, so the executor's
# concrete SINK type (and its `WorkerLocal`) is bound at the `run_with_state`
# call site (`band_producer.run_band_agg`) — the SAME (FS, SINK) pin-pair the
# subrg executor uses (see `_BandAggTask.execute`'s bitcast SAFETY block).
# =============================================================================
trait BandSink(Movable, Deinitable):
    """Per-BAND sink for the parquet band producer's fold-and-free executor.

    A `BandSink` abstracts the TERMINAL operation the producer performs on each
    decoded row-band: for the spike, the typed grouped-agg fold
    (`HashAggBandSink`, Half B). Everything UP TO `consume_band` (cursor open,
    per-RG decline, lockstep multi-column band fill) is sink-agnostic.

    Associated type:
        WorkerLocal: the per-worker PRIVATE partial. Built by
            `init_worker_state` once per worker; fed by `consume_band` per band;
            folded by `combine_workers`; finalized by `drain`. Movable +
            Deinitable so it lives in a per-worker
            `Slab[Optional[WorkerLocal]]` (the slab element is the Optional
            handle). Same shape `ScanChunkSink.WorkerLocal` already satisfies.
    """

    comptime WorkerLocal: Movable & Deinitable

    def init_worker_state(self) raises -> Self.WorkerLocal:
        """Build a worker's PRIVATE per-worker partial (disjoint slot). Mirrors
        `ScanChunkSink.init_worker_state`."""
        ...

    def consume_band[o: Origin[mut=False]](
        self, mut local: Self.WorkerLocal, band: BandView[o]
    ) raises:
        """Fold ONE band into `local`. `band` is BORROWED (read) — it must NOT
        be stored; the fold completes before the producer reuses the scratch for
        the next band (contract §1.3 guard 1). The fold reads codes/values
        straight from the band spans — NO RecordBatch, NO fresh Arrow column."""
        ...

    def combine_workers(
        self,
        var locals: Slab[Optional[Self.WorkerLocal]],
        num_workers: Int,
    ) raises -> Self.WorkerLocal:
        """Serial post-barrier combine of every worker's partial into one
        (mirror `run_subrg_agg`'s serial combine). Consumes the per-worker locals
        slab whole-segment (each populated slot taken via `Optional.take()` /
        `Slab.take_slot_unchecked`)."""
        ...

    def drain(
        self,
        var combined: Self.WorkerLocal,
        var output_schema: Schema,
    ) raises -> Slab[RecordBatch]:
        """Finalize the combined partial to the OUTPUT shape. The agg arm returns
        a SINGLE-ELEMENT Slab (finalize-to-one-batch stays inside the leaf)."""
        ...
