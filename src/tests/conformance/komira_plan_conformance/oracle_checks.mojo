# =============================================================================
# komira_plan_conformance/oracle_checks.mojo -- expectations tied to an
# upstream oracle file, and the Avro inputs' declared schema.
# =============================================================================
#
# Two checks for cases whose expected rows come from a file someone else
# wrote, not from a hand derivation alone:
#
#   check_rows_from    a case that names `RowsFrom` (a dataset, the columns it
#                      outputs, and at most one `<column> > <int>` filter)
#                      must expect exactly the dataset's rows, filtered and
#                      projected that way, as a multiset. scan_avro uses it:
#                      its expectations must equal upstream's weather.json
#                      (staged as datasets/weather.jsonl), so a hand edit to
#                      one row (22 -> 23) is refused. The filter is the
#                      case's filter restated, not read off the plan: the
#                      case registers both, and this check holds the
#                      expectation to the restatement.
#   check_avro_schema  an Avro object container file's header schema
#                      (`avro.schema` in the header metadata) must be a
#                      record whose fields have the declared columns' names,
#                      in order, and types: string -> string, long -> int64,
#                      int -> int32; a plain type is non-nullable, a union of
#                      "null" and one of those is nullable. Anything else is
#                      refused as unmodelled. This reads only the header (the
#                      magic, the metadata map), never a data block, so it
#                      does not re-test komira_avro's decoding.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_json import parse_json_value
from komira_json.value import JsonValue
from komira_plan_harness import CanonText, parse_canon
from komira_plan_harness.escape import escape_string
from komira_plan_harness.type_text import arrow_type_name


struct RowsFrom(Copyable, Movable):
    """Where a case's expected rows come from: every line of `dataset_path`
    (a JSON Lines file under the data root) whose `gt_column` value is
    greater than `gt_value` (every line when `gt_column` is empty), projected
    to `columns` in that order."""

    var dataset_path: String
    var columns: List[String]
    var gt_column: String
    var gt_value: Int64

    def __init__(
        out self,
        dataset_path: String,
        var columns: List[String],
        gt_column: String = String(),
        gt_value: Int64 = 0,
    ):
        self.dataset_path = dataset_path
        self.columns = columns^
        self.gt_column = gt_column
        self.gt_value = gt_value


def _cell_of(v: JsonValue) raises -> String:
    """A JSON scalar as canonical cell text: null, an integer, a string."""
    if v.is_null():
        return String("\\N")
    if v.is_string():
        return escape_string(v.as_string(), False)
    if v.is_integral_number():
        return String(v.as_int64())
    raise Error("the value " + v.serialize() + " is not null, an integer or a string")


def rows_from_text(spec: RowsFrom, jsonl: String) raises -> List[String]:
    """The rows `spec` selects from `jsonl`, each as its cells joined by
    TAB, in file order."""
    var res = List[String]()
    var line_no = 0
    for raw in jsonl.split("\n"):
        line_no += 1
        var line = String(raw)
        if line.byte_length() == 0:
            continue
        var obj = parse_json_value(line)
        if not obj.is_object():
            raise Error(spec.dataset_path + ":" + String(line_no) + ": not a JSON object")
        if spec.gt_column.byte_length() > 0:
            if not obj.has(spec.gt_column):
                raise Error(
                    spec.dataset_path + ":" + String(line_no) + ": no member '"
                    + spec.gt_column + "'"
                )
            var g = obj.get(spec.gt_column)
            # NULL > n is NULL, and a filter drops it (§1.2).
            if g.is_null() or g.as_int64() <= spec.gt_value:
                continue
        var row = String()
        for i in range(len(spec.columns)):
            if not obj.has(spec.columns[i]):
                raise Error(
                    spec.dataset_path + ":" + String(line_no) + ": no member '"
                    + spec.columns[i] + "'"
                )
            if i > 0:
                row += "\t"
            row += _cell_of(obj.get(spec.columns[i]))
        res.append(row^)
    return res^


def check_rows_from(
    label: String, spec: RowsFrom, expect_text: String, jsonl: String
) -> List[String]:
    """The expectation's column names and rows against the rows `spec`
    selects from `jsonl`, as a multiset. Reports every row on one side
    only."""
    var problems = List[String]()
    var where = "oracle: " + label + ": "
    var parsed: CanonText
    var want: List[String]
    try:
        parsed = parse_canon(expect_text)
        want = rows_from_text(spec, jsonl)
    except e:
        problems.append(where + String(e))
        return problems^
    if parsed.names != spec.columns:
        var got = String()
        for i in range(len(parsed.names)):
            got += (", " if i > 0 else "") + parsed.names[i]
        var exp = String()
        for i in range(len(spec.columns)):
            exp += (", " if i > 0 else "") + spec.columns[i]
        problems.append(
            where + "the expectation's columns are [" + got + "], the oracle's ["
            + exp + "]"
        )
        return problems^
    var used = List[Bool](length=len(want), fill=False)
    for r in range(parsed.num_rows()):
        var row = String()
        for c in range(parsed.num_columns()):
            if c > 0:
                row += "\t"
            row += parsed.rows[r][c]
        var hit = False
        for i in range(len(want)):
            if not used[i] and want[i] == row:
                used[i] = True
                hit = True
                break
        if not hit:
            problems.append(
                where + "expected row " + String(r + 1) + " `" + row
                + "` is not a row of " + spec.dataset_path
            )
    for i in range(len(want)):
        if not used[i]:
            problems.append(
                where + "the row `" + want[i] + "` of " + spec.dataset_path
                + " is missing from the expectation"
            )
    return problems^


# -----------------------------------------------------------------------------
# The Avro header schema
# -----------------------------------------------------------------------------


def _read_long(bs: List[UInt8], mut pos: Int) raises -> Int64:
    """One zig-zag varint (Avro `long`) at `pos`, advancing it."""
    var n = UInt64(0)
    var shift = UInt64(0)
    while True:
        if pos >= len(bs):
            raise Error("the header ends inside a varint")
        if shift > 63:
            raise Error("a varint is longer than 10 bytes")
        var b = bs[pos]
        pos += 1
        n |= UInt64(b & 0x7F) << shift
        if b < 0x80:
            break
        shift += 7
    return Int64(n >> 1) ^ -Int64(n & 1)


def _read_bytes(bs: List[UInt8], mut pos: Int) raises -> List[UInt8]:
    var n = _read_long(bs, pos)
    if n < 0 or Int(n) > len(bs) - pos:
        raise Error("a length of " + String(n) + " runs past the header")
    var res = List[UInt8](capacity=Int(n))
    for i in range(Int(n)):
        res.append(bs[pos + i])
    pos += Int(n)
    return res^


def _printable_ascii(bs: List[UInt8]) raises -> String:
    """`bs` as a String, refused unless every byte is printable ASCII or
    TAB/LF/CR (the weather schemas are), so no unvalidated byte reaches a
    String."""
    for b in bs:
        if not ((b >= 0x20 and b < 0x7F) or b == 9 or b == 10 or b == 13):
            raise Error("a header schema byte " + String(Int(b)) + " is not printable ASCII")
    return String(unsafe_from_utf8=Span(bs))


def avro_header_schema(bs: List[UInt8]) raises -> String:
    """The `avro.schema` value of an Avro object container file's header
    (magic `Obj` 0x01, then the metadata map), as text."""
    if len(bs) < 4 or bs[0] != 0x4F or bs[1] != 0x62 or bs[2] != 0x6A or bs[3] != 1:
        raise Error("not an Avro object container file (no `Obj` 0x01 magic)")
    var pos = 4
    while True:
        var count = _read_long(bs, pos)
        if count == 0:
            break
        if count < 0:
            count = -count
            _ = _read_long(bs, pos)  # the block's byte size
        for _ in range(Int(count)):
            var key = _printable_ascii(_read_bytes(bs, pos))
            var value = _read_bytes(bs, pos)
            if key == "avro.schema":
                return _printable_ascii(value)
    raise Error("the header has no avro.schema")


def _avro_primitive(name: String) -> Optional[ArrowType]:
    if name == "string":
        return ArrowType.STRING
    if name == "long":
        return ArrowType.INT64
    if name == "int":
        return ArrowType.INT32
    return None


def check_avro_schema(label: String, bs: List[UInt8], schema: Schema) -> List[String]:
    """The file's header schema against `schema` (see the module header)."""
    var problems = List[String]()
    var where = "avro: " + label + ": "
    try:
        var rec = parse_json_value(avro_header_schema(bs))
        if not rec.is_object() or not rec.has("fields") or not rec.get("fields").is_array():
            problems.append(where + "the header schema is not a record with fields")
            return problems^
        var fields = rec.get("fields")
        if fields.array_len() != schema.num_columns():
            problems.append(
                where + "the header schema has " + String(fields.array_len())
                + " fields, the declared schema " + String(schema.num_columns())
                + " columns"
            )
            return problems^
        for i in range(fields.array_len()):
            var f = fields.element_at(i)
            var name = f.get("name").as_string()
            var t = f.get("type")
            var arrow: Optional[ArrowType] = None
            var nullable = False
            if t.is_string():
                arrow = _avro_primitive(t.as_string())
            elif t.is_array() and t.array_len() == 2:
                for j in range(2):
                    var m = t.element_at(j)
                    if m.is_string() and m.as_string() == "null":
                        nullable = True
                    elif m.is_string():
                        arrow = _avro_primitive(m.as_string())
                if not nullable:
                    arrow = None
            if not arrow:
                problems.append(
                    where + "field " + String(i) + " '" + name + "' has type "
                    + t.serialize() + ", which this check does not model"
                )
                continue
            if name != schema.field_name(i):
                problems.append(
                    where + "field " + String(i) + " is '" + name
                    + "', the declared column is '" + schema.field_name(i) + "'"
                )
            var want_t = schema.field_arrow_type(i)
            if arrow.value() != want_t or nullable != schema.field_nullable(i):
                problems.append(
                    where + "field '" + name + "' is " + arrow_type_name(arrow.value())
                    + ("?" if nullable else "") + " in the header, the declared column "
                    + arrow_type_name(want_t) + ("?" if schema.field_nullable(i) else "")
                )
    except e:
        problems.append(where + String(e))
    return problems^
