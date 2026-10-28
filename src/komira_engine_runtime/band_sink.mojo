# =============================================================================
# komira_engine_runtime.band_sink -- the BandSink seam
# =============================================================================
#
# The seam for a per-page decompress -> decode -> aggregate pipeline: a band
# producer hands each decoded row-band to the sink as it is decoded.
#
# The producer decodes a row group into per-column band buffers and, per
# residency-sized row-band, constructs a `BandView` over its reused scratch and
# calls `sink.consume_band(local, band)`. A `BandSink` folds directly over the
# band spans; it never builds a fresh Arrow column or a RecordBatch.
#
# The trait lives here, not in the parquet package, so that both the producer
# (generic over a sink) and a concrete sink can depend on it without a
# dependency edge between them.
#
# Trait shape:
#   * `comptime WorkerLocal: Movable & Deinitable` is the per-worker private
#     partial, stored in a per-worker `Slab[Optional[WorkerLocal]]`; each worker
#     owns its slot.
#   * `init_worker_state(self) -> Self.WorkerLocal` builds a worker's partial.
#   * `consume_band[o](self, mut local, band: BandView[o])` folds one band into
#     `local`. `band` is borrowed: it must not be stored, and the fold completes
#     before the producer reuses the scratch for the next band.
#   * `combine_workers(self, var locals, nw) -> Self.WorkerLocal` is a serial
#     post-barrier combine of every worker's partial into one.
#   * `drain(self, var combined, var out_schema) -> Slab[RecordBatch]` finalizes
#     the combined partial to the output shape.
#
# No `UnsafePointer` appears in any signature; the band arrives as a safe
# borrowed `BandView[o]`.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.band_view import BandView
from komira_collections.slab import Slab


# The executor's concrete sink type (and its `WorkerLocal`) is bound at the
# generic call site, since trait declarations cannot carry parameters.
trait BandSink(Movable, Deinitable):
    """Per-BAND sink for the parquet band producer's fold-and-free executor.

    A `BandSink` abstracts the TERMINAL operation the producer performs on each
    decoded row-band, for example a typed grouped-aggregate fold. Everything
    up to `consume_band` (cursor open, per-row-group decline, lockstep
    multi-column band fill) is sink-agnostic.

    Associated type:
        WorkerLocal: the per-worker PRIVATE partial. Built by
            `init_worker_state` once per worker; fed by `consume_band` per band;
            folded by `combine_workers`; finalized by `drain`. Movable +
            Deinitable so it lives in a per-worker
            `Slab[Optional[WorkerLocal]]` (the slab element is the Optional
            handle).
    """

    comptime WorkerLocal: Movable & Deinitable

    def init_worker_state(self) raises -> Self.WorkerLocal:
        """Build a worker's private per-worker partial (its own slot)."""
        ...

    def consume_band[o: Origin[mut=False]](
        self, mut local: Self.WorkerLocal, band: BandView[o]
    ) raises:
        """Fold ONE band into `local`. `band` is BORROWED (read) — it must NOT
        be stored; the fold completes before the producer reuses the scratch for
        the next band. The fold reads codes/values
        straight from the band spans — NO RecordBatch, NO fresh Arrow column."""
        ...

    def combine_workers(
        self,
        var locals: Slab[Optional[Self.WorkerLocal]],
        num_workers: Int,
    ) raises -> Self.WorkerLocal:
        """Serial post-barrier combine of every worker's partial into one.
        Consumes the per-worker locals
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
