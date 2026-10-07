# =============================================================================
# row_builder.mojo — `_build_row[R]` / `_build_row_n[R]`: the generic UDF
#                    row constructors (arity 1 from a cell; arity N from a batch)
# =============================================================================
#
# WHY THE ENGINE BUILDS THE ROW
# -----------------------------
# The typed UDF traits expose ONE oracle each, a named-row method
# (`MapFn.run_row` / `FilterFn.keep_row`). Mojo cannot reach a struct's
# `@fieldwise_init`-synthesized positional constructor through trait
# dispatch, so the engine cannot write `F.InRow(c0.get(i), ...)`. Comptime
# reflection over `R` gives the field offsets instead, so the engine builds
# `R` itself and calls the row oracle directly. There is deliberately no
# positional heterogeneous-variadic "scalar oracle" alongside it — a parallel
# API rots, and it would cost every conformer a duplicated body and every
# reader the question of which of the two is authoritative.
#
# What the row-oracle-only shape allows:
#   * FALLIBLE UDFs. A `raises` variadic het-pack method is not merely
#     awkward, it CRASHES the 1.0.0 compiler; `run_row` is `raises` without
#     incident.
#   * STRING (and multi-column) OUTPUT. A variadic scalar oracle is pinned
#     to `-> Scalar[Self.OutType]` by its own shape; `run_row` is free to
#     return a row struct.
#   * The ROW-ORIENTED user surface, whose whole premise is that
#     the engine speaks rows.
#
# =============================================================================
# ⚠ TWO RESIDUES THIS FILE EXISTS TO CONTAIN — BOTH INVISIBLE ON arm64
# =============================================================================
#
# 1. ALIGNMENT. The blob MUST be `InlineArray[R, 1]`, never
#    `InlineArray[UInt8, size_of[R]()]`. The byte-array spelling declares
#    ALIGNMENT 1 for a row that needs 8; arm64 executes the unaligned store
#    silently and correctly, so NO test on an Apple-silicon box can catch
#    it, and it faults (or tears) on linux-x86-64. Measured, on this exact
#    pair of spellings:
#        align_of[InlineArray[UInt8, size_of[Order]()]] = 1
#        align_of[InlineArray[Order, 1]]                = 8
#    `InlineArray[R, 1]` gets both size AND alignment from R, by type.
#
# 2. DESTRUCTION OF BYTES THAT WERE NEVER CONSTRUCTED. The slot is
#    `uninitialized=True` and every field is written with `unsafe_write`.
#    It is NEVER zero-filled and never assigned through `[] =`: an
#    assignment runs R's destructor over whatever was in the slot first,
#    which is harmless for an F64/I64 row and a DOUBLE FREE the moment a
#    row field owns a heap allocation (a `String` input field is exactly
#    where this lands next).
#    The invariant that makes the copy-out sound is that EVERY field is
#    written before the slot is read — enforced below by construction: the
#    single field is written unconditionally, and an unsupported field type
#    is a `comptime assert` COMPILE ERROR, never a skipped store.
#
# =============================================================================
# TWO BUILDERS — `_build_row` (ARITY 1, from a CELL) and `_build_row_n`
#                (ARITY N, from a BATCH VIEW)
# =============================================================================
#
# `_build_row` builds a ONE-FIELD row from ONE typed cell, because that is
# the entire input surface the four cell-bound call-site adapters have: each
# is parameterised by a single bound input column (`col0` / `COL_OFFSET` /
# `col_idx`) and each documents "SCOPE — ARITY=1 INPUT". There is no
# column MAP to read a second field through, so its arity-1 assert stays and
# stays MEANINGFUL: a 2-field `InRow` reaching a cell-bound adapter is a
# COMPILE ERROR naming the mismatch (a variadic oracle would instead compile
# and read `vals[1]` off the end of a 1-element pack at run time). ⛔ DO NOT relax that assert to make an arity-N row fit —
# the adapter genuinely cannot supply field 1.
#
# `_build_row_n` is the sibling arm for adapters whose binding is a column
# MAP: it walks `reflect[R]`'s fields against it. The map is NOT a guess: the row-UDF SDK surface sets the SCAN PROJECTION to `reflect[R]`'s
# field names IN DECLARED ORDER (`row_udf.row_projection[R]()`), so the
# batch handed here has field k at column k BY CONSTRUCTION. That is why
# `_build_row_n` takes a `BatchView` and an index instead of cells: the
# adapter that calls it binds N columns, not one, and the identity of the
# k-th is fixed by the projection the same module authored.
#
# ⚠ THE POSITIONAL BINDING IS A CONTRACT WITH THE PROJECTION, NOT A GUESS
# ABOUT SCHEMA ORDER. Handed a batch whose columns are in any other order,
# `_build_row_n` reads the wrong column and reports nothing — a numeric
# column of the right dtype at the wrong index is indistinguishable from
# the right one. The SDK seam that authors the projection is the ONLY
# sanctioned caller; a caller that cannot author the projection must
# resolve the column indices itself and use a different builder.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in the signature — `_build_row` takes a typed
#     scalar and returns a typed value. The pointer arithmetic is confined
#     to this function body, over a blob it owns for the length of one
#     call.
#   - NO wildcard origins (`MutAnyOrigin` / `ImmutAnyOrigin` /
#     `MutExternalOrigin`). The blob pointer's origin is the local slot's.
#   - NO `unsafe_from_address=Int(...)`.
#   - NON-RAISING. A new `raise` here would ripple to every transitive
#     caller of the per-row path.
# =============================================================================


from komira_arrow.batch_view import BatchView


@always_inline
def _build_row[R: Copyable & Movable & Deinitable, dt: DType](
    v: Scalar[dt]
) -> R:
    """Build the UDF input row `R` from the single typed cell `v`.

    The engine's per-row replacement for the deleted positional variadic
    oracle: read the bound input column with the caller's existing typed
    accessor, hand the scalar here, then call `run_row` / `keep_row` on
    the result.

    Parameters:
        R: The UDF's `InRow` struct — exactly one field, whose type is
           `Scalar[dt]`. Both facts are comptime-asserted below.
        dt: The DType of the input cell (inferred from `v`).

    Args:
        v: The input cell value for this row.

    Returns:
        An `R` whose single field holds `v`.
    """
    comptime r = reflect[R]

    comptime assert r.field_count() == 1, (
        "_build_row: the UDF input row must have exactly ONE field — the"
        " four per-row adapters bind exactly one input column (col0 /"
        " COL_OFFSET / col_idx) and cannot supply a second. A"
        " multi-column UDF needs the adapters' column binding to become a"
        " column MAP first; see this module's SCOPE note."
    )

    comptime ts = r.field_types()
    comptime assert ts[0] == Scalar[dt], (
        "_build_row: the UDF input row's field type does not match the"
        " input column DType. The engine derives the cell DType from"
        " `F.InputSchema.cols[0].dtype`; declare an `InRow` whose field"
        " has that exact type (or fix `InputSchema`). Under the deleted"
        " variadic oracle this mismatch compiled and `rebind` reinterpreted"
        " the bytes — a silent wrong value."
    )

    # RESIDUE 1 (alignment): InlineArray[R, 1] carries R's align, not 1.
    # RESIDUE 2 (destruction): uninitialized + unsafe_write, never `[] =`.
    var slot = Array[R, 1](uninitialized=True)
    var base = slot.unsafe_ptr().unsafe_bitcast[UInt8]()
    comptime off = r.field_offset[index=0]()
    base.unsafe_offset(off).unsafe_bitcast[Scalar[dt]]().unsafe_write(v)
    return base.unsafe_bitcast[R]()[].copy()


# =============================================================================
# `_build_row_n` — the ARITY-N sibling arm
# =============================================================================


def _row_field_dtype[T: AnyType]() -> DType:
    """The `DType` of a row field's Mojo type.

    Allow-list, never a deny-list: an unmapped type is a `comptime assert`
    COMPILE ERROR, not a plausible default. That matters more here than in
    the schema derivation next door (`schema_descriptor._dtag_for`, which
    returns `DT_UNKNOWN` for an unmapped type): a wrong DType here is a
    typed WRITE into the row blob, i.e. a silent wrong value, where a wrong
    schema tag is caught downstream by `dtag_to_dtype`.
    """
    comptime if (T == Int8):
        return DType.int8
    elif (T == Int16):
        return DType.int16
    elif (T == Int32):
        return DType.int32
    elif (T == Int64):
        return DType.int64
    elif (T == UInt8):
        return DType.uint8
    elif (T == UInt16):
        return DType.uint16
    elif (T == UInt32):
        return DType.uint32
    elif (T == UInt64):
        return DType.uint64
    elif (T == Float32):
        return DType.float32
    elif (T == Float64):
        return DType.float64
    else:
        comptime assert False, (
            "_row_field_dtype: this row field's type is not a fixed-width"
            " numeric. The row-UDF surface covers the integer and float"
            " widths only; a String / Bool / Decimal field is not"
            " representable in the row blob yet (see the row-UDF surface"
            " module for what a String field would additionally need — an"
            " owning field also invalidates RESIDUE 2's never-destroy"
            " invariant)."
        )


@always_inline
def _build_row_n[
    R: Copyable & Movable & Deinitable, bo: Origin[mut=False]
](batch: BatchView[bo], i: Int) -> R:
    """Build the arity-N UDF input row `R` from row `i` of `batch`.

    Field `k` of `R` is read from batch COLUMN `k`. That positional binding
    is a contract with the projection the SDK row-UDF seam authors from
    `reflect[R].field_names()` — see this module's TWO BUILDERS note. It is
    NOT an assumption about the file's schema order.

    Parameters:
        R: The UDF's row struct. Every field must be a fixed-width numeric
           (`_row_field_dtype` is a comptime assert otherwise).
        bo: The (immutable) origin of the batch view.

    Args:
        batch: The morsel's batch view, projected to `R`'s fields in order.
        i: The logical row index within the batch.

    Returns:
        An `R` whose field `k` holds `batch` column `k`'s value at row `i`.
    """
    comptime r = reflect[R]
    comptime ts = r.field_types()

    comptime assert r.field_count() >= 1, (
        "_build_row_n: the UDF row struct has NO fields. A zero-column row"
        " reads nothing and every instance is identical, so a predicate or"
        " map over it is a constant — declare the columns the function"
        " actually reads."
    )

    # RESIDUE 1 (alignment): `InlineArray[R, 1]` carries R's align, not 1.
    #   `InlineArray[UInt8, size_of[R]()]` declares alignment 1 for a row
    #   that needs 8. arm64 executes the unaligned store silently; linux
    #   x86-64 does not. Measured on this exact pair:
    #     align_of[InlineArray[Order, 1]]                = 8
    #     align_of[InlineArray[UInt8, size_of[Order]()]] = 1
    # RESIDUE 2 (destruction): `uninitialized=True` + `unsafe_write` per
    #   field, never `[] =` (which would run R's destructor over
    #   uninitialised bytes). The invariant that makes the copy-out sound
    #   is that EVERY field is written before the slot is read — enforced
    #   by construction: the `comptime for` covers every field and an
    #   unsupported field type is a COMPILE ERROR in `_row_field_dtype`,
    #   never a skipped store.
    var slot = Array[R, 1](uninitialized=True)
    var base = slot.unsafe_ptr().unsafe_bitcast[UInt8]()
    comptime for k in range(r.field_count()):
        comptime off = r.field_offset[index=k]()
        comptime dt = _row_field_dtype[ts[k]]()
        base.unsafe_offset(off).unsafe_bitcast[Scalar[dt]]().unsafe_write(
            batch.col_scalar_nonraising[dt](k, i)
        )
    return base.unsafe_bitcast[R]()[].copy()


@always_inline
def _read_row_field[
    O: Copyable & Movable, k: Int, dt: DType
](o: O) -> Scalar[dt]:
    """Read field `k` of the row `o` as a `Scalar[dt]`.

    `reflect` exposes field COUNT, NAMES, TYPES and OFFSETS but no field
    VALUE accessor in Mojo 1.0.0 (eight spellings were tried; none compiles). Reading by offset is therefore the route, not a
    shortcut around a supported API.

    Encapsulation: the pointer is derived from a `ref` to the caller's own
    live local and never leaves this body — no `UnsafePointer` appears in
    the signature.
    """
    comptime off = reflect[O].field_offset[index=k]()
    # SAFETY: `off` is `reflect[O]`'s own offset for field k, `dt` is that
    # field's own DType (the single caller derives both from the same
    # `reflect[O]`), and `o` is live for the duration of the read.
    return (
        UnsafePointer(to=o)
        .unsafe_bitcast[UInt8]()
        .unsafe_offset(off)
        .unsafe_bitcast[Scalar[dt]]()[]
    )
