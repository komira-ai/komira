# Comparing two signatures. A difference is reported with the column and the
# field it is in; the comparison never stops at the first one.
#
# Rules:
# - row counts, column counts, per-column kinds, non-null counts, null counts
#   and NaN counts are equal;
# - integer columns compare their minimum and maximum exactly; their sum and
#   their sum of squares exactly while both sides stayed below 2^53 (mode
#   `exact`), and with the tolerance otherwise (mode `tolerance`);
# - other numeric columns compare with the tolerance: two numbers are equal
#   when they differ by at most the larger of the absolute floor and the
#   relative tolerance times the larger magnitude;
# - text columns compare the byte length of all cells, the smallest and the
#   largest cell exactly.
# Column names are not compared: engines name computed columns differently.

from .cells import KIND_INT, KIND_NULL, KIND_TEXT
from .signature import ColumnSignature, ResultSignature

comptime REL_TOL: Float64 = 1e-9
comptime ABS_FLOOR: Float64 = 1e-6


def numbers_close(a: Float64, b: Float64, rel_tol: Float64, abs_floor: Float64) -> Bool:
    """Whether `a` and `b` are equal under the tolerance."""
    var d = abs(a - b)
    var scale = abs(a)
    if abs(b) > scale:
        scale = abs(b)
    var allowed = rel_tol * scale
    if abs_floor > allowed:
        allowed = abs_floor
    return d <= allowed


def _relative_difference(a: Float64, b: Float64) -> Float64:
    var d = abs(a - b)
    var scale = abs(a)
    if abs(b) > scale:
        scale = abs(b)
    if scale == Float64(0):
        return Float64(0)
    return d / scale


struct ValueVerdict(Copyable, Movable):
    """The outcome of comparing an answer with a recorded one."""

    var identical: Bool
    var reasons: List[String]
    var modes: List[String]
    var max_rel: Float64

    def __init__(out self):
        self.identical = True
        self.reasons = List[String]()
        self.modes = List[String]()
        self.max_rel = Float64(0)

    def fail(mut self, reason: String):
        self.identical = False
        self.reasons.append(reason)

    def label(self) -> String:
        """`IDENTICAL`, or `DIVERGENT` with the first reason."""
        if self.identical:
            return String("IDENTICAL")
        return String("DIVERGENT: ") + self.reasons[0]


def _check_number(
    mut v: ValueVerdict,
    where: String,
    a: Float64,
    b: Float64,
    rel_tol: Float64,
    abs_floor: Float64,
):
    var rel = _relative_difference(a, b)
    if rel > v.max_rel:
        v.max_rel = rel
    if not numbers_close(a, b, rel_tol, abs_floor):
        v.fail(where + String(" differs: ") + String(a) + String(" against ") + String(b))


def _check_exact_int(mut v: ValueVerdict, where: String, a: Int64, b: Int64):
    if a != b:
        v.fail(where + String(" differs: ") + String(a) + String(" against ") + String(b))


def _check_field(
    mut v: ValueVerdict,
    col: String,
    field: String,
    exact: Bool,
    ia: Int64,
    ib: Int64,
    fa: Float64,
    fb: Float64,
    rel_tol: Float64,
    abs_floor: Float64,
):
    """One field of an integer column: exactly when both sides kept it exact,
    with the tolerance otherwise. The mode used is recorded."""
    if exact:
        _check_exact_int(v, col + String(" ") + field, ia, ib)
        v.modes.append(col + String(".") + field + String("=exact"))
    else:
        _check_number(v, col + String(" ") + field, fa, fb, rel_tol, abs_floor)
        v.modes.append(col + String(".") + field + String("=tolerance"))


def _compare_column(
    mut v: ValueVerdict,
    c: Int,
    a: ColumnSignature,
    b: ColumnSignature,
    rel_tol: Float64,
    abs_floor: Float64,
):
    var col = String("column ") + String(c)
    if a.mixed() or b.mixed():
        v.fail(col + String(" mixes numbers and texts"))
        return
    if a.kind() != b.kind():
        v.fail(col + String(" has kind ") + String(a.kind()) + String(" against ") + String(b.kind()))
        return
    if a.count != b.count:
        v.fail(col + String(" count differs: ") + String(a.count) + String(" against ") + String(b.count))
    if a.nulls != b.nulls:
        v.fail(col + String(" null count differs: ") + String(a.nulls) + String(" against ") + String(b.nulls))
    if a.nans != b.nans:
        v.fail(col + String(" NaN count differs: ") + String(a.nans) + String(" against ") + String(b.nans))
    var kind = a.kind()
    if kind == KIND_NULL:
        return
    if kind == KIND_TEXT:
        if a.text_bytes != b.text_bytes:
            v.fail(col + String(" text length differs: ") + String(a.text_bytes) + String(" against ") + String(b.text_bytes))
        if a.text_min != b.text_min:
            v.fail(col + String(" smallest text differs"))
        if a.text_max != b.text_max:
            v.fail(col + String(" largest text differs"))
        v.modes.append(col + String(".text=exact"))
        return
    if kind == KIND_INT:
        _check_field(v, col, String("sum"), a.sum_exact and b.sum_exact, a.isum, b.isum, a.sum, b.sum, rel_tol, abs_floor)
        _check_field(v, col, String("sumsq"), a.sumsq_exact and b.sumsq_exact, a.isumsq, b.isumsq, a.sumsq, b.sumsq, rel_tol, abs_floor)
        _check_field(v, col, String("min"), True, a.imin, b.imin, a.min_v, b.min_v, rel_tol, abs_floor)
        _check_field(v, col, String("max"), True, a.imax, b.imax, a.max_v, b.max_v, rel_tol, abs_floor)
        return
    _check_number(v, col + String(" sum"), a.sum, b.sum, rel_tol, abs_floor)
    _check_number(v, col + String(" sum of squares"), a.sumsq, b.sumsq, rel_tol, abs_floor)
    _check_number(v, col + String(" minimum"), a.min_v, b.min_v, rel_tol, abs_floor)
    _check_number(v, col + String(" maximum"), a.max_v, b.max_v, rel_tol, abs_floor)
    v.modes.append(col + String(".sum=tolerance"))


def compare_signatures(
    actual: ResultSignature,
    expected: ResultSignature,
    rel_tol: Float64 = REL_TOL,
    abs_floor: Float64 = ABS_FLOOR,
) -> ValueVerdict:
    """Compare `actual` with the recorded `expected` signature."""
    var v = ValueVerdict()
    if actual.rows != expected.rows:
        v.fail(String("row count differs: ") + String(actual.rows) + String(" against ") + String(expected.rows))
    if len(actual.columns) != len(expected.columns):
        v.fail(String("column count differs: ") + String(len(actual.columns)) + String(" against ") + String(len(expected.columns)))
        return v^
    for c in range(len(actual.columns)):
        _compare_column(v, c, actual.columns[c], expected.columns[c], rel_tol, abs_floor)
    return v^
