"""A plan's shape as text, and the wire bytes a fixture's encoding holds.

`plan_shape` renders the plan arms the pandas door emits (SCAN, SORT, JOIN,
AGGREGATE). It reads the `*Data` payloads directly because the plan's own
render (`String(plan)`, which `structural_hash` folds) leaves fields out: it
emits no output schema, and it omits a sort's `nulls_first` when it equals the
placement derived from `descending`, which is exactly the
`na_position="first"` case on an ascending key. It raises on a plan arm or an
expression arm it does not render, so a door plan that grows a new node or
expression cannot compare equal by omission.

What it compares:
- SORT and JOIN: every payload field.
- AGGREGATE: every payload field, with `udf` and `group_topk` compared as
  set or unset only.
- SCAN: the source, `source_path`, `source_type`, `schema`, `projection`,
  `filter`, `row_count`, whether `table_stats` is set, `source_kind`.
- A binding-backed source: every carried field of its `ScanBinding`, with
  `stats` as set or unset only; `handle` and `registry_epoch` are
  process-local and not compared.
- Every schema: per field, name, Arrow type, dtype, nullability, decimal
  precision and scale, time zone, dictionary index type, flags, union type
  ids, children; the field's metadata by count only (`Field` publishes no
  key list).
- Expressions: column references (name and side).

What it does not compare, and why:
- A non-binding source (the parquet leaves) is compared only through what
  `SourceVariant` publishes: kind name, fingerprint, structural id and schema.
  `ParquetSource.fingerprint()` folds the paths, the mtime and the partition
  column NAMES. The parquet arm itself is private, so the rest of what the
  wire carries for it is not compared: the `name` (`WireParquetSource` fields
  3 and 4), the partition columns' types (field 6) and the partition values
  (field 7). Fields 8 to 10 (`hive_dir_scan`, `has_hive_predicate`,
  `fs_is_local`) are not compared either; the decoder refuses a hive scan and
  a non-local file system, so a decoded plan holds only their defaults. The
  door's parquet fixtures set none of them.
- `ScanData.payload_narrow`: an optimizer annotation that the wire does not
  carry, so a decoded plan always has it empty.

`wire_bytes_from_hex` reads the hex format `proto_encode` writes (hex digits,
whitespace ignored).
"""

from komira_arrow.schema import Field, Schema
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_expr.expr import Expr, EXPR_COL_REF
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SCAN,
    PLAN_SORT,
)
from komira_scan_source.scan_binding import ScanBinding
from komira_scan_source.scan_params import PARAM_BYTES, PARAM_F64, PARAM_STR
from komira_scan_source.source_variant import SourceVariant


def _b(v: Bool) -> String:
    return String("T") if v else String("F")


def _bools(v: List[Bool]) -> String:
    var out = String("[")
    for i in range(len(v)):
        out += _b(v[i])
    out += "]"
    return out^


def _strs(v: List[String]) -> String:
    var out = String("[")
    for i in range(len(v)):
        if i > 0:
            out += ","
        out += v[i]
    out += "]"
    return out^


def field_shape(f: Field) -> String:
    """Every carried slot of a `Field` through its public accessors; the
    metadata by count only (`Field` publishes no key list)."""
    var out = (
        String("F(") + f.name
        + " arrow=" + String(Int(f.arrow_type.type_id))
        + " dtype=" + String(f.dtype)
        + " nullable=" + _b(f.nullable)
        + " dec=" + String(f.decimal_precision) + "," + String(f.decimal_scale)
        + " tz=" + f.timezone()
        + " dict_index=" + String(Int(f.dict_index_type().type_id))
        + " flags=" + String(Int(f.flags()))
        + " metadata=" + String(f.metadata_count())
        + " union_ids=["
    )
    var ids = f.union_type_ids()
    for i in range(len(ids)):
        if i > 0:
            out += ","
        out += String(ids[i])
    out += "] children=["
    for i in range(f.num_children()):
        if i > 0:
            out += ","
        out += (
            f.child_name(i) + ":" + String(Int(f.child_arrow_type(i).type_id))
            + _b(f.child_nullable(i))
        )
    out += "])"
    return out^


def schema_shape(s: Schema) raises -> String:
    var out = String("S[")
    for i in range(s.num_columns()):
        if i > 0:
            out += " "
        out += field_shape(s.field_at(i))
    out += "]"
    return out^


def expr_shape(e: Expr) raises -> String:
    """The door's expressions are column references; anything else raises."""
    if e.tag == EXPR_COL_REF:
        return (
            String("col(") + e.col_ref_name() + ",side="
            + String(Int(e.col_ref_side())) + ")"
        )
    raise Error(
        "plan_shape: expression tag " + String(Int(e.tag))
        + " is not one the pandas door emits; render it before comparing"
    )


def _opt_expr_shape(e: Optional[Expr]) raises -> String:
    if e:
        return expr_shape(e.value())
    return String("-")


def agg_shape(a: AggExpr) raises -> String:
    """All four sparse child slots, read as four, and the alias."""
    var alias_txt = String("-")
    if a.alias_name:
        alias_txt = a.alias_name.value()
    return (
        String("A(func=") + String(Int(a.func))
        + " child=" + _opt_expr_shape(a.child)
        + " child1=" + _opt_expr_shape(a.child1)
        + " child2=" + _opt_expr_shape(a.child2)
        + " child3=" + _opt_expr_shape(a.child3)
        + " alias=" + alias_txt + ")"
    )


def binding_shape(b: ScanBinding) raises -> String:
    """Every carried field of a binding. `handle` and `registry_epoch` are
    process-local and not on the wire, so they are not compared."""
    var params = String("P[")
    for i in range(b.params.num_params()):
        if i > 0:
            params += " "
        var v = b.params.value_at(i)
        params += b.params.key_at(i) + "=" + String(Int(v.tag)) + ":"
        if v.tag == PARAM_STR or v.tag == PARAM_BYTES:
            params += v.s
        elif v.tag == PARAM_F64:
            params += String(v.f)
        else:
            params += String(Int(v.i))
    params += "]"
    ref g = b.pushdown_gate
    return (
        String("B(kind_id=") + String(Int(b.kind_id))
        + " kind_name=" + b.kind_name
        + " name=" + b.name
        + " params=" + params
        + " schema=" + schema_shape(b.schema)
        + " stats=" + _b(b.stats.__bool__())
        + " fingerprint=" + String(b.fingerprint)
        + " structural_id=" + String(b.structural_id)
        + " gate=" + String(Int(g.mode)) + ","
        + String(Int(g.allowed_binary_ops)) + ","
        + _b(g.allow_and_recurse) + _b(g.allow_in_list)
        + _b(g.require_stat_friendly_col)
        + " extra_cols=" + _strs(b.pushdown_extra_cols)
        + " snapshot=" + String(Int(b.snapshot_policy)) + ","
        + String(b.snapshot_token)
        + " orientation=" + String(Int(b.orientation))
        + " legacy=" + String(Int(b.legacy_source_type)) + ")"
    )


def source_shape(s: SourceVariant) raises -> String:
    """A binding-backed source by its binding; any other source by what
    `SourceVariant` publishes (its kind, fingerprint, structural id and
    schema). A parquet source's fingerprint folds its paths, its mtime and
    its partition column names; see the module docstring for what is left."""
    var out = String("src(tag=") + String(Int(s.tag)) + " "
    if s.is_binding_backed():
        out += binding_shape(s.binding_ref())
    else:
        out += (
            String("kind=") + s.kind_name()
            + " fingerprint=" + String(s.fingerprint())
            + " structural_id=" + String(s.structural_id())
            + " schema=" + schema_shape(s.schema())
        )
    out += ")"
    return out^


def plan_shape(p: LogicalPlan) raises -> String:
    """The full shape of a door plan. Raises on an arm it does not render."""
    var head = (
        String("[") + String(Int(p.tag)) + " out=" + schema_shape(p.output_schema)
        + " "
    )
    if p.tag == PLAN_SCAN:
        ref d = p.scan_data_ref()
        var sch = String("-")
        if d.schema:
            sch = schema_shape(d.schema.value())
        var proj = String("-")
        if d.projection:
            proj = _strs(d.projection.value())
        var rc = String("-")
        if d.row_count:
            rc = String(d.row_count.value())
        return (
            head + "SCAN " + source_shape(d.source)
            + " path=" + d.source_path
            + " source_type=" + String(Int(d.source_type))
            + " schema=" + sch
            + " projection=" + proj
            + " filter=" + _opt_expr_shape(d.filter)
            + " row_count=" + rc
            + " table_stats=" + _b(d.table_stats.__bool__())
            + " source_kind=" + String(Int(d.source_kind)) + "]"
        )
    if p.tag == PLAN_SORT:
        ref d = p.sort_data_ref()
        return (
            head + "SORT keys=" + _strs(d.keys)
            + " descending=" + _bools(d.descending)
            + " nulls_first=" + _bools(d.nulls_first)
            + " child=" + plan_shape(d.child[]) + "]"
        )
    if p.tag == PLAN_JOIN:
        ref d = p.join_data_ref()
        var res = String("-")
        if d.residual:
            res = expr_shape(d.residual.value()[])
        return (
            head + "JOIN left_on=" + _strs(d.left_on)
            + " right_on=" + _strs(d.right_on)
            + " join_type=" + String(Int(d.join_type))
            + " algo_hint=" + String(Int(d.algo_hint))
            + " residual=" + res
            + " left=" + plan_shape(d.left[])
            + " right=" + plan_shape(d.right[]) + "]"
        )
    if p.tag == PLAN_AGGREGATE:
        ref d = p.aggregate_data_ref()
        var gb = String("[")
        for i in range(len(d.group_by)):
            if i > 0:
                gb += " "
            gb += expr_shape(d.group_by[i])
        gb += "]"
        var ax = String("[")
        for i in range(len(d.agg_exprs)):
            if i > 0:
                ax += " "
            ax += agg_shape(d.agg_exprs[i])
        ax += "]"
        var eg = String("-")
        if d.estimated_groups:
            eg = String(d.estimated_groups.value())
        return (
            head + "AGGREGATE group_by=" + gb + " aggs=" + ax
            + " estimated_groups=" + eg
            + " udf=" + _b(d.udf.__bool__())
            + " group_topk=" + _b(d.group_topk.__bool__())
            + " child=" + plan_shape(d.child[]) + "]"
        )
    raise Error(
        "plan_shape: plan tag " + String(Int(p.tag))
        + " is not one the pandas door emits; render it before comparing"
    )


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + 10
    raise Error("wire hex: byte " + String(Int(c)) + " is not a hex digit")


def wire_bytes_from_hex(text: String) raises -> List[UInt8]:
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c == UInt8(ord(" ")) or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r")) or c == UInt8(ord("\t"))
        ):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) == 0 or len(nibbles) % 2 != 0:
        raise Error(
            "wire hex: " + String(len(nibbles))
            + " hex digits; a fixture's encoding is a non-empty even count"
        )
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^
