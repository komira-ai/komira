# =============================================================================
# Dict-Aware Filter Evaluation -- avoid full string materialization
# =============================================================================
#
# When filtering on a dictionary-encoded string column (e.g., WHERE country = 'US'),
# the naive path is:
#   1. Decode the dictionary column to a full StringArray (N string copies)
#   2. Evaluate the filter predicate on every row (N string comparisons)
#   3. Produce a BooleanArray / SelectionVector
#
# The dict-aware path is:
#   1. Evaluate the predicate against the D dictionary values only (D << N)
#   2. Produce a "matching indices" bitmap of size D
#   3. Scan the index array (N int32 lookups) to build the SelectionVector
#
# For low-cardinality columns (D=1000, N=6M), this is 6000x fewer string
# comparisons. Even for medium-cardinality (D=100K), it avoids materializing
# 6M strings.
#
# Supported predicates:
#   - EQ (column == literal)
#   - NE (column != literal)
#   - LT, LE, GT, GE (lexicographic)
#   - IN (column in set of values) -- not supported here
#
# No wildcard-origin pointers are used anywhere in this module.
# =============================================================================

from std.ffi import external_call, c_int
from std.memory import UnsafePointer

from komira_simd.byte_class.byte_equal import bytes_equal
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.string_array import StringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.selection_vector import SelectionVector


# =============================================================================
# CRITICAL CORRECTNESS NOTE
# =============================================================================
#
# Do not use the pattern:
#
#     var val_ptr = UnsafePointer[UInt8, MutExternalOrigin](
#         unsafe_from_address=Int(val_copy.as_c_string_slice().unsafe_ptr())
#     )
#     var match_ptr = UnsafePointer[Bool, MutExternalOrigin](
#         unsafe_from_address=Int(dict_match.unsafe_ptr())
#     )
#
# Going through `unsafe_from_address=Int(...)` LAUNDERS the lifetime: the
# Mojo compiler no longer sees the raw pointer as a borrow of `val_copy` /
# `dict_match` and is free to destroy them before the per-row loop runs.
# For small Strings (SSO), the backing bytes live in a stack slot that is
# then reused by unrelated code; reads through the laundered pointer return
# whatever happens to be there: a filter like `c_mktsegment == 'BUILDING'`
# returns different row counts on different runs, and the nondeterminism
# propagates all the way to the query result. A `_ = struct` keepalive is
# NOT reliable for this.
#
# Nor wrap the scalar in `OwnedPointer[String]` and then cast
# the raw pointer through `.as_any_origin()` into `ImmutAnyOrigin`. From the
# Mojo docs: "Wildcard origins... effectively disable Mojo's ASAP destruction
# for any values in that scope, as long as the pointer is live. Accordingly,
# the use of wildcard origins is discouraged, and should be used as a last
# resort." Casting to a wildcard origin defeats the lifetime tracking.
#
# The design: pass the typed `String` across function
# boundaries and extract the raw pointer in the deepest scope where it is
# used. Mojo's borrow tracker sees the String as borrowed for the whole body
# of the entry function and keeps it alive across both phase-1 and phase-2.
# The inner helpers (`_compare_bytes`, `_memcmp`, `_lex_cmp`) are parametric
# on the concrete origins of the two pointers they read through. `dict_match`
# stays an MmapAlignedBuffer[64] (RAII heap buffer) whose `view_ro()._unsafe_ptr()`
# yields a concrete origin-tracked pointer -- no wildcard cast, we
# just pass the buffer pointer directly to the phase-2 scan functions.
# =============================================================================


# =============================================================================
# Predicate enum
# =============================================================================


struct DictFilterOp(ImplicitlyCopyable, Copyable, Equatable):
    """Filter comparison operators for dict-aware evaluation."""
    var _value: UInt8

    comptime EQ = DictFilterOp(0)
    comptime NE = DictFilterOp(1)
    comptime LT = DictFilterOp(2)
    comptime LE = DictFilterOp(3)
    comptime GT = DictFilterOp(4)
    comptime GE = DictFilterOp(5)

    def __init__(out self, value: UInt8):
        self._value = value

    def __init__(out self, value: Int):
        self._value = UInt8(value)

    @always_inline
    def __eq__(self, other: DictFilterOp) -> Bool:
        return self._value == other._value

    @always_inline
    def __ne__(self, other: DictFilterOp) -> Bool:
        return self._value != other._value


# =============================================================================
# Core: evaluate predicate against dictionary, then scan indices
# =============================================================================


def dict_filter_eval(
    dict_array: StringDictionaryArray,
    op: DictFilterOp,
    value: String,
) -> SelectionVector:
    """Evaluate a filter predicate on a dictionary-encoded string column.

    Instead of materializing all N strings, evaluates the predicate against
    the D dictionary entries, then scans the N-element index array to build
    the selection vector. Cost: O(D * string_cmp) + O(N * int_lookup).

    `value` is borrowed for the entire body; Mojo's borrow tracker keeps it
    alive across phase 1 and phase 2. No OwnedPointer, no wildcard origin.

    Args:
        dict_array: The dictionary-encoded string column.
        op: The comparison operator (EQ, NE, LT, LE, GT, GE).
        value: The scalar string value to compare against (borrowed).

    Returns:
        A SelectionVector containing indices of matching rows.
    """
    var dict_size = dict_array.dict_size()
    var num_rows = dict_array.length

    # Phase 1: Evaluate predicate against dictionary values. dict_match is an
    # MmapAlignedBuffer[64] -- RAII heap buffer freed automatically on scope exit.
    var dict_match = _eval_dict_predicate_buf(
        dict_array.dictionary, op, value, dict_size
    )

    # Phase 2: Scan the index array and collect matching row indices.
    # `view_ro()._unsafe_ptr()` (uint8-direct — the view returns
    # `UnsafePointer[UInt8, origin]`). `.as_immutable()` converts to
    # ImmutOrigin while preserving the lifetime tag tied to dict_match's
    # MmapAlignedBuffer.
    var match_view = dict_match.view_ro()
    var match_ptr = match_view._unsafe_ptr().as_imm()
    var result = _scan_indices_with_dict_match_buf(
        dict_array.indices, match_ptr, dict_size, num_rows
    )

    _ = dict_match^
    return result^


def dict_filter_eval_bool_mask(
    dict_array: StringDictionaryArray,
    op: DictFilterOp,
    value: String,
) -> BooleanArray:
    """Like dict_filter_eval but returns a BooleanArray instead of SelectionVector.

    Some downstream operators (e.g., boolean AND/OR composition) work with
    BooleanArray masks rather than SelectionVectors.

    Args:
        dict_array: The dictionary-encoded string column.
        op: The comparison operator.
        value: The scalar string value to compare against (borrowed).

    Returns:
        A BooleanArray where True indicates matching rows.
    """
    var dict_size = dict_array.dict_size()
    var num_rows = dict_array.length

    var dict_match = _eval_dict_predicate_buf(
        dict_array.dictionary, op, value, dict_size
    )
    # SAFETY: see dict_filter_eval. `view_ro()._unsafe_ptr()` (uint8-direct)
    # with an `.as_immutable()` tail.
    var match_view = dict_match.view_ro()
    var match_ptr = match_view._unsafe_ptr().as_imm()

    var result = _build_bool_mask_from_dict_match_buf(
        dict_array.indices, match_ptr, dict_size, num_rows
    )

    _ = dict_match^
    return result^


def dict_filter_eval_bool_mask_column(
    col: Column[HeapRegion],
    op: DictFilterOp,
    value: String,
) raises -> BooleanArray:
    """ZERO-COPY, BRANCH-FREE sibling of `dict_filter_eval_bool_mask` for a
    STRING-dictionary `Column` with Int32 codes.

    `dict_filter_eval_bool_mask` takes a `StringDictionaryArray`, so a caller
    must first run `Column.as_dictionary()`, which COPIES the whole code buffer
    (480 KB per 122,880-row row group) plus the dictionary, and it builds the
    mask one bit at a time behind two branches per row. On a dictionary-kept
    scan that pair is a significant share of all cycles. This
    reads the codes IN PLACE (honouring `_offset`) and builds each mask byte
    from eight table lookups with no branch: the per-entry verdict table has
    one extra ZERO entry at index `dict_size`, and every code is clamped into
    `[0, dict_size]` as an UNSIGNED min, so a negative or past-the-end code
    reads that zero (a `dict_idx < dict_match_len` test, spelled without a
    branch).

    Returns the RAW verdicts over the column's window `[_offset, _offset +
    _length)`, like its sibling — a NULL row answers whatever its code does;
    the caller applies the null policy (`kleene_cmp_finalize_scalar`).

    Raises:
        Error if `col` is not a STRING dictionary with Int32 codes.
    """
    if not col.is_string_dict():
        raise Error(
            "dict_filter_eval_bool_mask_column: not a STRING dictionary column"
        )
    if col._dict_index_byte_width != 4:
        raise Error(
            "dict_filter_eval_bool_mask_column: codes are "
            + String(col._dict_index_byte_width)
            + " bytes wide; this kernel reads Int32 codes"
        )
    var dict_size = col._dict_size
    var n = col._length

    # Phase 1: one 0/1 byte per dictionary entry, plus a trailing 0.
    var verdict = List[UInt8](length=dict_size + 1, fill=UInt8(0))
    var offs_view = col._offsets.value().view_ro()
    var data_view = col._dict_data.value().view_ro()
    # SAFETY: both views pin their buffers for this body; `value` is borrowed
    # for the body. Same origin discipline as `_eval_dict_predicate_buf`.
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = value.unsafe_ptr()
    var val_len = value.byte_length()
    for i in range(dict_size):
        var start = Int(offs_view.get_typed[Int32](i))
        var end = Int(offs_view.get_typed[Int32](i + 1))
        if _compare_bytes(data_ptr, start, end - start, val_ptr, val_len, op):
            verdict[i] = UInt8(1)

    # Phase 2: eight lookups per mask byte, no branch.
    var bm = Bitmap.create(n)
    var bm_view = bm.buffer.view_mut()
    var codes_view = col._data.view_ro()
    # SAFETY: `codes_view` pins the code buffer; the window starts at
    # `_offset` and holds `_length` Int32 codes. Read as UInt32 so a negative
    # code clamps to `dict_size` below.
    var codes = (
        codes_view._unsafe_ptr().bitcast[Scalar[DType.uint32]]() + col._offset
    )
    var vptr = verdict.unsafe_ptr()
    var cap = UInt32(dict_size)
    var full_bytes = n >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        comptime for bit in range(8):
            # SAFETY: `min(code, cap)` is in [0, dict_size] == the verdict
            # table's index range.
            var c = min((codes + base + bit)[], cap)
            byte_val = byte_val | ((vptr + Int(c))[] << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)
    var remaining = n & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var c = min((codes + base + bit)[], cap)
            byte_val = byte_val | ((vptr + Int(c))[] << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)
    _ = offs_view^
    _ = data_view^
    _ = codes_view^
    _ = verdict^
    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# Phase 1: Evaluate predicate against dictionary entries
# =============================================================================


def _eval_dict_predicate_buf(
    dictionary: StringArray,
    op: DictFilterOp,
    val: String,
    dict_size: Int,
) -> OwnedAlignedBuffer:
    """Evaluate a predicate against each dictionary entry.

    Returns an MmapAlignedBuffer where byte `i` is 1 if dictionary entry `i`
    matches the predicate and 0 otherwise. MmapAlignedBuffer is RAII so the
    caller simply holds it and lets it free on scope exit -- no explicit
    free() required. The 64-byte alignment also leaves the door open to a
    future SIMD scan of the match buffer.

    Using MmapAlignedBuffer (instead of raw `alloc` + manual `free`) also keeps
    the backing memory at a stable heap address for the duration of the
    phase-2 scan, which is the correctness invariant a regression test
    exercises. See the correctness note at the top of this file.

    Args:
        dictionary: The string dictionary (unique values).
        op: Comparison operator.
        val: The scalar string value (borrowed; Mojo tracks the borrow and
            keeps it alive across the per-dict loop).
        dict_size: Number of dictionary entries.
    """
    # +1 so we can still allocate when dict_size == 0 (MmapAlignedBuffer rejects
    # size <= 0).
    var buf = OwnedAlignedBuffer(dict_size + 1)
    buf.set_length(Int64(dict_size + 1))


    # Offsets and the match buffer go through the typed view API. The
    # `dictionary.data` pointer is passed to `_compare_bytes` (→ FFI memcmp for
    # ordering); its origin is tracked back to dictionary.data through the
    # function-parametric `data_origin` template arg of `_compare_bytes` /
    # `_lex_cmp`.
    var offsets_view = dictionary.offsets.view_ro()
    # SAFETY: `dictionary` is borrowed for the body, so the data buffer is
    # alive. `view_ro()._unsafe_ptr()` (uint8-direct); `.as_immutable()` flips
    # mut → immut while preserving the lifetime tag — no wildcard origin.
    var data_view = dictionary.data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    # SAFETY: `val` is borrowed for the body. Extracting the raw pointer
    # here ties it to val's origin; Mojo keeps val alive across the loop.
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var match_view = buf.view_mut()

    for i in range(dict_size):
        var start = Int(offsets_view.get_typed[Int32](i))
        var end = Int(offsets_view.get_typed[Int32](i + 1))
        var elem_len = end - start
        var matches = _compare_bytes(data_ptr, start, elem_len, val_ptr, val_len, op)
        match_view.write_u8_at(i, UInt8(1) if matches else UInt8(0))

    return buf^


@always_inline
def _compare_bytes[
    data_origin: ImmOrigin,
    val_origin: ImmOrigin,
](
    data_ptr: UnsafePointer[UInt8, data_origin],
    elem_start: Int,
    elem_len: Int,
    val_ptr: UnsafePointer[UInt8, val_origin],
    val_len: Int,
    op: DictFilterOp,
) -> Bool:
    """Compare a byte range against a value using the given operator.

    Uses C memcmp for the actual byte comparison. Parametric on both pointer
    origins so callers pass concrete borrow-tracked pointers through without
    needing a wildcard origin cast.
    """
    if op == DictFilterOp.EQ:
        if elem_len != val_len:
            return False
        if elem_len == 0:
            return True
        return _bytes_eq(data_ptr + elem_start, val_ptr, elem_len)
    elif op == DictFilterOp.NE:
        if elem_len != val_len:
            return True
        if elem_len == 0:
            return False
        return not _bytes_eq(data_ptr + elem_start, val_ptr, elem_len)
    else:
        # Lexicographic comparison for LT, LE, GT, GE.
        var cmp = _lex_cmp(data_ptr, elem_start, elem_len, val_ptr, val_len)
        if op == DictFilterOp.LT:
            return cmp < 0
        elif op == DictFilterOp.LE:
            return cmp <= 0
        elif op == DictFilterOp.GT:
            return cmp > 0
        else:  # GE
            return cmp >= 0


@always_inline
def _bytes_eq[
    a_origin: ImmOrigin,
    b_origin: ImmOrigin,
](
    a: UnsafePointer[UInt8, a_origin],
    b: UnsafePointer[UInt8, b_origin],
    n: Int,
) -> Bool:
    """True iff the `n` bytes at `a` and `b` are equal.

    The EQ / NE arms of `_dict_entry_matches` route here.
    `external_call["memcmp"] == 0` is rewritten by LLVM to `bcmp`, which a
    hermetic Zig-based C toolchain weak-DEFINES in the executable as
    `compiler_rt`'s six-instructions-per-byte loop — glibc's SIMD memcmp is
    never reachable. `bytes_equal` is `@always_inline` and issues no call at
    any width.

    ⚠⚠ CLAIM NOTHING FOR THIS ONE. This module compares a scalar literal
    against DICTIONARY ENTRIES, not against rows — the call population is the
    dictionary's CARDINALITY (TPC-H `l_shipmode` has SEVEN distinct values),
    and `_scan_indices_with_dict_match_buf` then walks the rows against a
    precomputed byte mask with no comparison at all. That is the whole point
    of the dict-filter path. The conversion is worth approximately zero wall;
    it is here because it is strictly fewer instructions, removes an FFI call,
    and leaves ONE equality kernel instead of two.

    Parametric on both origins; both are read-only.
    """
    if n == 0:
        return True
    return bytes_equal(
        Span[UInt8, a_origin](unsafe_ptr=a, length=n),
        Span[UInt8, b_origin](unsafe_ptr=b, length=n),
    )


@always_inline
def _memcmp[
    a_origin: ImmOrigin,
    b_origin: ImmOrigin,
](
    a: UnsafePointer[UInt8, a_origin],
    b: UnsafePointer[UInt8, b_origin],
    n: Int,
) -> Int:
    """C memcmp wrapper. Parametric on both origins; both are read-only.

    ⚠ ORDERING ONLY, ONE CALLER — `_lex_cmp`, which serves LT/LE/GT/GE and
    needs the SIGN. The EQ / NE arms use `_bytes_eq` above; do not route a
    new `== 0` / `!= 0` test through here. An equality kernel
    cannot answer a three-way compare, and no vector ordering kernel has been
    built (or measured to be worth building) for this path.
    """
    if n == 0:
        return 0
    return Int(external_call["memcmp", c_int](a, b, UInt(n)))


@always_inline
def _lex_cmp[
    data_origin: ImmOrigin,
    val_origin: ImmOrigin,
](
    data_ptr: UnsafePointer[UInt8, data_origin],
    elem_start: Int,
    elem_len: Int,
    val_ptr: UnsafePointer[UInt8, val_origin],
    val_len: Int,
) -> Int:
    """Lexicographic byte comparison. Returns <0, 0, >0. Parametric on origins."""
    var min_len = elem_len if elem_len < val_len else val_len
    if min_len > 0:
        var cmp = _memcmp(data_ptr + elem_start, val_ptr, min_len)
        if cmp != 0:
            return cmp
    return elem_len - val_len


# =============================================================================
# Phase 2: Scan index array with dict match bitmap
# =============================================================================


def _scan_indices_with_dict_match_buf[
    match_origin: ImmOrigin,
](
    indices: PrimitiveArray[DType.int32],
    dict_match: UnsafePointer[UInt8, match_origin],
    dict_match_len: Int,
    num_rows: Int,
) -> SelectionVector:
    """Scan the index array and collect rows whose dict entry matches.

    `dict_match` is a read-only pointer into a buffer held by the caller
    (typically an MmapAlignedBuffer[64]); byte `i` is nonzero iff dictionary
    entry `i` matches the scalar. Parametric on the buffer's concrete origin
    so the caller's MmapAlignedBuffer lifetime is visible to the borrow checker
    (no wildcard origin cast).

    Two-pass approach:
      1. Count matching rows.
      2. Fill the result array.
    """
    # Indices and the result go through `get_typed` / `set_typed`.
    # Pass 1: count matches.
    var count = 0
    for i in range(num_rows):
        var dict_idx = Int(indices.get_typed[Scalar[DType.int32]](i))
        if dict_idx < dict_match_len and (dict_match + dict_idx)[] != 0:
            count += 1

    if count == 0:
        return SelectionVector(PrimitiveArray[DType.int32].allocate(0))

    # Pass 2: fill result.
    var result = PrimitiveArray[DType.int32].allocate(count)
    var write_pos = 0
    for i in range(num_rows):
        var dict_idx = Int(indices.get_typed[Scalar[DType.int32]](i))
        if dict_idx < dict_match_len and (dict_match + dict_idx)[] != 0:
            result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](i))
            write_pos += 1

    return SelectionVector(result^)


def _build_bool_mask_from_dict_match_buf[
    match_origin: ImmOrigin,
](
    indices: PrimitiveArray[DType.int32],
    dict_match: UnsafePointer[UInt8, match_origin],
    dict_match_len: Int,
    num_rows: Int,
) -> BooleanArray:
    """Build a BooleanArray mask from dict match results.

    `dict_match` is a read-only pointer into a buffer held by the caller
    (typically an MmapAlignedBuffer[64]); entry `i` is nonzero iff dictionary
    entry `i` matches. Parametric on the buffer's origin for concrete
    borrow tracking.
    """
    # The bitmap goes through view_mut + write_u8_at, and indices through
    # `indices.get_typed[Scalar[DType.int32]]`. `dict_match` is a raw typed
    # pointer because it's origin-parametric (caller's
    # ImmutOrigin borrow) — matches an origin-tight primitive pattern.
    var bm = Bitmap.create(num_rows)
    var bm_view = bm.buffer.view_mut()

    # Process 8 rows at a time for efficient bit packing.
    var full_bytes = num_rows >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var dict_idx = Int(indices.get_typed[Scalar[DType.int32]](base + bit))
            if dict_idx < dict_match_len and (dict_match + dict_idx)[] != 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    # Handle remaining bits.
    var remaining = num_rows & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var dict_idx = Int(indices.get_typed[Scalar[DType.int32]](base + bit))
            if dict_idx < dict_match_len and (dict_match + dict_idx)[] != 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)
