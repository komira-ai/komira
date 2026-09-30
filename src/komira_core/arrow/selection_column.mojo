# =============================================================================
# selection_column -- a PROBE column served as (base column + index buffer)
# =============================================================================
#
# ⚠ WHERE THIS LAYOUT PAYS, AND WHERE IT DOES NOT.
# -----------------------------------------------------------------------------
# Serving a join's probe columns through this carrier really does delete two of
# every three gathered column-rows -- but **the bytes do not go away, they move
# to `flatten_selection_batch`**, which runs OUTSIDE the morsel fork that would
# otherwise have written them. Even with the egress on the worker pool it is a
# net loss on wide joins, because resolving outside the producer costs one
# extra pass over the codes (this file resolves ONE column at a time;
# `_gather_pair_into_range_i32` walks the match index once for TWO) plus a
# destination allocation per chunk.
#
#     A SELECTION CARRIER PAYS ONLY WHERE THE CONSUMER THAT RESOLVES IT IS AT
#     LEAST AS PARALLEL AS THE PRODUCER THAT WOULD OTHERWISE HAVE GATHERED.
#
# DuckDB never pays this because `ColumnDataCollection::Append` resolves its sel
# vector on the SAME THREAD as the probe -- the vector never crosses a fork.
# In this engine the producer is always the morsel wave, and the only consumer
# inside it is the agg-in-pass sink, whose intermediate is an L2-resident
# ~15K-row morsel. **So a proposal to "make consumer X selection-aware" must
# first say which FORK X runs in.** A terminal `SELECT *` has no consumer at
# all, and its values must be produced regardless.
#
# The layout itself is correct, is exercised by tests with mutants, and is
# shared with the parquet numeric-dict path.
#
# WHY THIS FILE EXISTS
# --------------------
# A fused parquet join that copies both PROBE columns off one walk of the
# match index (`_gather_pair_into_range_i32`) gathers 3 column-rows per output
# row where DuckDB gathers 1: **DuckDB does not run that kernel at all**. It
# serves its probe columns as SELECTION-VECTOR references:
#
#     result.Slice(left, chain_match_sel_vector, result_count)
#         -- duckdb/src/execution/join_hashtable.cpp
#
# and flattens only when the result is appended to a `ColumnDataCollection`.
# The sel-vector never leaves the engine.
#
# CARRIER: THE LAYOUT ALREADY EXISTED; NOTHING NEW WAS INVENTED. A `Column`
# whose `_data` holds per-row CODES and whose `_dict_data` holds the flat value
# buffer IS `(base, selection)` -- the NUMERIC DICTIONARY layout
# (`Column.from_numeric_dict`, `is_numeric_dict()`), used by the parquet
# dict-vector path. What this file adds is the ONE constructor
# that binds those two fields to buffers it does not own:
#
#     `_dict_data` = an Arc-SHARE of the BASE column's value buffer   (no copy)
#     `_data`      = the match-index buffer, reused as the CODES      (no copy)
#
# so the pair-gather does not run and no output bytes are written for those
# columns at all.
#
# THIS LAYOUT MUST NOT REACH AN EXTERNAL CONSUMER, AND THE REASON IS NOT
# TIDINESS. An Arrow DICTIONARY array asserts LOW CARDINALITY. Ours is the
# opposite by construction: on a high-cardinality join the "dictionary" is the
# whole ~15,360-row probe morsel with each entry used about once, and the whole
# result can be ~100M rows. A consumer that takes the Arrow contract at its
# word -- pandas / polars building a CATEGORICAL -- would materialise a
# dictionary with ~100M categories, which is dramatically WORSE than the copy
# this lever removes. So: dictionary layout INSIDE the engine, FLATTENED at the
# boundary. `flatten_selection_batch` below is that boundary, and it is the
# analogue of DuckDB's `ColumnDataCollection::Append`.
#
# AND THE BASE MUST OUTLIVE THE RESULT. `_dict_data` is an Arc share of the
# base column's buffer, so the buffer is refcount-pinned for the selection
# column's lifetime -- that half is sound by construction. What is NOT sound is
# a design that funnels N different bases into ONE contiguous output column:
# a selection column can name exactly ONE base, so a result stitched from N
# per-morsel probe batches cannot be selection-backed at all. The CHUNKED
# `Table` carrier is what makes this expressible -- one chunk per retained
# probe morsel, each naming its own base.
#
# WHAT IS DELIBERATELY REFUSED (`selection_admits`)
# -------------------------------------------------
# Every refusal below is a case where the layout would be silently WRONG rather
# than merely unsupported, so each is a hard `False` and the caller falls back
# to the gather it already has:
#
#   * a value type outside {INT32, INT64, FLOAT32, FLOAT64}. The flatten's only
#     implementation is `Column.resolve_numeric_dict_to_flat`, which emits
#     exactly those four tags -- so admitting DATE32 would round-trip it to
#     INT32 and CHANGE THE OUTPUT SCHEMA. A relabel that reads the same bytes
#     is still a different answer to `field_arrow_type`.
#   * a NULLABLE base. A dictionary column's validity is the CODES' validity,
#     and the codes here are match indices -- they carry no nulls of their own,
#     so the base's per-row null bits would have to be GATHERED to be
#     preserved, which is the copy this lever exists to delete.
#   * a base whose value buffer does not cover `[_offset, _offset + _length)`.
#     The codes are NOT bounds-checked (see below), so a short buffer is an
#     out-of-bounds read rather than a raise.
#
# A SLICED BASE (`_offset != 0`) IS ADMITTED, AND THE OFFSET IS HONOURED BY THE
# SHARE'S EXTENT -- NOT BY THE CODES, AND NOT BY A NEW `Column` FIELD.
# -----------------------------------------------------------------------------
# ⛔ REFUSING `_offset != 0` WOULD MAKE THIS LEVER UNABLE TO FIRE ON THE SHAPE
# IT IS BUILT FOR. `split_record_batch` cuts a row group into SUB-SLOT morsels
# that all alias the group's one decoded buffer and narrow it with
# `_offset`/`_length`, so morsel *m* carries `_offset == m * morsel_size` (e.g.
# 8 morsels of ~15,360 rows over a 122,880-row group -- all but the first
# sliced). Single-morsel test fixtures cannot see this 1:1-fixture-vs-1:N-
# production gap; test with multi-morsel inputs.
#
# THE FIX IS THAT `_dict_data` IS THE BASE'S OWN ROW WINDOW, NOT ITS WHOLE
# BUFFER: `share_range_as` narrows the Arc share to
# `[_offset * width, (_offset + _length) * width)`, so `dict_value_*(code)` --
# which reads `_dict_data` from ITS element 0 -- lands on base row `code`,
# which is `base._data[base._offset + code]`. That is EXACTLY the address
# `_gather_fixed_into_range` computes (`src_col[_offset + idx[i]]`), so the two
# paths agree by construction rather than by a convention a reader must honour.
#
# ⛔ AND THE OFFSET IS **NOT** FOLDED INTO THE CODES, WHICH IS THE OTHER
# OBVIOUS FIX AND IS UNSOUND HERE. ONE code buffer serves EVERY sliced probe
# column of a chunk -- that sharing is why the buffer is built by the caller
# and passed in -- and the columns of one morsel batch DO NOT ALL CARRY THE
# SAME `_offset`: `split_record_batch` zero-copy-slices an offset-honouring
# non-nullable column (`_offset == start_row`) but COPY-slices anything else
# (`_offset == 0`), so a single offset-folded code buffer cannot serve a mixed
# batch. Folding would also turn a `memcpy` of the match index into a per-row
# add pass on the driver thread. The window share costs nothing per row, is
# per-COLUMN by construction, and keeps `get_typed`'s bounds check meaningful:
# `_dict_data.len()` is `_dict_size * width` exactly, so a code past the base's
# last row is caught by the buffer's own bound instead of reading the next
# morsel's rows. (`share_range_as`'s own docstring states the general form of
# this argument -- a whole-buffer share hands a downstream copy the wrong
# extent.)
#
# THE CODES ARE NOT VALIDATED, AND THAT IS A DELIBERATE MATCH TO WHAT IT
# REPLACES. `Column.from_numeric_dict` runs `validate_dict_codes` because it
# binds an UNTRUSTED code stream (a parquet page) to a dictionary. These codes
# are the join's OWN match indices, and the kernel they replace
# (`_gather_fixed_into_range_i32`) already does raw pointer arithmetic with them
# and no bounds check at all. Adding an O(rows) validation pass here would make
# this path STRICTLY SAFER THAN THE GATHER, at a per-row cost, on the driver
# thread -- a trade nobody asked for. The trust level is identical to the
# incumbent's, by construction; it is stated rather than assumed.
# =============================================================================

from std.collections import List

from komira_core.io.heap_region import HeapRegion

from .arrow_types import ArrowType
from komira_core.dtype_sentinel import DTYPE_NONE
from .bitmap import Bitmap
from .column import Column
from .schema import RecordBatch, RecordBatchBuilder, Schema
from .shared_aligned_buffer import SharedAlignedBuffer
from .table import Table


@always_inline
def selection_value_dtype(at: ArrowType) -> DType:
    """The numeric-dictionary VALUE dtype a base column of tag `at` resolves to,
    or `DTYPE_NONE` when the tag may not be selection-backed.

    EXACTLY FOUR TAGS, AND THE LIST IS BOUNDED BY THE FLATTEN, NOT BY TASTE.
    `Column.resolve_numeric_dict_to_flat` emits INT32 / INT64 / FLOAT32 /
    FLOAT64 and nothing else, so any other admitted tag would come back from the
    round trip RELABELLED -- a DATE32 column emerging as INT32. The output
    schema is part of the answer, so that is a wrong answer, not a cosmetic one.
    """
    if at == ArrowType.INT32:
        return DType.int32
    if at == ArrowType.INT64:
        return DType.int64
    if at == ArrowType.FLOAT32:
        return DType.float32
    if at == ArrowType.FLOAT64:
        return DType.float64
    return DTYPE_NONE


def selection_admits(imm base: Column[HeapRegion]) -> Bool:
    """True iff `base` may be served through a selection column.

    Every clause is a case the layout would answer WRONGLY rather than refuse;
    the file header states each one. A `False` here is a fallback to the gather,
    never an error.
    """
    var vdt = selection_value_dtype(base.arrow_type)
    if vdt == DTYPE_NONE:
        return False
    if base._validity.__bool__() or base._null_count != 0:
        return False
    if base._length < 0 or base._offset < 0:
        return False
    # The value buffer must cover the base's OWN ROW WINDOW,
    # `[_offset, _offset + _length)` -- NOT `[0, _length)`. A sliced base is
    # admitted (its offset is honoured by narrowing the `_dict_data` share to
    # exactly this window), so the bound that matters is the window's END. The
    # codes are not bounds-checked by this path, so a short buffer reads out of
    # bounds instead of raising; this is also the precondition
    # `share_range_as` would otherwise raise on inside `make_selection_column`.
    var vw = 4 if (vdt == DType.int32 or vdt == DType.float32) else 8
    if base._data.len() < (base._offset + base._length) * vw:
        return False
    return True


def make_selection_column(
    imm base: Column[HeapRegion],
    imm codes: SharedAlignedBuffer[HeapRegion],
    code_byte_width: Int,
    n_rows: Int,
) raises -> Column[HeapRegion]:
    """Bind `codes` to `base` as a selection column: `out[r] == base[codes[r]]`.

    `base[c]` IS THE BASE'S OWN ROW `c`, i.e. `base._data[base._offset + c]`.
    A SLICED base is admitted and its `_offset` is honoured, because
    `_dict_data` is narrowed to the base's row window rather than shared whole
    -- see the file header for why the offset is carried by the share's EXTENT
    and not folded into `codes` (one code buffer serves columns whose bases may
    carry DIFFERENT offsets).

    NO BYTES ARE COPIED. `_dict_data` is an Arc share of `base._data` narrowed
    to `[_offset, _offset + _length)` (which is what pins the base for the
    result's lifetime) and `_data` is an Arc share of the caller's code buffer
    -- so ONE code buffer serves every probe column of a chunk, which is the
    whole point of sharing it in rather than building it here.

    THE CODES ARE READ FROM THEIR OWN ELEMENT 0. The returned column carries
    `offset=0`, and `dict_code_at(r)` reads `_data` at `_offset + r`, so the
    code stream starts at `codes`'s own window start -- which is what the
    length check below bounds. A caller handing in a code buffer that is itself
    a sub-window is therefore served correctly: `SharedAlignedBuffer.get_typed`
    is window-relative.

    Args:
        base: The column the codes select from. Must satisfy `selection_admits`.
        codes: The per-row selection indices, `n_rows` entries of
            `code_byte_width` bytes. The join's own match-index buffer.
        code_byte_width: 4 (Int32 codes) or 8 (Int64 codes).
        n_rows: Rows this column carries.

    Returns:
        A `DICTIONARY` Column with `is_numeric_dict()` True.

    Raises:
        Error when `base` is refused by `selection_admits`, when
        `code_byte_width` is neither 4 nor 8, or when `codes` is too short for
        `n_rows`. Each is a producer bug, and the alternative to raising is an
        out-of-bounds read behind a correct-looking row count.
    """
    if code_byte_width != 4 and code_byte_width != 8:
        raise Error(
            "make_selection_column: code_byte_width must be 4 or 8, got "
            + String(code_byte_width)
        )
    if n_rows < 0 or codes.len() < n_rows * code_byte_width:
        raise Error(
            "make_selection_column: code buffer holds "
            + String(codes.len())
            + " bytes but "
            + String(n_rows)
            + " rows at "
            + String(code_byte_width)
            + " bytes each need "
            + String(n_rows * code_byte_width)
        )
    var vdt = selection_value_dtype(base.arrow_type)
    if vdt == DTYPE_NONE or not selection_admits(base):
        raise Error(
            "make_selection_column: base column ("
            + String(base.arrow_type)
            + ", offset="
            + String(base._offset)
            + ", nullable="
            + String(base._validity.__bool__())
            + ") is not selection-admissible; the caller must gate on"
            " `selection_admits`."
        )
    var vw = 4 if (vdt == DType.int32 or vdt == DType.float32) else 8
    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=codes.share(),
        offsets=Optional[SharedAlignedBuffer[HeapRegion]](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=n_rows,
        null_count=0,
        offset=0,
    )
    # THE SHARE IS NARROWED TO THE BASE'S ROW WINDOW, NOT THE WHOLE BUFFER.
    # `dict_value_*(code)` indexes `_dict_data` from ITS element 0, so a
    # window starting at `base._offset` is what makes `base[codes[r]]` mean
    # base row `codes[r]` for a SLICED base -- the same address
    # `_gather_fixed_into_range` computes as `src_col[_offset + idx[i]]`.
    # The extent is exact (`_dict_size * vw`), which keeps `get_typed`'s bound
    # equal to the base's last row. `selection_admits` already proved the
    # window is inside the buffer, so this does not raise for an admitted base.
    col._dict_data = Optional(
        base._data.share_range_as[HeapRegion](
            base._offset * vw, base._length * vw
        )
    )
    col._dict_size = base._length
    col._dict_index_byte_width = code_byte_width
    col._dict_value_dtype = vdt
    return col^


@always_inline
def selection_index_arrow_type(code_byte_width: Int) raises -> ArrowType:
    """The `Field.dictionary` index tag for a `code_byte_width`-byte code."""
    if code_byte_width == 4:
        return ArrowType.INT32
    if code_byte_width == 8:
        return ArrowType.INT64
    raise Error(
        "selection_index_arrow_type: code_byte_width must be 4 or 8, got "
        + String(code_byte_width)
    )


def batch_carries_selection(imm batch: RecordBatch) -> Bool:
    """True iff any column of `batch` is a selection (numeric-dictionary)
    column. The identity test the flatten uses to stay free on the OFF arm."""
    for c in range(batch.num_columns()):
        if batch.column_at(c).is_numeric_dict():
            return True
    return False


def flatten_selection_batch(
    imm batch: RecordBatch, imm flat_schema: Schema
) raises -> RecordBatch:
    """THE EGRESS. Materialise every selection column of `batch` back to flat.

    `flat_schema` is the schema the FLAT result must carry -- the driver's own
    output schema, before the selection columns relabelled their fields to
    `DICTIONARY`. It is checked against every resolved column, so a producer
    that mislabelled one gets a named raise rather than a silently relabelled
    column.

    A non-selection column is Arc-SHARED, not copied: flattening a batch that
    carries no selection column is a refcount bump per column and no byte
    movement, which is what makes an unconditional call at the boundary safe.
    """
    var n = batch.num_columns()
    if flat_schema.num_columns() != n:
        raise Error(
            "flatten_selection_batch: batch has "
            + String(n)
            + " columns but the flat schema declares "
            + String(flat_schema.num_columns())
        )
    var builder = RecordBatchBuilder.with_capacity(n)
    for c in range(n):
        ref col = batch.column_at(c)
        var want = flat_schema.field_arrow_type(c)
        if col.is_numeric_dict():
            var flat = col.resolve_numeric_dict_to_flat()
            if flat.arrow_type != want:
                raise Error(
                    "flatten_selection_batch: column "
                    + String(c)
                    + " ('"
                    + flat_schema.field_name(c)
                    + "') resolved to "
                    + String(flat.arrow_type)
                    + " but the flat schema declares "
                    + String(want)
                    + " -- the selection column was built over a base whose"
                    " tag the flat schema does not describe."
                )
            builder.add_column(flat^)
        else:
            if col.arrow_type != want:
                raise Error(
                    "flatten_selection_batch: column "
                    + String(c)
                    + " ('"
                    + flat_schema.field_name(c)
                    + "') carries "
                    + String(col.arrow_type)
                    + " but the flat schema declares "
                    + String(want)
                )
            builder.add_column(col.share())
    return builder.build(flat_schema.copy())


def flatten_selection_table(
    var table: Table, imm flat_schema: Schema
) raises -> Table:
    """`flatten_selection_batch` over every chunk, preserving chunk order.

    IDENTITY WHEN NOTHING IS SELECTION-BACKED. The table is returned untouched
    when no chunk carries a selection column, so an unconditional call at the
    engine boundary costs one tag read per column on the OFF arm -- not a
    rebuild, and not a copy.
    """
    var any_sel = False
    for i in range(table.num_chunks()):
        if batch_carries_selection(table.chunks()[i]):
            any_sel = True
            break
    if not any_sel:
        # Nothing to materialise: hand the table straight back. Its OWN schema
        # is authoritative here, NOT `flat_schema` -- an OFF-arm table may
        # legitimately carry a shape this function was never asked to describe
        # (the 0-column `count_only` carrier), and substituting a schema it does
        # not have would make `from_chunks` raise on a healthy result.
        return table^
    var chunks = table.take_chunks()
    var out = List[RecordBatch](capacity=len(chunks))
    for i in range(len(chunks)):
        out.append(flatten_selection_batch(chunks[i], flat_schema))
    _ = chunks^
    _ = table^
    return Table.from_chunks(out^, flat_schema.copy())
