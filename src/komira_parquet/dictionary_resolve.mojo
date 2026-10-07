# =============================================================================
# Dictionary resolve kernels — the gathers behind DictionaryDecoder.resolve_*
# =============================================================================
#
# `DictionaryDecoder` (dictionary.mojo) holds the decoded dictionary page; its
# `resolve_*` methods check that a dictionary of the right type is loaded,
# try the blocked, bounds-fused arm (dict_gather_fused.mojo) and otherwise
# call the legacy gathers here, with the dictionary values passed in. Every
# gather first proves the code stream in range (`_validate_dict_indices`).
#
# SAFETY: the gathers read the code and dictionary arrays through pointers
# taken from origin-tied `view_ro()` borrows held live across each loop, and
# write through a `view_mut()` of the output buffer they allocate. No
# signature here names a pointer.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of, simd_width_of
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.binary_array import BinaryArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from .plain_flba import _flba_value_to_int64_be, _simd_bswap_u64


# Prefetch distance for dict-resolve loops, sized for L2 miss latency
# (values from 8 to 32 perform about the same). Issue prefetch on the
# dict_values byte at idx[i + _DICT_PF] so by the time the load actually
# happens, the line is in L1.
comptime _DICT_PF_INT64: Int = 16

# Float64 has the same 8-byte gather shape
# as int64 — same prefetch distance applies (same L2 miss latency, same
# OOO-issue throughput).
comptime _DICT_PF_FLOAT64: Int = 16

# Int32 has a half-width gather (4 bytes per
# load) — a single 64-byte cache line covers 16 dict entries vs 8 for
# int64. Doubling the prefetch distance keeps the prefetch-ahead working
# set roughly cache-line-balanced.
comptime _DICT_PF_INT32: Int = 32


# =============================================================================
# ROBUSTNESS: the dictionary-index range gate
# =============================================================================
#
# THE HAZARD. Every `resolve_*` below gathers with a raw
# `dict_typed_ptr.load[width=1](idx)` (and `dict_data_ptr + idx *
# type_length` for the FLBA/decimal arms). That a code lies in the dictionary
# is a claim made BY THE FILE BEING PARSED, which is exactly what an
# adversarial input violates. A dictionary code is a full Int32, so an
# unchecked read reaches gigabytes past the dictionary allocation at a
# granularity the attacker picks. The FLBA arm is worse than a crash: both
# `idx` (page data) and `type_length` (footer schema) are attacker-chosen, so
# `memcpy(dst, dict + idx * type_length, type_length)` would copy arbitrary
# process memory into an output column the query can then SELECT, an
# information-disclosure primitive. The scalar tails are no safer: they go
# through `PrimitiveArray.get_typed`, which does not check the upper bound.
#
# WHY THIS SHAPE. A per-lookup `if 0 <= idx and idx < dict_size` would put a
# branch inside the gather fan-out that lowers to native hardware gathers,
# i.e. onto the hot path. So the check is hoisted OUT of the gather into ONE
# branchless min/max reduction over the code stream, run once before the
# loop: one W-wide compare pair per W codes against a stream already resident
# in cache, and a gather loop that is unchanged. A stream proven in range
# needs no re-checking per lookup, which is the point of validating at a
# boundary.
@always_inline
def _validate_dict_indices(
    indices: PrimitiveArray[DType.int32],
    dict_len: Int,
    what: String,
) raises:
    """Raise unless every code in `indices` lies in [0, dict_len).

    Args:
        indices: Decoded RLE_DICTIONARY codes for one column chunk.
        dict_len: Number of entries ACTUALLY loaded into the dictionary
            (the array's own length — not the page-declared `dict_size`,
            which is itself attacker-supplied).
        what: Resolver name, for the error message.

    Raises:
        Error naming the offending bound and the dictionary extent.
    """
    var n = indices.length
    if n <= 0:
        return
    if dict_len <= 0:
        raise Error(
            "parquet: corrupt dictionary page: "
            + what
            + " has "
            + String(n)
            + " codes to resolve but the dictionary holds no entries"
        )

    var idx_view = indices.view_ro()
    var p = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    comptime W: Int = simd_width_of[DType.int32]()
    var min_code = p.load[width=1](0)
    var max_code = min_code
    var i = 1
    var simd_end = (n // W) * W
    if simd_end > 0:
        var first = p.load[width=W](0)
        var min_acc = first
        var max_acc = first
        i = W
        while i < simd_end:
            var chunk = p.load[width=W](i)
            min_acc = (min_acc.lt(chunk)).select(min_acc, chunk)
            max_acc = (max_acc.gt(chunk)).select(max_acc, chunk)
            i += W
        min_code = min_acc.reduce_min()
        max_code = max_acc.reduce_max()
    while i < n:
        var v = p.load[width=1](i)
        if v < min_code:
            min_code = v
        if v > max_code:
            max_code = v
        i += 1
    _ = idx_view

    if Int(min_code) < 0 or Int(max_code) >= dict_len:
        raise Error(
            "parquet: corrupt dictionary-encoded page: "
            + what
            + " saw dictionary codes in ["
            + String(Int(min_code))
            + ", "
            + String(Int(max_code))
            + "] but the loaded dictionary holds only "
            + String(dict_len)
            + " entries"
        )


struct _Gathers:
    """The gathers behind `DictionaryDecoder.resolve_*`, as static methods:
    methods of a struct, as they were of `DictionaryDecoder`, so the bodies
    keep the indentation they had there; the dictionary they gather from is
    an argument instead of a field of `self`."""

    @staticmethod
    def resolve_int32_legacy(
        indices: PrimitiveArray[DType.int32],
        dict_values: PrimitiveArray[DType.int32],
    ) raises -> PrimitiveArray[DType.int32]:
        """The legacy arm of `DictionaryDecoder.resolve_int32`: validate the whole
        code stream, then gather."""
        # The dict and idx pointers come from origin-tied `view_ro() +
        # _unsafe_ptr().bitcast[Scalar[Int32]]()`. The `_view` locals are held in
        # scope for the entire SIMD+scalar-tail loop body so the
        # ByteView borrow keeps the underlying PrimitiveArray.data
        # alive.
        # ROBUSTNESS GATE: one
        # branchless min/max pass over the code stream before the
        # gather loop below. See `_validate_dict_indices`.
        _validate_dict_indices(
            indices, dict_values.length, "resolve_int32"
        )
        var num_values = indices.length

        comptime int32_size = size_of[Scalar[DType.int32]]()
        var buf = OwnedAlignedBuffer(num_values * int32_size)
        buf.set_length(Int64(num_values * int32_size))

        # out_ptr via origin-tied `view_mut` on the buffer.
        var buf_view = buf.view_mut()
        var out_ptr = buf_view._unsafe_ptr().bitcast[Int32]()

        # PERF-CRITICAL: cross-row SIMD gather
        # fast-path. comptime W = simd_width_of gives 4 on NEON, 8 on
        # AVX2, 16 on AVX-512. Gate W >= 4 as in rle.mojo (a 2-lane
        # fan-out was slower than scalar on arm64). An L1 prefetch inside
        # the loop fetches dict_values _DICT_PF_INT32 rows ahead to hide L2
        # miss latency on the random-access gather.
        var idx_view = indices.view_ro()
        var idx_typed_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var dict_view = dict_values.view_ro()
        var dict_typed_ptr = dict_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        comptime W: Int = simd_width_of[DType.int32]()
        var i = 0

        comptime if W >= 4:
            var simd_end = (num_values // W) * W
            while i < simd_end:
                # Prefetch dict_values for the row _DICT_PF_INT32 ahead.
                if i + _DICT_PF_INT32 < num_values:
                    var pf_idx = Int(idx_typed_ptr.load[width=1](i + _DICT_PF_INT32))
                    # SAFETY: prefetch is a hint; OOB addresses silently ignored.
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (dict_typed_ptr + pf_idx).bitcast[Scalar[DType.int32]]()
                    )
                var lanes = SIMD[DType.int32, W](0)

                comptime for k in range(W):
                    var idx_k = Int(idx_typed_ptr.load[width=1](i + k))
                    # SAFETY: idx in [0, dict_len) — ENFORCED by the
                    # `_validate_dict_indices` pass at the top of this
                    # function, not assumed from the file being parsed.
                    lanes[k] = dict_typed_ptr.load[width=1](idx_k)
                out_ptr.store[width=W](i, lanes)
                i += W

        # Scalar tail (also serves the W < 4 case via comptime DCE).
        while i < num_values:
            var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
            (out_ptr + i)[] = dict_values.get_typed[Scalar[DType.int32]](idx)
            i += 1

        return PrimitiveArray[DType.int32](buf^, num_values, None, 0, 0)

    @staticmethod
    def resolve_int64_legacy(
        indices: PrimitiveArray[DType.int32],
        dict_values: PrimitiveArray[DType.int64],
    ) raises -> PrimitiveArray[DType.int64]:
        """The legacy arm of `DictionaryDecoder.resolve_int64`: validate the whole
        code stream, then gather."""
        # Same view_ro + bitcast pattern as resolve_int32, with _view locals
        # held in scope for the loop body.
        # ROBUSTNESS GATE: one
        # branchless min/max pass over the code stream before the
        # gather loop below. See `_validate_dict_indices`.
        _validate_dict_indices(
            indices, dict_values.length, "resolve_int64"
        )
        var num_values = indices.length

        comptime int64_size = size_of[Scalar[DType.int64]]()
        var buf = OwnedAlignedBuffer(num_values * int64_size)
        buf.set_length(Int64(num_values * int64_size))

        # out_ptr via origin-tied `view_mut` on the buffer.
        var buf_view = buf.view_mut()
        var out_ptr = buf_view._unsafe_ptr().bitcast[Int64]()

        # PERF-CRITICAL: cross-row SIMD gather
        # fast-path. comptime W = simd_width_of[Int64] gives 2 on NEON,
        # 4 on AVX2, **8 on AVX-512**. A fixed W=4 unroll would limit
        # codegen to `vpgatherdq ymm` (4-lane AVX2) on AVX-512 hosts; the
        # `comptime W` fan-out lets LLVM emit `vpgatherqq zmm` (8-lane
        # gather) when simd_width_of==8. The L1 prefetch
        # `_DICT_PF_INT64` rows ahead hides L2 miss latency on the
        # random-access gather.
        var idx_view = indices.view_ro()
        var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var dict_view = dict_values.view_ro()
        var dict_ptr = dict_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        comptime W: Int = simd_width_of[DType.int64]()
        var i = 0

        # Gate W>=2, not W>=4. On arm64
        # simd_width_of[int64]()=2, so W>=4 would make this comptime-FALSE
        # and the entire SIMD gather body + _DICT_PF_INT64 prefetch would be
        # dead-code-eliminated -> resolve_int64 would run fully scalar (serial
        # dep chain, no prefetch). The dict GATHER is memory-latency-
        # bound (random dict access), NOT throughput-bound like rle.mojo's
        # _unpack_generic_simd (whose 2-lane slowdown motivated the W>=4
        # gate there) — so even W=2 wins here: 2 independent loads issue in
        # parallel on the OOO core (halves the dep-chain) AND the prefetch
        # runs. x86 W=4(AVX2)/W=8(AVX-512) paths are the same (still >=2).
        comptime if W >= 2:
            var simd_end = (num_values // W) * W
            while i < simd_end:
                # Prefetch dict_values for the row _DICT_PF_INT64 ahead.
                if i + _DICT_PF_INT64 < num_values:
                    var pf_idx = Int((idx_ptr + i + _DICT_PF_INT64)[])
                    # SAFETY: prefetch is a hint; OOB addresses silently ignored.
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (dict_ptr + pf_idx).bitcast[Scalar[DType.int64]]()
                    )
                var lanes = SIMD[DType.int64, W](0)

                comptime for k in range(W):
                    var idx_k = Int((idx_ptr + i + k)[])
                    # SAFETY: idx in [0, dict_len) — ENFORCED by the
                    # `_validate_dict_indices` pass at the top of this
                    # function, not assumed from the file being parsed.
                    lanes[k] = (dict_ptr + idx_k)[]
                out_ptr.store[width=W](i, lanes)
                i += W

        # Scalar tail (also serves the W < 4 case via comptime DCE).
        while i < num_values:
            var idx = Int((idx_ptr + i)[])
            (out_ptr + i)[] = (dict_ptr + idx)[]
            i += 1

        # The `idx_view` / `dict_view` ByteView locals hold the borrow
        # through this scope, which is compile-time tracked.

        return PrimitiveArray[DType.int64](buf^, num_values, None, 0, 0)

    @staticmethod
    def resolve_float32_legacy(
        indices: PrimitiveArray[DType.int32],
        dict_values: PrimitiveArray[DType.float32],
    ) raises -> PrimitiveArray[DType.float32]:
        """The legacy arm of `DictionaryDecoder.resolve_float32`: validate the whole
        code stream, then gather."""
        # Same view_ro + bitcast pattern as resolve_int32, with _view locals
        # held in scope for the loop body.
        # ROBUSTNESS GATE: one
        # branchless min/max pass over the code stream before the
        # gather loop below. See `_validate_dict_indices`.
        _validate_dict_indices(
            indices, dict_values.length, "resolve_float32"
        )
        var num_values = indices.length

        comptime f32_size = size_of[Scalar[DType.float32]]()
        var buf = OwnedAlignedBuffer(num_values * f32_size)
        buf.set_length(Int64(num_values * f32_size))

        # out_ptr via origin-tied `view_mut` on the buffer.
        var buf_view = buf.view_mut()
        var out_ptr = buf_view._unsafe_ptr().bitcast[Float32]()

        # PERF-CRITICAL: see resolve_int32 above. W =
        # simd_width_of[Float32] is 4 on NEON / 8 on AVX2 / 16 on
        # AVX-512; gate condition is always satisfied (W>=4). On AVX-512
        # this lowers to `vgatherdps zmm{k1}` (16-lane gather).
        var idx_view = indices.view_ro()
        var idx_typed_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var dict_view = dict_values.view_ro()
        var dict_typed_ptr = dict_view._unsafe_ptr().bitcast[Scalar[DType.float32]]()
        comptime W: Int = simd_width_of[DType.float32]()
        var i = 0

        comptime if W >= 4:
            var simd_end = (num_values // W) * W
            while i < simd_end:
                var lanes = SIMD[DType.float32, W](0)

                comptime for k in range(W):
                    var idx_k = Int(idx_typed_ptr.load[width=1](i + k))
                    # SAFETY: idx in [0, dict_size).
                    lanes[k] = dict_typed_ptr.load[width=1](idx_k)
                out_ptr.store[width=W](i, lanes)
                i += W

        while i < num_values:
            var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
            (out_ptr + i)[] = dict_values.get_typed[Scalar[DType.float32]](idx)
            i += 1

        return PrimitiveArray[DType.float32](buf^, num_values, None, 0, 0)

    @staticmethod
    def resolve_float64_legacy(
        indices: PrimitiveArray[DType.int32],
        dict_values: PrimitiveArray[DType.float64],
    ) raises -> PrimitiveArray[DType.float64]:
        """The legacy arm of `DictionaryDecoder.resolve_float64`: validate the whole
        code stream, then gather."""
        # Same view_ro + bitcast pattern as resolve_int32, with _view locals
        # held in scope for the loop body.
        # ROBUSTNESS GATE: one
        # branchless min/max pass over the code stream before the
        # gather loop below. See `_validate_dict_indices`.
        _validate_dict_indices(
            indices, dict_values.length, "resolve_float64"
        )
        var num_values = indices.length

        comptime f64_size = size_of[Scalar[DType.float64]]()
        var buf = OwnedAlignedBuffer(num_values * f64_size)
        buf.set_length(Int64(num_values * f64_size))

        # out_ptr via origin-tied `view_mut` on the buffer.
        var buf_view = buf.view_mut()
        var out_ptr = buf_view._unsafe_ptr().bitcast[Float64]()

        # PERF-CRITICAL: cross-row SIMD
        # gather fast-path. comptime W = simd_width_of[Float64] gives 2
        # on NEON, 4 on AVX2, **8 on AVX-512**; the `comptime W` fan-out
        # lets LLVM emit `vgatherqpd zmm` (8-lane gather) when
        # simd_width_of==8. The
        # L1 prefetch `_DICT_PF_FLOAT64` rows ahead hides L2 miss
        # latency on the random-access gather.
        var idx_view = indices.view_ro()
        var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var dict_view = dict_values.view_ro()
        var dict_ptr = dict_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
        comptime W: Int = simd_width_of[DType.float64]()
        var i = 0

        # Gate W>=2, not W>=4, for the same arm64 reason as resolve_int64
        # above (simd_width_of[float64]()=2, so W>=4 would be comptime-FALSE
        # and the SIMD gather + _DICT_PF_FLOAT64 prefetch would be
        # eliminated). The gather is latency-bound; W=2 hides it. See
        # resolve_int64.
        comptime if W >= 2:
            var simd_end = (num_values // W) * W
            while i < simd_end:
                if i + _DICT_PF_FLOAT64 < num_values:
                    var pf_idx = Int((idx_ptr + i + _DICT_PF_FLOAT64)[])
                    # SAFETY: prefetch is a hint; OOB addresses silently ignored.
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (dict_ptr + pf_idx).bitcast[Scalar[DType.float64]]()
                    )
                var lanes = SIMD[DType.float64, W](0)

                comptime for k in range(W):
                    var idx_k = Int((idx_ptr + i + k)[])
                    # SAFETY: idx in [0, dict_len) — ENFORCED by the
                    # `_validate_dict_indices` pass at the top of this
                    # function, not assumed from the file being parsed.
                    lanes[k] = (dict_ptr + idx_k)[]
                out_ptr.store[width=W](i, lanes)
                i += W

        # Scalar tail (also serves the W < 4 case via comptime DCE).
        while i < num_values:
            var idx = Int((idx_ptr + i)[])
            (out_ptr + i)[] = (dict_ptr + idx)[]
            i += 1

        # The `idx_view` / `dict_view` ByteView locals hold the borrow
        # through this scope, which is compile-time tracked.

        return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)

    @staticmethod
    def resolve_flba_as_binary(
        indices: PrimitiveArray[DType.int32],
        dict_flba: BinaryArray[HeapRegion],
        type_length: Int,
    ) raises -> BinaryArray[HeapRegion]:
        """The body of `DictionaryDecoder.resolve_flba_as_binary`."""
        # ROBUSTNESS GATE. This arm is
        # the information-disclosure one: `memcpy(dst, dict + idx *
        # type_length, type_length)` with BOTH `idx` (page) and
        # `type_length` (footer schema) attacker-chosen reads arbitrary
        # process memory into a SELECT-able column. Bound the code stream
        # once, against the dictionary's OWN length. See
        # `_validate_dict_indices`.
        _validate_dict_indices(
            indices,
            dict_flba.length,
            "resolve_flba_as_binary",
        )

        var num_values = indices.length
        if type_length > 0 and num_values > 2147483647 // type_length:
            raise Error(
                "DictionaryDecoder.resolve_flba_as_binary: "
                + String(num_values)
                + " values of "
                + String(type_length)
                + " bytes pass the Int32 offsets"
            )

        # Allocate output offsets (uniform stride == type_length).
        # Writes via `set_typed[Int32]` on the buffer.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer((num_values + 1) * int32_size)
        for i in range(num_values + 1):
            offsets_buf.set_typed[Int32](i, Int32(i * type_length))
        offsets_buf.set_length(Int64((num_values + 1) * int32_size))


        # Allocate data and copy each selected dictionary value.
        # The dict-data source is an origin-tied view on the FLBA
        # dictionary's data; the data dest pointer comes from `view_mut`
        # so the per-value memcpy loop shares one borrow. Codes are read
        # with `indices.get_typed`; `dict_data_ptr` (from
        # ByteView._unsafe_ptr) is the per-row memcpy src.
        var total_bytes = num_values * type_length
        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
        var dict_data_view = dict_flba.data.view_ro()
        var dict_data_ptr = dict_data_view._unsafe_ptr()
        var data_dst_view = data_buf.view_mut()
        var data_dst_ptr = data_dst_view._unsafe_ptr()
        for i in range(num_values):
            var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
            if type_length > 0:
                unsafe_memcpy(
                    dest=data_dst_ptr + i * type_length,
                    src=dict_data_ptr + idx * type_length,
                    count=type_length,
                )
        data_buf.set_length(Int64(total_bytes))


        return BinaryArray[HeapRegion](
            offsets_buf^, data_buf^, None, num_values, total_bytes, 0
        )

    @staticmethod
    def resolve_flba_decimal_to_float64(
        indices: PrimitiveArray[DType.int32],
        dict_flba: BinaryArray[HeapRegion],
        type_length: Int,
        scale: Int,
    ) raises -> PrimitiveArray[DType.float64]:
        """The body of `DictionaryDecoder.resolve_flba_decimal_to_float64`."""
        # ROBUSTNESS GATE. This arm is
        # the information-disclosure one: `memcpy(dst, dict + idx *
        # type_length, type_length)` with BOTH `idx` (page) and
        # `type_length` (footer schema) attacker-chosen reads arbitrary
        # process memory into a SELECT-able column. Bound the code stream
        # once, against the dictionary's OWN length. See
        # `_validate_dict_indices`.
        _validate_dict_indices(
            indices,
            dict_flba.length,
            "resolve_flba_decimal_to_float64",
        )

        var num_values = indices.length

        comptime f64_size = size_of[Scalar[DType.float64]]()
        var buf = OwnedAlignedBuffer(max(num_values * f64_size, 1))
        buf.set_length(Int64(num_values * f64_size))


        # Precompute inverse divisor once.
        var divisor = Float64(1.0)
        for _ in range(scale):
            divisor = divisor * Float64(10.0)
        var inv_divisor = Float64(1.0) / divisor

        # The dict-data source is an origin-tied view; the scalar tails
        # write via `set_typed[Float64]`, the SIMD bodies through out_ptr
        # (origin-tied `view_mut() + _unsafe_ptr().bitcast[Float64]`), and
        # idx_typed_ptr is an origin-tied view_ro + bitcast (as in
        # resolve_int32 above).
        var dict_data_view = dict_flba.data.view_ro()
        var dict_data_ptr = dict_data_view._unsafe_ptr()
        var out_view = buf.view_mut()
        var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()

        # PERF-CRITICAL: cross-row SIMD fast-path
        # mirroring the PLAIN FLBA decimal SIMD body in plain_flba.mojo. Same
        # bswap+convert+multiply shape, but the per-lane load is gathered
        # through the dict via the per-row `idx`. Only fires for the two
        # FLBA widths that matter: 16 (DECIMAL P>=19) and 8 (DECIMAL P<=18
        # rare-FLBA-form).
        var idx_view = indices.view_ro()
        var idx_typed_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

        if type_length == 16:
            comptime W: Int = simd_width_of[DType.float64]()
            var simd_end = (num_values // W) * W
            var i = 0
            while i < simd_end:
                var raw = SIMD[DType.uint64, W](0)
                comptime for k in range(W):
                    var idx_k = Int(idx_typed_ptr.load[width=1](i + k))
                    var lane_ptr = dict_data_ptr + idx_k * 16 + 8
                    # SAFETY: idx in [0, dict_size); 16-byte stride
                    # bound-checked by the dict invariant.
                    raw[k] = lane_ptr.bitcast[Scalar[DType.uint64]]().load[width=1]()
                var be_swapped = _simd_bswap_u64[W](raw)
                var as_i64 = be_swapped.cast[DType.int64]()
                var as_f64 = as_i64.cast[DType.float64]() * SIMD[DType.float64, W](inv_divisor)
                out_ptr.store[width=W](i, as_f64)
                i += W
            # Scalar tail.
            while i < num_values:
                var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
                var value_ptr = dict_data_ptr + idx * 16
                var as_int = _flba_value_to_int64_be(value_ptr, 16)
                buf.set_typed[Float64](i, Float64(as_int) * inv_divisor)
                i += 1
            return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)

        if type_length == 8:
            comptime W: Int = simd_width_of[DType.float64]()
            var simd_end = (num_values // W) * W
            var i = 0
            while i < simd_end:
                var raw = SIMD[DType.uint64, W](0)
                comptime for k in range(W):
                    var idx_k = Int(idx_typed_ptr.load[width=1](i + k))
                    var lane_ptr = dict_data_ptr + idx_k * 8
                    raw[k] = lane_ptr.bitcast[Scalar[DType.uint64]]().load[width=1]()
                var be_swapped = _simd_bswap_u64[W](raw)
                var as_i64 = be_swapped.cast[DType.int64]()
                var as_f64 = as_i64.cast[DType.float64]() * SIMD[DType.float64, W](inv_divisor)
                out_ptr.store[width=W](i, as_f64)
                i += W
            while i < num_values:
                var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
                var value_ptr = dict_data_ptr + idx * 8
                var as_int = _flba_value_to_int64_be(value_ptr, 8)
                buf.set_typed[Float64](i, Float64(as_int) * inv_divisor)
                i += 1
            return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)

        # Generic scalar fallback for type_length not in {8, 16}.
        for i in range(num_values):
            var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
            var value_ptr = dict_data_ptr + idx * type_length
            var as_int = _flba_value_to_int64_be(value_ptr, type_length)
            buf.set_typed[Float64](
                i, Float64(as_int) * inv_divisor
            )

        return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)
