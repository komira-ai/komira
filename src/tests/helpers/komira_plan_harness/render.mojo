# =============================================================================
# komira_plan_harness/render.mojo -- RecordBatch / Table -> canonical text.
# =============================================================================
#
# Cells, by type (NULL is `\N` for every type, decided by the column's
# validity alone, in one place: _is_null):
#
#   bool                          true | false
#   int8..int64, uint8..uint64    decimal integer
#   float16/32/64                 <shortest decimal>|0x<IEEE bits> (float_text);
#                                 inside a nested value 0x<IEEE bits> alone,
#                                 or NaN for any NaN
#   string, large_string          escaped UTF-8 (escape.mojo)
#   binary, large_binary,
#   fixed_size_binary             lower-case hex, two digits a byte
#   date32 (days), date64 (ms), time32_*, time64_*, timestamp*, duration_*
#                                 the stored integer, in the column's unit
#   interval_year_month           months, an integer
#   interval_day_time             <days>d<millis>ms
#   interval_month_day_nano       <months>m<days>d<nanos>ns
#   decimal128, decimal256        <unscaled integer>e<-scale>: 12345 at scale
#                                 2 is `12345e-2`, at scale 0 `12345e0`
#   dictionary                    the decoded value, rendered as its value type
#                                 (float values read as raw bits)
#   list, large_list,
#   fixed_size_list               [<v>,<v>,...]
#   struct                        {<name>:<v>,...} in field order
#   map                           {<k>:<v>,...} sorted by the key's text, then
#                                 (duplicate keys) the value's
#   union_sparse, union_dense     (<type code>:<v>)
#   null                          \N
#
# Inside brackets each <v> is a cell of the child type, `\N` for a NULL, with
# the bracket characters escaped in strings and struct names escaped as names
# (escape.mojo). The schema entry spells the whole type tree (type_text.mojo),
# so two columns whose cells could read alike never share a schema line. The view types (binary_view,
# utf8_view, list_view, large_list_view) and any unknown type are
# REFUSED by name: canon never renders a value it cannot render exactly.
#
# canon reads the Arrow buffers itself (the values buffer through
# `values_view_native`, offsets through the column's offsets buffer, honouring
# the column's slice offset) instead of komira_arrow's typed accessors, so a
# reader defect is not shared with the typed accessors it may also break.
# Every offset and length is checked against its buffer before a read.
# =============================================================================

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.table import Table
from komira_buffer.heap_region import HeapRegion

from ._bignat import BigNat
from .canon_text import CanonPolicy, CanonText
from .escape import (
    ESC_NESTED,
    ESC_SCALAR,
    _bytes_to_string,
    escape_bytes_into,
    escape_name,
)
from .type_text import (
    arrow_type_name,
    column_float_width,
    float_width_of,
    schema_entry,
    schema_entry_of_field,
)
from .float_text import bits_hex, float_cell_text, float_is_nan


# ---------------------------------------------------------------------------
# Buffer reads, checked
# ---------------------------------------------------------------------------


@always_inline
def _phys(col: Column[HeapRegion], row: Int) -> Int:
    """The physical index of logical row `row`: the ONE place canon applies a
    column's slice offset (validity applies it inside `is_null_at`)."""
    return col.offset() + row


@always_inline
def _is_null(col: Column[HeapRegion], row: Int) -> Bool:
    """The ONE validity decision for every type (row is logical, the
    column's slice offset is applied by `is_null_at`)."""
    return col.is_null_at(row)


def _need_values(col: Column[HeapRegion], nbytes: Int, path: String) raises:
    var have = col.values_view_native().len()
    if have < nbytes:
        raise Error(
            "canon: column " + path + ": values buffer holds " + String(have)
            + " bytes, the rows need " + String(nbytes)
        )


def _offset_at(col: Column[HeapRegion], i: Int, wide: Bool, path: String) raises -> Int:
    """Entry `i` (physical, slice offset already added) of the offsets
    buffer: Int32, or Int64 when `wide`."""
    if not col._offsets:
        raise Error("canon: column " + path + " has no offsets buffer")
    ref buf = col._offsets.value()
    var w = 8 if wide else 4
    if (i + 1) * w > buf.len():
        raise Error(
            "canon: column " + path + ": offsets buffer too short for entry "
            + String(i)
        )
    if wide:
        return Int(buf.read_i64_le_at(i * w))
    return Int(buf.read_i32_le_at(i * w))


def _span(
    col: Column[HeapRegion], row: Int, wide: Bool, limit: Int, path: String
) raises -> Tuple[Int, Int]:
    """[start, end) of logical row `row` by the offsets buffer, checked to be
    ordered and within `limit`."""
    var p = _phys(col, row)
    var start = _offset_at(col, p, wide, path)
    var end = _offset_at(col, p + 1, wide, path)
    if start < 0 or end < start or end > limit:
        raise Error(
            "canon: column " + path + " row " + String(row) + ": offsets ["
            + String(start) + ", " + String(end) + ") out of bounds "
            + String(limit)
        )
    return (start, end)


def _hex_into(mut res: List[UInt8], b: UInt8):
    var digits = "0123456789abcdef".as_bytes()
    res.append(digits[Int(b >> 4)])
    res.append(digits[Int(b & 0xF)])


def _bytes_cell(col: Column[HeapRegion], start: Int, end: Int, hex: Bool, nested: Bool) -> String:
    var view = col.values_view_native()
    var res = List[UInt8]()
    if hex:
        for i in range(start, end):
            _hex_into(res, view.read_u8_at(i))
        return _bytes_to_string(res)
    var raw = List[UInt8](capacity=end - start)
    for i in range(start, end):
        raw.append(view.read_u8_at(i))
    escape_bytes_into(res, Span(raw), ESC_NESTED if nested else ESC_SCALAR)
    return _bytes_to_string(res)


def _decimal_cell(col: Column[HeapRegion], pos: Int, nbytes: Int, scale: Int) -> String:
    """Little-endian two's complement of `nbytes` at byte `pos`, as
    `<unscaled>e<-scale>`."""
    var view = col.values_view_native()
    var limbs = List[UInt32]()
    for k in range(nbytes // 4):
        limbs.append(view.read_u32_le_at(pos + 4 * k))
    var negative = (limbs[len(limbs) - 1] >> 31) != 0
    if negative:
        var carry: UInt64 = 1
        for k in range(len(limbs)):
            var v = UInt64(~limbs[k]) + carry
            limbs[k] = UInt32(v & 0xFFFFFFFF)
            carry = v >> 32
    var s = BigNat.from_u32_limbs(limbs^).to_decimal()
    if negative:
        s = "-" + s
    return s + "e" + String(-scale)


# ---------------------------------------------------------------------------
# Columns
# ---------------------------------------------------------------------------


def _fixed_width(t: ArrowType) -> Int:
    """Bytes per value of a fixed-width scalar type, 0 if not one."""
    if t == ArrowType.INT8 or t == ArrowType.UINT8:
        return 1
    if t == ArrowType.INT16 or t == ArrowType.UINT16 or t == ArrowType.FLOAT16:
        return 2
    if (
        t == ArrowType.INT32 or t == ArrowType.UINT32 or t == ArrowType.FLOAT32
        or t == ArrowType.DATE32 or t == ArrowType.TIME32_S
        or t == ArrowType.TIME32_MS or t == ArrowType.INTERVAL_YEAR_MONTH
    ):
        return 4
    if (
        t == ArrowType.INT64 or t == ArrowType.UINT64 or t == ArrowType.FLOAT64
        or t == ArrowType.DATE64 or t == ArrowType.TIME64_US
        or t == ArrowType.TIME64_NS or t.is_timestamp() or t.is_duration()
        or t == ArrowType.INTERVAL_DAY_TIME
    ):
        return 8
    if t == ArrowType.DECIMAL128 or t == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return 16
    if t == ArrowType.DECIMAL256:
        return 32
    return 0


def _float_cell(bits: UInt64, width: Int, nested: Bool) -> String:
    """A top-level float is `<decimal>|0x<bits>`; one inside a nested value
    is its bits alone (`0x<bits>`), or `NaN` for any NaN, so the text of a
    nested value never depends on how a decimal is printed."""
    if not nested:
        return float_cell_text(bits, width)
    if float_is_nan(bits, width):
        return String("NaN")
    return bits_hex(bits, width)


def _fixed_cell(col: Column[HeapRegion], row: Int, nested: Bool) -> String:
    var t = col.arrow_type
    var w = _fixed_width(t)
    var pos = (_phys(col, row)) * w
    var view = col.values_view_native()
    if t == ArrowType.INT8:
        return String(Int(bitcast[DType.int8](view.read_u8_at(pos))))
    if t == ArrowType.UINT8:
        return String(Int(view.read_u8_at(pos)))
    if t == ArrowType.INT16:
        return String(Int(bitcast[DType.int16](view.read_u16_le_at(pos))))
    if t == ArrowType.UINT16:
        return String(Int(view.read_u16_le_at(pos)))
    if t == ArrowType.FLOAT16:
        return _float_cell(UInt64(view.read_u16_le_at(pos)), 16, nested)
    if t == ArrowType.UINT32:
        return String(view.read_u32_le_at(pos))
    if t == ArrowType.FLOAT32:
        return _float_cell(UInt64(view.read_u32_le_at(pos)), 32, nested)
    if t == ArrowType.UINT64:
        return String(view.read_u64_le_at(pos))
    if t == ArrowType.FLOAT64:
        return _float_cell(view.read_u64_le_at(pos), 64, nested)
    if t == ArrowType.INTERVAL_DAY_TIME:
        return (
            String(view.read_i32_le_at(pos)) + "d"
            + String(view.read_i32_le_at(pos + 4)) + "ms"
        )
    if t == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return (
            String(view.read_i32_le_at(pos)) + "m"
            + String(view.read_i32_le_at(pos + 4)) + "d"
            + String(view.read_i64_le_at(pos + 8)) + "ns"
        )
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        return _decimal_cell(col, pos, w, col.decimal_scale())
    if w == 4:
        return String(view.read_i32_le_at(pos))
    return String(view.read_i64_le_at(pos))


def _join(cells: List[String], start: Int, end: Int, lead: String, tail: String) -> String:
    var s = String(lead)
    for i in range(start, end):
        if i > start:
            s += ","
        s += cells[i]
    return s + tail


def _dict_cell(col: Column[HeapRegion], row: Int, nested: Bool, path: String) raises -> String:
    var code = col.dict_code_at(row)
    if code < 0 or code >= col.dict_size():
        raise Error(
            "canon: column " + path + " row " + String(row) + ": dictionary code "
            + String(code) + " outside [0, " + String(col.dict_size()) + ")"
        )
    if col.is_string_dict():
        var v = col.string_dict_value_at(code)
        var raw = List[UInt8](capacity=v.len())
        for i in range(v.len()):
            raw.append(v.read_u8_at(i))
        var res = List[UInt8]()
        escape_bytes_into(res, Span(raw), ESC_NESTED if nested else ESC_SCALAR)
        return _bytes_to_string(res)
    if col.is_numeric_dict():
        var dt = col.dict_value_dtype()
        var vw = 8 if (dt == DType.int64 or dt == DType.float64) else 4
        if (code + 1) * vw > col._dict_data.value().len():
            raise Error("canon: column " + path + ": dictionary values buffer too short")
        if dt == DType.int32 or dt == DType.int64:
            return String(col.dict_value_i64(code))
        if dt == DType.float64:
            # Raw bits from the dictionary's value buffer, never through a
            # float conversion (which may quiet a signalling NaN).
            return _float_cell(col._dict_data.value().read_u64_le_at(code * 8), 64, nested)
        if dt == DType.float32:
            return _float_cell(
                UInt64(col._dict_data.value().read_u32_le_at(code * 4)), 32, nested
            )
        raise Error(
            "canon: column " + path + ": dictionary value type " + String(dt)
            + " is not rendered"
        )
    raise Error("canon: column " + path + ": dictionary with no value layout")


def _entry_less(keys: List[String], vals: List[String], i: Int, j: Int) -> Bool:
    """Entry i before entry j: by key text, ties (duplicate keys) by value
    text."""
    if keys[i] != keys[j]:
        return keys[i] < keys[j]
    return vals[i] < vals[j]


def _sorted_map_entries(
    keys: List[String], vals: List[String], start: Int, end: Int
) -> String:
    # Bottom-up merge sort of the entry indices: n log n, and a total order,
    # so a map with duplicate keys still has one canonical text.
    var src = List[Int](capacity=end - start)
    for i in range(start, end):
        src.append(i)
    var n = len(src)
    var width = 1
    while width < n:
        var dst = List[Int](capacity=n)
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            while i < mid and j < hi:
                if _entry_less(keys, vals, src[j], src[i]):
                    dst.append(src[j])
                    j += 1
                else:
                    dst.append(src[i])
                    i += 1
            while i < mid:
                dst.append(src[i])
                i += 1
            while j < hi:
                dst.append(src[j])
                j += 1
            lo = hi
        src = dst^
        width *= 2
    var s = String("{")
    for i in range(n):
        if i > 0:
            s += ","
        s += keys[src[i]] + ":" + vals[src[i]]
    return s + "}"


def render_column(col: Column[HeapRegion], path: String, nested: Bool) raises -> List[String]:
    """One cell per logical row of `col`. `path` names the column in errors
    (`a`, `a.item`, `a.b`); `nested` selects the bracket escapes."""
    var t = col.arrow_type
    var n = col.length()
    var cells = List[String](capacity=n)
    var null_cell = String("\\N")

    if t == ArrowType.NULL:
        for _ in range(n):
            cells.append(null_cell)
        return cells^

    var w = _fixed_width(t)
    if w > 0:
        _need_values(col, (_phys(col, n)) * w, path)
        for r in range(n):
            cells.append(null_cell if _is_null(col, r) else _fixed_cell(col, r, nested))
        return cells^

    if t == ArrowType.BOOL:
        _need_values(col, (_phys(col, n) + 7) // 8, path)
        var view = col.values_view_native()
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var p = _phys(col, r)
            var bit = (view.read_u8_at(p >> 3) >> UInt8(p & 7)) & 1
            cells.append(String("true") if bit == 1 else String("false"))
        return cells^

    if (
        t == ArrowType.STRING or t == ArrowType.LARGE_STRING
        or t == ArrowType.BINARY or t == ArrowType.LARGE_BINARY
    ):
        var wide = t == ArrowType.LARGE_STRING or t == ArrowType.LARGE_BINARY
        var hex = t == ArrowType.BINARY or t == ArrowType.LARGE_BINARY
        var limit = col.values_view_native().len()
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var se = _span(col, r, wide, limit, path)
            cells.append(_bytes_cell(col, se[0], se[1], hex, nested))
        return cells^

    if t == ArrowType.FIXED_SIZE_BINARY:
        # komira_arrow keeps the byte width on the column only.
        var bw = col._inner_size
        if bw <= 0:
            raise Error("canon: column " + path + ": fixed_size_binary width " + String(bw))
        _need_values(col, (_phys(col, n)) * bw, path)
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var p = (_phys(col, r)) * bw
            cells.append(_bytes_cell(col, p, p + bw, True, nested))
        return cells^

    if t == ArrowType.DICTIONARY:
        for r in range(n):
            cells.append(null_cell if _is_null(col, r) else _dict_cell(col, r, nested, path))
        return cells^

    if t == ArrowType.LIST or t == ArrowType.LARGE_LIST:
        if col.num_children() != 1:
            raise Error("canon: column " + path + ": a list needs one child")
        var child = render_column(col.child_at(0), path + ".item", True)
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var se = _span(col, r, t == ArrowType.LARGE_LIST, len(child), path)
            cells.append(_join(child, se[0], se[1], "[", "]"))
        return cells^

    if t == ArrowType.FIXED_SIZE_LIST:
        if col.num_children() != 1:
            raise Error("canon: column " + path + ": a list needs one child")
        var size = col._inner_size
        var child = render_column(col.child_at(0), path + ".item", True)
        if size <= 0 or (_phys(col, n)) * size > len(child):
            raise Error(
                "canon: column " + path + ": fixed_size_list of " + String(size)
                + " over a child of " + String(len(child)) + " rows"
            )
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var p = (_phys(col, r)) * size
            cells.append(_join(child, p, p + size, "[", "]"))
        return cells^

    if t == ArrowType.STRUCT:
        var nc = col.num_children()
        var kids = List[List[String]]()
        var names = List[String]()
        for c in range(nc):
            var name = escape_name(col.field_name(c))
            kids.append(render_column(col.child_at(c), path + "." + name, True))
            names.append(name^)
            if len(kids[c]) < _phys(col, n):
                raise Error("canon: column " + path + "." + names[c] + " is shorter than its struct")
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var s = String("{")
            for c in range(nc):
                if c > 0:
                    s += ","
                s += names[c] + ":" + kids[c][_phys(col, r)]
            cells.append(s + "}")
        return cells^

    if t == ArrowType.MAP:
        if col.num_children() != 1 or col.child_at(0).num_children() != 2:
            raise Error("canon: column " + path + ": a map needs one entries struct of two children")
        ref entries = col.child_at(0)
        var ko = _phys(entries, 0)
        var keys = render_column(entries.child_at(0), path + ".key", True)
        var vals = render_column(entries.child_at(1), path + ".value", True)
        var limit = min(len(keys), len(vals)) - ko
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var se = _span(col, r, False, limit, path)
            cells.append(_sorted_map_entries(keys, vals, ko + se[0], ko + se[1]))
        return cells^

    if t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        var dense = t == ArrowType.UNION_DENSE
        var ids = col.type_ids()
        var kids = List[List[String]]()
        for c in range(col.num_children()):
            kids.append(render_column(col.child_at(c), path + "." + String(c), True))
        _need_values(col, _phys(col, n), path)
        var view = col.values_view_native()
        for r in range(n):
            var p = _phys(col, r)
            var code = Int(bitcast[DType.int8](view.read_u8_at(p)))
            var child = -1
            if len(ids) == 0:
                child = code
            else:
                for c in range(len(ids)):
                    if ids[c] == code:
                        child = c
            if child < 0 or child >= len(kids):
                raise Error(
                    "canon: column " + path + " row " + String(r) + ": union type code "
                    + String(code) + " names no child"
                )
            var crow = _offset_at(col, p, False, path) if dense else p
            if crow < 0 or crow >= len(kids[child]):
                raise Error("canon: column " + path + " row " + String(r) + ": union child row out of bounds")
            cells.append("(" + String(code) + ":" + kids[child][crow] + ")")
        return cells^

    raise Error(
        "canon: cannot render column " + path + " of type " + arrow_type_name(t)
        + "; canon refuses a type it cannot render exactly"
    )


# ---------------------------------------------------------------------------
# Batches and tables
# ---------------------------------------------------------------------------


def _schema_of_batch(mut res: CanonText, batch: RecordBatch) raises:
    """Schema entries from the batch's Fields and the trees of its columns
    (type_text.mojo)."""
    var nc = batch.schema.num_columns()
    if nc != batch.num_columns():
        raise Error(
            "canon: batch has " + String(batch.num_columns()) + " columns, schema "
            + String(nc)
        )
    for c in range(nc):
        var f = batch.schema.field_at(c)
        ref col = batch.column_at(c)
        res.schema.append(schema_entry(f, col))
        res.names.append(escape_name(f.name))
        res.float_widths.append(column_float_width(f, col))


def _schema_of_fields(mut res: CanonText, schema: Schema) raises:
    for c in range(schema.num_columns()):
        var f = schema.field_at(c)
        res.schema.append(schema_entry_of_field(f))
        res.names.append(escape_name(f.name))
        res.float_widths.append(float_width_of(f.arrow_type))


def _rows_into(mut res: CanonText, batch: RecordBatch) raises:
    var nc = batch.num_columns()
    if nc != len(res.schema):
        raise Error(
            "canon: batch has " + String(nc) + " columns, schema "
            + String(len(res.schema))
        )
    var cols = List[List[String]]()
    for c in range(nc):
        ref col = batch.column_at(c)
        var f = batch.schema.field_at(c)
        var path = escape_name(f.name)
        if col.arrow_type != f.arrow_type:
            raise Error(
                "canon: column " + path + ": field says " + arrow_type_name(f.arrow_type)
                + ", column holds " + arrow_type_name(col.arrow_type)
            )
        if (
            f.arrow_type == ArrowType.DECIMAL128 or f.arrow_type == ArrowType.DECIMAL256
        ) and col.decimal_scale() != f.decimal_scale:
            raise Error(
                "canon: column " + path + ": field scale " + String(f.decimal_scale)
                + ", column scale " + String(col.decimal_scale())
            )
        if col.length() != batch.num_rows():
            raise Error(
                "canon: column " + path + " holds " + String(col.length())
                + " rows, the batch " + String(batch.num_rows())
            )
        cols.append(render_column(col, path, False))
    for r in range(batch.num_rows()):
        if batch.has_selection_mask() and not batch.selection_mask_get(r):
            continue
        var row = List[String](capacity=nc)
        for c in range(nc):
            row.append(cols[c][r])
        res.rows.append(row^)


def render_batch(batch: RecordBatch, var policy: CanonPolicy) raises -> CanonText:
    """The canonical text of one batch (rows a selection mask drops are not
    rows of the result)."""
    var res = CanonText(policy^)
    _schema_of_batch(res, batch)
    _rows_into(res, batch)
    return res^


def _same_strings(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _field_heads(batch: RecordBatch) raises -> List[String]:
    """Per column, the name, top-level type, the Field's own type parameters
    (decimal precision and scale, timestamp time zone) and nullability of
    its Field: what a zero-row chunk must agree on (its dictionary and
    children may be absent, so the rest of its type is not compared)."""
    var heads = List[String]()
    for c in range(batch.schema.num_columns()):
        var f = batch.schema.field_at(c)
        var t = f.arrow_type
        var h = escape_name(f.name) + ":" + arrow_type_name(t)
        if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
            h += "(" + String(f.decimal_precision) + "," + String(f.decimal_scale) + ")"
        elif t.is_timestamp():
            h += "(" + escape_name(f.timezone()) + ")"
        if f.nullable:
            h += "?"
        heads.append(h^)
    return heads^


def render_table(table: Table, var policy: CanonPolicy) raises -> CanonText:
    """The canonical text of a chunked result: its chunks' rows in order.
    The schema is spelled from the first chunk that holds rows (from chunk 0
    when none does, from the Fields alone when there is no chunk), and every
    chunk that holds rows must spell the same. A zero-row chunk (an engine's
    empty morsel) is not rendered, and only its Fields' names, top-level
    types, decimal precision and scale, time zones and nullability are
    compared with the reference chunk's: a
    zero-row nested or dictionary column may have no children or dictionary
    to spell its full type or read its cells from."""
    var res = CanonText(policy^)
    var n = table.num_chunks()
    if n == 0:
        _schema_of_fields(res, table.schema())
        return res^
    var first = 0
    while first < n and table.chunk(first).num_rows() == 0:
        first += 1
    var reference = first if first < n else 0
    _schema_of_batch(res, table.chunk(reference))
    var heads = _field_heads(table.chunk(reference))
    for i in range(n):
        ref chunk = table.chunk(i)
        if i != reference and chunk.num_rows() == 0:
            if not _same_strings(_field_heads(chunk), heads):
                raise Error(
                    "canon: table chunk " + String(i)
                    + " (zero rows) has another column name, type or nullability"
                )
        if i != first and chunk.num_rows() > 0:
            var probe = CanonText(CanonPolicy())
            _schema_of_batch(probe, chunk)
            if not _same_strings(probe.schema, res.schema):
                raise Error("canon: table chunk " + String(i) + " has another schema")
        if chunk.num_rows() > 0:
            _rows_into(res, chunk)
    return res^
