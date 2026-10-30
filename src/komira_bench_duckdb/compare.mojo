# Comparing two signatures. A difference is reported with the column and the
# field it is in; the comparison never stops at the first one.
#
# Rules:
# - row counts, column counts, per-column kinds, non-null counts, null counts
#   and NaN counts are equal; when both results have no rows the columns are
#   not compared (a result with no rows carries no column names);
# - integer columns compare their minimum and maximum, their sum and their sum
#   of squares exactly (the sums modulo 2^64, mode `exact`);
# - a numeric column that is integers on one side and doubles on the other
#   (engines return SUM, COUNT or AVG as different types) compares as numbers,
#   with the tolerance (mode `tolerance`);
# - other numeric columns compare with the tolerance: two numbers are equal
#   when they are the same value (infinities included) or differ by at most
#   the larger of the absolute floor and the relative tolerance times the
#   larger magnitude;
# - an exact decimal column (a DECIMAL, or integers past 64 bits) compares its
#   count of decimals, their exact sum, their smallest and largest value and the
#   hash sum of their canonical texts exactly, and the integers among them as
#   an integer column does; a decimal column against a column of any other kind,
#   a double column included, is a difference of kinds, never a tolerance;
# - text columns compare the byte length of all cells, the smallest and the
#   largest cell, and the sum of a hash of each cell, exactly.
# - the declared type of each column (declared_types.mojo) is compared before the
#   values, and a difference is a failure of its own (`type_reasons`, also in
#   `reasons`): DECIMAL(38,2) against DECIMAL(38,4), or BIGINT against
#   DECIMAL(18,0), fails even when the values agree. A type outside the
#   vocabulary fails, even against itself. Types recorded on one side only fail,
#   and when neither side has any (a result built by hand) there is nothing to
#   compare. With no rows on both sides the types are compared only when both
#   sides have them.
# Column names are not compared: engines name computed columns differently.

from .cells import KIND_DECIMAL, KIND_FLOAT, KIND_INT, KIND_NULL, KIND_TEXT
from .declared_types import is_unmapped
from .signature import ColumnSignature, ResultSignature

comptime REL_TOL: Float64 = 1e-9
comptime ABS_FLOOR: Float64 = 1e-6


def numbers_close(a: Float64, b: Float64, rel_tol: Float64, abs_floor: Float64) -> Bool:
    """Whether `a` and `b` are equal under the tolerance. The same value is
    always close (two infinities of one sign included); NaN is close to
    nothing."""
    if a == b:
        return True
    if a - a != Float64(0) or b - b != Float64(0):
        return False  # a NaN or an infinity that is not the other value
    var d = abs(a - b)
    var scale = abs(a)
    if abs(b) > scale:
        scale = abs(b)
    var allowed = rel_tol * scale
    if abs_floor > allowed:
        allowed = abs_floor
    return d <= allowed


def _relative_difference(a: Float64, b: Float64) -> Float64:
    if a == b:
        return Float64(0)
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
    var type_reasons: List[String]
    var modes: List[String]
    var max_rel: Float64

    def __init__(out self):
        self.identical = True
        self.reasons = List[String]()
        self.type_reasons = List[String]()
        self.modes = List[String]()
        self.max_rel = Float64(0)

    def fail(mut self, reason: String):
        self.identical = False
        self.reasons.append(reason)

    def fail_type(mut self, reason: String):
        """A failure of the declared types, kept apart from value failures."""
        self.fail(reason)
        self.type_reasons.append(reason)

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


def kind_name(kind: Int) -> String:
    """A column kind as its number and its name."""
    var name = String("no value")
    if kind == KIND_INT:
        name = String("integer")
    elif kind == KIND_FLOAT:
        name = String("double")
    elif kind == KIND_TEXT:
        name = String("text")
    elif kind == KIND_DECIMAL:
        name = String("exact decimal")
    return String(kind) + String(" (") + name + String(")")


def _check_exact_int(mut v: ValueVerdict, where: String, a: Int64, b: Int64):
    if a != b:
        v.fail(where + String(" differs: ") + String(a) + String(" against ") + String(b))


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
        v.fail(col + String(" mixes values that cannot be compared (numbers and texts, or exact decimals and doubles)"))
        return
    var numeric_mix = (
        (a.kind() == KIND_INT and b.kind() == KIND_FLOAT)
        or (a.kind() == KIND_FLOAT and b.kind() == KIND_INT)
    )
    if a.kind() != b.kind() and not numeric_mix:
        v.fail(col + String(" has kind ") + kind_name(a.kind()) + String(" against ") + kind_name(b.kind()))
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
        if a.text_hash != b.text_hash:
            v.fail(col + String(" texts differ (the hash sum of the cells)"))
        v.modes.append(col + String(".text=exact"))
        return
    if kind == KIND_DECIMAL:
        if a.dcount != b.dcount:
            v.fail(col + String(" decimal count differs: ") + String(a.dcount) + String(" against ") + String(b.dcount))
        var sa = a.dsum.text()
        var sb = b.dsum.text()
        if sa != sb:
            v.fail(col + String(" sum differs: ") + sa + String(" against ") + sb)
        if a.dmin != b.dmin:
            v.fail(col + String(" minimum differs: ") + a.dmin + String(" against ") + b.dmin)
        if a.dmax != b.dmax:
            v.fail(col + String(" maximum differs: ") + a.dmax + String(" against ") + b.dmax)
        if a.dhash != b.dhash:
            v.fail(col + String(" decimals differ (the hash sum of the cells)"))
        _check_exact_int(v, col + String(" integer sum"), a.isum, b.isum)
        _check_exact_int(v, col + String(" integer sum of squares"), a.isumsq, b.isumsq)
        _check_exact_int(v, col + String(" integer minimum"), a.imin, b.imin)
        _check_exact_int(v, col + String(" integer maximum"), a.imax, b.imax)
        v.modes.append(col + String(".sum=exact"))
        return
    if kind == KIND_INT and not numeric_mix:
        _check_exact_int(v, col + String(" sum"), a.isum, b.isum)
        _check_exact_int(v, col + String(" sum of squares"), a.isumsq, b.isumsq)
        _check_exact_int(v, col + String(" minimum"), a.imin, b.imin)
        _check_exact_int(v, col + String(" maximum"), a.imax, b.imax)
        v.modes.append(col + String(".sum=exact"))
        return
    _check_number(v, col + String(" sum"), a.sum, b.sum, rel_tol, abs_floor)
    _check_number(v, col + String(" sum of squares"), a.sumsq, b.sumsq, rel_tol, abs_floor)
    _check_number(v, col + String(" minimum"), a.min_v, b.min_v, rel_tol, abs_floor)
    _check_number(v, col + String(" maximum"), a.max_v, b.max_v, rel_tol, abs_floor)
    v.modes.append(col + String(".sum=tolerance"))


def _compare_types(mut v: ValueVerdict, actual: ResultSignature, expected: ResultSignature):
    var have = len(actual.types) > 0
    if not have and len(expected.types) == 0:
        return
    if have != (len(expected.types) > 0):
        var side = String("the actual side") if have else String("the expected side")
        v.fail_type(String("declared types are recorded on one side only (") + side + String(" has them)"))
        return
    if len(actual.types) != len(expected.types):
        v.fail_type(
            String("declared type count differs: ") + String(len(actual.types))
            + String(" against ") + String(len(expected.types))
        )
        return
    for c in range(len(actual.types)):
        var a = actual.types[c]
        var e = expected.types[c]
        var col = String("column ") + String(c)
        if is_unmapped(a):
            v.fail_type(col + String(" declared type ") + a + String(" is not in the mapping (see README.md)"))
        if is_unmapped(e):
            v.fail_type(col + String(" declared type ") + e + String(" is not in the mapping (see README.md)"))
        if not is_unmapped(a) and not is_unmapped(e) and a != e:
            v.fail_type(col + String(" declared type differs: ") + a + String(" against ") + e)


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
    if actual.rows == 0 and expected.rows == 0:
        if len(actual.types) > 0 and len(expected.types) > 0:
            _compare_types(v, actual, expected)
        return v^
    if len(actual.columns) != len(expected.columns):
        v.fail(String("column count differs: ") + String(len(actual.columns)) + String(" against ") + String(len(expected.columns)))
        return v^
    _compare_types(v, actual, expected)
    for c in range(len(actual.columns)):
        _compare_column(v, c, actual.columns[c], expected.columns[c], rel_tol, abs_floor)
    return v^
