# =============================================================================
# komira_plan_harness/type_text.mojo -- how a column's type is spelled.
# =============================================================================
#
# A schema entry is `<name>:<type>[?]`. The type is the whole tree, so two
# columns whose values could render alike never share a spelling:
#
#   <base>[(<params>)][<children>]
#
#   base       plan_vocabulary's ArrowType name, lower case, no prefix
#   params     decimal128/256 (precision,scale); timestamp_* (time zone, top
#              level only: a child column carries none); fixed_size_binary
#              (width); fixed_size_list (size); union_* (type codes)
#   children   list / large_list / fixed_size_list <item type>
#              struct <name:type,...>
#              map <key type,value type>
#              union_* <type,...> in child order
#              dictionary <index type,value type>
#
# The top level takes name, nullability and the parameters its Field carries
# (decimal, time zone, dictionary index type, union type codes); everything
# below comes from the column itself (child_at, field_name, decimal
# precision and scale, is_string_dict / dict_value_dtype), so it is the type
# of the data actually rendered. Child nullability is NOT spelled: komira's
# Field carries it one level deep only and a Column not at all.
#
# One limit is komira_arrow's, not canon's: a zero-row nested column built
# from a schema has no child columns. Its children are then spelled from the
# Field's one level (names and type names); a pyarrow spelling of a deeper
# type will differ there, and the compare reports it as a schema mismatch.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field
from komira_buffer.heap_region import HeapRegion

from .escape import escape_name


def arrow_type_name(t: ArrowType) raises -> String:
    """plan_vocabulary's ArrowType name without `ARROW_TYPE_`, lower case
    (the legacy TIMESTAMP is spelled timestamp_us, which it is)."""
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
        # The legacy alias IS microseconds: one type, one spelling.
        return String("timestamp_us")
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
    raise Error("canon: unknown arrow type id " + String(Int(t.type_id)))


def float_width_of(t: ArrowType) -> Int:
    if t == ArrowType.FLOAT16:
        return 16
    if t == ArrowType.FLOAT32:
        return 32
    if t == ArrowType.FLOAT64:
        return 64
    return 0


def _dtype_name(dt: DType) raises -> String:
    if dt == DType.int32:
        return String("int32")
    if dt == DType.int64:
        return String("int64")
    if dt == DType.float32:
        return String("float32")
    if dt == DType.float64:
        return String("float64")
    raise Error("canon: dictionary value type " + String(dt) + " is not rendered")


def _dict_value_type(col: Column[HeapRegion]) raises -> String:
    if col.is_string_dict():
        return String("string")
    if col.is_numeric_dict():
        return _dtype_name(col.dict_value_dtype())
    return String("")


def dict_float_width(col: Column[HeapRegion]) -> Int:
    """16/32/64 for a dictionary of floats, else 0."""
    if col.arrow_type != ArrowType.DICTIONARY or not col.is_numeric_dict():
        return 0
    var dt = col.dict_value_dtype()
    if dt == DType.float32:
        return 32
    if dt == DType.float64:
        return 64
    return 0


def column_float_width(f: Field, col: Column[HeapRegion]) -> Int:
    """The width the compare treats a top-level column's cells as floats
    of: a float column, or a dictionary of floats."""
    var w = float_width_of(f.arrow_type)
    if w > 0:
        return w
    return dict_float_width(col)


def _children_of_column(col: Column[HeapRegion]) raises -> String:
    """The <children> part spelled from the column's own child columns, or
    "" when it has none."""
    var t = col.arrow_type
    var n = col.num_children()
    if n == 0:
        return String("")
    if t == ArrowType.LIST or t == ArrowType.LARGE_LIST or t == ArrowType.FIXED_SIZE_LIST:
        return "<" + column_type(col.child_at(0)) + ">"
    if t == ArrowType.STRUCT:
        var s = String("<")
        for i in range(n):
            if i > 0:
                s += ","
            s += escape_name(col.field_name(i)) + ":" + column_type(col.child_at(i))
        return s + ">"
    if t == ArrowType.MAP:
        ref entries = col.child_at(0)
        if entries.num_children() != 2:
            raise Error("canon: a map's entries need two children")
        return (
            "<" + column_type(entries.child_at(0)) + ","
            + column_type(entries.child_at(1)) + ">"
        )
    if t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        var s = String("<")
        for i in range(n):
            if i > 0:
                s += ","
            s += column_type(col.child_at(i))
        return s + ">"
    return String("")


def _children_of_field(f: Field) raises -> String:
    var n = f.num_children()
    if n == 0:
        return String("")
    var t = f.arrow_type
    var listy = (
        t == ArrowType.LIST or t == ArrowType.LARGE_LIST
        or t == ArrowType.FIXED_SIZE_LIST
    )
    var s = String("<")
    for i in range(n):
        if i > 0:
            s += ","
        if not listy:
            s += escape_name(f.child_name(i)) + ":"
        s += arrow_type_name(f.child_arrow_type(i))
    return s + ">"


def _ids(ids: List[Int]) -> String:
    var s = String("(")
    for i in range(len(ids)):
        if i > 0:
            s += ","
        s += String(ids[i])
    return s + ")"


def column_type(col: Column[HeapRegion]) raises -> String:
    """The full type of a column below the top level."""
    var t = col.arrow_type
    var s = arrow_type_name(t)
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        s += "(" + String(col.decimal_precision()) + "," + String(col.decimal_scale()) + ")"
    elif t == ArrowType.FIXED_SIZE_BINARY or t == ArrowType.FIXED_SIZE_LIST:
        s += "(" + String(col._inner_size) + ")"
    elif t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        s += _ids(col.type_ids())
    elif t == ArrowType.DICTIONARY:
        s += "<" + String("int64" if col.dict_index_byte_width() == 8 else "int32")
        s += "," + _dict_value_type(col) + ">"
    return s + _children_of_column(col)


def field_column_type(f: Field, col: Column[HeapRegion]) raises -> String:
    """The full type of a top-level column: the Field's parameters, the
    column's tree below them."""
    var t = f.arrow_type
    var s = arrow_type_name(t)
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        s += "(" + String(f.decimal_precision) + "," + String(f.decimal_scale) + ")"
    elif t.is_timestamp():
        var tz = f.timezone()
        if tz.byte_length() > 0:
            s += "(" + escape_name(tz) + ")"
    elif t == ArrowType.FIXED_SIZE_BINARY or t == ArrowType.FIXED_SIZE_LIST:
        s += "(" + String(col._inner_size) + ")"
    elif t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        s += _ids(f.union_type_ids())
    elif t == ArrowType.DICTIONARY:
        s += "<" + arrow_type_name(f.dict_index_type())
        var v = _dict_value_type(col)
        if v.byte_length() > 0:
            s += "," + v
        s += ">"
    var kids = _children_of_column(col)
    if kids.byte_length() == 0:
        kids = _children_of_field(f)
    return s + kids


def field_only_type(f: Field) raises -> String:
    """A type spelled from the Field alone (a table with no chunks)."""
    var t = f.arrow_type
    var s = arrow_type_name(t)
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        s += "(" + String(f.decimal_precision) + "," + String(f.decimal_scale) + ")"
    elif t.is_timestamp():
        var tz = f.timezone()
        if tz.byte_length() > 0:
            s += "(" + escape_name(tz) + ")"
    elif t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        s += _ids(f.union_type_ids())
    elif t == ArrowType.DICTIONARY:
        s += "<" + arrow_type_name(f.dict_index_type()) + ">"
    return s + _children_of_field(f)


def schema_entry(f: Field, col: Column[HeapRegion]) raises -> String:
    var s = escape_name(f.name) + ":" + field_column_type(f, col)
    if f.nullable:
        s += "?"
    return s


def schema_entry_of_field(f: Field) raises -> String:
    var s = escape_name(f.name) + ":" + field_only_type(f)
    if f.nullable:
        s += "?"
    return s
