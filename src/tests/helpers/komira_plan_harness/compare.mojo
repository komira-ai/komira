# =============================================================================
# komira_plan_harness/compare.mojo -- expected vs actual canonical text.
# =============================================================================
#
# The EXPECTED side's policy governs:
#
#   schema         every entry (name, type, nullability) must be equal; one
#                  mismatch is reported per differing column. Cells are still
#                  compared when the column counts agree.
#   order: total   row r against row r, every cell.
#   order: keys=   the key projection row r against row r; then the rows of
#                  each tie group (a run of expected rows with equal key
#                  cells) compare as multisets.
#   order: none    all rows compare as multisets.
#   floats         float_text.float_cells_match under the column's tolerance;
#                  every other cell by its text.
#
# EVERY mismatch is reported, never only the first: each differing cell (row,
# column, expected, actual), each row only one side holds, and the row counts
# when they differ. A multiset compare sorts both sides into one total order
# and walks them together, so one missing row is one report, not a cascade;
# rows the walk leaves unpaired are then paired by a first-fit search (a
# tolerance or a bare NaN can defeat the sort order), which is skipped when
# neither is present (the walk is exact then). `keys=` compares the
# key projection positionally and does not resynchronise after a missing
# row (canon_text.mojo states both limits).
# =============================================================================

from .canon_text import ORDER_KEYS, ORDER_NONE, ORDER_TOTAL, CanonText
from .float_text import FloatCell, FloatTolerance, float_cells_match, float_cells_order


struct Mismatch(Copyable, Movable, Writable):
    """One difference. `kind` is schema, row_count, cell, key, missing_row
    (expected only) or extra_row (actual only). `row` / `actual_row` are
    0-based data row indices (-1 when not applicable); `column` is the
    escaped column name ("" for a whole row)."""

    var kind: String
    var row: Int
    var actual_row: Int
    var column: String
    var expected: String
    var actual: String

    def __init__(
        out self,
        kind: String,
        row: Int,
        actual_row: Int,
        column: String,
        expected: String,
        actual: String,
    ):
        self.kind = kind
        self.row = row
        self.actual_row = actual_row
        self.column = column
        self.expected = expected
        self.actual = actual

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.kind)
        if self.row >= 0:
            writer.write(" row ", self.row)
        if self.actual_row >= 0 and self.actual_row != self.row:
            writer.write(" (actual row ", self.actual_row, ")")
        if self.column.byte_length() > 0:
            writer.write(" column ", self.column)
        writer.write(": expected [", self.expected, "] actual [", self.actual, "]")


struct CompareReport(Copyable, Movable, Writable):
    """Every mismatch found; empty when the results agree.
    `first_fit_probes` counts the row pairs the first-fit search after a
    multiset walk tried (0 when the walk was exact and the search skipped)."""

    var mismatches: List[Mismatch]
    var first_fit_probes: Int

    def __init__(out self):
        self.mismatches = List[Mismatch]()
        self.first_fit_probes = 0

    def ok(self) -> Bool:
        return len(self.mismatches) == 0

    def count(self) -> Int:
        return len(self.mismatches)

    def count_of(self, kind: String) -> Int:
        var n = 0
        for m in self.mismatches:
            if m.kind == kind:
                n += 1
        return n

    def add(mut self, var m: Mismatch):
        self.mismatches.append(m^)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(len(self.mismatches), " mismatch(es)")
        for m in self.mismatches:
            writer.write("\n  ", m)


def _canonical_float(text: String, width: Int) raises -> FloatCell:
    """A cell already in canonical form (parse_canon or render): the bits
    are after the `|`."""
    if text == "\\N":
        return FloatCell(True, False, 0)
    if text == "NaN":
        return FloatCell(False, True, 0)
    var bar = text.find("|")
    if bar < 0:
        raise Error("canon: float cell '" + text + "' is not canonical")
    var bs = text.as_bytes()
    var v: UInt64 = 0
    for k in range(bar + 3, len(bs)):
        var b = bs[k]
        var d: UInt64
        if b >= 48 and b <= 57:
            d = UInt64(b - 48)
        else:
            d = UInt64(b - 55)
        v = (v << 4) | d
    return FloatCell(False, False, v)


def _cell_match(
    e: String, a: String, width: Int, tol: FloatTolerance
) raises -> Bool:
    if width == 0 or e == a:
        return e == a
    return float_cells_match(
        _canonical_float(e, width), _canonical_float(a, width), tol, width
    )


def _cell_order(x: String, y: String, width: Int) raises -> Int:
    if width > 0:
        return float_cells_order(
            _canonical_float(x, width), _canonical_float(y, width), width
        )
    if x == y:
        return 0
    return -1 if x < y else 1


struct _Cols(Movable):
    """Per-column widths and tolerances of the expected side. A column is
    compared as floats only when BOTH sides hold floats of the same width;
    otherwise (already a schema mismatch) its cells compare as text."""

    var widths: List[Int]
    var tols: List[FloatTolerance]
    var names: List[String]

    def __init__(out self, expected: CanonText, actual: CanonText):
        self.widths = List[Int]()
        for c in range(len(expected.float_widths)):
            var w = expected.float_widths[c]
            if c >= len(actual.float_widths) or actual.float_widths[c] != w:
                w = 0
            self.widths.append(w)
        self.names = expected.names.copy()
        self.tols = List[FloatTolerance]()
        for c in range(len(expected.names)):
            self.tols.append(expected.policy.tolerance_for(expected.names[c]))


def _rows_match(
    e: CanonText, er: Int, a: CanonText, ar: Int, cols: _Cols
) raises -> Bool:
    for c in range(len(cols.widths)):
        if not _cell_match(e.rows[er][c], a.rows[ar][c], cols.widths[c], cols.tols[c]):
            return False
    return True


def _row_order(
    x: CanonText, xr: Int, y: CanonText, yr: Int, cols: _Cols
) raises -> Int:
    for c in range(len(cols.widths)):
        var o = _cell_order(x.rows[xr][c], y.rows[yr][c], cols.widths[c])
        if o != 0:
            return o
    return 0


def _sort_rows(t: CanonText, var idx: List[Int], cols: _Cols) raises -> List[Int]:
    """Bottom-up merge sort of row indices by _row_order (stable)."""
    var n = len(idx)
    var src = idx^
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
                if _row_order(t, src[j], t, src[i], cols) < 0:
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
    return src^


def _has_bare_nan(t: CanonText, rows: List[Int], cols: _Cols) -> Bool:
    for r in rows:
        for c in range(len(cols.widths)):
            if cols.widths[c] > 0 and t.rows[r][c] == "NaN":
                return True
    return False


def _walk_is_exact(
    e: CanonText, missing: List[Int], a: CanonText, extra: List[Int], cols: _Cols
) -> Bool:
    """True when no compared float column has a tolerance (`ulps=0`) and no
    row the walk left unpaired holds a bare NaN in one: then two rows match
    exactly when _row_order calls them equal, and the walk pairs every
    matching pair it can."""
    for c in range(len(cols.widths)):
        if cols.widths[c] > 0 and (cols.tols[c].is_rel or cols.tols[c].ulps != 0):
            return False
    return not (_has_bare_nan(e, missing, cols) or _has_bare_nan(a, extra, cols))


def _multiset_diff(
    e: CanonText,
    a: CanonText,
    var e_rows: List[Int],
    var a_rows: List[Int],
    cols: _Cols,
    mut report: CompareReport,
) raises:
    var es = _sort_rows(e, e_rows^, cols)
    var as_ = _sort_rows(a, a_rows^, cols)
    var missing = List[Int]()
    var extra = List[Int]()
    var i = 0
    var j = 0
    while i < len(es) and j < len(as_):
        if _rows_match(e, es[i], a, as_[j], cols):
            i += 1
            j += 1
            continue
        var o = _row_order(e, es[i], a, as_[j], cols)
        if o <= 0:
            missing.append(es[i])
            i += 1
        if o >= 0:
            extra.append(as_[j])
            j += 1
    while i < len(es):
        missing.append(es[i])
        i += 1
    while j < len(as_):
        extra.append(as_[j])
        j += 1
    # The sorted walk pairs rows by exact sort order; under a tolerance or a
    # bare NaN, a row it left unpaired may still match one on the other side.
    # Pair those by search (first fit) before reporting. Without either, two
    # rows match exactly when they sort equal, so the walk is exact and the
    # O(missing x extra) search is skipped.
    if len(missing) > 0 and len(extra) > 0 and _walk_is_exact(e, missing, a, extra, cols):
        for mi in missing:
            report.add(Mismatch("missing_row", mi, -1, "", e.row_text(mi), ""))
        for xi in extra:
            report.add(Mismatch("extra_row", -1, xi, "", "", a.row_text(xi)))
        return
    var used = List[Bool](capacity=len(extra))
    for _ in range(len(extra)):
        used.append(False)
    for mi in range(len(missing)):
        var found = False
        for xi in range(len(extra)):
            if used[xi]:
                continue
            report.first_fit_probes += 1
            if _rows_match(e, missing[mi], a, extra[xi], cols):
                used[xi] = True
                found = True
                break
        if not found:
            report.add(
                Mismatch("missing_row", missing[mi], -1, "", e.row_text(missing[mi]), "")
            )
    for xi in range(len(extra)):
        if not used[xi]:
            report.add(Mismatch("extra_row", -1, extra[xi], "", "", a.row_text(extra[xi])))


def _range(start: Int, end: Int) -> List[Int]:
    var res = List[Int](capacity=max(end - start, 0))
    for i in range(start, end):
        res.append(i)
    return res^


def _tail_rows(e: CanonText, a: CanonText, m: Int, mut report: CompareReport):
    for r in range(m, e.num_rows()):
        report.add(Mismatch("missing_row", r, -1, "", e.row_text(r), ""))
    for r in range(m, a.num_rows()):
        report.add(Mismatch("extra_row", -1, r, "", "", a.row_text(r)))


def compare_canon(expected: CanonText, actual: CanonText) raises -> CompareReport:
    """Compare under the expected side's policy; see the module header."""
    var report = CompareReport()
    var ne = expected.num_rows()
    var na = actual.num_rows()
    var nc = expected.num_columns()

    if nc != actual.num_columns():
        var es = String()
        var as_ = String()
        for c in range(nc):
            es += ("\t" if c > 0 else "") + expected.schema[c]
        for c in range(actual.num_columns()):
            as_ += ("\t" if c > 0 else "") + actual.schema[c]
        report.add(Mismatch("schema", -1, -1, "", es, as_))
        if ne != na:
            report.add(Mismatch("row_count", -1, -1, "", String(ne), String(na)))
        return report^
    for c in range(nc):
        if expected.schema[c] != actual.schema[c]:
            report.add(
                Mismatch("schema", -1, -1, expected.names[c], expected.schema[c], actual.schema[c])
            )
    if ne != na:
        report.add(Mismatch("row_count", -1, -1, "", String(ne), String(na)))

    var cols = _Cols(expected, actual)
    var m = min(ne, na)
    var order = expected.policy.order

    if order == ORDER_TOTAL:
        for r in range(m):
            for c in range(nc):
                if not _cell_match(
                    expected.rows[r][c], actual.rows[r][c], cols.widths[c], cols.tols[c]
                ):
                    report.add(
                        Mismatch(
                            "cell", r, r, expected.names[c],
                            expected.rows[r][c], actual.rows[r][c],
                        )
                    )
        _tail_rows(expected, actual, m, report)
        return report^

    if order == ORDER_NONE:
        _multiset_diff(expected, actual, _range(0, ne), _range(0, na), cols, report)
        return report^

    # ORDER_KEYS
    var key_cols = List[Int]()
    for k in expected.policy.keys:
        var c = expected.column_index(k)
        if c < 0:
            raise Error("canon: order key '" + k + "' names no column")
        key_cols.append(c)
    for r in range(m):
        for c in key_cols:
            if not _cell_match(
                expected.rows[r][c], actual.rows[r][c], cols.widths[c], cols.tols[c]
            ):
                report.add(
                    Mismatch(
                        "key", r, r, expected.names[c],
                        expected.rows[r][c], actual.rows[r][c],
                    )
                )
    var start = 0
    while start < m:
        var end = start + 1
        while end < m:
            var same = True
            for c in key_cols:
                if expected.rows[end][c] != expected.rows[start][c]:
                    same = False
                    break
            if not same:
                break
            end += 1
        _multiset_diff(
            expected, actual, _range(start, end), _range(start, end), cols, report
        )
        start = end
    _tail_rows(expected, actual, m, report)
    return report^
