# =============================================================================
# excel_error_code.mojo — the Excel error-value code space (SHARED, core-owned)
# =============================================================================
#
# This is the SINGLE SOURCE OF TRUTH for Excel error codes.
#
# The numbering is shared with the Excel formula layer's scalar tagged value
# (`FormulaValue`), so:
#   (a) the scalar-path tagged value and
#   (b) this columnar 3-state status lane + sparse code sidecar
# share ONE code space and the scalar<->columnar boundary is a 1:1 code copy
# (no re-encoding). The formula layer re-exports from here:
#   `from komira_plan_expr.excel_error_code import *`.
#
# SCOPE (this file): the code space + the TYPE SUBSTRATE for the columnar
# carrier (3-state status constants + the sparse sidecar struct SHAPE). The
# error-DOMINANT propagation ALGEBRA (AND/OR/compare/aggregate dominance) is
# NOT here — it belongs to the formula layer (a separate kernel family).
# Wiring the status lane + sidecar THROUGH Column/RecordBatch/breakers is not
# done yet.
#
# Encapsulation: no UnsafePointer anywhere. POD UInt8 codes +
# List-backed sparse storage + value helpers.
# =============================================================================


# --- The code space. 0 = "not an error" (a valid value). ---
comptime XL_ERR_NONE: UInt8 = 0
comptime XL_ERR_DIV0: UInt8 = 1       # #DIV/0!
comptime XL_ERR_NA: UInt8 = 2         # #N/A
comptime XL_ERR_VALUE: UInt8 = 3      # #VALUE!
comptime XL_ERR_REF: UInt8 = 4        # #REF!
comptime XL_ERR_NAME: UInt8 = 5       # #NAME?
comptime XL_ERR_NUM: UInt8 = 6        # #NUM!
comptime XL_ERR_NULL: UInt8 = 7       # #NULL!
comptime XL_ERR_SPILL: UInt8 = 8      # #SPILL!   (dynamic-array collision)
comptime XL_ERR_CALC: UInt8 = 9       # #CALC!    (empty dynamic array)
comptime XL_ERR_CIRCULAR: UInt8 = 10  # circular reference (recalc layer — deferred)


# --- The columnar 3-state STATUS lane. ---
# A straightforward widening of the 1-bit validity bitmap: a value column's
# per-row status is VALID / NULL / ERROR. The error CODE (when ERROR) lives in
# the sparse sidecar below, because errors are rare in real sheets.
comptime STATUS_VALID: UInt8 = 0
comptime STATUS_NULL: UInt8 = 1
comptime STATUS_ERROR: UInt8 = 2


@always_inline
def _write_excel_error_text[W: Writer](mut writer: W, code: UInt8):
    """WRITE what `excel_error_text` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a
    shared library can bind such a pair CROSSED and crash the host
    interpreter."""
    if code == XL_ERR_DIV0:
        writer.write(String("#DIV/0!"))
        return
    if code == XL_ERR_NA:
        writer.write(String("#N/A"))
        return
    if code == XL_ERR_VALUE:
        writer.write(String("#VALUE!"))
        return
    if code == XL_ERR_REF:
        writer.write(String("#REF!"))
        return
    if code == XL_ERR_NAME:
        writer.write(String("#NAME?"))
        return
    if code == XL_ERR_NUM:
        writer.write(String("#NUM!"))
        return
    if code == XL_ERR_NULL:
        writer.write(String("#NULL!"))
        return
    if code == XL_ERR_SPILL:
        writer.write(String("#SPILL!"))
        return
    if code == XL_ERR_CALC:
        writer.write(String("#CALC!"))
        return
    if code == XL_ERR_CIRCULAR:
        writer.write(String("#CIRCULAR!"))
        return
    writer.write(String("#ERR?"))
    return


@always_inline
def excel_error_text(code: UInt8) -> String:
    """The Excel display text for an error code (for messages + golden tests).

    Returns "#ERR?" for an unrecognized code.
    """
    var out = String()
    _write_excel_error_text(out, code)
    return out^


@always_inline
def excel_error_code_from_literal(text: String) -> UInt8:
    """Map an error LITERAL as written in a formula (`#DIV/0!`, `#N/A`, ...) to
    its code. Every code with an Excel literal has an arm (nine: all but
    XL_ERR_NONE and XL_ERR_CIRCULAR), so literal -> code -> text is the
    identity. Returns XL_ERR_NAME for an unrecognized `#...` token (Excel treats
    an unknown `#name` as a name error)."""
    if text == String("#DIV/0!"):
        return XL_ERR_DIV0
    if text == String("#N/A"):
        return XL_ERR_NA
    if text == String("#VALUE!"):
        return XL_ERR_VALUE
    if text == String("#REF!"):
        return XL_ERR_REF
    if text == String("#NAME?"):
        return XL_ERR_NAME
    if text == String("#NUM!"):
        return XL_ERR_NUM
    if text == String("#NULL!"):
        return XL_ERR_NULL
    if text == String("#SPILL!"):
        return XL_ERR_SPILL
    if text == String("#CALC!"):
        return XL_ERR_CALC
    # XL_ERR_CIRCULAR has no literal: Excel reports a circular reference as a
    # warning, not as an error value a formula can carry.
    return XL_ERR_NAME


struct SparseErrorSidecar(Movable, Copyable):
    """The sparse row-indexed error-code sidecar for a
    columnar value column (the TYPE SUBSTRATE, not the propagation algebra).

    Errors are rare, so the code is NOT stored densely per row: instead a
    sorted parallel-list run of `(row_idx, code)` pairs records only the rows
    whose 3-state status is STATUS_ERROR. A row absent from the run is either
    STATUS_VALID or STATUS_NULL (that distinction lives on the existing
    validity bitmap / the 3-state status lane, not here).

    This is a POD-ish carrier (two Lists, no pointers) that composes with the
    existing columnar machinery. Threading it THROUGH Column / RecordBatch /
    the agg-join-sort breakers so a grouped/joined error keeps its code — and
    the error-DOMINANT merge kernels that consume it — are not done. This
    struct only fixes the SHAPE the boundary is a 1:1 copy into."""

    # Kept sorted-ascending by row index (append in row order; callers that
    # build out of order can sort). Parallel arrays: rows[i] carries codes[i].
    var rows: List[Int]
    var codes: List[UInt8]

    def __init__(out self):
        """Empty sidecar — no error rows."""
        self.rows = List[Int]()
        self.codes = List[UInt8]()

    def copy(self) -> Self:
        var s = Self()
        s.rows = self.rows.copy()
        s.codes = self.codes.copy()
        return s^

    @always_inline
    def is_empty(self) -> Bool:
        """True if no row carries an error code."""
        return len(self.rows) == 0

    @always_inline
    def num_errors(self) -> Int:
        """The count of error rows recorded."""
        return len(self.rows)

    def set_error(mut self, row: Int, code: UInt8):
        """Record `row` as STATUS_ERROR carrying `code`. Appends a (row, code)
        pair; the caller is responsible for not double-recording a row (the
        sparse run allows duplicates — dedup/sort is a build-time concern)."""
        self.rows.append(row)
        self.codes.append(code)

    def code_for(self, row: Int) -> UInt8:
        """The error code for `row`, or XL_ERR_NONE if `row` is not an error
        row. Linear scan — errors are rare, so the run is short; a sorted
        binary search is a later optimization if a column is error-dense."""
        for i in range(len(self.rows)):
            if self.rows[i] == row:
                return self.codes[i]
        return XL_ERR_NONE
