# The human table of a result. A ratio is printed only where the cell holds
# one, so a cell whose values were not verified, or that komira did not run,
# shows a dash; its row still stands and the footer counts it in the
# denominator. Every footer line carries the PASS count with the threshold and
# the DuckDB pin.

from .format import format_fixed, pad_left, pad_right
from .model import BenchResult, Cell, Side
from .summary import summarize, summary_line
from .verdict import (
    CELL_FAIL,
    CELL_NO_RATIO,
    CELL_PASS,
    VALUE_DIVERGENT,
    VALUE_IDENTICAL,
)


def _ms(side: Optional[Side]) -> String:
    if not side:
        return String("-")
    return format_fixed(side.value().ms, 2)


def _rows(c: Cell) -> String:
    if c.komira:
        return String(c.komira.value().rows)
    if c.duckdb:
        return String(c.duckdb.value().rows)
    return String("-")


def _values(c: Cell) -> String:
    if c.value.kind == String(VALUE_IDENTICAL):
        return String("IDENT")
    if c.value.kind == String(VALUE_DIVERGENT):
        return String("DIVERG")
    return String("UNVER")


def _verdict(c: Cell, pass_max: Float64) -> String:
    if c.verdict == String(CELL_PASS):
        return String("PASS")
    if c.verdict == String(CELL_FAIL):
        return String("FAIL(") + String(pass_max) + String(")")
    var why = String("")
    if not c.stage.is_ok():
        why = c.stage.text()
    elif not c.value.is_identical():
        why = c.value.text()
    else:
        why = String("not measured on both sides")
    return String(CELL_NO_RATIO) + String("(") + why + String(")")


def _scale_label(result: BenchResult) -> String:
    if result.run.scale_kind == String("sf"):
        return String("SF") + String(result.run.scale_value)
    return String(result.run.scale_value) + String(" rows")


def _suites_label(result: BenchResult) -> String:
    var out = String("")
    var seen = List[String]()
    for i in range(len(result.cells)):
        var s = result.cells[i].suite.copy()
        var known = False
        for j in range(len(seen)):
            if seen[j] == s:
                known = True
        if not known:
            if len(seen) > 0:
                out += String(",")
            out += s
            seen.append(s^)
    return out^


def render_table(result: BenchResult) raises -> String:
    """The table of `result`: a banner, one row per cell in the order given,
    then a PASS line and geomean for each suite and for the whole run."""
    var duck = result.env.duckdb.copy()
    var lock8 = String(result.env.dataset_lock_sha256[byte=0:8])
    var out = (
        String("komira-bench  ")
        + _suites_label(result)
        + String(" ")
        + _scale_label(result)
        + String("  threads=")
        + String(result.run.threads)
        + String("  duckdb ")
        + duck.version
        + String(" (")
        + duck.pin
        + String(")  komira ")
        + result.env.komira_version
        + String("  dataset ")
        + lock8
        + String("\n")
    )
    var idw = 4
    for i in range(len(result.cells)):
        if result.cells[i].id.byte_length() > idw:
            idw = result.cells[i].id.byte_length()
    out += (
        String(" ")
        + pad_right(String("cell"), idw)
        + String(" ")
        + pad_left(String("komira ms"), 10)
        + String(" ")
        + pad_left(String("duckdb ms"), 10)
        + String(" ")
        + pad_left(String("ratio"), 6)
        + String(" ")
        + pad_left(String("rows"), 10)
        + String("  ")
        + pad_right(String("values"), 6)
        + String("  verdict\n")
    )
    for i in range(len(result.cells)):
        var c = result.cells[i].copy()
        var ratio = String("-")
        if c.ratio:
            ratio = format_fixed(c.ratio.value(), 2)
        out += (
            String(" ")
            + pad_right(c.id, idw)
            + String(" ")
            + pad_left(_ms(c.komira), 10)
            + String(" ")
            + pad_left(_ms(c.duckdb), 10)
            + String(" ")
            + pad_left(ratio, 6)
            + String(" ")
            + pad_left(_rows(c), 10)
            + String("  ")
            + pad_right(_values(c), 6)
            + String("  ")
            + _verdict(c, result.run.pass_max)
            + String("\n")
        )
    var summary = summarize(result)
    for i in range(len(summary.suites)):
        out += (
            String(" ")
            + summary.suites[i].suite
            + String(": ")
            + summary_line(summary.suites[i], result.run.pass_max, duck)
            + String("\n")
        )
    out += (
        String(" all: ")
        + summary_line(summary.overall, result.run.pass_max, duck)
        + String("\n")
    )
    return out^
