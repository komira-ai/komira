# =============================================================================
# parallel_reader — multi-thread parallel CSV reader
# =============================================================================
#
# Builds on:
#   * the byte-class primitives (movemask + PCLMULQDQ/PMULL64)
#   * the single-thread reader driver (`read_csv_bytes_to_batch[Q]`)
#   * the movemask_u8x32 32-byte SIMD scan
#   * the PCLMULQDQ/PMULL64 64-byte simdcsv-tier scan (the per-worker
#     scan kernel here)
#
# Algorithm:
#   1. Partition the byte buffer into N approximately-equal sub-ranges.
#      For each sub-range boundary, scan forward (memchr-style) to the
#      next outside-quote newline byte; adjust the boundary so each
#      worker scans complete rows.
#   2. Worker 0 strips the header row (if `has_header`) and produces
#      header_names. Inference runs on worker 0's first `infer_rows`
#      rows to derive a single shared schema across all workers.
#   3. Per-worker dispatch (via stdlib `parallelize`): each worker
#      independently runs `_dispatch_scan[Q, SCANNER_VARIANT_PHASE_3]`
#      on its byte slice + materializes a per-worker `RecordBatch`
#      using the shared schema.
#   4. Serial N-way concat of per-worker batches via `_concat_two_batches`.
#
# Key design decisions:
#   * Per-worker quote-region carry init = 0: guaranteed correct because
#     each worker's byte range starts at an outside-quote position (the
#     partition phase, `compute_csv_quote_safe_row_ranges`, only splits
#     at a newline it can prove is OUTSIDE any quoted region).
#   * The parallel sections run on `LocalDispatcher.run_with_state` when
#     the caller supplies a dispatcher (the `_with_dispatcher` entry
#     points) and serially otherwise, since the byte-level read path can
#     be invoked before the engine pipeline exists.
#   * Worker count = caller-provided `n_workers`; default to
#     `num_physical_cores()` when not specified.
#   * Threshold gates: byte buffer < `_MIN_PARALLEL_BYTES` (1 MiB) or
#     `n_workers <= 1` -> fall back to single-thread via
#     `read_csv_bytes_to_batch[Q, SCANNER_VARIANT_PHASE_3]`.
#
# Parallel region:
#   * Disjointness: worker `w` is the unique writer to
#     `worker_batches[w]`. All other captured state (`bytes`,
#     `worker_ranges`, `shared_schema`, `header_names`, `options`) is
#     read-only.
#   * Liveness: all captured locals live on the driver stack across
#     `parallelize[worker]`. stdlib `parallelize` is synchronous --
#     workers join before the call returns. Per repro7 pattern:
#     `Pointer(to=...)` local + capture; no bare `ref` capture.
#   * No-realloc: `worker_batches` is pre-sized to N and never grows;
#     per-worker writes are `__setitem__` (destroy-then-init) on
#     `Optional[RecordBatch]` slots.
#   * Encapsulation: no `UnsafePointer` in any signature. No wildcard
#     origins. The `_load_u8x*` helpers in csv_scanner_phase1 are
#     private + carry SAFETY blocks (inherited).
# =============================================================================

from komira_async.runtime.sched_trace import SITE_FORMAT_READ
from std.memory import UnsafePointer
from std.sys import num_physical_cores
from std.time import perf_counter_ns


# Design rule: library code never calls stdlib `parallelize` directly. The two
# per-worker / per-column dispatch sites below route through the runtime
# substrate `LocalDispatcher.run_with_state` instead of stdlib
# `parallelize[worker](n)`. Mirrors the canonical
# `agg_count_distinct_kernel._dedup_groups_parallel_impl` +
# `ocf_block_emit.compress_blocks_parallel` shape: a `(KeepAlive, Movable)`
# State that OWNS the per-dispatch mutable outputs (as `Optional[T]`,
# extracted post-drain via `Optional.take()` rather than a partial move) and BORROWS
# the read-only inputs through typed-origin pointers (no MutExternalOrigin
# or wildcard origin), plus a POD `(Segment)` Task whose
# `execute[State]` bitcasts to the concrete State. The dispatcher +
# cancel-token are threaded through the public driver signature
# (`_with_dispatcher` variant) so the borrowed/owned state lives on a
# per-dispatch value whose lifetime the compiler tracks, not a struct
# field that outlives the caller.
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_arrow.streaming_concat import (
    _concat_two_batches,
    _concat_fixed_columns_multi,
    _concat_string_columns_multi,
)
from komira_arrow.concat import _concat_columns
from komira_buffer.heap_region import HeapRegion

from .csv_options import CsvReadOptions, check_declared_column_types
from .input_limits import check_csv_cell_budget, check_csv_column_count
from .record_shape import check_csv_record_shape, skip_leading_blank_lines
from .csv_scanner_phase1 import (
    scan_csv_phase1_into_cells,
    scan_csv_phase2_movemask_into_cells,
    scan_csv_phase3_pclmulqdq_into_cells,
)
from .scanned_cells import ScannedCells
from .cell_parsers import (
    _try_parse_bool,
    cell_to_string,
)
# The per-DType
# SIMD fast-paths (int64 / float64 / date32) live behind
# `int_column_simd.build_{int64,float64,date32}_column_simd`. The
# `cell_parsers_simd` imports they consume (fast_parse_int64_simple,
# fast_parse_float64_simple, cell_is_simple_numeric, fast_parse_iso_date32)
# are imported there; this driver does not reference them directly
# since `_build_int64/float64/date32_column` delegate end-to-end.
# Bulk-memcpy
# fast path for STRING/BINARY column builder. See string_column_simd.mojo.
from .string_column_simd import build_string_column_simd
# Per-cell iteration
# overhead reshape — drop-validity-bitmap-RMW + hoist-row-base +
# skip-null-check-on-numeric-fast-path. See int_column_simd.mojo.
from .int_column_simd import (
    build_int64_column_simd,
    build_float64_column_simd,
    build_date32_column_simd,
)
from .null_detection import is_null_cell
from .quote_styles import QuoteStyle, Rfc4180, Excel, Posix
# THE body partitioner, shared with
# the row-path reader. Replaces this module's own `_compute_byte_ranges`.
from .csv_chunk_split import compute_csv_quote_safe_row_ranges
from .type_inference import infer_column_types
from .reader import (
    SCANNER_VARIANT_PHASE_1,
    SCANNER_VARIANT_PHASE_2,
    SCANNER_VARIANT_PHASE_3,
    read_csv_bytes_to_batch,
)
from .csv_options import (
    QUOTE_STYLE_TAG_RFC4180,
    QUOTE_STYLE_TAG_EXCEL,
    QUOTE_STYLE_TAG_POSIX,
)


# =============================================================================
# Threshold gates + tunables.
# =============================================================================

# Files smaller than this fall back to single-thread (variant=3). Below
# ~1 MiB the partition + concat overhead exceeds the parallel scan win.
comptime _MIN_PARALLEL_BYTES: Int = 1 * 1024 * 1024  # 1 MiB

# There is no cap on the splitter's forward newline walk: not finding a boundary
# simply yields one fewer range, which IS the single-thread fallback, reached
# by the partition returning what it can prove rather than by a byte budget.

# Cap on worker count. More than 32 workers rarely pays back the
# partition overhead; on 16-core+ machines we cap to keep the
# per-worker slice large enough to amortize cold-cache fill.
comptime _MAX_WORKERS: Int = 32

# Cap the serial type-inference prefix scan at ~256 KB of worker 0's slice.
# We only need `options.infer_rows + 1` rows for inference (header +
# small data prefix); for a 64-byte/row CSV that's ~6.4 KB; the
# 256 KB cap is intentionally generous so wide-row CSVs (~2-4 KB
# rows) still see enough rows. Scanning worker 0's ENTIRE slice serially
# for inference instead costs seconds of serial work on a large file
# BEFORE the parallel dispatch starts -- the dominant Amdahl bottleneck.
comptime _INFER_PREFIX_BYTES: Int = 256 * 1024  # 256 KB


# =============================================================================
# per-stage timing instrumentation. OFF by default (zero hot-
# path cost). Pass `stage_timing=True` to emit a single
# `[CSV_PHASE4_TIMING] key=us ...` line on stdout per
# `read_csv_bytes_to_batch_parallel` call.
#
# Stages reported (level 1 — driver + per-worker aggregate):
#   partition_us           — driver-side _compute_byte_ranges
#   infer_us               — driver-side worker-0 prefix scan + type inference
#   scan_max_us            — max across workers of scan_csv_phase3 wall;
#                            bounds the parallel-section wall contribution
#   scan_sum_us            — aggregate scan core-time across all workers
#   materialize_max_us     — max across workers of _materialize_batch wall
#   materialize_sum_us     — aggregate materialize core-time
#   concat_us              — driver-side column-parallel N-way concat
#   total_us               — wall (perf_counter_ns delta around the public fn body)
#
# Stages reported (level 2 — per-dtype materialize breakdown, aggregate):
#   build_int64_sum_us / build_float64_sum_us / build_string_sum_us /
#   build_date32_sum_us / build_bool_sum_us
#
# Aggregate share interpretation:
#   * For Amdahl analysis vs total wall, use `max_us` for the parallel
#     stages (scan / materialize) and the driver wall for partition /
#     infer / concat. The synthetic total = partition + infer +
#     max(scan + materialize per-worker) + concat closely tracks the
#     observed `total_us`.
#   * `sum_us` numbers are core-seconds spent in each stage, useful for
#     identifying the dominant compute consumer across cores even when
#     a stage is well-parallelized.
# =============================================================================


struct _PhaseTiming(Copyable, Movable, ImplicitlyCopyable):
    """Per-worker timing accumulator (in microseconds).

    POD shape: all fields are `Int`. `Copyable` so `List[_PhaseTiming]`
    is well-formed under Mojo 1.0.0b1 (which requires T: Copyable for
    List). Storing as List[struct] keeps the per-worker capture surface
    tight (one Pointer for the whole array) vs 7 parallel List[Int]
    arrays.

    Disjointness contract: worker `w` writes ONLY its own slot via
    setitem of a freshly-built _PhaseTiming. Read-after-write within
    one worker is sequential (no inter-thread accumulation).
    """
    var scan_us: Int
    var materialize_us: Int
    var build_int64_us: Int
    var build_float64_us: Int
    var build_string_us: Int
    var build_date32_us: Int
    var build_bool_us: Int

    def __init__(out self):
        self.scan_us = 0
        self.materialize_us = 0
        self.build_int64_us = 0
        self.build_float64_us = 0
        self.build_string_us = 0
        self.build_date32_us = 0
        self.build_bool_us = 0




def _max2(a: Int, b: Int) -> Int:
    if a > b:
        return a
    return b


def _emit_phase4_timing_report(
    n_bytes: Int,
    k_workers: Int,
    partition_us: Int,
    infer_us: Int,
    concat_us: Int,
    worker_timings: List[_PhaseTiming],
    total_us: Int,
):
    """Single-line stage report. Format mirrors the JSONL_WRITE_TIMING
    line for grep / parse symmetry:

        [CSV_PHASE4_TIMING] bytes=N workers=K partition_us=N infer_us=N
        scan_max_us=N scan_sum_us=N materialize_max_us=N
        materialize_sum_us=N concat_us=N total_us=N
        build_int64_sum_us=N build_float64_sum_us=N build_string_sum_us=N
        build_date32_sum_us=N build_bool_sum_us=N
        synthetic_total_us=N

    `synthetic_total_us` = partition + infer + max(scan+materialize per
    worker) + concat. Equals `total_us` to within parallelize-dispatch
    overhead (~50-200 us). Used as the denominator for Amdahl-style
    stage percentages.
    """
    var scan_max = 0
    var scan_sum = 0
    var mat_max = 0
    var mat_sum = 0
    var worker_max = 0
    var b_int64_sum = 0
    var b_float64_sum = 0
    var b_string_sum = 0
    var b_date32_sum = 0
    var b_bool_sum = 0
    var w = 0
    while w < k_workers:
        var t = worker_timings[w]
        scan_max = _max2(scan_max, t.scan_us)
        scan_sum = scan_sum + t.scan_us
        mat_max = _max2(mat_max, t.materialize_us)
        mat_sum = mat_sum + t.materialize_us
        var worker_total = t.scan_us + t.materialize_us
        worker_max = _max2(worker_max, worker_total)
        b_int64_sum = b_int64_sum + t.build_int64_us
        b_float64_sum = b_float64_sum + t.build_float64_us
        b_string_sum = b_string_sum + t.build_string_us
        b_date32_sum = b_date32_sum + t.build_date32_us
        b_bool_sum = b_bool_sum + t.build_bool_us
        w = w + 1

    var synthetic_total = partition_us + infer_us + worker_max + concat_us

    print(
        "[CSV_PHASE4_TIMING] bytes=",
        n_bytes,
        " workers=",
        k_workers,
        " partition_us=",
        partition_us,
        " infer_us=",
        infer_us,
        " scan_max_us=",
        scan_max,
        " scan_sum_us=",
        scan_sum,
        " materialize_max_us=",
        mat_max,
        " materialize_sum_us=",
        mat_sum,
        " concat_us=",
        concat_us,
        " total_us=",
        total_us,
        " synthetic_total_us=",
        synthetic_total,
        " build_int64_sum_us=",
        b_int64_sum,
        " build_float64_sum_us=",
        b_float64_sum,
        " build_string_sum_us=",
        b_string_sum,
        " build_date32_sum_us=",
        b_date32_sum,
        " build_bool_sum_us=",
        b_bool_sum,
        sep="",
    )


# =============================================================================
# State + Segment for the per-worker parallel scan+materialize dispatch (site 1).
# =============================================================================
#
# Mirrors `agg_count_distinct_kernel._CdGroupState`/`_CdGroupTask` +
# `ocf_block_emit._CompressBlocksState`. The State OWNS the per-dispatch
# mutable outputs (`worker_batches` / `worker_errors` / `worker_timings`,
# each wrapped in `Optional[T]` and extracted post-drain via
# `Optional.take()` rather than a partial move) and BORROWS all read-only inputs via
# typed-origin pointers under a single shared immutable origin `in_o`
# (anchored on the driver stack frame; no MutExternalOrigin or wildcard
# origin). One task per worker `tid` in [0, k); `tid==0` strips
# the header. The bytes buffer is borrowed as a base pointer + length and
# the per-worker `[lo, hi)` slice is reconstructed with `Span(unsafe_ptr=,
# length=)` (the scanner + materialize helpers are origin-poly
# `Span[UInt8, _]`).


struct _CsvScanState[
    Q: QuoteStyle,
    in_o: ImmOrigin,
](KeepAlive, Movable):
    """State for per-worker parallel CSV scan+materialize (`site 1`).

    THE OWNERSHIP RULE THIS STRUCT ENFORCES, and why it is a rule:

      * It BORROWS only inputs the CALLER owns — the `bytes` base+len and
        `options`, both parameters of `read_csv_bytes_to_batch_parallel_
        impl` and therefore outliving every frame inside it. `in_o` is
        anchored on the bytes span, so for these two the label is the truth.
      * Everything the DRIVER FRAME owns — the `los`/`his` boundary lists,
        `header_names`, `shared_col_types` — is MOVED IN as `Optional[T]`
        and taken back with `Optional.take()` after the drain barrier, the
        same way `worker_batches` / `worker_errors` / `worker_timings`
        already were.

    ⚠ THE SECOND BULLET IS A CORRECTNESS RULE, NOT A STYLE PREFERENCE.
    Borrowing those four like the first two (`UnsafePointer(to=los).
    unsafe_origin_cast[in_o]()`) is a use-after-free. `in_o` is the BYTES buffer's origin —
    it says nothing about a local named `los`, and the `unsafe_origin_cast`
    DISCARDS the true `origin_of(los)` that `UnsafePointer(to=)` had just
    produced. With no liveness edge left, ASAP destruction freed `los` and
    `his` at their last source use — the pointer-taking line itself, BEFORE
    `run_with_state` posts a single task — and every worker reads its
    `[lo, hi)` out of freed heap. A debug build reports it as an
    out-of-bounds index on a destroyed List; in a release build
    `debug_assert` is inert, so a garbage `lo` makes `bytes_base + lo` a
    wild pointer and the scanner faults on its first byte compare.

    `header_names` / `shared_col_types` would carry the identical severed
    origin and survive only by ACCIDENT — the column-concat call below
    happens to use them after the barrier, a liveness guarantee no reader
    can see and any refactor could delete. They are moved in too.

    A keepalive on the POINTER (`_ = los_p`) does not fix this: the pointer is POD, so keeping it alive keeps an
    address, not a pointee. The only sound options are a real origin edge or
    ownership. Ownership is what the output slots already used, and unlike
    an origin label it cannot be quietly mislabelled.
    """
    # Borrowed read-only inputs — CALLER-OWNED ONLY (see the rule above).
    # SAFETY: Internal typed pointers — never exposed to public API. Both
    # point at parameters of the enclosing driver fn, which outlive the
    # synchronous dispatch barrier by construction.
    var bytes_base: UnsafePointer[UInt8, Self.in_o]
    var bytes_len: Int
    var options_ptr: UnsafePointer[CsvReadOptions, Self.in_o]
    var timing_enabled: Bool
    # OWNED read-only scan inputs — moved in from the driver frame, taken
    # back after the barrier. Workers read these; no worker mutates them.
    var los: Optional[List[Int]]
    var his: Optional[List[Int]]
    var names: Optional[List[String]]
    var types: Optional[List[ArrowType]]
    # OWNED per-worker outputs — each task writes its disjoint slot.
    var batches: Optional[Slab[Optional[RecordBatch]]]
    var errors: Optional[List[Optional[String]]]
    var timings: Optional[List[_PhaseTiming]]

    def __init__(
        out self,
        bytes_base: UnsafePointer[UInt8, Self.in_o],
        bytes_len: Int,
        options_ptr: UnsafePointer[CsvReadOptions, Self.in_o],
        timing_enabled: Bool,
        var los: List[Int],
        var his: List[Int],
        var names: List[String],
        var types: List[ArrowType],
        var batches: Slab[Optional[RecordBatch]],
        var errors: List[Optional[String]],
        var timings: List[_PhaseTiming],
    ):
        self.bytes_base = bytes_base
        self.bytes_len = bytes_len
        self.options_ptr = options_ptr
        self.timing_enabled = timing_enabled
        self.los = Optional[List[Int]](los^)
        self.his = Optional[List[Int]](his^)
        self.names = Optional[List[String]](names^)
        self.types = Optional[List[ArrowType]](types^)
        self.batches = Optional[Slab[Optional[RecordBatch]]](batches^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.timings = Optional[List[_PhaseTiming]](timings^)


@fieldwise_init
struct _CsvScanTask[
    Q: QuoteStyle,
    in_o: ImmOrigin,
](Segment):
    """POD Segment for `_CsvScanState` dispatch — one task per worker."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_CsvScanState[Q, in_o], _CsvScanTask[Q, in_o]); the bitcast
        # resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _CsvScanState[Self.Q, Self.in_o]
        ]()
        var tid = Int(task_id)
        # `los`/`his` are OWNED BY THE STATE: the
        # driver moved them in, so their storage is reachable from `state`
        # and cannot be destroyed while `run_with_state` borrows it. Borrowed
        # pointers carrying the BYTES buffer's origin could not be tied to the
        # driver's locals — see the struct docstring.
        var lo = sp[].los.value()[tid]
        var hi = sp[].his.value()[tid]
        # Reconstruct the per-worker [lo, hi) byte slice from the borrowed
        # base pointer; origin-poly scanner / materialize helpers accept
        # any `Span[UInt8, _]`.
        var slice = Span[UInt8, Self.in_o](
            unsafe_ptr=sp[].bytes_base + lo, length=hi - lo
        )
        var timing_enabled = sp[].timing_enabled

        # Per-worker quote-region carry init = 0 (correct because the
        # partition phase aligned `lo` to an outside-quote newline
        # position; the scanner's internal state starts at STANDARD
        # with quote_region_carry=False, doubled_quote_tail_carry=False).
        try:
            var t_scan0 = perf_counter_ns() if timing_enabled else 0
            var cells_local = scan_csv_phase3_pclmulqdq_into_cells[Self.Q](
                slice, sp[].options_ptr[].delimiter, sp[].options_ptr[].quote
            )
            # ROW-BYTE CEILING (holds with assertions compiled out). Same check
            # the single-thread reader applies; stated per worker because this
            # path never routes through that entry. One pass over this
            # worker's row_starts, before its builders allocate.
            cells_local.enforce_max_row_bytes(
                sp[].options_ptr[].max_row_bytes
            )
            var scan_us_local = (Int(perf_counter_ns() - t_scan0) // 1000) if timing_enabled else 0

            # Worker 0 skips blank lines before the header / first record
            # and strips the header row. Workers 1..k-1 scan all rows.
            if tid == 0:
                skip_leading_blank_lines(cells_local)
            var data_skip = 0
            if tid == 0 and sp[].options_ptr[].has_header:
                data_skip = 1
            # RECORD SHAPE (komira-ai/komira#449), per worker: this slice is
            # all this worker sees. The whole input is passed so a refusal
            # can number the record from the start of the file.
            check_csv_record_shape[Self.Q](
                Span[UInt8, Self.in_o](
                    unsafe_ptr=sp[].bytes_base, length=sp[].bytes_len
                ),
                lo,
                0,
                cells_local,
                data_skip,
                sp[].names.value(),
                sp[].options_ptr[].has_header,
                sp[].options_ptr[].delimiter,
                sp[].options_ptr[].quote,
            )
            var num_rows_local = cells_local.num_rows() - data_skip
            if num_rows_local <= 0:
                # Empty worker -- batch slot stays None (pre-initialized).
                if timing_enabled:
                    var t = _PhaseTiming()
                    t.scan_us = scan_us_local
                    sp[].timings.value()[tid] = t
            else:
                var t_mat0 = perf_counter_ns() if timing_enabled else 0
                if timing_enabled:
                    var t = _PhaseTiming()
                    t.scan_us = scan_us_local
                    var batch = _materialize_batch_with_schema_timed[Self.Q](
                        slice,
                        cells_local,
                        data_skip,
                        sp[].names.value(),
                        sp[].types.value(),
                        num_rows_local,
                        sp[].options_ptr[],
                        t,
                    )
                    t.materialize_us = Int(perf_counter_ns() - t_mat0) // 1000
                    sp[].timings.value()[tid] = t
                    sp[].batches.value()[tid] = Optional[RecordBatch](batch^)
                else:
                    var batch = _materialize_batch_with_schema[Self.Q](
                        slice,
                        cells_local,
                        data_skip,
                        sp[].names.value(),
                        sp[].types.value(),
                        num_rows_local,
                        sp[].options_ptr[],
                    )
                    sp[].batches.value()[tid] = Optional[RecordBatch](batch^)
        except e:
            # Capture the error string for re-raise at the driver.
            sp[].errors.value()[tid] = Optional[String](String(e))


# =============================================================================
# Public entry point.
# =============================================================================


def read_csv_bytes_to_batch_parallel[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    options: CsvReadOptions,
    n_workers: Int = 0,
    stage_timing: Bool = False,
) raises -> RecordBatch:
    """Serial-fallback entry for `read_csv_bytes_to_batch_parallel_impl`.

    The parallel scan and
    column-concat dispatch route through `LocalDispatcher.
    run_with_state` (library code never calls stdlib `parallelize`
    directly). This wrapper is the dispatcher-less variant for callers without
    a EngineContext (test fixtures, the `_dynamic` wrapper's
    pre-engine-pipeline invocation): it forwards `has_dispatcher=False`,
    which selects the serial per-worker / per-column loop. SDK callers
    that hold a `ctx.dispatcher()` should call
    `read_csv_bytes_to_batch_parallel_with_dispatcher[Q, disp_o]` instead.
    """
    return read_csv_bytes_to_batch_parallel_impl[
        Q, has_dispatcher=False, disp_o=MutAnyOrigin
    ](
        bytes,
        options,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
        n_workers,
        stage_timing,
    )


def read_csv_bytes_to_batch_parallel_with_dispatcher[
    Q: QuoteStyle,
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    options: CsvReadOptions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    n_workers: Int = 0,
    stage_timing: Bool = False,
) raises -> RecordBatch:
    """Dispatcher-dispatched parallel CSV read — typed-origin dispatcher.

    The per-worker scan and
    column-parallel concat both dispatch through `LocalDispatcher.
    run_with_state`. Threads the substrate dispatcher (from
    `ctx.dispatcher()`) + cancel token through the impl, which routes the
    two parallel sections onto the runtime worker pool.
    """
    return read_csv_bytes_to_batch_parallel_impl[
        Q, has_dispatcher=True, disp_o=disp_o
    ](
        bytes,
        options,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
        n_workers,
        stage_timing,
    )


def read_csv_bytes_to_batch_parallel_impl[
    Q: QuoteStyle,
    has_dispatcher: Bool,
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    options: CsvReadOptions,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
    n_workers: Int = 0,
    stage_timing: Bool = False,
) raises -> RecordBatch:
    """Read CSV bytes in parallel into a RecordBatch (Phase 4 driver).


    Partitions the byte buffer into approximately-equal sub-ranges
    aligned to newline boundaries, dispatches one worker per sub-range
    using the Phase 3 simdcsv-tier scanner kernel, and concats the
    per-worker batches into a single output.

    Falls back to single-thread (variant=3) when:
      - buffer is smaller than `_MIN_PARALLEL_BYTES`
      - `n_workers <= 1` (caller-requested serial)
      - effective worker count after partition resolves to 1 (e.g.
        single massive row, or buffer too small to partition cleanly)

    Args:
        bytes:     Origin-poly Span over the full file contents.
        options:   CsvReadOptions (header, delimiter, null strings, etc.).
        n_workers: Caller-requested worker count. Defaults to 0, which
                   queries `num_physical_cores()` and caps at `_MAX_WORKERS`.
                   Pass 1 to force single-thread.

    Returns:
        A single `RecordBatch` carrying all rows, with the schema
        inferred from worker 0's first `options.infer_rows` rows.

    Raises:
        Error on unterminated quoted region (EOF inside QUOTED state)
        within any worker's byte slice. The partition is quote-safe
        (`compute_csv_quote_safe_row_ranges`), so this means the input
        itself ends inside a quoted field.
        Error on a malformed record in any worker's slice (a field count
        other than the header's, or a byte after a closing quote that is not
        the delimiter or a line end), numbered from the start of the input
        (`record_shape`).
    """
    # Stage timing (`stage_timing`). The flag is fixed per public-fn call;
    # all `if _timing` checks below are predicated on this local Bool so
    # the un-instrumented path is exactly one extra branch per stage
    # boundary (zero overhead on the unset path; the LLVM optimizer can
    # constant-fold the entire timing scaffold when it is False).
    var _timing = stage_timing
    var _t_total0 = perf_counter_ns() if _timing else 0

    var n = len(bytes)
    if n == 0:
        # Empty file: defer to the single-thread reader (handles the
        # empty-schema empty-batch case correctly).
        return read_csv_bytes_to_batch[Q, SCANNER_VARIANT_PHASE_3](bytes, options)

    # Resolve effective worker count.
    var effective_workers = n_workers
    if effective_workers <= 0:
        effective_workers = num_physical_cores()
    if effective_workers > _MAX_WORKERS:
        effective_workers = _MAX_WORKERS
    if effective_workers < 1:
        effective_workers = 1

    # Threshold gate: below 1 MiB the partition+concat overhead exceeds
    # the parallel scan win; defer to single-thread.
    if n < _MIN_PARALLEL_BYTES or effective_workers == 1:
        return read_csv_bytes_to_batch[Q, SCANNER_VARIANT_PHASE_3](bytes, options)

    # =====================================================================
    # Step 1: Partition phase -- compute boundary offsets.
    # =====================================================================
    # We split the buffer into `effective_workers` sub-ranges, each starting
    # at a row boundary that is OUTSIDE any quoted field. The result is two
    # parallel List[Int]: `los[w]` is worker w's inclusive start, `his[w]` is
    # worker w's exclusive end. Each [lo, hi) range is a complete-row
    # half-open range.
    #
    # ⚠ A split that advances each candidate to the next RAW newline with no
    # quote tracking is wrong: a CSV with a quoted newline near a partition
    # boundary either fails with unterminated-quote or, worse, splits at a
    # `\n` that the FSA does not consider a row end and returns shredded rows.
    #
    # `compute_csv_quote_safe_row_ranges` classifies each boundary by quote
    # parity and declines to split what it cannot prove. It is the SAME
    # primitive the row-path reader uses — deliberately, so the next fix to
    # it cannot land in one reader and miss the other.
    #
    # Two parallel List[Int] are used (rather than List[InlineArray[Int,2]])
    # because InlineArray requires keyword-only ctors
    # (`fill=` / `uninitialized=True`), and List[Int] is the simpler
    # POD shape with no pointer field.
    var _t_partition0 = perf_counter_ns() if _timing else 0
    var los = List[Int]()
    var his = List[Int]()
    compute_csv_quote_safe_row_ranges[Q](
        bytes, 0, effective_workers, options.delimiter, options.quote,
        los, his,
    )
    var k = len(los)
    var _partition_us = (Int(perf_counter_ns() - _t_partition0) // 1000) if _timing else 0

    if k <= 1:
        # Partition collapsed to a single worker (e.g. one giant row, or
        # newline-find walked past max-row-bytes). Single-thread fallback.
        return read_csv_bytes_to_batch[Q, SCANNER_VARIANT_PHASE_3](bytes, options)

    var _t_infer0 = perf_counter_ns() if _timing else 0

    # =====================================================================
    # Step 2: Header + shared schema inference (PREFIX of worker 0 only).
    # =====================================================================
    # Scanning worker 0's ENTIRE slice on the driver thread for
    # inference would, at n_workers=2, be 50% of the
    # buffer scanned serially BEFORE the parallel dispatch starts --
    # the dominant Amdahl bottleneck on the multi-thread path.
    #
    # Cap the prefix scan at `_INFER_PREFIX_BYTES` (~256 KB). We only
    # need `options.infer_rows + 1` rows for inference (header + a
    # small data prefix); for a 64-byte/row CSV that's ~6.4 KB; the
    # 256 KB cap is intentionally generous so wide-row CSVs (~2-4 KB
    # rows) still see enough rows. Worker 0 covers the remaining
    # post-prefix bytes in Step 4.
    var worker0_lo = los[0]
    var worker0_hi = his[0]
    var infer_rows_target = options.infer_rows
    if infer_rows_target <= 0:
        infer_rows_target = 100
    # Scan a small prefix of worker 0's slice for inference.
    var prefix_hi_in_buf = worker0_lo + _INFER_PREFIX_BYTES
    if prefix_hi_in_buf > worker0_hi:
        prefix_hi_in_buf = worker0_hi
    # Always include at least 64 bytes to ensure header is captured.
    # Try the prefix scan first; if it raises (e.g. unterminated-quote
    # because the prefix cut mid-quoted-row), fall back to scanning the
    # full worker 0 slice. The fallback path is
    # correctness-preserving; the only cost is the full-slice
    # serial wall on quote-rich files where the prefix
    # didn't land cleanly.
    var worker0_prefix_slice = bytes[worker0_lo:prefix_hi_in_buf]
    var worker0_cells_prefix: ScannedCells
    try:
        worker0_cells_prefix = scan_csv_phase3_pclmulqdq_into_cells[Q](
            worker0_prefix_slice, options.delimiter, options.quote
        )
    except:
        # Prefix cut mid-quote; retry with full worker 0 slice. Reset
        # the prefix slice variable to the full slice so the byte-range
        # references below resolve against the right buffer.
        worker0_prefix_slice = bytes[worker0_lo:worker0_hi]
        worker0_cells_prefix = scan_csv_phase3_pclmulqdq_into_cells[Q](
            worker0_prefix_slice, options.delimiter, options.quote
        )

    # Blank lines before the header / first record (`record_shape`); worker
    # 0 drops the same rows from its own scan below.
    skip_leading_blank_lines(worker0_cells_prefix)
    if worker0_cells_prefix.num_rows() == 0:
        # Empty worker 0 -- no headers, no inference possible. Defer.
        return read_csv_bytes_to_batch[Q, SCANNER_VARIANT_PHASE_3](bytes, options)

    # Extract header_names (used by every worker to stamp output schema).
    # Names come from the prefix-slice byte ranges -- cell_to_string
    # extracts the bytes into owned Strings, so the prefix-slice's
    # lifetime is irrelevant once header_names is built.
    var header_names = List[String]()
    var data_start_offset_in_worker0 = 0
    if options.has_header:
        var ncols_header = worker0_cells_prefix.num_cells_in_row(0)
        var i = 0
        while i < ncols_header:
            var cr = worker0_cells_prefix.cell(0, i)
            var s = cell_to_string(
                worker0_prefix_slice[cr.start:cr.end],
                cr.needs_unescape,
                Q.DOUBLE_QUOTE_ESCAPES,
                options.quote,
                Q.ESCAPE_BYTE,
            )
            header_names.append(s^)
            i = i + 1
        data_start_offset_in_worker0 = 1
    else:
        var ncols_first = worker0_cells_prefix.num_cells_in_row(0)
        var i = 0
        while i < ncols_first:
            header_names.append(String("col_") + String(i))
            i = i + 1

    var num_cols = len(header_names)
    # HOSTILE-INPUT CEILING (holds with assertions compiled out). Same bound as
    # the single-thread reader, stated here too because this driver never
    # reaches that entry on the parallel path -- and it pays the rows x cols
    # allocation once PER WORKER (up to _MAX_WORKERS = 32).
    check_csv_column_count(num_cols)
    if num_cols == 0:
        # No columns inferable. Fallback.
        return read_csv_bytes_to_batch[Q, SCANNER_VARIANT_PHASE_3](bytes, options)

    # Infer types from worker 0's PREFIX data rows (post-header).
    # The prefix is bounded at _INFER_PREFIX_BYTES, so this is bounded
    # serial work regardless of file size or worker 0 slice size.
    # Cap at infer_rows to avoid over-inferring when the prefix
    # happens to be wider than needed.
    var data_rows_available = worker0_cells_prefix.num_rows() - data_start_offset_in_worker0
    var data_rows_to_use = data_rows_available
    if data_rows_to_use > infer_rows_target:
        data_rows_to_use = infer_rows_target
    var shared_col_types: List[ArrowType]
    if len(options.declared_column_types) > 0:
        # DECLARED-SCHEMA DECODE. Applied HERE, at the
        # ONE place the parallel reader resolves types, so every worker builds
        # its partition at the declared dtypes — the schema-directed property
        # `row_column_reroute` requires of a re-routable columnar decoder, and
        # the reason that module's CSV arm said NO.
        check_declared_column_types(
            options.declared_column_types,
            num_cols,
            String("read_csv_bytes_to_batch_parallel"),
        )
        shared_col_types = options.declared_column_types.copy()
    else:
        shared_col_types = infer_column_types(
            worker0_prefix_slice,
            worker0_cells_prefix,
            data_start_offset_in_worker0,
            data_rows_to_use,
            num_cols,
            options,
        )
    var _infer_us = (Int(perf_counter_ns() - _t_infer0) // 1000) if _timing else 0

    # =====================================================================
    # Step 3: Pre-size per-worker output buffer.
    # =====================================================================
    # Slot w receives worker w's RecordBatch. Worker 0's batch covers
    # rows AFTER the header; workers 1..k-1 cover all rows in their
    # slice (no header skip).
    #
    # `Slab[Optional[RecordBatch]]` (not `List[...]`) because RecordBatch
    # is Movable but NOT Copyable, and List[T] requires T: Copyable on
    # Mojo 1.0.0b1. Slab[T] requires only Movable + Deinitable
    # — the same shape as the engine's per-bucket morsel-result slabs.
    var worker_batches = Slab[Optional[RecordBatch]].create(k)
    var slot = 0
    while slot < k:
        worker_batches.append(Optional[RecordBatch](None))
        slot = slot + 1

    # Per-worker error string. Optional[String] is Copyable so List works.
    var worker_errors = List[Optional[String]]()
    var slot2 = 0
    while slot2 < k:
        worker_errors.append(Optional[String](None))
        slot2 = slot2 + 1

    # Per-worker timing accumulators (`stage_timing`). Pre-sized; per-worker writes are setitem on existing
    # slots. Same disjointness contract as `worker_batches` /
    # `worker_errors`. List[_PhaseTiming] requires _PhaseTiming: Copyable
    # which is satisfied by the all-Int POD layout above.
    var worker_timings = List[_PhaseTiming]()
    if _timing:
        var slot3 = 0
        while slot3 < k:
            worker_timings.append(_PhaseTiming())
            slot3 = slot3 + 1

    # =====================================================================
    # Step 4: Parallel scan + materialize.
    # =====================================================================
    # Dispatch the per-worker
    # scan+materialize through `LocalDispatcher.run_with_state` (no stdlib
    # `parallelize`). One task per worker `tid` in [0, k). The borrowed
    # read-only inputs are pinned to the driver stack via `in_o`; the
    # owned per-worker outputs (`worker_batches` / `worker_errors` /
    # `worker_timings`) are moved INTO the State and extracted via
    # `Optional.take()` after the drain barrier (hard-ban #11).
    #
    # DISPATCH-BOUNDARY:
    #   * Disjointness: worker `tid` writes ONLY `batches[tid]` /
    #     `errors[tid]` / `timings[tid]` (slot setitem; destroy-then-init
    #     on Optional). Reads of `los/his[tid]`, `types[*]`, `names[*]`,
    #     `options`, the bytes slice are read-only per worker.
    #   * Liveness: `bytes` and `options` are PARAMETERS of this fn, so they
    #     outlive every frame inside it and are borrowed. `los` / `his` /
    #     `header_names` / `shared_col_types` are LOCALS of this fn and are
    #     therefore MOVED INTO the State, not borrowed — see the
    #     `_CsvScanState` docstring for the use-after-free that taught us the
    #     difference. `run_with_state` is a synchronous wake-word barrier
    #     (every worker joins before it returns), so the State — and with it
    #     everything moved into it — outlives every task.
    #   * No-realloc: `batches` / `errors` / `timings` are pre-sized to k
    #     (above); per-worker writes are `__setitem__`, never `append`.
    #   * Encapsulation: the State's borrowed pointers carry the concrete
    #     `in_o` origin (NOT MutExternalOrigin); no raw pointer arithmetic
    #     crosses the public signature.
    # Anchor a single shared IMMUTABLE origin on the driver stack frame;
    # all borrowed inputs outlive the synchronous dispatch identically.
    # `in_o` MUST be immutable to match `_CsvScanState.in_o: ImmutOrigin`
    # AND the immutable `bytes_base` below — deriving it from `origin_of(los)`
    # (a mutable local) yields a MUTABLE origin, which the serial-fallback
    # `Span[UInt8, in_o]` over the immutable `bytes_base` rejects
    # (`.mut of left value is 'False' but right value is 'True'`). Anchor it
    # on the read-only input's immutable origin instead (same contract as the
    # avro driver's `bytes.get_immutable()`); no wildcard origins.
    var bytes_ro = bytes.as_imm()
    comptime in_o = origin_of(bytes_ro.origin)
    var bytes_base = bytes_ro.unsafe_ptr().unsafe_origin_cast[in_o]()
    # ⛔ `los` / `his` / `header_names` / `shared_col_types` ARE LOCALS OF THIS
    # FN AND MUST NOT BE BORROWED INTO THE STATE. They were, until
    # Via
    # `UnsafePointer(to=los).unsafe_mut_cast[False]().unsafe_origin_cast[in_o]()`
    # — and that cast is the defect: it throws away the `origin_of(los)` the
    # `UnsafePointer(to=)` had just produced and relabels the pointer with the
    # BYTES buffer's origin, which names a different object entirely. The
    # compiler was then free to run `los`'s destructor at this very line, and
    # did. They are moved into the State below instead.
    #
    # `options` is a read-only PARAM of this fn (not a local), so it genuinely
    # outlives the dispatch and borrowing it is sound; `in_o` is a truthful
    # label for it in the only sense that matters — the pointee outlives the
    # barrier.
    var options_p = UnsafePointer(to=options).unsafe_origin_cast[in_o]()

    comptime if has_dispatcher:
        # PERF-CRITICAL: dispatcher.run_with_state per-worker scan dispatch.
        # State OWNS the per-worker outputs
        # AND every driver-frame input; only the two caller-owned params
        # (`bytes`, `options`) are borrowed. No wildcard widening.
        var state = _CsvScanState[Q, in_o](
            bytes_base,
            n,
            options_p,
            _timing,
            los^,
            his^,
            header_names^,
            shared_col_types^,
            worker_batches^,
            worker_errors^,
            worker_timings^,
        )
        var task = _CsvScanTask[Q, in_o](Int32(0))
        var disp = dispatcher_ptr.value()
        # Clone the token for THIS dispatch; the original is reused for the
        # column-concat dispatch below (multi-phase driver pattern).
        _ = disp[].run_with_state[
            _CsvScanState[Q, in_o], _CsvScanTask[Q, in_o]
        ](state, task^, k, cancel_token.clone(), site_id=SITE_FORMAT_READ)
        # Reclaim the owned outputs from State (Optional.take, hard-ban #11).
        worker_batches = state.batches.take()
        worker_errors = state.errors.take()
        worker_timings = state.timings.take()
        # Reclaim the owned INPUTS too. `header_names` / `shared_col_types`
        # are consumed by the column-concat below, so this is not bookkeeping
        # — the take is what makes them available again after the barrier.
        # `los` / `his` are reclaimed for symmetry: a future post-barrier
        # reader of the ranges (the timing dump is one) must find them here
        # rather than reintroduce a borrow.
        los = state.los.take()
        his = state.his.take()
        header_names = state.names.take()
        shared_col_types = state.types.take()
        _ = state^
    else:
        # Serial fallback (no dispatcher): per-worker scan loop. Preserves
        # the exact per-worker semantics (worker 0 header-skip, error
        # capture, stage timing) of the parallel path. `cancel_token`
        # is carried forward to the column-concat call below.
        var w = 0
        while w < k:
            var lo = los[w]
            var hi = his[w]
            var slice = Span[UInt8, in_o](
                unsafe_ptr=bytes_base + lo, length=hi - lo
            )
            try:
                var t_scan0 = perf_counter_ns() if _timing else 0
                var cells_local = scan_csv_phase3_pclmulqdq_into_cells[Q](
                    slice, options.delimiter, options.quote
                )
                # ROW-BYTE CEILING (holds with assertions compiled out) -- see
                # the twin in the dispatcher-backed worker above.
                cells_local.enforce_max_row_bytes(options.max_row_bytes)
                var scan_us_local = (Int(perf_counter_ns() - t_scan0) // 1000) if _timing else 0
                if w == 0:
                    skip_leading_blank_lines(cells_local)
                var data_skip = 0
                if w == 0 and options.has_header:
                    data_skip = 1
                # RECORD SHAPE -- see the twin in the dispatcher-backed
                # worker above.
                check_csv_record_shape[Q](
                    bytes, lo, 0, cells_local, data_skip, header_names,
                    options.has_header, options.delimiter, options.quote,
                )
                var num_rows_local = cells_local.num_rows() - data_skip
                if num_rows_local <= 0:
                    if _timing:
                        var t = _PhaseTiming()
                        t.scan_us = scan_us_local
                        worker_timings[w] = t
                else:
                    var t_mat0 = perf_counter_ns() if _timing else 0
                    if _timing:
                        var t = _PhaseTiming()
                        t.scan_us = scan_us_local
                        var batch = _materialize_batch_with_schema_timed[Q](
                            slice,
                            cells_local,
                            data_skip,
                            header_names,
                            shared_col_types,
                            num_rows_local,
                            options,
                            t,
                        )
                        t.materialize_us = Int(perf_counter_ns() - t_mat0) // 1000
                        worker_timings[w] = t
                        worker_batches[w] = Optional[RecordBatch](batch^)
                    else:
                        var batch = _materialize_batch_with_schema[Q](
                            slice,
                            cells_local,
                            data_skip,
                            header_names,
                            shared_col_types,
                            num_rows_local,
                            options,
                        )
                        worker_batches[w] = Optional[RecordBatch](batch^)
            except e:
                worker_errors[w] = Optional[String](String(e))
            w = w + 1
    # Keepalive of the borrowed inputs across the dispatch.
    #
    # ⚠ THIS BLOCK IS WEAKER THAN IT LOOKS. `bytes_base` and `options_p` are
    # `UnsafePointer` — POD. `_ =` on a POD pointer keeps an ADDRESS alive,
    # never the pointee, so it cannot pin a driver-frame list across the
    # barrier; the driver-frame lists are MOVED INTO the State instead
    # (see `_CsvScanState`).
    # What keeps `bytes` and `options` alive here is not this block — it is
    # that both are parameters of this function.
    _ = bytes_base
    _ = options_p

    # =====================================================================
    # Step 5: Drain error slots; re-raise the first failure.
    # =====================================================================
    var e_idx = 0
    while e_idx < k:
        if worker_errors[e_idx]:
            var msg = worker_errors[e_idx].value().copy()
            raise Error(
                String("komira_csv.parallel_reader: worker ")
                + String(e_idx)
                + String(" failed: ")
                + msg
            )
        e_idx = e_idx + 1

    # =====================================================================
    # Step 6: Column-parallel N-way concat.
    # =====================================================================
    # A serial pair-wise concat fold is
    # the Amdahl bottleneck at high worker count -- workers complete in
    # (total_wall / N) but a serial concat costs ~O(N * per-col-bytes).
    # So the concat is column-parallel: spawn one worker per output
    # column, each runs its own per-column N-way merge in parallel.
    #
    # Uses the existing single-pass multi-way helpers from
    # `komira_arrow.streaming_concat`:
    #   * `_concat_string_columns_multi` for STRING/BINARY columns
    #   * `_concat_fixed_columns_multi` for fixed-width numeric columns
    #   * Pair-wise `_concat_columns` fallback for BOOL / DATE32 (the
    #     multi-way helpers do not handle these; per-column serial pair-
    #     wise fold via _concat_columns)
    var _t_concat0 = perf_counter_ns() if _timing else 0
    var out_batch = _concat_csv_batches_column_parallel[
        has_dispatcher=has_dispatcher, disp_o=disp_o
    ](
        worker_batches^,
        k,
        num_cols,
        header_names,
        shared_col_types,
        dispatcher_ptr,
        cancel_token^,
    )
    var _concat_us = (Int(perf_counter_ns() - _t_concat0) // 1000) if _timing else 0

    if _timing:
        _emit_phase4_timing_report(
            n,
            k,
            _partition_us,
            _infer_us,
            _concat_us,
            worker_timings,
            Int(perf_counter_ns() - _t_total0) // 1000,
        )

    return out_batch^


# =============================================================================
# Runtime QuoteStyle dispatcher for the parallel reader.
# =============================================================================
#
# Mirrors
# `reader.read_csv_bytes_to_batch_dynamic` but routes to the parallel
# reader. Used by `session_context._read_csv_eager` to switch to the
# parallel path on files large enough that the partition+concat
# overhead is amortized (currently ≥ `_PARALLEL_BYTES_THRESHOLD`).
# Below that threshold OR on `n_workers <= 1`, the parallel reader
# internally short-circuits to single-thread fallback.

# Threshold for SDK to choose parallel over serial reader. Distinct
# from the parallel reader's internal `_MIN_PARALLEL_BYTES` (1 MiB) —
# this is the SDK-level routing decision (we are more conservative at
# the SDK boundary since the call overhead is higher than a
# direct invocation). 4 MiB matches the per-Worker working-set size
# where the parallel scan+materialize fully pays back the partition
# and concat overhead on m2-mbp 10-core.
comptime _PARALLEL_SDK_BYTES_THRESHOLD: Int = 4 * 1024 * 1024  # 4 MiB


def read_csv_bytes_to_batch_parallel_dynamic(
    bytes: Span[UInt8, _],
    options: CsvReadOptions,
    n_workers: Int = 0,
    stage_timing: Bool = False,
) raises -> RecordBatch:
    """Runtime-dispatch wrapper over `read_csv_bytes_to_batch_parallel[Q]`.

    Selects the QuoteStyle via `options.quote_style_tag` (0=Rfc4180,
    1=Excel, 2=Posix) and forwards to the parallel reader. Falls back
    to single-thread internally for buffers smaller than
    `_MIN_PARALLEL_BYTES` or when `n_workers == 1`.

    """
    var tag = options.quote_style_tag
    if tag == QUOTE_STYLE_TAG_RFC4180:
        return read_csv_bytes_to_batch_parallel[Rfc4180](bytes, options, n_workers, stage_timing)
    if tag == QUOTE_STYLE_TAG_EXCEL:
        return read_csv_bytes_to_batch_parallel[Excel](bytes, options, n_workers, stage_timing)
    if tag == QUOTE_STYLE_TAG_POSIX:
        return read_csv_bytes_to_batch_parallel[Posix](bytes, options, n_workers, stage_timing)
    raise Error(
        "read_csv_bytes_to_batch_parallel_dynamic: unknown options.quote_style_tag "
        + String(tag)
        + " — expected 0 (Rfc4180), 1 (Excel), or 2 (Posix)."
    )


def read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher[
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    options: CsvReadOptions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    n_workers: Int = 0,
    stage_timing: Bool = False,
) raises -> RecordBatch:
    """Dispatcher-aware runtime-`Q`-dispatch wrapper over
    `read_csv_bytes_to_batch_parallel_with_dispatcher[Q, disp_o]`.

    the SDK entry
    (`ctx._read_csv_eager`) threads `ctx.dispatcher()` + `ctx.cancel_token()`
    through here so the per-worker scan + column-concat run on the runtime
    worker pool (no stdlib `parallelize`). Selects the QuoteStyle via
    `options.quote_style_tag` (0=Rfc4180 / 1=Excel / 2=Posix).
    """
    var tag = options.quote_style_tag
    if tag == QUOTE_STYLE_TAG_RFC4180:
        return read_csv_bytes_to_batch_parallel_with_dispatcher[
            Rfc4180, disp_o
        ](bytes, options, dispatcher_ptr, cancel_token^, n_workers, stage_timing)
    if tag == QUOTE_STYLE_TAG_EXCEL:
        return read_csv_bytes_to_batch_parallel_with_dispatcher[Excel, disp_o](
            bytes, options, dispatcher_ptr, cancel_token^, n_workers,
            stage_timing,
        )
    if tag == QUOTE_STYLE_TAG_POSIX:
        return read_csv_bytes_to_batch_parallel_with_dispatcher[Posix, disp_o](
            bytes, options, dispatcher_ptr, cancel_token^, n_workers,
            stage_timing,
        )
    raise Error(
        "read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher: unknown"
        " options.quote_style_tag "
        + String(tag)
        + " — expected 0 (Rfc4180), 1 (Excel), or 2 (Posix)."
    )


# =============================================================================
# Partition phase -- see `csv_chunk_split.compute_csv_quote_safe_row_ranges`
# =============================================================================
#
# There is exactly one splitter. A second, newline-snapped one would let a
# fix to one land without the other.
#
# =============================================================================
# Per-worker materialization helpers.
# =============================================================================
#
# These mirror the private helpers in reader.mojo but take an externally
# inferred `col_types` rather than re-inferring per-worker. Inference
# happens once on worker 0's prefix and is shared across all workers
# via the `types_ptr` capture.


def _materialize_batch_with_schema[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    header_names: List[String],
    col_types: List[ArrowType],
    num_rows: Int,
    options: CsvReadOptions,
) raises -> RecordBatch:
    """Materialize a per-worker RecordBatch using a caller-supplied
    schema (header_names + col_types).

    Mirrors `reader._build_column` cascade but applies a pre-resolved
    type per column instead of re-inferring. The output is a
    single-worker contribution to the final concat.
    """
    var num_cols = len(header_names)
    # CELL BUDGET (holds with assertions compiled out). `bytes` is THIS WORKER's
    # slice, so the budget is stated against the bytes that produced these
    # rows — which is also the tighter statement, since each of the up-to-32
    # workers pays the rows x cols allocation independently. ONE compare,
    # before the loop below makes the first `allocate(num_rows)`.
    check_csv_cell_budget(num_rows, num_cols, len(bytes))
    var rbb = RecordBatchBuilder()
    var sb = SchemaBuilder()

    var c = 0
    while c < num_cols:
        var dtype = col_types[c]
        sb.add_field(Field(header_names[c], dtype, True))
        var col = _build_column_typed[Q](
            bytes, cells, data_start, c, dtype, num_rows, options
        )
        rbb.add_column(col^)
        c = c + 1

    var schema = sb.build()
    return rbb.build(schema^)


def _materialize_batch_with_schema_timed[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    header_names: List[String],
    col_types: List[ArrowType],
    num_rows: Int,
    options: CsvReadOptions,
    mut timing: _PhaseTiming,
) raises -> RecordBatch:
    """Identical body to `_materialize_batch_with_schema` but accumulates
    per-dtype build wall (microseconds) into `timing`.

    timing
    variant; ONLY invoked from the timed path (`_timing=True` in
    `read_csv_bytes_to_batch_parallel`). The un-instrumented path uses
    `_materialize_batch_with_schema` unchanged.

    Per-dtype accumulator branches inline by ArrowType. The fall-through
    is captured under the matching `build_*_us` field; the (very rare)
    unsupported-dtype raise path takes whichever path the original would.
    """
    var num_cols = len(header_names)
    # CELL BUDGET (holds with assertions compiled out) — the timed twin of
    # `_materialize_batch_with_schema`. Same check, stated here because this
    # body is a copy, not a wrapper, and a guard on one copy is the exact shape
    # that made round 1 refutable.
    check_csv_cell_budget(num_rows, num_cols, len(bytes))
    var rbb = RecordBatchBuilder()
    var sb = SchemaBuilder()

    var c = 0
    while c < num_cols:
        var dtype = col_types[c]
        sb.add_field(Field(header_names[c], dtype, True))
        var t0 = perf_counter_ns()
        var col = _build_column_typed[Q](
            bytes, cells, data_start, c, dtype, num_rows, options
        )
        var elapsed_us = Int(perf_counter_ns() - t0) // 1000
        if dtype == ArrowType.INT64:
            timing.build_int64_us = timing.build_int64_us + elapsed_us
        elif dtype == ArrowType.FLOAT64:
            timing.build_float64_us = timing.build_float64_us + elapsed_us
        elif dtype == ArrowType.STRING:
            timing.build_string_us = timing.build_string_us + elapsed_us
        elif dtype == ArrowType.DATE32:
            timing.build_date32_us = timing.build_date32_us + elapsed_us
        elif dtype == ArrowType.BOOL:
            timing.build_bool_us = timing.build_bool_us + elapsed_us
        # Other dtypes fall through unattributed (raise was already taken
        # by _build_column_typed if unsupported).
        rbb.add_column(col^)
        c = c + 1

    var schema = sb.build()
    return rbb.build(schema^)


def _build_column_typed[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    dtype: ArrowType,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Per-DType column materializer (Phase 4 variant -- caller-supplied
    dtype, no inference).

    Identical body to `reader._build_column`; duplicated here to keep
    the parallel reader self-contained and avoid exposing the
    single-thread reader's private helpers to a new module.
    """
    if dtype == ArrowType.INT64:
        return _build_int64_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.FLOAT64:
        return _build_float64_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.DATE32:
        return _build_date32_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.BOOL:
        return _build_bool_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.STRING:
        return _build_string_column[Q](bytes, cells, data_start, col_idx, num_rows, options)
    raise Error(
        "komira_csv.parallel_reader: unsupported inferred ArrowType for column "
        + String(col_idx)
        + " (the parallel reader builds Int64/Float64/Date32/Bool/String;"
        + " other DTypes are not supported here)."
    )


def _build_int64_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build an Int64 column from per-worker rows.

    reshape:
    delegates the per-row inner loop to `build_int64_column_simd` in
    `int_column_simd.mojo`. The reshape moves three sources of per-cell
    overhead off the hot path:

      1. Drop the validity-bitmap RMW from `arr.set(r, val)` by switching
         from `allocate_nullable` to `allocate` + `data.set_typed[Int64]`;
         the bitmap is built once at the end iff any nulls are observed.
      2. Hoist `cells.row_starts[data_start + r]` to a per-row cursor;
         read `cell_starts[row_base + col_idx]` directly to skip the
         double indirection in `cells.cell_start(r, c)`.
      3. Skip `is_null_cell` on the SIMD fast path (a passing cell is
         all-numeric and cannot match any default null token).

    Inside the delegate:
      * SIMD fast path via `fast_parse_int64_simple` for cells passing
        the `cell_is_simple_numeric` applicability gate.
      * Deferred null bitmap construction (only built when null_positions
        is non-empty).

    See module header in `int_column_simd.mojo` for the per-cell cost
    breakdown that motivated the reshape.
    """
    return build_int64_column_simd(
        bytes, cells, data_start, col_idx, num_rows, options
    )


def _build_float64_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Float64 column from per-worker rows.

    delegates to
    `build_float64_column_simd` in `int_column_simd.mojo`. See sibling
    `_build_int64_column` for the per-cell overhead breakdown that
    motivated the reshape.
    """
    return build_float64_column_simd(
        bytes, cells, data_start, col_idx, num_rows, options
    )


def _build_date32_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Date32 column from per-worker rows.

    delegates to
    `build_date32_column_simd` in `int_column_simd.mojo`. See sibling
    `_build_int64_column` for the per-cell overhead breakdown that
    motivated the reshape.
    """
    return build_date32_column_simd(
        bytes, cells, data_start, col_idx, num_rows, options
    )


def _build_bool_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Bool column from per-worker rows.

    Bool parser is already cheap (string-table lookup); no SIMD path.
    Apply the null-deferral idiom for consistency.
    """
    var arr = BooleanArray.allocate_nullable(num_rows)
    var null_positions = List[Int]()
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            null_positions.append(r)
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            null_positions.append(r)
            r = r + 1
            continue
        var parsed = _try_parse_bool(cell, options)
        if parsed:
            arr.set(r, parsed.value())
        else:
            null_positions.append(r)
        r = r + 1
    var k = 0
    while k < len(null_positions):
        arr._set_null(null_positions[k])
        k = k + 1
    arr.null_count = len(null_positions)
    return Column.from_boolean(arr)


def _build_string_column[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a STRING column from per-worker rows.

    Uses the bulk-memcpy + deferred-null pattern in
    `string_column_simd.build_string_column_simd`: 2 passes (size + fill) with a single `memcpy` per cell.
    """
    var arr = build_string_column_simd(
        bytes,
        cells,
        data_start,
        col_idx,
        num_rows,
        options,
        options.quote,
        Q.DOUBLE_QUOTE_ESCAPES,
        Q.ESCAPE_BYTE,
    )
    return Column.from_string(arr)


# =============================================================================
# Helper.
# =============================================================================
# Column-parallel N-way concat of per-worker batches. Eliminates the serial
# pair-wise fold Amdahl bottleneck on the parallel reader's driver tail. Spawns one
# stdlib `parallelize` worker per output column; each worker runs its own
# multi-way merge for that column index using the canonical single-pass
# helpers from `komira_arrow.streaming_concat`. BOOL and DATE32
# columns (which the multi-way fast helpers do not handle) fall through to
# a per-column pair-wise `_concat_columns` fold inside the same worker --
# parallelism across columns still holds, only the *intra-column* path
# changes for those types.
#
# Why a CSV-local primitive instead of reusing the engine's
# `streaming_concat_parallel.concat_record_batches_column_parallel`?
# That primitive requires a `LocalDispatcher[NoopSink]` + `CancellationToken`
# borrow -- both live on the EngineContext substrate. The byte-level CSV
# read path is invoked BEFORE the engine pipeline exists (it's the
# FILE -> RecordBatch step that FEEDS the pipeline). Lifting that primitive
# would couple the read path to the engine dispatcher and reverse the
# existing module dependency direction. A synchronous fork-join is the
# right primitive for this scenario: no EngineContext threading required.
# =============================================================================


# =============================================================================
# — State + Segment for the
# column-parallel N-way concat dispatch (site 2).
# =============================================================================
#
# OWNS the input `batches` storage slab + the per-column outputs
# (`out_columns` / `col_errors`, wrapped in `Optional[T]`, extracted via
# `Optional.take()` post-drain per hard-ban #11) and BORROWS
# `shared_col_types` via a typed-origin pointer pinned to `in_o`. One task
# per column `c` in [0, num_cols). The staging pointer the streaming-concat
# helpers consume is derived INSIDE `execute` from the State-owned slab
# (`get_mut_interior(0)`) — the storage lives in the borrowed State, not on
# a caller stack frame, so it outlives the synchronous drain.


struct _CsvConcatState[in_o: ImmOrigin](KeepAlive, Movable):
    """State for column-parallel CSV concat (`site 2`).

    OWNS `batches` (the input Slab[Optional[RecordBatch]] storage the
    column workers read in place), `out_columns` (Slab[Column[HeapRegion]])
    and `col_errors` (List[Optional[String]]) — the latter two as
    `Optional[T]` extracted via `Optional.take()` after the drain. BORROWS
    `shared_col_types` via a `in_o`-pinned pointer. No MutExternalOrigin.
    """
    # OWNED input storage — workers read the c-th column of each slot in
    # place; the staging pointer is derived from THIS slab inside execute.
    var batches: Optional[Slab[Optional[RecordBatch]]]
    # OWNED per-column outputs.
    var out_columns: Optional[Slab[Column[HeapRegion]]]
    var col_errors: Optional[List[Optional[String]]]
    # Borrowed read-only column types — pinned to caller via `in_o`.
    # SAFETY: Internal typed pointer — never exposed to public API.
    var types_ptr: UnsafePointer[List[ArrowType], Self.in_o]
    var k: Int

    def __init__(
        out self,
        var batches: Slab[Optional[RecordBatch]],
        var out_columns: Slab[Column[HeapRegion]],
        var col_errors: List[Optional[String]],
        types_ptr: UnsafePointer[List[ArrowType], Self.in_o],
        k: Int,
    ):
        self.batches = Optional[Slab[Optional[RecordBatch]]](batches^)
        self.out_columns = Optional[Slab[Column[HeapRegion]]](out_columns^)
        self.col_errors = Optional[List[Optional[String]]](col_errors^)
        self.types_ptr = types_ptr
        self.k = k


@fieldwise_init
struct _CsvConcatTask[in_o: ImmOrigin](Segment):
    """POD Segment for `_CsvConcatState` dispatch — one task per column."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_CsvConcatState[in_o], _CsvConcatTask[in_o]); the bitcast
        # resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _CsvConcatState[Self.in_o]
        ]()
        var c = Int(task_id)
        var k_local = sp[].k
        # Derive the staging pointer from the State-owned slab. The
        # streaming-concat helpers consume an `UnsafePointer[Optional[
        # RecordBatch], mut_o]`; column workers READ the c-th column of
        # every slot in place (the per-column variant does NOT .take()).
        # Disjoint c values touch disjoint Column slots → no alias.
        ref slot0 = sp[].batches.value().get_mut_interior(0)
        var staging_ptr = UnsafePointer(to=slot0)
        try:
            var at = sp[].types_ptr[][c]
            var concatted: Column[HeapRegion]
            if at == ArrowType.STRING or at == ArrowType.BINARY:
                concatted = _concat_string_columns_multi(
                    staging_ptr, k_local, c
                )
            elif _arrow_type_has_fixed_width_concat(at):
                concatted = _concat_fixed_columns_multi(
                    staging_ptr, k_local, c, at
                )
            else:
                # BOOL / DATE32 / other -- per-column pair-wise fold.
                concatted = _concat_one_column_pairwise(
                    staging_ptr, k_local, c
                )
            sp[].out_columns.value()[c] = concatted^
        except e:
            sp[].col_errors.value()[c] = Optional[String](String(e))


def _concat_csv_batches_column_parallel[
    has_dispatcher: Bool,
    disp_o: Origin[mut=True],
](
    var worker_batches: Slab[Optional[RecordBatch]],
    k: Int,
    num_cols: Int,
    header_names: List[String],
    shared_col_types: List[ArrowType],
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Column[HeapRegion]-parallel N-way concat of per-worker batches.

    Each of `num_cols` columns is concatenated independently by a separate
    `parallelize` worker. STRING/BINARY columns use
    `_concat_string_columns_multi`; fixed-width numeric columns use
    `_concat_fixed_columns_multi`; BOOL and DATE32 columns fall back to
    per-column pair-wise `_concat_columns` fold (still parallel across
    columns -- only the intra-column algorithm differs for those types).

    Args:
        worker_batches: Slab of per-worker Optional[RecordBatch] outputs
            (consumed). Each non-None slot is a per-worker contribution
            to the final concat; None slots are skipped.
        k: Number of worker slots (== len(worker_batches)).
        num_cols: Number of output columns.
        header_names: Output column names.
        shared_col_types: Output column types (per-column ArrowType from
            the shared schema inferred on worker 0).

    Returns:
        Single concatenated RecordBatch with one row per input row across
        all worker batches, columns in shared_col_types order.

    Note:
        On all-empty input (every worker returned None), emits an empty
        batch stamped with the inferred schema -- mirrors the single-thread
        empty-row path.
    """
    # Drain the input slab into a contiguous storage Slab[Optional[
    # RecordBatch]] over which we hand a stable byte pointer to each
    # column-parallel worker. The streaming_concat helpers consume an
    # `UnsafePointer[Optional[RecordBatch], o]` pointing at slot 0 and
    # walk by index; we need that pointer to remain valid across the
    # `parallelize[]` call. Move ownership in here so the storage Slab
    # outlives the parallel dispatch.
    var batches = worker_batches^

    # Fast paths.
    if num_cols == 0 or k == 0:
        var sb_empty = SchemaBuilder()
        var f_idx = 0
        while f_idx < num_cols:
            sb_empty.add_field(
                Field(header_names[f_idx], shared_col_types[f_idx], True)
            )
            f_idx = f_idx + 1
        var rbb_empty = RecordBatchBuilder()
        _ = batches^
        return rbb_empty.build(sb_empty.build())

    # Pre-fill output Slab[Column] with empty placeholders. Workers
    # __setitem__ their disjoint slot -- no growth across the dispatch.
    var out_columns = Slab[Column[HeapRegion]].create(num_cols)
    var _c = 0
    while _c < num_cols:
        out_columns.append(Column[HeapRegion]())
        _c = _c + 1

    # Per-column error channel. Optional[String] is Copyable so List works.
    var col_errors = List[Optional[String]]()
    var _ce = 0
    while _ce < num_cols:
        col_errors.append(Optional[String](None))
        _ce = _ce + 1

    # =====================================================================
    # Dispatch the per-column
    # concat through `LocalDispatcher.run_with_state` (no stdlib
    # `parallelize`). One task per column `c` in [0, num_cols). The State
    # OWNS the input `batches` storage slab + `out_columns` / `col_errors`;
    # the staging pointer is derived from the State-owned slab inside
    # `execute`. `shared_col_types` is borrowed via `in_o`.
    #
    # DISPATCH-BOUNDARY:
    #   * Disjointness: worker `c` reads `staging[i].column_at(c)` for all
    #     i in [0, k) (the c-th column of every input batch) and writes
    #     ONLY `out_columns[c]` (Slab __setitem__; pre-sized). Distinct c
    #     touch disjoint Column slots on input AND output.
    #   * Liveness: the input storage slab + outputs live inside the
    #     borrowed State; `shared_col_types` lives on this fn's stack
    #     across the synchronous `run_with_state` drain barrier.
    #   * No-realloc: `out_columns` / `col_errors` pre-sized to num_cols;
    #     per-worker writes are `__setitem__`, never `append`.
    #   * Encapsulation: no raw pointer crosses the public signature; the
    #     staging pointer is module-internal, derived from a Slab interior.
    comptime in_o = origin_of(shared_col_types)
    var types_p = UnsafePointer(to=shared_col_types).unsafe_mut_cast[
        False
    ]().unsafe_origin_cast[in_o]()

    comptime if has_dispatcher:
        # PERF-CRITICAL: dispatcher.run_with_state per-column concat
        # dispatch. State OWNS the input
        # storage + outputs; `shared_col_types` borrowed via `in_o`.
        var state = _CsvConcatState[in_o](
            batches^,
            out_columns^,
            col_errors^,
            types_p,
            k,
        )
        var task = _CsvConcatTask[in_o](Int32(0))
        var disp = dispatcher_ptr.value()
        _ = disp[].run_with_state[
            _CsvConcatState[in_o], _CsvConcatTask[in_o]
        ](state, task^, num_cols, cancel_token^, site_id=SITE_FORMAT_READ)
        # Reclaim owned storage + outputs (Optional.take, hard-ban #11).
        batches = state.batches.take()
        out_columns = state.out_columns.take()
        col_errors = state.col_errors.take()
        _ = state^
    else:
        # Serial fallback (no dispatcher): per-column concat loop.
        _ = cancel_token^
        ref slot0 = batches.get_mut_interior(0)
        var staging_ptr = UnsafePointer(to=slot0)
        var c = 0
        while c < num_cols:
            try:
                var at = shared_col_types[c]
                var concatted: Column[HeapRegion]
                if at == ArrowType.STRING or at == ArrowType.BINARY:
                    concatted = _concat_string_columns_multi(staging_ptr, k, c)
                elif _arrow_type_has_fixed_width_concat(at):
                    concatted = _concat_fixed_columns_multi(
                        staging_ptr, k, c, at
                    )
                else:
                    concatted = _concat_one_column_pairwise(staging_ptr, k, c)
                out_columns[c] = concatted^
            except e:
                col_errors[c] = Optional[String](String(e))
            c = c + 1
    _ = types_p

    # Drain error slots; re-raise the first failure.
    var ce_idx = 0
    while ce_idx < num_cols:
        if col_errors[ce_idx]:
            var msg = col_errors[ce_idx].value().copy()
            raise Error(
                String("komira_csv.parallel_reader: column-parallel concat ")
                + String("column ")
                + String(ce_idx)
                + String(" failed: ")
                + msg
            )
        ce_idx = ce_idx + 1

    # Drain any still-populated input slots (the per-column helpers do
    # not call .take(); they read in place). Letting `batches` drop at
    # scope exit handles this naturally via Slab's destructor.
    _ = batches^

    # Detect all-empty (no contribution rows from any worker): every
    # output column would have length 0. Mirror the all-empty path.
    var any_nonempty = False
    var probe = 0
    while probe < num_cols:
        if out_columns[probe]._length > 0:
            any_nonempty = True
            break
        probe = probe + 1

    if not any_nonempty:
        # Build empty schema-stamped batch.
        var sb_e = SchemaBuilder()
        var f_i = 0
        while f_i < num_cols:
            sb_e.add_field(
                Field(header_names[f_i], shared_col_types[f_i], True)
            )
            f_i = f_i + 1
        _ = out_columns^
        var rbb_e = RecordBatchBuilder()
        return rbb_e.build(sb_e.build())

    # Assemble the output RecordBatch. Schema from header_names +
    # shared_col_types so the result matches the inferred schema even
    # if a column's per-batch metadata varied (it should not, but this
    # is the authoritative source).
    var sb = SchemaBuilder()
    var f_idx = 0
    while f_idx < num_cols:
        sb.add_field(
            Field(header_names[f_idx], shared_col_types[f_idx], True)
        )
        f_idx = f_idx + 1

    var rbb = RecordBatchBuilder.with_capacity(num_cols)
    var i = 0
    while i < num_cols:
        var col = out_columns.replace(i, Column[HeapRegion]())
        rbb.add_column(col^)
        i = i + 1
    _ = out_columns^
    return rbb.build(sb.build())


def _arrow_type_has_fixed_width_concat(at: ArrowType) -> Bool:
    """Whether `_concat_fixed_columns_multi` can handle this ArrowType.

    The streaming_concat helper's `_arrow_type_byte_width` returns
    non-zero only for the 8 base numeric DTypes (INT8/16/32/64,
    UINT8/16/32/64, FLOAT16/32/64). CSV-emitted columns are currently
    one of {INT64, FLOAT64, DATE32, BOOL, STRING} — so this routes
    INT64 + FLOAT64 to the fast multi-way path and BOOL + DATE32 to
    the pair-wise fallback.

    Mirrors `_arrow_type_byte_width` in the core packages' streaming_concat (which
    is the authoritative source). Listing all base numeric types here
    instead of importing `_arrow_type_byte_width` keeps the dispatch
    decision colocated with the cascade.
    """
    if at == ArrowType.INT8 or at == ArrowType.UINT8:
        return True
    if (
        at == ArrowType.INT16
        or at == ArrowType.UINT16
        or at == ArrowType.FLOAT16
    ):
        return True
    if (
        at == ArrowType.INT32
        or at == ArrowType.UINT32
        or at == ArrowType.FLOAT32
    ):
        return True
    if (
        at == ArrowType.INT64
        or at == ArrowType.UINT64
        or at == ArrowType.FLOAT64
    ):
        return True
    return False


def _concat_one_column_pairwise[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col_idx: Int,
) raises -> Column[HeapRegion]:
    """Per-column pair-wise fold via `_concat_columns`.

    Used for BOOL / DATE32 columns that the streaming_concat fast
    multi-way helpers do not handle. Still runs in parallel ACROSS
    columns (each column-worker calls this for its one column);
    only the intra-column algorithm is the legacy pair-wise path.

    Pair-wise fold over the `col_idx`-th column of each non-None
    input batch. Each call to `_concat_columns(a, b)` produces a
    new Column; the running accumulator is replaced at each step.

    Args:
        rg_batches: Pointer to slot 0 of the input slab.
        num_rgs:    Number of slots in the input slab.
        col_idx:    Column index within each batch.

    Returns:
        Concatenated Column for `col_idx` across all non-None batches.
        Empty Column if all batches are None or have zero rows.
    """
    # SAFETY (internal): `rg_batches` carries a
    # CONCRETE origin `o` (not a wildcard) tracking the borrowed input slab,
    # which the caller keeps live across this whole concat. `o` is mut so the
    # in-place pairwise fold may read each slot's Optional[RecordBatch]; we
    # only index within [0, num_rgs) and never retain a raw pointer past the
    # loop. The pointer does not cross a public boundary (file-private helper).
    var result_opt = Optional[Column[HeapRegion]](None)
    var i = 0
    while i < num_rgs:
        if (rg_batches + i)[]:
            ref col_ref = (rg_batches + i)[].value().column_at(col_idx)
            if result_opt:
                ref prev = result_opt.value()
                var merged = _concat_columns(prev, col_ref)
                result_opt = Optional[Column[HeapRegion]](merged^)
            else:
                # First batch: deep-copy the column (Column is Movable
                # not Copyable, so we cannot move from the borrowed ref).
                # deep_copy clones every buffer + recursively any children.
                var dc = col_ref.deep_copy()
                result_opt = Optional[Column[HeapRegion]](dc^)
        i = i + 1
    if result_opt:
        return result_opt.take()
    return Column[HeapRegion]()
