# =============================================================================
# cast_to_varchar_kernels — numeric / bool / string / dict / null -> Utf8 kernels
# =============================================================================
#
# The STRING -> number direction is `cast_string_to_number.mojo`.
#
#   numeric/bool/etc. -> STRING
#                      Int8..Int64 and UInt8..UInt64 use an itoa-style
#                      4-digit-step algorithm (after dtolnay/itoa's
#                      u64::fmt) into a single
#                      (data: List[UInt8], offsets: List[Int32]) buffer pair,
#                      then wrap via `StringArray.from_buffers`. This avoids
#                      a per-row `String(v)` allocation + `List[String]`
#                      intermediate + `StringArray.from_strings`
#                      re-serialize pass.
#
#                      The digit emit uses:
#                        - itoa-style div-by-10000 (4 digits per iter)
#                        - integer divide-by-10/100 via magic-mul codegen
#                          (NO SIMD LUT: a 2-digit LUT indexed by value
#                          spills 4 zmm registers per lookup)
#                        - Array[UInt8, 24] stack scratch
#                          (uninit; written right-to-left)
#                        - direct-pointer-cursor write into pre-grown `data`
#                      Codegen: the 4-digit emit vectorizes to vpinsrb-pack +
#                      vpaddb('0') + a 4-byte vmovd store.
#
#   Other kernels: cast_bool_to_string, cast_string_passthrough,
#                  cast_dictionary_to_string, cast_null_to_empty.
#
#   Scalar fallbacks: cast_float64_to_string, cast_float32_to_string.
#                These remain because `compiler_eval_column._eval_cast`
#                routes FLOAT64/FLOAT32 -> STRING through them; an
#                arrow-cast based float formatter is the intended
#                replacement.
#
# Semantics (parity with DuckDB unless noted):
#   - Bool format: lowercase `"true"` / `"false"` (DuckDB parity).
#   - Null format: empty string + null-validity bit set.
# =============================================================================

from std.memory import unsafe_memcpy

from arrow.string_array import StringArray
from arrow.primitive_array import PrimitiveArray
from arrow.dictionary_array import StringDictionaryArray
from arrow.bitmap import Bitmap
from byte_buffer.heap_region import HeapRegion
# STRDRAIN counter: site attribution, see
# counters.strdrain_counter
from counters.strdrain_counter import strdrain_note_site


# =============================================================================
# Scalar formatters — used for one-shot ScalarValue formatting
# =============================================================================


@always_inline
def i64_to_str(v: Int64) -> String:
    return String(v)


@always_inline
def i32_to_str(v: Int32) -> String:
    return String(v)


@always_inline
def f64_to_str(v: Float64) -> String:
    return String(v)


@always_inline
def f32_to_str(v: Float32) -> String:
    return String(v)


# =============================================================================
# itoa-style 4-digit-step LUT — the Int -> ASCII inner kernel (PERF-CRITICAL)
# =============================================================================
#
# Algorithm reference: `dtolnay/itoa` v1.0 `src/lib.rs` u64::fmt. This is
# the algorithm `lexical_core::write` / `itoa::write_i64` uses internally
# and which arrow-cast's `cast_with_options(_, &DataType::Utf8)` reaches
# through `fmt::Display for i64`. The shape:
#
#   while u >= 10000:                          # 4 digits at a time
#       quad   = u % 10000                      # one div-by-10000
#       u     /= 10000
#       pair1  = quad / 100
#       pair2  = quad % 100
#       emit lut[pair1*2 .. pair1*2+2]         # 2 bytes
#       emit lut[pair2*2 .. pair2*2+2]         # 2 bytes  -> 4 total
#   if u >= 100:                                # 2-digit tail (3-4 digit input)
#       ...
#   if u >= 10:                                 # 1-digit tail (if first sub-100)
#       ...
#
# vs. an Andersson 2-digit-per-step kernel:
#   while u >= 100:
#       pair = u % 100
#       u   /= 100
#       emit lut[pair*2 .. pair*2+2]           # 2 bytes per iter
#   if u >= 10 ...
#
# Why the 4-digit step matters for Int32/Int64:
#   - Int64 max ~20 digits: 5 iters of div-by-10000 + 1 tail vs. 10 iters
#     of div-by-100 + 1 tail. **40% fewer divisions** on the hot path.
#   - Int32 max ~10 digits: 2 iters of div-by-10000 + 1 tail vs. 5 iters
#     of div-by-100 + 1 tail. **40% fewer divisions** on hot.
#   - Smaller widths (Int8/Int16) skip the while entirely; the 4-digit
#     hot loop has no effect on them — they remain Andersson-shape via
#     the 2-digit-tail + 1-digit-tail path.
#
# Why the direct-pointer-write matters:
#   - Pre-grow `data` ONCE to `n * worst_case` via `resize(unsafe_uninit_length=)`
#     (the canonical pattern from `string_builder.push_contiguous_block`).
#   - Maintain a `write_pos: Int` cursor; the per-row emit kernel writes
#     into `data.unsafe_ptr() + write_pos` via raw store and advances it.
#   - Skip ALL per-byte `data.append()` bounds-checks + per-row scratch
#     bulk-extend (12-20 byte-append calls per row otherwise).
#
# # SAFETY: the kernel runs at module-internal scope only. `data_ptr` and
# `offsets_ptr` are derived from `data.unsafe_ptr()` / `offsets.unsafe_ptr()`
# AFTER a `resize(unsafe_uninit_length=)` that grows both buffers to the
# upper bound (sign+digits per row for `data`, n+1 for `offsets`). The
# raw cursor MUST NOT exceed `n * MAX_DIGITS_PER_ROW` writes; this is
# guaranteed by the per-DType maximums (Int8: 4 bytes incl. sign;
# Int16: 6; Int32: 11; Int64: 20). The final `data.unsafe_set_len(write_pos)`
# trims trailing uninitialised bytes before handoff to `from_buffers`.
# =============================================================================


@always_inline
def _emit_u64_itoa[
    o: Origin[mut=True],
](
    data_ptr: UnsafePointer[UInt8, o],
    write_pos_in: Int,
    u_in: UInt64,
) -> Int:
    """Emit `u_in` as decimal ASCII digits, written directly into
    `data_ptr[write_pos_in ..]` from right-to-left then memmoved left.

    Returns the new `write_pos` (i.e. `write_pos_in + digit_count`).

    Algorithm:
        1. Write digits right-to-left into a fixed-size scratch ending at
           `write_pos_in + MAX_DIGITS`.
        2. itoa 4-digit step: while u >= 10000, divmod by 10000 to extract
           4 trailing digits, write them as two pairs.
        3. 2-digit tail for u in [100..9999]; 1-or-2 digit final.
        4. memmove the live span left to start at `data_ptr + write_pos_in`.

    DESIGN NOTES (vs an Andersson-via-SIMD-LUT shape):
        - **NO 256-byte SIMD LUT.** Passing
          `lut: SIMD[DType.uint8, 256]` by value to every emit call makes the
          compiler spill 4 zmm registers to stack to do indexed scalar
          lookups on each pair (~20 spill+reload sequences per row at
          Int64 widths). 0xCD / 11-shift integer-divide-by-10 replaces
          the LUT and stays in scalar registers.
        - **NO SIMD[UInt8, 24] scratch.** SIMD indexed writes do runtime
          bounds-checking + cmov clamping. We use a fixed
          `Array[UInt8, 24]` on stack — direct addressed byte stores.
        - **Forward memcpy at end** to land the live span at write_pos.

    # SAFETY: caller has guaranteed `data_ptr + write_pos_in + 20` is
    in-bounds via the pre-grow `resize(unsafe_uninit_length=...)`.
    """
    var u = u_in
    # Uninitialised scratch — every byte is written before being read.
    var scratch = Array[UInt8, 24](uninitialized=True)
    var tail = 24  # write pointer into `scratch` (decrements).

    # 4-digit-step hot loop. Each iter consumes 4 trailing decimal digits
    # of `u` via one div/mod-by-10000 + integer-divide-by-100 + integer
    # divide-by-10 (all compiler-strength-reduced to mulx/shr).
    while u >= UInt64(10000):
        var quad_u = u % UInt64(10000)
        u //= UInt64(10000)
        var quad = Int(quad_u)
        var pair1 = quad // 100          # high 2 digits
        var pair2 = quad - pair1 * 100   # low 2 digits
        var p1_hi = pair1 // 10
        var p1_lo = pair1 - p1_hi * 10
        var p2_hi = pair2 // 10
        var p2_lo = pair2 - p2_hi * 10
        tail -= 4
        scratch[tail + 0] = UInt8(48 + p1_hi)
        scratch[tail + 1] = UInt8(48 + p1_lo)
        scratch[tail + 2] = UInt8(48 + p2_hi)
        scratch[tail + 3] = UInt8(48 + p2_lo)

    # 2-digit tail: handles u in [100, 9999] (1 iter) or [10, 99] (skip).
    if u >= UInt64(100):
        var pair_u = u % UInt64(100)
        u //= UInt64(100)
        var pair = Int(pair_u)
        var hi = pair // 10
        var lo = pair - hi * 10
        tail -= 2
        scratch[tail] = UInt8(48 + hi)
        scratch[tail + 1] = UInt8(48 + lo)

    # Final 1-or-2 digits (u < 100 at this point).
    if u >= UInt64(10):
        var pair = Int(u)
        var hi = pair // 10
        var lo = pair - hi * 10
        tail -= 2
        scratch[tail] = UInt8(48 + hi)
        scratch[tail + 1] = UInt8(48 + lo)
    else:
        tail -= 1
        scratch[tail] = UInt8(48 + Int(u))

    # Bulk-copy live scratch [tail..24] into `data_ptr[write_pos..]`.
    var digit_count = 24 - tail
    var dst = data_ptr + write_pos_in
    var src = scratch.unsafe_ptr() + tail
    unsafe_memcpy(dest=dst, src=src, count=digit_count)

    return write_pos_in + digit_count


@always_inline
def _emit_i64_itoa[
    o: Origin[mut=True],
](
    data_ptr: UnsafePointer[UInt8, o],
    write_pos_in: Int,
    v: Int64,
) -> Int:
    """Emit `v` as decimal ASCII digits with leading `-` for negatives,
    written into `data_ptr[write_pos_in ..]`. Returns the new write_pos.

    Handles INT64_MIN as a special case (cannot negate without overflow).

    # SAFETY: caller has guaranteed `data_ptr + write_pos_in + 21` is
    in-bounds (20 digits + 1 sign).
    """
    if v == Int64.MIN:
        # "-9223372036854775808" — 20 bytes. Inline byte writes (avoid
        # a String allocation).
        var dst = data_ptr + write_pos_in
        dst[0] = UInt8(45)   # '-'
        dst[1] = UInt8(57)   # '9'
        dst[2] = UInt8(50)   # '2'
        dst[3] = UInt8(50)
        dst[4] = UInt8(51)   # '3'
        dst[5] = UInt8(51)
        dst[6] = UInt8(55)   # '7'
        dst[7] = UInt8(50)   # '2'
        dst[8] = UInt8(48)   # '0'
        dst[9] = UInt8(51)
        dst[10] = UInt8(54)  # '6'
        dst[11] = UInt8(56)  # '8'
        dst[12] = UInt8(53)  # '5'
        dst[13] = UInt8(52)  # '4'
        dst[14] = UInt8(55)
        dst[15] = UInt8(55)
        dst[16] = UInt8(53)  # '5'
        dst[17] = UInt8(56)  # '8'
        dst[18] = UInt8(48)  # '0'
        dst[19] = UInt8(56)  # '8'
        return write_pos_in + 20

    var write_pos = write_pos_in
    var u: UInt64
    if v < Int64(0):
        (data_ptr + write_pos)[0] = UInt8(45)  # '-'
        write_pos += 1
        u = UInt64(-v)
    else:
        u = UInt64(v)

    return _emit_u64_itoa(data_ptr, write_pos, u)


# =============================================================================
# Bool / null / "passthrough" emitters
# =============================================================================


@always_inline
def _emit_bool(mut data: List[UInt8], v: Bool):
    """Emit `"true"` (4 bytes) or `"false"` (5 bytes). DuckDB lowercase."""
    if v:
        data.append(UInt8(116))  # 't'
        data.append(UInt8(114))  # 'r'
        data.append(UInt8(117))  # 'u'
        data.append(UInt8(101))  # 'e'
    else:
        data.append(UInt8(102))  # 'f'
        data.append(UInt8(97))   # 'a'
        data.append(UInt8(108))  # 'l'
        data.append(UInt8(115))  # 's'
        data.append(UInt8(101))  # 'e'


# =============================================================================
# StringArray builder — pair (data, offsets) into a typed StringArray
# =============================================================================


def _wrap_string_array(
    var data: List[UInt8],
    var offsets: List[Int32],
    n: Int,
    null_count: Int,
    has_validity: Bool,
    var validity_bitmap: Optional[Bitmap[HeapRegion]],
) raises -> StringArray[HeapRegion]:
    """Wrap the packed `(data, offsets)` pair plus optional validity into a
    StringArray via `StringArray.from_buffers`. Caller has already populated
    `offsets[0..N]` with cumulative byte positions (offsets[0]==0,
    offsets[N]==len(data))."""
    return StringArray.from_buffers(
        offsets, data, validity_bitmap^, null_count
    )


# =============================================================================
# Generic Int kernel via Andersson, monomorphized per dtype
# =============================================================================


@always_inline
def _max_digits_per_row[dtype: DType, unsigned: Bool]() -> Int:
    """Upper bound on bytes emitted for one row of this dtype, including
    the optional sign byte. Used to size the pre-grow of `data`.

    UInt8 max = "255" = 3.  Int8 min = "-128" = 4.
    UInt16 max = "65535" = 5.  Int16 min = "-32768" = 6.
    UInt32 max = "4294967295" = 10.  Int32 min = "-2147483648" = 11.
    UInt64 max = "18446744073709551615" = 20.  Int64 min = "-9223372036854775808" = 20.
    """
    comptime if dtype == DType.int8:
        return 4
    elif dtype == DType.uint8:
        return 3
    elif dtype == DType.int16:
        return 6
    elif dtype == DType.uint16:
        return 5
    elif dtype == DType.int32:
        return 11
    elif dtype == DType.uint32:
        return 10
    else:
        # int64 / uint64 — 20 bytes either way (Int64.MIN is 20 with sign;
        # UInt64.MAX is 20 without).
        return 20


def _cast_int_to_string_andersson[
    dtype: DType,
    unsigned: Bool,
](pa: PrimitiveArray[dtype]) raises -> StringArray[HeapRegion]:
    """Single internal kernel that handles Int8..Int64 + UInt8..UInt64.

    Specialization-by-dtype carries through `pa.get()` returning
    `Scalar[dtype]`; we widen each scalar to Int64/UInt64 for the
    itoa emitter. The compiler monomorphizes the wrapping shape.

    Parameters:
        dtype: PrimitiveArray DType being cast.
        unsigned: True for UInt8..UInt64 (skip sign branch). Comptime to
            allow `@parameter if` dispatch of the inner emitter.

    Pre-grow strategy: `data` is sized to `n * max_digits_per_row` UP-FRONT
    via `resize(unsafe_uninit_length=)`, and `offsets` to `n + 1`. The
    per-row inner kernel writes via a raw `UnsafePointer[UInt8]` cursor
    into `data.unsafe_ptr()`, avoiding per-byte List grow checks. After
    the loop, `data.unsafe_set_len(write_pos)` trims uninitialised tail.

    # SAFETY: `data_ptr` and `offsets_ptr` are derived from `data.unsafe_ptr()`
    and `offsets.unsafe_ptr()` after the resize-to-upper-bound. The per-row
    emit kernel cannot exceed `max_digits_per_row` bytes (compile-time
    constant per dtype). The cursor is module-internal — never escapes the
    function scope. `data` / `offsets` are owned `List[UInt8]` / `List[Int32]`
    moved into `from_buffers` at the end.
    """
    var n = pa.length

    comptime max_per_row = _max_digits_per_row[dtype, unsigned]()
    var upper_bytes = n * max_per_row

    var data = List[UInt8]()
    data.resize(unsafe_uninit_length=upper_bytes)
    var offsets = List[Int32]()
    offsets.resize(unsafe_uninit_length=n + 1)

    # Raw cursors — written through after the upper-bound resize. See
    # # SAFETY block in the docstring.
    var data_ptr = data.unsafe_ptr()
    var offsets_ptr = offsets.unsafe_ptr()
    offsets_ptr[0] = Int32(0)

    var has_validity_in = Bool(pa.validity)
    var nc = 0
    var write_pos = 0

    if has_validity_in:
        var bitmap = Bitmap.create_all_valid(n)
        for i in range(n):
            if pa.is_null(i):
                bitmap.clear(i)
                nc += 1
                # null row -> empty cell (write_pos unchanged)
            else:
                var sc = pa.get(i)
                comptime if unsigned:
                    write_pos = _emit_u64_itoa(
                        data_ptr, write_pos, UInt64(Int(sc))
                    )
                else:
                    write_pos = _emit_i64_itoa(
                        data_ptr, write_pos, Int64(Int(sc))
                    )
            offsets_ptr[i + 1] = Int32(write_pos)

        # Shrink `data` down to the actual byte count. Both up- and
        # down-resize via `resize(unsafe_uninit_length=)` are supported on
        # List[UInt8] in Mojo 1.0.0b1 (verified empirically); no
        # `unsafe_set_len` method exists on List, but down-resize has
        # the same trim-without-construct semantics.
        data.resize(unsafe_uninit_length=write_pos)

        return StringArray.from_buffers(
            offsets, data, Optional(bitmap^), nc
        )
    else:
        for i in range(n):
            var sc = pa.get(i)
            comptime if unsigned:
                write_pos = _emit_u64_itoa(
                    data_ptr, write_pos, UInt64(Int(sc))
                )
            else:
                write_pos = _emit_i64_itoa(
                    data_ptr, write_pos, Int64(Int(sc))
                )
            offsets_ptr[i + 1] = Int32(write_pos)

        # Shrink `data` down to the actual byte count. Both up- and
        # down-resize via `resize(unsafe_uninit_length=)` are supported on
        # List[UInt8] in Mojo 1.0.0b1 (verified empirically); no
        # `unsafe_set_len` method exists on List, but down-resize has
        # the same trim-without-construct semantics.
        data.resize(unsafe_uninit_length=write_pos)

        return StringArray.from_buffers(
            offsets, data, Optional[Bitmap[HeapRegion]](None), 0
        )


# =============================================================================
# Public numeric -> STRING kernels (signed)
# =============================================================================


def cast_int8_to_string(pa: PrimitiveArray[DType.int8]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[int8] to a StringArray. Nulls -> empty cell."""
    return _cast_int_to_string_andersson[DType.int8, False](pa)


def cast_int16_to_string(pa: PrimitiveArray[DType.int16]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[int16] to a StringArray. Nulls -> empty cell."""
    return _cast_int_to_string_andersson[DType.int16, False](pa)


def cast_int32_to_string(pa: PrimitiveArray[DType.int32]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[int32] to a StringArray. Nulls -> empty cell."""
    return _cast_int_to_string_andersson[DType.int32, False](pa)


def cast_int64_to_string(pa: PrimitiveArray[DType.int64]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[int64] to a StringArray. Nulls -> empty cell.

    Hot path — uses the 4-digit-step itoa kernel. See the module docstring.
    """
    return _cast_int_to_string_andersson[DType.int64, False](pa)


# =============================================================================
# Public numeric -> STRING kernels (unsigned)
# =============================================================================


def cast_uint8_to_string(pa: PrimitiveArray[DType.uint8]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[uint8] to a StringArray. Nulls -> empty cell."""
    return _cast_int_to_string_andersson[DType.uint8, True](pa)


def cast_uint16_to_string(pa: PrimitiveArray[DType.uint16]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[uint16] to a StringArray. Nulls -> empty cell."""
    return _cast_int_to_string_andersson[DType.uint16, True](pa)


def cast_uint32_to_string(pa: PrimitiveArray[DType.uint32]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[uint32] to a StringArray. Nulls -> empty cell."""
    return _cast_int_to_string_andersson[DType.uint32, True](pa)


def cast_uint64_to_string(pa: PrimitiveArray[DType.uint64]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[uint64] to a StringArray. Nulls -> empty cell."""
    return _cast_int_to_string_andersson[DType.uint64, True](pa)


# =============================================================================
# Bool -> STRING ("true" / "false") — DuckDB lowercase parity
# =============================================================================


def cast_bool_to_string(pa: PrimitiveArray[DType.bool]) raises -> StringArray[HeapRegion]:
    """Cast a PrimitiveArray[bool] to a StringArray.

    `True`  -> `"true"`  (4 bytes)
    `False` -> `"false"` (5 bytes)
    Nulls   -> `""`      (0 bytes; validity bit cleared)
    """
    var n = pa.length
    var data = List[UInt8]()
    # Max output = n * 5 bytes (all False). Reserve so we never realloc.
    data.reserve(n * 5)
    var offsets = List[Int32]()
    offsets.reserve(n + 1)
    offsets.append(Int32(0))

    var has_validity_in = Bool(pa.validity)
    var nc = 0

    if has_validity_in:
        var bitmap = Bitmap.create_all_valid(n)
        for i in range(n):
            if pa.is_null(i):
                bitmap.clear(i)
                nc += 1
                offsets.append(Int32(len(data)))
            else:
                var v = pa.get(i)
                _emit_bool(data, Bool(v))
                offsets.append(Int32(len(data)))
        return StringArray.from_buffers(offsets, data, Optional(bitmap^), nc)
    else:
        for i in range(n):
            var v = pa.get(i)
            _emit_bool(data, Bool(v))
            offsets.append(Int32(len(data)))
        return StringArray.from_buffers(
            offsets, data, Optional[Bitmap[HeapRegion]](None), 0
        )


# =============================================================================
# STRING -> STRING passthrough
# =============================================================================


def cast_string_passthrough(var sa: StringArray[HeapRegion]) -> StringArray[HeapRegion]:
    """Identity cast — the input is already a StringArray.

    Takes the StringArray by-move and returns it. the
    underlying buffers (`SharedAlignedBuffer`) are already shared / Arc-
    refcounted, so this is a structurally O(1) move (no per-cell work).
    """
    return sa^


# =============================================================================
# DICTIONARY (StringDictionaryArray) -> STRING — decode-at-cast
# =============================================================================
#
# The sink layer prefers DICT passthrough
# (the sink itself dispatches dict-aware via a small extra arm), but for
# the kernel API we MUST provide a decode form that materializes the
# string-per-row form. A cast dispatcher decides
# whether to call this or to passthrough.
#
# Algorithm: for each row, look up the dict-decoded string via
# `dict.get(row)`. This pays per-row hashing-free dict lookups + per-row
# `StringArray.get` calls. For high-cardinality (low-dup) columns this
# is the right shape; for low-cardinality the dispatcher should call
# `cast_dictionary_passthrough` instead.
# =============================================================================


def cast_dictionary_to_string(
    var dict_arr: StringDictionaryArray,
) raises -> StringArray[HeapRegion]:
    """Cast a StringDictionaryArray to a StringArray by materializing the
    decoded string for each row.

    A cast dispatcher may prefer passthrough for low-cardinality columns.
    """
    var n = dict_arr.length

    # Estimate avg cell bytes from the dictionary's total byte length.
    var dict_total_bytes = dict_arr.dictionary.data_length
    var dict_n = dict_arr.dictionary.length
    var bytes_per_cell_est = 16
    if dict_n > 0:
        bytes_per_cell_est = max(1, dict_total_bytes // dict_n)

    var data = List[UInt8]()
    data.reserve(n * bytes_per_cell_est)
    var offsets = List[Int32]()
    offsets.reserve(n + 1)
    offsets.append(Int32(0))

    # NB: indices carry their own nullability; we conservatively treat null-index rows as empty cells with the
    # null-validity bit set. (StringDictionaryArray has no separate row
    # validity bitmap; indices' validity IS the row validity.)
    var has_validity_in = Bool(dict_arr.indices.validity)
    var nc = 0

    if has_validity_in:
        var bitmap = Bitmap.create_all_valid(n)
        for i in range(n):
            if dict_arr.indices.is_null(i):
                bitmap.clear(i)
                nc += 1
                offsets.append(Int32(len(data)))
            else:
                var s = dict_arr.get(i)  # decodes via dictionary
                var sb = s.as_bytes()
                for j in range(len(sb)):
                    data.append(sb[j])
                offsets.append(Int32(len(data)))
        return StringArray.from_buffers(offsets, data, Optional(bitmap^), nc)
    else:
        for i in range(n):
            var s = dict_arr.get(i)
            var sb = s.as_bytes()
            for j in range(len(sb)):
                data.append(sb[j])
            offsets.append(Int32(len(data)))
        return StringArray.from_buffers(
            offsets, data, Optional[Bitmap[HeapRegion]](None), 0
        )


# =============================================================================
# NULL-typed -> STRING — N empty cells, all-null validity
# =============================================================================
#
# A NULL-typed column has no value buffer, only
# row count. Cast produces `offsets = [0, 0, ..., 0]` (N+1 zeros),
# `data = []`, `validity = Bitmap.create_all_zero(N)` (all rows null).
# =============================================================================


def cast_null_to_empty(num_rows: Int) raises -> StringArray[HeapRegion]:
    """Cast an N-row NULL-typed column to a StringArray of N empty cells.

    All rows are null in the resulting validity bitmap.
    """
    var data = List[UInt8]()
    var offsets = List[Int32]()
    offsets.reserve(num_rows + 1)
    for _ in range(num_rows + 1):
        offsets.append(Int32(0))

    # All-zero validity = every row is null.
    var bitmap = Bitmap.create_all_valid(num_rows)
    for i in range(num_rows):
        bitmap.clear(i)

    return StringArray.from_buffers(
        offsets, data, Optional(bitmap^), num_rows
    )


# =============================================================================
# Float -> STRING (scalar fallback)
# =============================================================================
#
# These kernels are scalar fallbacks: `komira_compiler.compiler_eval_column`
# (the `_eval_cast` arm) routes FLOAT32/FLOAT64 -> STRING through them. An
# arrow-cast based float formatter (Rust `ryu`, ~3-4 GB/s) is the intended
# replacement, so no shortest-round-trip float formatter is hand-written
# here.
# =============================================================================


def cast_float64_to_string(pa: PrimitiveArray[DType.float64]) raises -> StringArray[HeapRegion]:
    """Scalar fallback.

    Uses default Mojo `String(v)` formatting (matches Rust's
    `format!("{}", f)` behavior). The per-row String allocation is the
    known slow shape.
    """
    var n = pa.length
    var values = List[String]()
    var validity_list = List[Bool]()
    var has_null = False
    for i in range(n):
        if pa.is_null(i):
            values.append(String(""))
            validity_list.append(False)
            has_null = True
        else:
            values.append(f64_to_str(pa.get(i)))
            validity_list.append(True)
    strdrain_note_site(3, n)  # STRDRAIN counter: cast-to-varchar
    var sa = StringArray.from_strings(values)
    if has_null:
        var bitmap = Bitmap.create_all_valid(n)
        var nc = 0
        for i in range(n):
            if not validity_list[i]:
                bitmap.clear(i)
                nc += 1
        sa.validity = bitmap^
        sa.null_count = nc
    return sa^


def cast_float32_to_string(pa: PrimitiveArray[DType.float32]) raises -> StringArray[HeapRegion]:
    """Scalar fallback."""
    var n = pa.length
    var values = List[String]()
    var validity_list = List[Bool]()
    var has_null = False
    for i in range(n):
        if pa.is_null(i):
            values.append(String(""))
            validity_list.append(False)
            has_null = True
        else:
            values.append(f32_to_str(pa.get(i)))
            validity_list.append(True)
    strdrain_note_site(3, n)  # STRDRAIN counter: cast-to-varchar
    var sa = StringArray.from_strings(values)
    if has_null:
        var bitmap = Bitmap.create_all_valid(n)
        var nc = 0
        for i in range(n):
            if not validity_list[i]:
                bitmap.clear(i)
                nc += 1
        sa.validity = bitmap^
        sa.null_count = nc
    return sa^
