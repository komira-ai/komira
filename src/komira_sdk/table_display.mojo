# =============================================================================
# Table Display -- Pretty-print RecordBatch as ASCII table
# =============================================================================
#
# Formats a RecordBatch as a human-readable ASCII table with column names,
# types, separator lines, data rows, and a row count footer. Uses ASCII
# box-drawing characters (+ - |) for maximum compatibility.
#
# Output format:
#   +----------+-----+--------+
#   | name     | age | region |
#   | str      | i64 | str    |
#   +----------+-----+--------+
#   | alice    |  30 | EMEA   |
#   | bob      |  25 | NA     |
#   +----------+-----+--------+
#   2 rows
#
# Reference: playbook Phase 6 (SDK polish, developer experience)
# =============================================================================

from komira_arrow.schema import RecordBatch
from komira_arrow.arrow_types import ArrowType


@always_inline
def _write_type_short_name[W: Writer](mut writer: W, at: ArrowType):
    """WRITE what `_type_short_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; once a
    shipped `_komira` bound such a pair CROSSED and took the
    interpreter with it."""
    if at == ArrowType.BOOL:
        writer.write("bool")
        return
    elif at == ArrowType.INT8:
        writer.write("i8")
        return
    elif at == ArrowType.INT16:
        writer.write("i16")
        return
    elif at == ArrowType.INT32:
        writer.write("i32")
        return
    elif at == ArrowType.INT64:
        writer.write("i64")
        return
    elif at == ArrowType.UINT8:
        writer.write("u8")
        return
    elif at == ArrowType.UINT16:
        writer.write("u16")
        return
    elif at == ArrowType.UINT32:
        writer.write("u32")
        return
    elif at == ArrowType.UINT64:
        writer.write("u64")
        return
    elif at == ArrowType.FLOAT16:
        writer.write("f16")
        return
    elif at == ArrowType.FLOAT32:
        writer.write("f32")
        return
    elif at == ArrowType.FLOAT64:
        writer.write("f64")
        return
    elif at == ArrowType.STRING:
        writer.write("str")
        return
    elif at == ArrowType.LARGE_STRING:
        writer.write("str")
        return
    elif at == ArrowType.BINARY:
        writer.write("bin")
        return
    elif at == ArrowType.LARGE_BINARY:
        writer.write("bin")
        return
    elif at == ArrowType.DATE32:
        writer.write("date")
        return
    elif at == ArrowType.DATE64:
        writer.write("date")
        return
    elif at == ArrowType.DICTIONARY:
        writer.write("dict")
        return
    elif at == ArrowType.DECIMAL128:
        writer.write("dec128")
        return
    else:
        writer.write("?")
        return


@always_inline
def _type_short_name(at: ArrowType) -> String:
    """Return a short display name for an ArrowType.

    Abbreviates common types for compact table headers:
    INT64 -> i64, FLOAT64 -> f64, STRING -> str, etc.

    Args:
        at: The ArrowType to abbreviate.

    Returns:
        A short string representation.
    """
    var out = String()
    _write_type_short_name(out, at)
    return out^


def _cell_value(batch: RecordBatch, col_idx: Int, row_idx: Int) raises -> String:
    """Extract the string representation of a single cell value.

    Dispatches on the column's ArrowType to read the value using the
    appropriate typed accessor and convert it to a string.

    Args:
        batch: The RecordBatch containing the data.
        col_idx: Zero-based column index.
        row_idx: Zero-based row index.

    Returns:
        The cell value as a string.
    """
    var at = batch.schema.field_arrow_type(col_idx)
    if at == ArrowType.STRING or at == ArrowType.LARGE_STRING:
        # ⚠ THE ARM ALREADY NAMED LARGE_STRING AND COULD NOT SERVE IT.
        # `column_as_string` had no int64-offset path, so `df.show()` on a
        # PROMOTED result raised `Column.as_string: arrow_type is
        # large_string` — the branch matched and the body refused.
        #
        # Two changes, both load-bearing:
        #   * `utf8_value_at` reads the row's bounding offsets at the COLUMN's
        #     own width, so both widths render through one call and no future
        #     renderer has to remember a second arm.
        #   * it reads ONE ROW instead of copying the entire column. This
        #     function is called per CELL, so the old shape memcpy'd the whole
        #     column once per printed cell — merely wasteful on a narrow
        #     column, and unusable on a `large_string` one, which exists in
        #     this tree only because it passed 2 GiB.
        #
        # DICTIONARY under a STRING field keeps its decode: `column_as_string`
        # resolves each ordinal AND the indices validity bitmap, which is how
        # a dict-encoded scan column has always displayed here. Reading its
        # codes as per-row offsets is the B-5 P0 segfault.
        ref col = batch.column_at(col_idx)
        if col.arrow_type == ArrowType.DICTIONARY:
            var arr = batch.column_as_string(col_idx)
            return arr.get(row_idx)
        return col.utf8_value_at(row_idx)
    elif at == ArrowType.INT64:
        var arr = batch.column_as_primitive_int64(col_idx)
        return String(Int(arr.get(row_idx)))
    elif at == ArrowType.INT32:
        var arr = batch.column_as_primitive_int32(col_idx)
        return String(Int(arr.get(row_idx)))
    elif at == ArrowType.FLOAT64:
        var arr = batch.column_as_primitive_float64(col_idx)
        return String(Float64(arr.get(row_idx)))
    elif at == ArrowType.FLOAT32:
        # Read as float64 and display
        var arr = batch.column_as_primitive_float64(col_idx)
        return String(Float64(arr.get(row_idx)))
    else:
        # Fallback: try reading as int64
        var val = batch.column_value(col_idx, row_idx)
        return String(Int(val))


def _pad_right(s: String, width: Int) -> String:
    """Pad a string on the right with spaces to reach the given width.

    `width` is a count of CHARACTERS, not of UTF-8 bytes — see `_pad_left`.

    Args:
        s: The string to pad.
        width: The desired total width.

    Returns:
        The padded string.
    """
    var result = s
    var pad = width - s.count_codepoints()
    for _ in range(pad):
        result += " "
    return result^


def _pad_left(s: String, width: Int) -> String:
    """Pad a string on the left with spaces to reach the given width.

    ⚠ `width` IS A COUNT OF CHARACTERS, NOT OF UTF-8 BYTES, AND IT HAS TO BE.
    This was `len(s)` — the byte count — which over-counts every non-ASCII cell
    and silently broke the grid: `café` is 5 bytes and 4 characters, so the
    column was sized 5 and the cell padded by 5-5=0, rendering 4 columns of text
    inside a 5-wide box. The unit is not a preference — `_separator_line` draws
    the rule one `-` per iteration of `range(width + 2)`, i.e. in CHARACTERS, so
    a byte-valued width can never agree with it.

    Codepoints is exact for the dominant non-ASCII case (Latin with diacritics:
    2 bytes, 1 codepoint, 1 terminal column) and strictly closer than bytes
    everywhere else. It is NOT a full terminal-width model — East-Asian wide
    characters are 2 columns and combining marks are 0, which a wcwidth table
    would be needed to handle. Pinned by
    tests/sdk/test_display_width_non_ascii.mojo.

    Args:
        s: The string to pad.
        width: The desired total width.

    Returns:
        The padded string.
    """
    var result = String("")
    var pad = width - s.count_codepoints()
    for _ in range(pad):
        result += " "
    result += s
    return result^


@always_inline
def _is_numeric_type(at: ArrowType) -> Bool:
    """Return True if the ArrowType is numeric (right-align in display).

    Args:
        at: The ArrowType to check.

    Returns:
        True for integer and floating-point types.
    """
    return (
        at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
        or at == ArrowType.UINT8
        or at == ArrowType.UINT16
        or at == ArrowType.UINT32
        or at == ArrowType.UINT64
        or at == ArrowType.FLOAT16
        or at == ArrowType.FLOAT32
        or at == ArrowType.FLOAT64
        or at == ArrowType.DECIMAL128
    )


def _separator_line(widths: List[Int]) -> String:
    """Build a separator line like +------+-----+--------+.

    Args:
        widths: List of column widths (content width, excluding padding).

    Returns:
        The separator line string.
    """
    var line = String("+")
    for i in range(len(widths)):
        # Each cell has 1 space padding on each side = width + 2 dashes
        for _ in range(widths[i] + 2):
            line += "-"
        line += "+"
    return line^


def format_table(batch: RecordBatch, max_rows: Int = 20) raises -> String:
    """Format a RecordBatch as a pretty-printed ASCII table.

    Produces output like:
        +----------+-----+--------+
        | name     | age | region |
        | str      | i64 | str    |
        +----------+-----+--------+
        | alice    |  30 | EMEA   |
        | bob      |  25 | NA     |
        +----------+-----+--------+
        2 rows

    Numeric columns are right-aligned, string columns are left-aligned.
    When num_rows > max_rows, only the first max_rows are shown and a
    "... N more rows" note is appended.

    Args:
        batch: The RecordBatch to format.
        max_rows: Maximum number of data rows to display. Default 20.

    Returns:
        The formatted table as a string.

    Examples:
        ```mojo
        from komira_sdk.table_display import format_table
        from komira_sdk import col
        # render a materialized result as an ASCII table (first 3 rows)
        var batch = ctx.materialize(df^.filter(col("age") > 25)^)
        print(format_table(batch, max_rows=3))
        ```
    (LIFT tests/sdk/test_display_stats.mojo:83, :145).
    """
    var ncols = batch.num_columns()
    var nrows = batch.num_rows()

    # Handle empty batch (0 columns)
    if ncols == 0:
        return String("(empty: 0 columns, ") + String(nrows) + " rows)"

    # Collect column names and type names
    var names = List[String]()
    var type_names = List[String]()
    var arrow_types = List[UInt8]()
    for c in range(ncols):
        names.append(batch.schema.field_name(c))
        type_names.append(_type_short_name(batch.schema.field_arrow_type(c)))
        arrow_types.append(batch.schema.field_arrow_type(c).type_id)

    # Determine how many rows to display
    var display_rows = nrows
    if max_rows >= 0 and nrows > max_rows:
        display_rows = max_rows

    # Pre-compute all cell string values
    # cells is a flat array: cells[row * ncols + col]
    var cells = List[String]()
    for r in range(display_rows):
        for c in range(ncols):
            cells.append(_cell_value(batch, c, r))

    # Compute column widths: max of name, type_name, and all cell values.
    # In CHARACTERS — the same unit `_pad_right` pads in and `_separator_line`
    # draws in. A byte count here desynchronises all three for non-ASCII data.
    var widths = List[Int]()
    for c in range(ncols):
        var w = names[c].count_codepoints()
        if type_names[c].count_codepoints() > w:
            w = type_names[c].count_codepoints()
        for r in range(display_rows):
            var cell_len = cells[r * ncols + c].count_codepoints()
            if cell_len > w:
                w = cell_len
        widths.append(w)

    # Build the table string
    var sep = _separator_line(widths)
    var result = sep + "\n"

    # Header row: column names
    var header = String("|")
    for c in range(ncols):
        header += " " + _pad_right(names[c], widths[c]) + " |"
    result += header + "\n"

    # Type row
    var type_row = String("|")
    for c in range(ncols):
        type_row += " " + _pad_right(type_names[c], widths[c]) + " |"
    result += type_row + "\n"

    # Separator between header and data
    result += sep + "\n"

    # Data rows
    for r in range(display_rows):
        var row = String("|")
        for c in range(ncols):
            var val = cells[r * ncols + c]
            var at = ArrowType(arrow_types[c])
            if _is_numeric_type(at):
                row += " " + _pad_left(val, widths[c]) + " |"
            else:
                row += " " + _pad_right(val, widths[c]) + " |"
        result += row + "\n"

    # Bottom separator
    result += sep + "\n"

    # Row count footer
    result += String(nrows) + " rows"
    if display_rows < nrows:
        result += " (showing " + String(display_rows) + ", ... " + String(nrows - display_rows) + " more rows)"

    return result^
