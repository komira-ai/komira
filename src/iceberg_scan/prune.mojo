# =============================================================================
# iceberg_scan/prune.mojo -- which files a scan's filter can skip
# =============================================================================
#
# WHAT THIS IS. The evaluator behind file skipping (docs/design/iceberg_tables.md,
# "Pruning"). Pruning never changes a result: a file is skipped only when it
# provably holds no row that passes the filter, and every doubt reads as "may
# match". The scan's pushed filter is also kept as an operator above the scan,
# so a file this evaluator keeps but whose rows fail the filter is filtered
# there.
#
# WHAT IT UNDERSTANDS, per conjunct of the filter: `col <op> literal` and
# `literal <op> col` (=, <>, <, <=, >, >=), `col IS NULL` and `col IS NOT NULL`,
# where `col` is a column of type int, long, date, timestamp, timestamptz,
# float, double, string or boolean, and the literal is of that column's kind
# (an integer for the integer family, a date for date, a timestamp for the
# timestamps, a float, or an integer exactly representable as a double, for
# float and double, a string, a boolean). Any other conjunct is ignored.
#
# THE RULES (each is a case in tests/test_iceberg_prune.mojo):
#   * A missing metric is "may match".
#   * NaN is never a bound. On a float or double column `>` and `>=` skip by the
#     upper bound only when the file's NaN count is present and 0, because
#     DuckDB orders NaN above every number. A NaN literal never skips.
#   * `<>` never skips.
#   * IS NULL skips a file whose null count is 0. IS NOT NULL and every
#     comparison skip a file whose null count equals its value count (every row
#     is null).
#   * A bound decodes by its stored length: an int bound (4 bytes) under a
#     column now typed long reads as 4 bytes.
#   * String bounds compare as unsigned bytes. A string bound may be truncated:
#     a lower bound is a prefix of the least value and so still bounds it from
#     below, and an upper bound skips only when it is smaller than the literal
#     and is not a prefix of it, which holds whether or not the writer
#     incremented its last character.
#   * Partitions: an identity transform's value is compared with the predicate
#     on the entry's partition tuple and on the manifest list's partition
#     summaries. Other transforms are not projected in this slice: they may match.
# =============================================================================

from std.memory import bitcast

from plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_UNARY_OP,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    COL_SIDE_NONE,
)
from plan_expr.expr_helpers import flatten_and_conjuncts
from plan_expr.scalar_value import ScalarValue

from .manifests import IcebergFileEntry, IcebergManifestFile
from .table_metadata import IcebergField, IcebergPartitionSpecDef


comptime PRUNE_EQ: Int = 0
comptime PRUNE_NE: Int = 1
comptime PRUNE_LT: Int = 2
comptime PRUNE_LE: Int = 3
comptime PRUNE_GT: Int = 4
comptime PRUNE_GE: Int = 5
comptime PRUNE_IS_NULL: Int = 6
comptime PRUNE_IS_NOT_NULL: Int = 7

comptime _V_INT: Int = 0
comptime _V_FLOAT: Int = 1
comptime _V_BYTES: Int = 2

comptime _TWO_53: Int64 = 9007199254740992


struct _Val(Copyable, Movable):
    """A bound or a literal: an integer, a float or bytes."""

    var kind: Int
    var i: Int64
    var f: Float64
    var b: List[UInt8]

    def __init__(out self, kind: Int):
        self.kind = kind
        self.i = 0
        self.f = 0.0
        self.b = List[UInt8]()


struct IcebergPrunePredicate(Copyable, Movable):
    """One understood conjunct: an operator on a column and its literal."""

    var field_id: Int
    var column: String
    var type_name: String
    var op: Int
    var lit: _Val

    def __init__(
        out self,
        field_id: Int,
        var column: String,
        var type_name: String,
        op: Int,
        var lit: _Val,
    ):
        self.field_id = field_id
        self.column = column^
        self.type_name = type_name^
        self.op = op
        self.lit = lit^


# =============================================================================
# The predicates of a filter.
# =============================================================================


def _is_int_family(t: String) -> Bool:
    return t == "int" or t == "long" or t == "date" or t == "timestamp" or t == "timestamptz"


def _column_index(columns: List[IcebergField], name: String) -> Int:
    for i in range(len(columns)):
        if columns[i].name == name:
            return i
    return -1


def _literal_of(type_name: String, v: ScalarValue) -> Optional[_Val]:
    """The literal `v` as a value comparable with a bound of `type_name`, or
    None when its kind is not the column's."""
    if v.is_null():
        return None
    if type_name == "int" or type_name == "long":
        if v.fits_int64_family():
            var out = _Val(_V_INT)
            out.i = v.int_val
            return Optional[_Val](out^)
    elif type_name == "date":
        if v.is_date32():
            var out = _Val(_V_INT)
            out.i = Int64(Int(v.date32_val))
            return Optional[_Val](out^)
    elif type_name == "timestamp" or type_name == "timestamptz":
        if v.is_timestamp():
            var out = _Val(_V_INT)
            out.i = v.ts_micros
            return Optional[_Val](out^)
    elif type_name == "float" or type_name == "double":
        if v.is_float():
            var out = _Val(_V_FLOAT)
            out.f = v.float_val
            return Optional[_Val](out^)
        if v.fits_int64_family() and v.int_val > -_TWO_53 and v.int_val < _TWO_53:
            var out = _Val(_V_FLOAT)
            out.f = Float64(v.int_val)
            return Optional[_Val](out^)
    elif type_name == "string":
        if v.is_string():
            var out = _Val(_V_BYTES)
            for b in v.string_val.as_bytes():
                out.b.append(b)
            return Optional[_Val](out^)
    elif type_name == "boolean":
        if v.is_bool():
            var out = _Val(_V_INT)
            out.i = Int64(1) if v.bool_val else Int64(0)
            return Optional[_Val](out^)
    return None


def _prune_op_of(bin_op: UInt8) -> Int:
    """The prune operator of a comparison `BIN_*`, or -1."""
    if bin_op == BIN_EQ:
        return PRUNE_EQ
    elif bin_op == BIN_NE:
        return PRUNE_NE
    elif bin_op == BIN_LT:
        return PRUNE_LT
    elif bin_op == BIN_LE:
        return PRUNE_LE
    elif bin_op == BIN_GT:
        return PRUNE_GT
    elif bin_op == BIN_GE:
        return PRUNE_GE
    return -1


def _mirrored(op: Int) -> Int:
    """The operator for `literal op col` read as `col op' literal`."""
    if op == PRUNE_LT:
        return PRUNE_GT
    elif op == PRUNE_LE:
        return PRUNE_GE
    elif op == PRUNE_GT:
        return PRUNE_LT
    elif op == PRUNE_GE:
        return PRUNE_LE
    return op


def _is_plain_col(e: Expr) -> Bool:
    return e.tag == EXPR_COL_REF and e.col_ref_side() == COL_SIDE_NONE


def _conjunct_predicate(
    e: Expr, columns: List[IcebergField]
) -> Optional[IcebergPrunePredicate]:
    var col_expr_name = String("")
    var op = -1
    var lit = Optional[ScalarValue](None)
    if e.tag == EXPR_UNARY_OP:
        var un = e.unary_op()
        if (un == UN_IS_NULL or un == UN_IS_NOT_NULL) and _is_plain_col(
            e.unary_child_ref()
        ):
            col_expr_name = e.unary_child_ref().col_ref_name()
            op = PRUNE_IS_NULL if un == UN_IS_NULL else PRUNE_IS_NOT_NULL
    elif e.tag == EXPR_BINARY_OP:
        var bop = _prune_op_of(e.binary_op())
        if bop >= 0:
            if _is_plain_col(e.binary_left_ref()) and e.binary_right_ref().tag == EXPR_LITERAL:
                col_expr_name = e.binary_left_ref().col_ref_name()
                op = bop
                lit = Optional[ScalarValue](e.binary_right_ref().literal_value())
            elif _is_plain_col(e.binary_right_ref()) and e.binary_left_ref().tag == EXPR_LITERAL:
                col_expr_name = e.binary_right_ref().col_ref_name()
                op = _mirrored(bop)
                lit = Optional[ScalarValue](e.binary_left_ref().literal_value())
    if op < 0:
        return None
    var ci = _column_index(columns, col_expr_name)
    if ci < 0:
        return None
    ref col = columns[ci]
    var t = col.type_name
    if not (_is_int_family(t) or t == "float" or t == "double" or t == "string" or t == "boolean"):
        return None
    if op == PRUNE_IS_NULL or op == PRUNE_IS_NOT_NULL:
        return Optional[IcebergPrunePredicate](
            IcebergPrunePredicate(col.id, col.name, t, op, _Val(_V_INT))
        )
    var value = _literal_of(t, lit.value())
    if not value:
        return None
    return Optional[IcebergPrunePredicate](
        IcebergPrunePredicate(col.id, col.name, t, op, value.take())
    )


def prune_predicates_of(
    filter: Optional[Expr], columns: List[IcebergField]
) -> List[IcebergPrunePredicate]:
    """The conjuncts of `filter` this evaluator understands (module header),
    bound to `columns`; every other conjunct is dropped."""
    var out = List[IcebergPrunePredicate]()
    if not filter:
        return out^
    var conjuncts = flatten_and_conjuncts(filter.value())
    for i in range(len(conjuncts)):
        var p = _conjunct_predicate(conjuncts[i], columns)
        if p:
            out.append(p.take())
    return out^


# =============================================================================
# Values.
# =============================================================================


def _compare_bytes(a: List[UInt8], b: List[UInt8]) -> Int:
    """Unsigned lexicographic order: -1, 0 or 1."""
    var n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    if len(a) == len(b):
        return 0
    return -1 if len(a) < len(b) else 1


def _compare(a: _Val, b: _Val) -> Int:
    """-1, 0 or 1; the values are of one kind and floats are not NaN."""
    if a.kind == _V_BYTES:
        return _compare_bytes(a.b, b.b)
    if a.kind == _V_FLOAT:
        if a.f < b.f:
            return -1
        return 1 if a.f > b.f else 0
    if a.i < b.i:
        return -1
    return 1 if a.i > b.i else 0


def _starts_with(s: List[UInt8], prefix: List[UInt8]) -> Bool:
    if len(prefix) > len(s):
        return False
    for i in range(len(prefix)):
        if s[i] != prefix[i]:
            return False
    return True


def _le_uint(bytes: List[UInt8], width: Int) -> UInt64:
    var v: UInt64 = 0
    for k in range(width):
        v |= UInt64(bytes[k]) << UInt64(8 * k)
    return v


def _decode_bound(type_name: String, bytes: List[UInt8]) -> Optional[_Val]:
    """A stored bound or partition value as a value, decoded by its stored
    length; None when the length does not fit the type or the value is NaN."""
    var n = len(bytes)
    if _is_int_family(type_name):
        var out = _Val(_V_INT)
        if n == 4:
            out.i = Int64(bitcast[DType.int32, 1](UInt32(_le_uint(bytes, 4))))
        elif n == 8:
            out.i = bitcast[DType.int64, 1](_le_uint(bytes, 8))
        else:
            return None
        return Optional[_Val](out^)
    elif type_name == "float" or type_name == "double":
        var out = _Val(_V_FLOAT)
        if n == 4:
            out.f = Float64(bitcast[DType.float32, 1](UInt32(_le_uint(bytes, 4))))
        elif n == 8:
            out.f = bitcast[DType.float64, 1](_le_uint(bytes, 8))
        else:
            return None
        if out.f != out.f:
            return None
        return Optional[_Val](out^)
    elif type_name == "string":
        var out = _Val(_V_BYTES)
        out.b = bytes.copy()
        return Optional[_Val](out^)
    elif type_name == "boolean":
        if n != 1:
            return None
        var out = _Val(_V_INT)
        out.i = Int64(1) if bytes[0] != 0 else Int64(0)
        return Optional[_Val](out^)
    return None


def _decoded(type_name: String, bytes: Optional[List[UInt8]]) -> Optional[_Val]:
    if not bytes:
        return None
    return _decode_bound(type_name, bytes.value())


# =============================================================================
# The comparison rules.
# =============================================================================


def _upper_below(upper: _Val, lit: _Val) -> Bool:
    """Every value at or under `upper` is strictly below `lit`. For strings
    `upper` may be a truncated prefix, so it must also not be a prefix of
    `lit` (a longer true maximum could then reach it)."""
    if _compare(upper, lit) >= 0:
        return False
    if upper.kind == _V_BYTES:
        return not _starts_with(lit.b, upper.b)
    return True


def _upper_at_most(upper: _Val, lit: _Val) -> Bool:
    """Every value at or under `upper` is at most `lit`."""
    if upper.kind == _V_BYTES:
        return _upper_below(upper, lit)
    return _compare(upper, lit) <= 0


def _bounds_may_match(
    p: IcebergPrunePredicate,
    lower: Optional[_Val],
    upper: Optional[_Val],
    nan_free: Bool,
) -> Bool:
    """Whether a comparison can hold for some value in [lower, upper]; a
    missing bound is unbounded. `nan_free`: no value is NaN."""
    if p.op == PRUNE_NE:
        return True
    if p.lit.kind == _V_FLOAT and p.lit.f != p.lit.f:
        return True
    var float_col = p.lit.kind == _V_FLOAT
    if p.op == PRUNE_EQ:
        if lower and _compare(p.lit, lower.value()) < 0:
            return False
        if upper and _upper_below(upper.value(), p.lit):
            return False
    elif p.op == PRUNE_LT:
        if lower and _compare(lower.value(), p.lit) >= 0:
            return False
    elif p.op == PRUNE_LE:
        if lower and _compare(lower.value(), p.lit) > 0:
            return False
    elif p.op == PRUNE_GT:
        if upper and (nan_free or not float_col) and _upper_at_most(upper.value(), p.lit):
            return False
    elif p.op == PRUNE_GE:
        if upper and (nan_free or not float_col) and _upper_below(upper.value(), p.lit):
            return False
    return True


def _metrics_may_match(p: IcebergPrunePredicate, e: IcebergFileEntry) -> Bool:
    var nulls = e.null_value_counts.get(p.field_id)
    if p.op == PRUNE_IS_NULL:
        if nulls and nulls.value() == 0:
            return False
        return True
    var values = e.value_counts.get(p.field_id)
    var all_null = Bool(nulls) and Bool(values) and nulls.value() == values.value()
    if p.op == PRUNE_IS_NOT_NULL:
        return not all_null
    if p.op == PRUNE_NE:
        return True
    if all_null:
        return False
    var nans = e.nan_value_counts.get(p.field_id)
    var nan_free = Bool(nans) and nans.value() == 0
    return _bounds_may_match(
        p,
        _decoded(p.type_name, e.lower_bounds.get(p.field_id)),
        _decoded(p.type_name, e.upper_bounds.get(p.field_id)),
        nan_free,
    )


def _partition_value_may_match(
    p: IcebergPrunePredicate, value: Optional[List[UInt8]]
) -> Bool:
    """The predicate on the one value every row of a file holds for an
    identity partition field (None: null)."""
    if not value:
        return p.op == PRUNE_IS_NULL
    if p.op == PRUNE_IS_NULL:
        return False
    if p.op == PRUNE_IS_NOT_NULL:
        return True
    var v = _decode_bound(p.type_name, value.value())
    return _bounds_may_match(p, v.copy(), v.copy(), True)


def entry_may_match(
    entry: IcebergFileEntry,
    spec: IcebergPartitionSpecDef,
    preds: List[IcebergPrunePredicate],
) -> Bool:
    """False only when `entry` provably holds no row passing every predicate:
    by an identity partition value of its tuple, or by its column metrics."""
    for pi in range(len(preds)):
        ref p = preds[pi]
        for k in range(len(spec.fields)):
            ref f = spec.fields[k]
            if f.transform == "identity" and f.source_id == p.field_id and k < len(entry.partition):
                if not _partition_value_may_match(p, entry.partition[k].copy()):
                    return False
        if not _metrics_may_match(p, entry):
            return False
    return True


def _summary_may_match(p: IcebergPrunePredicate, m: IcebergManifestFile, k: Int) -> Bool:
    ref s = m.partitions[k]
    if p.op == PRUNE_IS_NULL:
        return s.contains_null
    if p.op == PRUNE_IS_NOT_NULL or p.op == PRUNE_NE:
        return True
    var nan_free = Bool(s.contains_nan) and not s.contains_nan.value()
    return _bounds_may_match(
        p,
        _decoded(p.type_name, s.lower.copy()),
        _decoded(p.type_name, s.upper.copy()),
        nan_free,
    )


def manifest_may_match(
    m: IcebergManifestFile,
    spec: IcebergPartitionSpecDef,
    preds: List[IcebergPrunePredicate],
) -> Bool:
    """False only when the manifest's partition summaries show that no file of
    it can hold a row passing every predicate. A manifest whose list entry
    carries no summaries, or one per spec field fewer, may match."""
    if len(m.partitions) != len(spec.fields):
        return True
    for pi in range(len(preds)):
        ref p = preds[pi]
        for k in range(len(spec.fields)):
            ref f = spec.fields[k]
            if f.transform == "identity" and f.source_id == p.field_id:
                if not _summary_may_match(p, m, k):
                    return False
    return True
