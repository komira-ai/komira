# The aggregates of a result: counts, geomean and median of the ratios, for the
# whole run and per suite. The denominator of every count is the number of
# cells the suite has, so a cell the engine refused or failed, and a cell whose
# values did not match, still count against the totals; only a cell with a
# ratio enters the geomean, and the line that reports it says how many did.

from .format import format_fixed
from .model import BenchResult, Cell, DuckDbPin
from .stats import geomean, median
from .verdict import CELL_FAIL, CELL_PASS


struct SuiteSummary(Copyable, Movable):
    """The counts of one suite (or, for `Summary.overall`, of the whole run).

    `n_cells` is every cell, `n_ran` those whose run ended in EXEC_OK,
    `n_verified` those whose values are IDENTICAL, `n_ratio` those with a
    ratio; `geomean` and `median_ratio` are over the ratios and absent when
    there are none."""

    var suite: String
    var n_cells: Int
    var n_ran: Int
    var n_verified: Int
    var n_ratio: Int
    var n_pass: Int
    var n_fail: Int
    var geomean: Optional[Float64]
    var median_ratio: Optional[Float64]

    def __init__(
        out self,
        var suite: String,
        n_cells: Int,
        n_ran: Int,
        n_verified: Int,
        n_ratio: Int,
        n_pass: Int,
        n_fail: Int,
        var geomean: Optional[Float64],
        var median_ratio: Optional[Float64],
    ):
        self.suite = suite^
        self.n_cells = n_cells
        self.n_ran = n_ran
        self.n_verified = n_verified
        self.n_ratio = n_ratio
        self.n_pass = n_pass
        self.n_fail = n_fail
        self.geomean = geomean^
        self.median_ratio = median_ratio^


struct Summary(Copyable, Movable):
    """The aggregates of a result: `overall`, and one `SuiteSummary` per suite
    in the order the suites first appear in the cells."""

    var overall: SuiteSummary
    var suites: List[SuiteSummary]

    def __init__(
        out self, var overall: SuiteSummary, var suites: List[SuiteSummary]
    ):
        self.overall = overall^
        self.suites = suites^


def _summarize_cells(
    var label: String, cells: List[Cell]
) raises -> SuiteSummary:
    var n_ran = 0
    var n_verified = 0
    var n_pass = 0
    var n_fail = 0
    var ratios = List[Float64]()
    for i in range(len(cells)):
        var c = cells[i].copy()
        if c.stage.is_ok():
            n_ran += 1
        if c.value.is_identical():
            n_verified += 1
        if c.ratio:
            ratios.append(c.ratio.value())
        if c.verdict == String(CELL_PASS):
            n_pass += 1
        if c.verdict == String(CELL_FAIL):
            n_fail += 1
    var g = Optional[Float64]()
    var m = Optional[Float64]()
    if len(ratios) > 0:
        g = Optional[Float64](geomean(ratios))
        m = Optional[Float64](median(ratios))
    return SuiteSummary(
        label^,
        len(cells),
        n_ran,
        n_verified,
        len(ratios),
        n_pass,
        n_fail,
        g^,
        m^,
    )


def summarize(result: BenchResult) raises -> Summary:
    """The aggregates of `result`, whole and per suite."""
    var names = List[String]()
    for i in range(len(result.cells)):
        var suite = result.cells[i].suite.copy()
        var known = False
        for j in range(len(names)):
            if names[j] == suite:
                known = True
        if not known:
            names.append(suite)
    var suites = List[SuiteSummary]()
    for j in range(len(names)):
        var members = List[Cell]()
        for i in range(len(result.cells)):
            if result.cells[i].suite == names[j]:
                members.append(result.cells[i].copy())
        suites.append(_summarize_cells(names[j].copy(), members))
    var overall = _summarize_cells(String("all"), result.cells)
    return Summary(overall^, suites^)


def exit_code(summary: Summary) -> Int:
    """0 only when every cell ran and its values were verified; 1 otherwise.
    A cell that fails the ratio threshold does not change it. A run of mode
    `komira` or `duckdb` verifies no values, so it gives 1."""
    if (
        summary.overall.n_ran == summary.overall.n_cells
        and summary.overall.n_verified == summary.overall.n_cells
    ):
        return 0
    return 1


def summary_line(s: SuiteSummary, pass_max: Float64, duckdb: DuckDbPin) -> String:
    """One line that states a suite's result: the PASS count over every cell
    with the threshold and the DuckDB pin beside it, then the geomean with the
    number of cells it covers."""
    var line = (
        String("PASS ")
        + String(s.n_pass)
        + String("/")
        + String(s.n_cells)
        + String(" at <= ")
        + String(pass_max)
        + String("x vs duckdb ")
        + duckdb.version
        + String(" (")
        + duckdb.pin
        + String(")")
    )
    if s.geomean:
        line += (
            String(" | geomean ")
            + format_fixed(s.geomean.value(), 2)
            + String("x over ")
            + String(s.n_ratio)
            + String("/")
            + String(s.n_cells)
            + String(" value-verified")
            + String(" | median ")
            + format_fixed(s.median_ratio.value(), 2)
            + String("x")
        )
    else:
        line += (
            String(" | geomean n/a (0/")
            + String(s.n_cells)
            + String(" cells have a ratio)")
        )
    return line^
