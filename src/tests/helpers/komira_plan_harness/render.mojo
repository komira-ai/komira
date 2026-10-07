# =============================================================================
# komira_plan_harness/render.mojo -- RecordBatch / Table -> canonical text.
# =============================================================================
#
# Cells, by type (NULL is `\N` for every type, decided by the column's
# validity alone, in one place: _is_null):
#
#   bool                          true | false
#   int8..int64, uint8..uint64    decimal integer
#   float16/32/64                 <shortest decimal>|0x<IEEE bits> (float_text)
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
#   list, large_list,
#   fixed_size_list               [<v>,<v>,...]
#   struct                        {<name>:<v>,...} in field order
#   map                           {<k>:<v>,...} sorted by the key's text
#   union_sparse, union_dense     (<type code>:<v>)
#   null                          \N
#
# Inside brackets each <v> is a cell of the child type, `\N` for a NULL, with
# the bracket characters escaped in strings. The view types (binary_view,
# utf8_view, list_view, large_list_view), `error` and any unknown type are
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
    bytes_to_string,
    escape_bytes_into,
    escape_name,
)
from .float_text import float_cell_text


# ---------------------------------------------------------------------------
# Type spelling
# ---------------------------------------------------------------------------


def arrow_type_name(t: ArrowType) raises -> String:
    """plan_vocabulary's ArrowType name without `ARROW_TYPE_`, lower case."""
    if t == ArrowType.NULL:
        return String("null")
    if t == ArrowType.BOOL:
        return String("bool")
    if t == ArrowType.INT8:
        return String("int8")
    if t == ArrowType.INT16:
        return String("int16")
    if t == ArrowType.INT32:
        return String("int32")
    if t == ArrowType.INT64:
        return String("int64")
    if t == ArrowType.UINT8:
        return String("uint8")
    if t == ArrowType.UINT16:
        return String("uint16")
    if t == ArrowType.UINT32:
        return String("uint32")
    if t == ArrowType.UINT64:
        return String("uint64")
    if t == ArrowType.FLOAT16:
        return String("float16")
    if t == ArrowType.FLOAT32:
        return String("float32")
    if t == ArrowType.FLOAT64:
        return String("float64")
    if t == ArrowType.STRING:
        return String("string")
    if t == ArrowType.BINARY:
        return String("binary")
    if t == ArrowType.DATE32:
        return String("date32")
    if t == ArrowType.DATE64:
        return String("date64")
    if t == ArrowType.TIMESTAMP:
        return String("timestamp")
    if t == ArrowType.DECIMAL128:
        return String("decimal128")
    if t == ArrowType.DICTIONARY:
        return String("dictionary")
    if t == ArrowType.LIST:
        return String("list")
    if t == ArrowType.STRUCT:
        return String("struct")
    if t == ArrowType.TIMESTAMP_S:
        return String("timestamp_s")
    if t == ArrowType.TIMESTAMP_MS:
        return String("timestamp_ms")
    if t == ArrowType.TIMESTAMP_US:
        return String("timestamp_us")
    if t == ArrowType.TIMESTAMP_NS:
        return String("timestamp_ns")
    if t == ArrowType.LARGE_STRING:
        return String("large_string")
    if t == ArrowType.LARGE_BINARY:
        return String("large_binary")
    if t == ArrowType.MAP:
        return String("map")
    if t == ArrowType.DECIMAL256:
        return String("decimal256")
    if t == ArrowType.TIME32_S:
        return String("time32_s")
    if t == ArrowType.TIME32_MS:
        return String("time32_ms")
    if t == ArrowType.TIME64_US:
        return String("time64_us")
    if t == ArrowType.TIME64_NS:
        return String("time64_ns")
    if t == ArrowType.DURATION_S:
        return String("duration_s")
    if t == ArrowType.DURATION_MS:
        return String("duration_ms")
    if t == ArrowType.DURATION_US:
        return String("duration_us")
    if t == ArrowType.DURATION_NS:
        return String("duration_ns")
    if t == ArrowType.INTERVAL_YEAR_MONTH:
        return String("interval_year_month")
    if t == ArrowType.INTERVAL_DAY_TIME:
        return String("interval_day_time")
    if t == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return String("interval_month_day_nano")
    if t == ArrowType.UNION_SPARSE:
        return String("union_sparse")
    if t == ArrowType.UNION_DENSE:
        return String("union_dense")
    if t == ArrowType.LARGE_LIST:
        return String("large_list")
    if t == ArrowType.FIXED_SIZE_BINARY:
        return String("fixed_size_binary")
    if t == ArrowType.FIXED_SIZE_LIST:
        return String("fixed_size_list")
    if t == ArrowType.BINARY_VIEW:
        return String("binary_view")
    if t == ArrowType.UTF8_VIEW:
        return String("utf8_view")
    if t == ArrowType.LIST_VIEW:
        return String("list_view")
    if t == ArrowType.LARGE_LIST_VIEW:
        return String("large_list_view")
    if t == ArrowType.ERROR:
        return String("error")
    raise Error("canon: unknown arrow type id " + String(Int(t.type_id)))


def float_width_of(t: ArrowType) -> Int:
    if t == ArrowType.FLOAT16:
        return 16
    if t == ArrowType.FLOAT32:
        return 32
    if t == ArrowType.FLOAT64:
        return 64
    return 0


def type_spelling(f: Field) raises -> String:
    """The type part of a schema entry (see canon_text.mojo)."""
    var t = f.arrow_type
    var s = arrow_type_name(t)
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        s += "(" + String(f.decimal_precision) + "," + String(f.decimal_scale) + ")"
    elif t.is_timestamp():
        var tz = f.timezone()
        if tz.byte_length() > 0:
            s += "(" + escape_name(tz) + ")"
    elif t == ArrowType.DICTIONARY:
        s += "(" + arrow_type_name(f.dict_index_type()) + ")"
    elif t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        var ids = f.union_type_ids()
        s += "("
        for i in range(len(ids)):
            if i > 0:
                s += ","
            s += String(ids[i])
        s += ")"
    if f.num_children() > 0:
        s += "<"
        for i in range(f.num_children()):
            if i > 0:
                s += ","
            s += escape_name(f.child_name(i)) + ":"
            s += arrow_type_name(f.child_arrow_type(i))
            if f.child_nullable(i):
                s += "?"
        s += ">"
    return s


def schema_entry(f: Field) raises -> String:
    var s = escape_name(f.name) + ":" + type_spelling(f)
    if f.nullable:
        s += "?"
    return s


# ---------------------------------------------------------------------------
# Buffer reads, checked
# ---------------------------------------------------------------------------


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
    var p = col.offset() + row
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
        return bytes_to_string(res)
    var raw = List[UInt8](capacity=end - start)
    for i in range(start, end):
        raw.append(view.read_u8_at(i))
    escape_bytes_into(res, Span(raw), ESC_NESTED if nested else ESC_SCALAR)
    return bytes_to_string(res)


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


def _fixed_cell(col: Column[HeapRegion], row: Int) -> String:
    var t = col.arrow_type
    var w = _fixed_width(t)
    var pos = (col.offset() + row) * w
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
        return float_cell_text(UInt64(view.read_u16_le_at(pos)), 16)
    if t == ArrowType.UINT32:
        return String(view.read_u32_le_at(pos))
    if t == ArrowType.FLOAT32:
        return float_cell_text(UInt64(view.read_u32_le_at(pos)), 32)
    if t == ArrowType.UINT64:
        return String(view.read_u64_le_at(pos))
    if t == ArrowType.FLOAT64:
        return float_cell_text(view.read_u64_le_at(pos), 64)
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
        return bytes_to_string(res)
    if col.is_numeric_dict():
        var dt = col.dict_value_dtype()
        if dt == DType.int32 or dt == DType.int64:
            return String(col.dict_value_i64(code))
        if dt == DType.float64:
            return float_cell_text(bitcast[DType.uint64](col.dict_value_f64(code)), 64)
        if dt == DType.float32:
            var f = Float32(col.dict_value_f64(code))
            return float_cell_text(UInt64(bitcast[DType.uint32](f)), 32)
        raise Error(
            "canon: column " + path + ": dictionary value type " + String(dt)
            + " is not rendered"
        )
    raise Error("canon: column " + path + ": dictionary with no value layout")


def _sorted_map_entries(
    keys: List[String], vals: List[String], start: Int, end: Int
) -> String:
    var idx = List[Int]()
    for i in range(start, end):
        idx.append(i)
    # Insertion sort by key text (a map row is small).
    for i in range(1, len(idx)):
        var j = i
        while j > 0 and keys[idx[j]] < keys[idx[j - 1]]:
            var tmp = idx[j]
            idx[j] = idx[j - 1]
            idx[j - 1] = tmp
            j -= 1
    var s = String("{")
    for i in range(len(idx)):
        if i > 0:
            s += ","
        s += keys[idx[i]] + ":" + vals[idx[i]]
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
        _need_values(col, (col.offset() + n) * w, path)
        for r in range(n):
            cells.append(null_cell if _is_null(col, r) else _fixed_cell(col, r))
        return cells^

    if t == ArrowType.BOOL:
        _need_values(col, (col.offset() + n + 7) // 8, path)
        var view = col.values_view_native()
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var p = col.offset() + r
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
        _need_values(col, (col.offset() + n) * bw, path)
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var p = (col.offset() + r) * bw
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
        if size <= 0 or (col.offset() + n) * size > len(child):
            raise Error(
                "canon: column " + path + ": fixed_size_list of " + String(size)
                + " over a child of " + String(len(child)) + " rows"
            )
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var p = (col.offset() + r) * size
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
            if len(kids[c]) < col.offset() + n:
                raise Error("canon: column " + path + "." + names[c] + " is shorter than its struct")
        for r in range(n):
            if _is_null(col, r):
                cells.append(null_cell)
                continue
            var s = String("{")
            for c in range(nc):
                if c > 0:
                    s += ","
                s += names[c] + ":" + kids[c][col.offset() + r]
            cells.append(s + "}")
        return cells^

    if t == ArrowType.MAP:
        if col.num_children() != 1 or col.child_at(0).num_children() != 2:
            raise Error("canon: column " + path + ": a map needs one entries struct of two children")
        ref entries = col.child_at(0)
        var ko = entries.offset()
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
        _need_values(col, col.offset() + n, path)
        var view = col.values_view_native()
        for r in range(n):
            var p = col.offset() + r
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


def _schema_into(mut res: CanonText, schema: Schema) raises:
    for c in range(schema.num_columns()):
        var f = schema.field_at(c)
        res.schema.append(schema_entry(f))
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
    _schema_into(res, batch.schema)
    _rows_into(res, batch)
    return res^


def _same_strings(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def render_table(table: Table, var policy: CanonPolicy) raises -> CanonText:
    """The canonical text of a chunked result: its chunks' rows in order.
    Every chunk must carry the table's schema."""
    var res = CanonText(policy^)
    _schema_into(res, table.schema())
    for i in range(table.num_chunks()):
        ref chunk = table.chunk(i)
        var probe = CanonText(CanonPolicy())
        _schema_into(probe, chunk.schema)
        if not _same_strings(probe.schema, res.schema):
            raise Error("canon: table chunk " + String(i) + " has another schema")
        _rows_into(res, chunk)
    return res^
