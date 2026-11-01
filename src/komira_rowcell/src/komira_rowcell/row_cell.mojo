# =============================================================================
# row_cell.mojo — a typed table cell with VALUE EQUALITY. A zero-dep LEAF.
# =============================================================================
#
# `RowCell` is a small tagged union over the scalar kinds a CDC/table row cell
# can hold — boolean / int / long / float / double / string, plus a typed NULL.
# It is a plain owned-field struct (a `String` for the string arm, an `Int64` for
# the integral arms, a `Float64` for the float arms), so it is Copyable + Movable
# with NO pointer field.
#
# WHY IT IS ITS OWN LIBRARY: a small general-purpose type parked inside a large
# domain library makes everyone who wants the type pay for the library. A table
# format's row encode/decode genuinely needs its schema and file-format code,
# but a CDC change record and each provider client's value mapping want ONLY
# the cell model. If the cell lived inside the table-format writer, those
# consumers would pay for the ENTIRE writer (and through it the file formats
# and the query engine) to get a 6-arm scalar union.
#
# ⚠ EMPTY `deps` IS LOAD-BEARING, NOT INCIDENTAL. Anything added to this
# library's deps lands back in the closure of every CDC provider client — and,
# through them, in the control plane's. Keep it importing nothing but the Mojo
# stdlib. If you need a file format or a table schema here, you are writing the
# wrong file: put it in the consumer.
#
# WHAT DELIBERATELY DOES NOT LIVE HERE: rendering a tag as a table format's spec
# type name, the encode-boundary type check (its errors are that format's
# errors), and the wire encode/decode of cells, rows and data files. Those
# mappings belong to the format, not to the cell.
#
# THE TAG CONSTANTS ARE THE CELL'S DISCRIMINANT, so they live WITH the cell.
# `RowCell.type_tag` IS one of `CELL_T_*`; a consumer cannot construct or read a
# cell without them, so putting them anywhere else would make this "leaf"
# unusable and drag a heavier dep back in through the tag import alone. Their
# ordinal VALUES are internal (0..5), NOT any format's spec values; a format
# that wants its own spelling re-exports them under its own names.
#
# Every function takes owned/borrowed typed values and returns owned typed
# values; nothing here holds or exposes a pointer.
# =============================================================================


# =============================================================================
# Cell type tags — the RowCell discriminant.
# =============================================================================
#
# The scalar kinds a cell can hold. The ordinals are internal; consumers must
# always name the constant, never the literal.

comptime CELL_T_BOOLEAN: Int = 0
comptime CELL_T_INT: Int = 1  # 32-bit signed
comptime CELL_T_LONG: Int = 2  # 64-bit signed
comptime CELL_T_FLOAT: Int = 3
comptime CELL_T_DOUBLE: Int = 4
comptime CELL_T_STRING: Int = 5


# =============================================================================
# RowCell — one typed table cell.
# =============================================================================


struct RowCell(Copyable, Movable, Deinitable):
    """A single typed table cell.

    The value is stored discriminated by `type_tag` (one of CELL_T_*):
      * BOOLEAN / INT / LONG  -> `i` (Int64; boolean is 0/1, int is sign-extended)
      * FLOAT / DOUBLE        -> `f` (Float64; float is stored widened to f64)
      * STRING                -> `s` (String)
    The unused arms hold their zero value. `equals` compares the active arm.

    `null` marks a NULL cell (all value arms zero). Schema evolution's add-column
    tolerance produces null cells for a column absent from an OLD data file; a
    null cell never VALUE-equals a non-null cell (so an equality delete on a
    non-null key does not mask a null-filled row)."""

    var type_tag: Int
    var i: Int64
    var f: Float64
    var s: String
    var null: Bool

    def __init__(
        out self,
        type_tag: Int,
        i: Int64,
        f: Float64,
        var s: String,
        null: Bool = False,
    ):
        self.type_tag = type_tag
        self.i = i
        self.f = f
        self.s = s^
        self.null = null

    def copy(self) -> Self:
        return Self(self.type_tag, self.i, self.f, String(self.s), self.null)

    @always_inline
    def is_null(self) -> Bool:
        """True iff this cell is NULL (a null-filled added column, e.g.)."""
        return self.null

    @always_inline
    def as_long(self) -> Int64:
        """The integral value (BOOLEAN / INT / LONG arms)."""
        return self.i

    @always_inline
    def as_double(self) -> Float64:
        """The floating value (FLOAT / DOUBLE arms)."""
        return self.f

    @always_inline
    def as_string(self) -> String:
        """The string value (STRING arm)."""
        return String(self.s)

    def equals(self, other: RowCell) -> Bool:
        """VALUE equality within the same type. Two cells of DIFFERENT type_tags
        never compare equal (an equality-delete key column and the data column
        it matches share the same field-id => same declared type, so this only
        compares like-typed cells in practice).

        A NULL cell equals ONLY another NULL cell of the same type (SQL `=`
        would return UNKNOWN, but the equality-delete predicate needs a total
        function; a NULL delete key is REJECTED at the Iceberg write boundary,
        so this null-vs-null branch is not reachable for equality deletes on a
        nullable key today)."""
        if self.type_tag != other.type_tag:
            return False
        if self.null or other.null:
            return self.null and other.null
        var t = self.type_tag
        if t == CELL_T_STRING:
            return _str_eq(self.s, other.s)
        elif t == CELL_T_FLOAT or t == CELL_T_DOUBLE:
            return self.f == other.f
        else:
            # BOOLEAN / INT / LONG
            return self.i == other.i


@always_inline
def _str_eq(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            return False
    return True


# =============================================================================
# Cell constructors (the typed public constructors — no raw tag juggling).
# =============================================================================


@always_inline
def make_boolean_cell(v: Bool) -> RowCell:
    return RowCell(
        CELL_T_BOOLEAN, Int64(1) if v else Int64(0), Float64(0), String("")
    )


@always_inline
def make_int_cell(v: Int32) -> RowCell:
    return RowCell(CELL_T_INT, Int64(v), Float64(0), String(""))


@always_inline
def make_long_cell(v: Int64) -> RowCell:
    return RowCell(CELL_T_LONG, v, Float64(0), String(""))


@always_inline
def make_float_cell(v: Float32) -> RowCell:
    return RowCell(CELL_T_FLOAT, Int64(0), Float64(v), String(""))


@always_inline
def make_double_cell(v: Float64) -> RowCell:
    return RowCell(CELL_T_DOUBLE, Int64(0), v, String(""))


@always_inline
def make_string_cell(var v: String) -> RowCell:
    return RowCell(CELL_T_STRING, Int64(0), Float64(0), v^)


@always_inline
def make_null_cell(type_tag: Int) -> RowCell:
    """A NULL cell of declared `type_tag` (all value arms zero, null flag set).

    Schema evolution's add-column null-fill produces these for a column absent
    from an OLD data file (written under the prior, narrower schema)."""
    return RowCell(type_tag, Int64(0), Float64(0), String(""), True)


# =============================================================================
# Row-level value equality.
# =============================================================================


def rows_equal(a: List[RowCell], b: List[RowCell]) -> Bool:
    """True iff two rows are cell-wise VALUE-equal (same arity, each cell
    equals). The equality-delete match predicate."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not a[i].equals(b[i]):
            return False
    return True
