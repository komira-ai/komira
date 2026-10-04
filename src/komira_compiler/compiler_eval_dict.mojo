# =============================================================================
# compiler_eval_dict — dictionary materialization helper for expression eval
# =============================================================================
#
# Split out of compiler_eval.mojo.
# Contains:
#   _materialize_dict_to_string  — DICTIONARY Column -> flat StringArray
#   _densify_dict_column         — DICTIONARY Column -> STRING Column
#                                  (pass-through for everything else)
#
# Natural home for future dict-aware string-op kernels (SIMD memmem for
# CONTAINS/LIKE, etc.). Imported by compiler_eval_predicate.mojo.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.io.heap_region import HeapRegion

from .compiler_dict_mat_counter import compiler_dict_mat_counter_incr
from komira_core.instr.rxcensus import (
    RXC_DICTMAT_ROWS,
    RXC_DICTMAT_BYTES,
    rxcensus_add,
)


# =============================================================================
# Dictionary materialization helper
# =============================================================================


def _materialize_dict_to_string(col: Column) raises -> StringArray[HeapRegion]:
    """Materialize a DICTIONARY column to a flat StringArray.

    Used as a fallback for string operations (CONTAINS, STARTS_WITH, etc.)
    that don't yet have dict-aware implementations. For equality/comparison
    predicates, prefer dict_filter_eval_bool_mask which avoids materialization.

    NULLS: a NULL row materializes as a ZERO-LENGTH string
    with its output validity bit CLEAR, and its dictionary code is NEVER
    dereferenced. Same contract as the sibling expander
    `ipc_decoder_dispatch.expand_dict_indices_to_string`. Consumers that
    propagate nulls (`eval_regexp_*`, the `EXPR_SUBSTRING` arm) gate on
    `null_count > 0 and validity`, so BOTH are set here.

    CODE WIDTH: the per-row code stride is
    `col._dict_index_byte_width` (4 for `from_dictionary`, 8 for
    `from_int64_dict_indices`), matching `Column.dict_code_at`.

    Args:
        col: A Column with arrow_type == DICTIONARY.

    Returns:
        A StringArray with all dictionary values resolved, carrying the
        source column's per-row validity (rebased to the window).
    """
    # ⛔⛔ A NUMERIC DICTIONARY CARRIES THE SAME `ArrowType.DICTIONARY` TAG AND
    # MUST NOT REACH THE BODY BELOW. `Column`'s own `is_dict`
    # docstring says it: "operators that need to distinguish the two physical
    # layouts MUST further call `is_numeric_dict` / `is_string_dict`, not
    # act on this tag alone." Every one of this function's five callers
    # branches on the TAG (`src_at == ArrowType.DICTIONARY`), so the
    # discrimination has to happen HERE or nowhere.
    #
    # It is not hypothetical: `komira_parquet/column_decoder.mojo` builds
    # `Column.from_numeric_dict{,_codes_view}` on the PRODUCTION decode path
    # whenever `preserve_dict` + dict-vec are on. A numeric dictionary has
    # `_offsets == None` and `_dict_data == None`, so the very first statement
    # of the body — `col._offsets.value` — would read through an EMPTY
    # Optional. That is not a raise; a named refusal is.
    if not col.is_string_dict():
        raise Error(
            "_materialize_dict_to_string: not a STRING dictionary column"
            " (arrow_type=" + String(col.arrow_type)
            + ", is_numeric_dict=" + String(col.is_numeric_dict()) + ")"
        )

    # Reach witness. One relaxed atomic per CALL, never per
    # row. This function is the dict string-op fallback and the home of the
    # LIVE `_offset`-window bug; a test that claims to
    # cover it must be able to PROVE it got here, and a test that claims the
    # code-native path must be able to prove it did NOT. See
    # `compiler_dict_mat_counter.mojo` for why an abort probe was not enough.
    compiler_dict_mat_counter_incr()

    comptime int32_size = size_of[Int32]()
    var num_rows = col._length

    # The typed pointer comes from the origin-tied
    # `view_ro._unsafe_ptr.bitcast[Scalar[T]]`. The three ByteView
    # locals pin the underlying AlignedBuffers' origin chain through
    # `col._offsets.value` / `col._dict_data.value` / `col._data`
    # for the whole function body (both passes + memcpy below).
    # SAFETY: all three buffers are owned by `col`; views outlive scope
    # via the trailing `_ = col` keepalive at function end.
    var dict_offsets_view = col._offsets.value().view_ro()
    var dict_offsets_ptr = (
        dict_offsets_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    )
    var dict_data_view = col._dict_data.value().view_ro()
    var dict_data_ptr = dict_data_view._unsafe_ptr()
    # ARC_RESLICE: the per-row CODE window is
    # `[_offset, _offset+_length)` of the int32 code buffer, NOT the
    # `[0, _length)` prefix. `ArrowType.DICTIONARY` is on the
    # `supports_zero_copy_slice` whitelist, so `Column.slice` (and therefore
    # `split_record_batch`, which Arc-reslices by default) hands the string-op
    # call sites a column with `_offset > 0` whose codes start mid-buffer; a
    # `[0, _length)` read resolves the WRONG dictionary entries and returns
    # WRONG STRINGS silently. `view_range_ro` resolves the offset ONCE here
    # (outside both passes below) and bounds the view to the window, mirroring
    # `Column.as_dictionary` / `as_primitive`. The dict payload (`_offsets` /
    # `_dict_data`) is addressed by the CODE, so it is NOT offset-shifted —
    # only the code buffer honors `_offset`. Byte-identical on the
    # `_offset == 0` (non-sliced) path.
    # WIDE CODES: the code stride is
    # `_dict_index_byte_width`, NOT a hardcoded 4. `from_int64_dict_indices`
    # (live producer: `komira_search/fast_fields._materialize_keyword`) sets 8.
    # Reading an 8-byte-stride buffer as int32 lands even rows on the LOW half
    # of code i/2 and odd rows on the HIGH half (0 for every real code) —
    # silently interleaved-and-halved garbage. Only ONE of the two typed
    # pointers below is ever dereferenced (`codes_are_wide` selects); both are
    # bitcasts of the same origin-tied view, so the origin chain is unchanged.
    var code_width = col._dict_index_byte_width
    var codes_are_wide = code_width == 8
    var idx_view = col._data.view_range_ro(
        col._offset * code_width, num_rows * code_width
    )
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var idx_ptr64 = idx_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var dict_size = col._dict_size

    # VALIDITY: the output validity is the source column's
    # bitmap REBASED to the window. `Column.slice` Arc-shares the WHOLE-column
    # bitmap and carries `_offset > 0` (validity is offset-based — see
    # `Column.slice`), so the source bit for output row `i` is at ABSOLUTE
    # index `col._offset + i`. Pre-fix this function passed `None` + a
    # null_count of 0 unconditionally, so every NULL row emerged as a
    # non-null string — whatever entry its placeholder code addressed.
    var has_validity = Bool(col._validity)
    var out_validity = Optional[Bitmap[HeapRegion]](None)
    var out_null_count = 0
    if has_validity:
        var out_bm = Bitmap.create_all_valid(num_rows)
        ref src_bm = col._validity.value()
        for i in range(num_rows):
            if not src_bm.test(col._offset + i):
                out_bm.clear(i)
                out_null_count += 1
        out_validity = Optional[Bitmap[HeapRegion]](out_bm^)

    # First pass: compute total data bytes. A NULL row contributes 0 bytes and
    # its code is NOT resolved — Arrow does not constrain the index value at a
    # null slot, so resolving it would be an out-of-bounds read of the dict
    # offsets buffer.
    var total_bytes = 0
    for i in range(num_rows):
        if has_validity and not out_validity.value().test(i):
            continue
        var dict_idx = (
            Int((idx_ptr64 + i)[]) if codes_are_wide else Int((idx_ptr + i)[])
        )
        var start = Int((dict_offsets_ptr + dict_idx)[])
        var end = Int((dict_offsets_ptr + dict_idx + 1)[])
        total_bytes += end - start

    # Allocate output offsets and data buffers.
    var out_offsets = OwnedAlignedBuffer((num_rows + 1) * int32_size)
    var out_data = OwnedAlignedBuffer(max(total_bytes, 1))
    # Origin-tied
    # `view_mut._unsafe_ptr.bitcast[Scalar[T]]`. The two ByteView
    # locals (off_view + data_view) pin out_offsets / out_data through
    # the second-pass write loop. SAFETY: both out_* buffers are local-mut
    # and remain alive across the loop via the trailing moves into
    # `StringArray(out_offsets^, out_data^, ...)`.
    var off_view = out_offsets.view_mut()
    var off_ptr = off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = out_data.view_mut()
    var data_ptr = data_view._unsafe_ptr()
    var write_pos = 0
    (off_ptr + 0)[] = Int32(0)

    # Second pass: copy resolved strings. A NULL row emits an empty run (its
    # offset pair collapses) and never touches the dictionary payload.
    for i in range(num_rows):
        if has_validity and not out_validity.value().test(i):
            (off_ptr + i + 1)[] = Int32(write_pos)
            continue
        var dict_idx = (
            Int((idx_ptr64 + i)[]) if codes_are_wide else Int((idx_ptr + i)[])
        )
        var start = Int((dict_offsets_ptr + dict_idx)[])
        var end = Int((dict_offsets_ptr + dict_idx + 1)[])
        var str_len = end - start
        if str_len > 0:
            unsafe_memcpy(dest=data_ptr + write_pos, src=dict_data_ptr + start, count=str_len)
        write_pos += str_len
        (off_ptr + i + 1)[] = Int32(write_pos)

    out_offsets.set_length(Int64((num_rows + 1) * int32_size))

    out_data.set_length(Int64(total_bytes))

    # RXCENSUS. The CALL count already exists above;
    # what a densification COSTS is rows x bytes, and neither was recorded.
    rxcensus_add(RXC_DICTMAT_ROWS, num_rows)
    rxcensus_add(RXC_DICTMAT_BYTES, total_bytes)

    # keepalive: col must outlive pointer reads above
    _ = col
    return StringArray(
        out_offsets^,
        out_data^,
        out_validity^,
        num_rows,
        total_bytes,
        out_null_count,
    )


def _densify_dict_column(var col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """DICTIONARY -> STRING at the COLUMN level. Anything else passes through
    UNTOUCHED and UNCOPIED.

    ⭐ THE COLUMN-SHAPED SIBLING OF `_materialize_dict_to_string`, AND THE ONLY
    ONE. Every string KERNEL in `compiler_eval_column.mojo` (`EXPR_REGEXP`,
    `EXPR_SUBSTRING`, `EXPR_STRING_FN`, `EXPR_STRING_FN_N`) already takes the
    dictionary fallback, but each of them wants a `StringArray` and hands it
    straight to a kernel. `_eval_when_expr` is the first caller that needs the
    densified cell back as a `Column`, because a CASE arm is COMPARED against
    the output type and then OVERLAID — it never leaves the Column domain.

    ⛔ IT IS NOT A RELAXATION OF ANY DTYPE GUARD, AND MUST NOT BECOME ONE. The
    guards in `compiler_eval_case.mojo` refuse rather than reinterpret —
    "Without this, a ByteArray reinterpret is a silent correctness bug" — and
    they are UNCHANGED. This function makes the dictionary column genuinely
    STRING-shaped (bytes resolved, validity carried, offsets rebuilt) BEFORE
    the guard reads its type, which is the same thing the route this fix
    repairs used to do at decode time. A THEN arm that is INT64 under a STRING
    default still raises, exactly as before.

    ZERO-COPY HAND-OFF. `_materialize_dict_to_string` allocates BOTH output
    buffers fresh (`out_offsets` / `out_data`, refcount 1) and aliases nothing
    from `col`, so it is precisely the producer shape `from_string_shared`
    documents as its intended caller: the StringArray is consumed here and the
    returned Column is its sole owner.

    ⛔ IT TESTS `is_string_dict`, NOT THE `DICTIONARY` TAG, AND THAT IS THE
    WHOLE DIFFERENCE BETWEEN A REFUSAL AND A FABRICATED VALUE. A NUMERIC
    dictionary (`Column.from_numeric_dict`, built on the production parquet
    decode path under `preserve_dict`) carries the SAME `ArrowType.DICTIONARY`
    tag with `_offsets == None`. Densifying one "to a string" would resolve
    integer codes against a dictionary payload that is not there. A numeric
    dictionary therefore passes through UNTOUCHED and meets whatever dtype
    guard its caller already has — which refuses, and refusing is correct.

    Args:
        col: Any Column. Consumed.

    Returns:
        `col` unchanged when it is not a STRING dictionary; otherwise an
        equivalent STRING Column with the same logical cells, same length and
        same per-row validity.
    """
    if not col.is_string_dict():
        return col^
    return Column.from_string_shared(_materialize_dict_to_string(col))
