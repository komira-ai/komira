# =============================================================================
# varlen_width_guard.mojo — the fixed-width FALLTHROUGH, made LOUD.
# =============================================================================
#
# THE DEFECT SHAPE THIS FILE EXISTS TO KILL
# -----------------------------------------
# A per-column dispatcher of this shape appears all over the tree:
#
#     if at == ArrowType.STRING or at == ArrowType.BINARY:
#         ... variable-length arm: copy offsets + payload ...
#     if at == ArrowType.DICTIONARY:
#         ... dictionary arm ...
#     # Fixed-width primitives: just concat/copy the data buffer.
#     var byte_width = _some_byte_width(at)        # else: return 8  # fallback
#     ... copy `length * byte_width` bytes; build Column(offsets=None) ...
#
# Every Arrow type that is NOT named by an arm above falls into that final
# fixed-width arm. For a type that carries an OFFSETS buffer or CHILDREN,
# that is not a truncation and not a wrap — it is a REINTERPRET:
#
#   * the payload buffer (UTF-8 text, or child values) is read as though it
#     were `length * 8` bytes of fixed-width cells,
#   * the offsets buffer is DROPPED (`offsets=None`),
#   * the children are DROPPED,
#   * `arrow_type` is faithfully copied onto the output, so the result still
#     CLAIMS to be a LARGE_STRING / LIST / STRUCT,
#   * and `length` is exactly right — so a row-count assertion passes clean.
#
# It is also an unbounded heap OVERREAD in the common direction: 1000 rows of
# 3-byte strings hold 3000 payload bytes, and the fixed-width arm reads
# 1000 * 8 == 8000 of them. Whether that overread faults is a fact about arena
# layout on the day, NOT a fact about whether the input was accepted — which
# is precisely why this guard asserts REJECTION rather than relying on a crash.
#
# FOUR LOCAL FIXES OF THE SAME DEFECT
# ----------------------------------
#   * DECIMAL128 / DECIMAL256 / INTERVAL_MONTH_DAY_NANO — fixed ONLY in
#     `copy_column_ref.mojo`
#     (`_elem_byte_width`, see its docstring: "silently truncated each row to
#     8 bytes").
#   * DICTIONARY — fixed ONLY in `komira_morsel` (see the
#     `_slice_dictionary` arm's comment: "Without this branch the DICTIONARY
#     column hits the 8-byte fixed-width fallback, which reads past the int32
#     index buffer and drops _dict_data / _dict_size entirely").
#   * LARGE_STRING / LARGE_BINARY — fixed ONLY in
#     `helpers/compiler_helpers.mojo:_copy_column` (see its
#     comment: "this fell into the else: fixed-width branch —
#     element_size(at) returned the 8-byte default fallback, the data buffer
#     was sized as `num_rows * 8`, and the resulting column had NO offsets").
#
# Three separate discoveries of ONE defect, each patched in the single file
# where someone happened to notice it, and never swept to its siblings. This
# module is the sweep: a single predicate + a single named error, called from
# every fixed-width fallthrough, so the NEXT type added to `ArrowType` fails
# loudly at the fallthrough instead of silently reinterpreting buffers.
#
# WHY A PREDICATE AND NOT A WIDER BYTE-WIDTH TABLE
# ------------------------------------------------
# Adding LARGE_STRING to a byte-width table is the wrong fix: there IS no byte
# width for it. The bug is not "the table lacks an entry", it is "a type that
# cannot be copied by byte-stride reached a byte-stride copier". So the guard
# names the CLASS (carries offsets / carries children) rather than enumerating
# the types that are safe — a new offset-carrying type is caught by default.
# =============================================================================

from komira_arrow.arrow_types import ArrowType


@always_inline
def carries_offsets(at: ArrowType) -> Bool:
    """Does a column of this type carry a separate OFFSETS buffer?

    These are the Arrow variable-length layouts. A byte-stride copy of the
    data buffer alone loses the offsets and produces an unreadable column.

    Args:
        at: The Arrow type to classify.

    Returns:
        True if a column of this type has a meaningful `_offsets` buffer.
    """
    return (
        at == ArrowType.STRING
        or at == ArrowType.BINARY
        or at == ArrowType.LARGE_STRING
        or at == ArrowType.LARGE_BINARY
        or at == ArrowType.LIST
        or at == ArrowType.LARGE_LIST
        or at == ArrowType.MAP
    )


@always_inline
def offset_width_bytes(at: ArrowType) -> Int:
    """Byte width of ONE entry in this type's offsets buffer, else 0.

    4 for the Int32-offset layouts (STRING / BINARY / LIST / MAP), 8 for the
    Int64-offset layouts (LARGE_STRING / LARGE_BINARY / LARGE_LIST), 0 for a
    type that carries no offsets at all.

    Args:
        at: The Arrow type to classify.

    Returns:
        4, 8, or 0.
    """
    if (
        at == ArrowType.LARGE_STRING
        or at == ArrowType.LARGE_BINARY
        or at == ArrowType.LARGE_LIST
    ):
        return 8
    if carries_offsets(at):
        return 4
    return 0


@always_inline
def offset_width_bytes_or_raise(site: StaticString, at: ArrowType) raises -> Int:
    """Offsets width for `at` — 4 or 8. RAISES rather than returning 0.

    THE READ-SITE ENTRY POINT. `offset_width_bytes` is a pure CLASSIFIER and
    its 0 return is load-bearing for two existing consumers (the
    "carries children" arm of `arrow_fixed_width_fallthrough` below, and the
    guard's own regression test), so it must keep returning 0. A site that is
    about to READ an offsets buffer has no such use for 0: it must pick a
    stride, and defaulting the unknown case to 4 is exactly the silent
    reinterpretation this module exists to prevent (a
    LARGE_STRING column's Int64 offsets read at Int32 stride produced wrong
    GROUP BY groups with a correct row count and no raise).

    Args:
        site: The dispatcher about to read offsets (`"column_stats"`).
        at: The Arrow type of the column being read.

    Returns:
        4 for the Int32-offset layouts, 8 for the Int64-offset layouts.

    Raises:
        If `at` carries no offsets buffer, so no width is correct.
    """
    var ow = offset_width_bytes(at)
    if ow == 0:
        raise Error(
            String("ArrowVarlenOffsetWidthUnknown: ")
            + String(site)
            + String(" is about to read an offsets buffer for arrow_type=")
            + String(at)
            + String(
                ", which carries no offsets buffer. There is no correct"
                " stride for it: reading its data buffer at either width"
                " would REINTERPRET those bytes and emit wrong values with"
                " an exactly-correct row count."
            )
        )
    return ow


def arrow_offsets_buffer_undersized(
    site: StaticString,
    at: ArrowType,
    index: Int,
    length: Int,
    have_bytes: Int,
    need_bytes: Int,
) -> Error:
    """Build the named `ArrowOffsetsBufferUndersized` error. COLD path only.

    Args:
        site: The site that checked (`"RecordBatchBuilder.build"`).
        at: The type tag the column CLAIMS.
        index: Column index within the batch, or -1 when there is none.
        length: The column's row count.
        have_bytes: Bytes the offsets buffer actually holds.
        need_bytes: Bytes a column of `length` rows of `at` must hold.

    Returns:
        An `Error` naming the tag, the two byte counts, and the width the
        tag claims.
    """
    var where: String
    if index < 0:
        where = String()
    else:
        where = String(" at column index ") + String(index)
    return Error(
        String("ArrowOffsetsBufferUndersized: ")
        + String(site)
        + where
        + String(" holds a column TAGGED ")
        + String(at)
        + String(" (which claims Int")
        + String(offset_width_bytes(at) * 8)
        + String(" offsets, i.e. (")
        + String(length)
        + String(" + 1) * ")
        + String(offset_width_bytes(at))
        + String(" == ")
        + String(need_bytes)
        + String(" bytes) over an offsets buffer of only ")
        + String(have_bytes)
        + String(
            " bytes. The TAG IS A LIE ABOUT THE BUFFERS. Reading this column"
            " through the accessor its tag selects strides past the end of"
            " the buffer — an unbounded heap OVERREAD whose row COUNT stays"
            " exactly correct, so no row-count check can see it. Nothing"
            " downstream re-derives the width from the buffer, so this is"
            " the last place the two halves are both in hand: the producer"
            " that stamped this tag must either emit a real Int"
            + String(offset_width_bytes(at) * 8)
            + " offsets buffer or stamp the narrow tag."
        )
    )


@always_inline
def check_offsets_buffer_width(
    site: StaticString,
    at: ArrowType,
    index: Int,
    length: Int,
    have_bytes: Int,
) raises:
    """Raise if a column's offsets buffer is too small for the width its TAG
    claims. O(1), branch-only; call once per column.

    ★ WHY A SIZE CHECK IS THE ONLY HONEST ONE, AND WHY IT IS ONE-DIRECTIONAL.
    A type tag is the *only* thing that tells a reader whether to stride the
    offsets buffer by 4 or by 8, and every tag-vs-tag guard in this tree
    (`layouts_conflict`, `_reject_layout_conflict`) compares one tag against
    ANOTHER TAG. Two tags that agree with each other and both disagree with
    the buffer therefore pass every one of them. This is the check that
    consults the buffer.

    It fires only on the UNDER-sized direction (a tag claiming Int64 offsets
    over a buffer sized for Int32), because that is the direction a size can
    prove. The reverse — a narrow tag over an over-sized buffer — is
    indistinguishable from the two legitimate shapes that produce exactly
    that: a SLICE that retains its parent's full offsets buffer, and any
    buffer padded up by an IPC / mmap producer. A guard that fired there
    would reject correct columns, so it does not fire there, and the honest
    statement of this function's coverage is: it proves a tag is a lie when
    the arithmetic says so, and is silent otherwise.

    Args:
        site: The site performing the check.
        at: The column's type tag.
        index: Column index within its batch, or -1 when there is none.
        length: The column's row count.
        have_bytes: `_offsets.value().len()` — the buffer's logical length.

    Raises:
        Error: named `ArrowOffsetsBufferUndersized`.
    """
    var ow = offset_width_bytes(at)
    if ow == 0:
        # Not an offsets-carrying type (or a DICTIONARY, whose `_offsets`
        # buffer is sized by dict_size and not by row count) — no invariant.
        return
    var need = (length + 1) * ow
    if have_bytes < need:
        raise arrow_offsets_buffer_undersized(
            site, at, index, length, have_bytes, need
        )


@always_inline
def dict_offset_width_bytes() -> Int:
    """Byte width of ONE entry in a DICTIONARY column's dict-value offsets: 4.

    THE STATED 4. `ArrowType.DICTIONARY` is deliberately NOT in
    `carries_offsets` — a dict column's `_offsets` buffer does not index ROWS,
    it indexes the DICTIONARY VALUES that `_dict_data` holds, so the
    row-offsets classifiers above have no answer for it and
    `offset_width_bytes_or_raise` correctly refuses it. But several read sites
    admit DICTIONARY in the same arm as STRING / LARGE_STRING and then stride
    that buffer, and before this function they did so via a bare literal `4`
    with the refusal branched around — an unasserted width at a read site,
    which is exactly the silent reinterpretation this module exists to
    prevent.

    THE EVIDENCE FOR 4, and it is a fact about the CONSTRUCTORS, not a wish:
    every `Column` dictionary constructor allocates the dict-value offsets as
    `(dict_size + 1) * 4` bytes and writes them as `Int32`
    (`column.mojo:from_dictionary`, `from_int64_dict_indices`,
    `from_numeric_dict`, `from_numeric_dict_codes_view`,
    `from_string_dict_codes_view`), and the Arrow C Data import refuses any
    dictionary VALUE format other than `"u"` (STRING, i.e. Int32 offsets) in
    `c_data_stream.mojo`. There is no path that produces a `"U"`-valued
    dictionary in-engine today.

    So this is a one-line function on purpose: its value is the DOCSTRING and
    the single name a future `large_string`-valued dictionary has to change.
    Call it at the read site instead of writing `4`; if it ever stops being
    4, every site that consults it is a compile-time-locatable list.

    Returns:
        4 — the width of one Int32 dict-value offset entry.
    """
    return 4


@always_inline
def carries_children(at: ArrowType) -> Bool:
    """Does a column of this type carry CHILD columns?

    A byte-stride copy of the parent's data buffer drops the children, which
    for these types is where all the values actually live.

    Args:
        at: The Arrow type to classify.

    Returns:
        True if a column of this type has child columns.
    """
    return (
        at.is_nested()
        or at == ArrowType.UNION_DENSE
        or at == ArrowType.UNION_SPARSE
    )


def arrow_fixed_width_fallthrough(
    site: StaticString,
    at: ArrowType,
    n_values: Int,
) -> Error:
    """Build the named `ArrowFixedWidthFallthrough` error. COLD path only.

    Args:
        site: Dispatcher that fell through (`"concat(pair-wise)"`).
        at: The Arrow type that reached the fixed-width arm.
        n_values: Number of values (rows) in the offending column.

    Returns:
        An `Error` naming the type, the site, the offsets width that would
        have been lost, and what the silent path would have produced.
    """
    var why: String
    var ow = offset_width_bytes(at)
    if ow != 0:
        why = (
            String("carries an Int")
            + String(ow * 8)
            + String(
                "-offsets buffer, which a fixed-width byte-stride copy drops"
                " (the output would have had offsets=None)"
            )
        )
    else:
        why = String(
            "carries child columns, which a fixed-width byte-stride copy"
            " drops (the output would have had no children)"
        )
    return Error(
        String("ArrowFixedWidthFallthrough: ")
        + String(site)
        + String(" reached its fixed-width arm with arrow_type=")
        + String(at)
        + String(" (")
        + String(n_values)
        + String(" rows), but that type ")
        + why
        + String(
            ". The fixed-width arm would have read n_rows*8 bytes from the"
            " payload buffer as if they were 8-byte cells — a REINTERPRET,"
            " not a truncation — and emitted a column still TAGGED with this"
            " type and with an exactly-correct row COUNT, so a row-count"
            " check would have passed. Add an explicit arm for this type to"
            " the dispatcher at the named site; do not add it to the"
            " byte-width table, because this type has no byte width."
        )
    )


@always_inline
def check_fixed_width_dispatch(
    site: StaticString,
    at: ArrowType,
    n_values: Int,
) raises:
    """Raise if `at` must not be handled by a fixed-width byte-stride path.

    Call this immediately before the fixed-width fallthrough arm of any
    per-column dispatcher, once per column. O(1), branch-only, off the
    per-element path.

    Args:
        site: Dispatcher performing the check.
        at: The Arrow type that reached the fixed-width arm.
        n_values: Number of values (rows) in the column.

    Raises:
        Error: named `ArrowFixedWidthFallthrough`, when `at` carries offsets
            or children.
    """
    if carries_offsets(at) or carries_children(at):
        raise arrow_fixed_width_fallthrough(site, at, n_values)
