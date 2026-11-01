# The result model of one benchmark run: the run's settings, the environment
# fingerprint, and the cells. Every struct here is plain data; `validate_result`
# is the one place that says which combinations are allowed, and both the JSON
# writer and the JSON reader call it, so a result that is written can be read
# and a result that is read could have been written.

from std.math import isfinite

from .stats import (
    minimum,
    ratio_of,
    sweep_medians,
)
from .stats import spread_pct as spread_of
from .verdict import (
    StageOutcome,
    ValueVerdict,
    cell_verdict,
)

comptime RESULT_SCHEMA = "komira-bench-result/3"
# Schema 2 (the change that added `n_departure` and the DEPARTURE verdict) is
# still read: it holds no runs, no page faults, no first run and no first-run
# ratio (read as empty `runs_ms` and no `first_ratio`), and its times left the
# first rep of each sweep out of the median. Schema 1 is refused by name: its
# numbers mean something else.
comptime RESULT_SCHEMA_V2 = "komira-bench-result/2"
comptime PREVIOUS_SCHEMA = "komira-bench-result/1"
comptime STATISTIC_MIN_OF_SWEEP_MEDIAN = "min_of_sweep_median"
comptime PIN_PINNED = "PINNED"
comptime PIN_UNPINNED_PREFIX = "UNPINNED:"


def _close(a: Float64, b: Float64) -> Bool:
    var scale = 1.0
    if a > scale:
        scale = a
    if b > scale:
        scale = b
    var d = a - b
    if d < 0.0:
        d = -d
    return d <= 1e-9 * scale


def _is_sha256(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) != 64:
        return False
    for i in range(64):
        var c = b[i]
        var digit = c >= 0x30 and c <= 0x39
        var lower = c >= 0x61 and c <= 0x66
        if not digit and not lower:
            return False
    return True


def _refuse_path_like(text: String, field: String) raises:
    """A field of the environment is text about the machine, never a place on
    it or an account on it. Refused: a slash, a backslash, a control character,
    and an at sign unless a space stands on both sides of it. The spaced at
    sign is how /proc/cpuinfo writes a clock ("... CPU E5-4669 v4 @ 2.20GHz")
    and is no address; "user@host", "a@b.c", "a @b", "a@ b", "@host" and "cpu @"
    are refused, because the at sign is first, last or touches a character."""
    var b = text.as_bytes()
    var n = len(b)
    for i in range(n):
        var c = b[i]
        var bad = c == 0x2F or c == 0x5C or c < 0x20
        if c == 0x40:
            var spaced = i > 0 and i + 1 < n and b[i - 1] == 0x20 and b[i + 1] == 0x20
            bad = bad or not spaced
        if bad:
            raise Error(
                "environment." + field + " looks like a path or an address or"
                " holds a control character"
            )


def _is_class_label(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= 0x61 and c <= 0x7A)
            or (c >= 0x30 and c <= 0x39)
            or c == 0x2D
            or c == 0x5F
        )
        if not ok:
            return False
    return True


struct Side(Copyable, Movable):
    """What one engine measured for one cell: the rows it returned, the cell's
    steady-state time `ms` (the least of the per-sweep medians of all the
    reps of each sweep, in milliseconds), those per-sweep medians, and
    their spread in percent; and every run: `runs_ms` holds each sweep's runs
    in order with the first run first, and `minor_faults` and `major_faults`,
    when the engine's page faults were measured, hold the faults each run took
    in the same shape (empty when they were not measured). `first` is the first
    run of the query on that engine, the run that checks the answer, executed
    before the sweeps, with its own page faults (`first_minor`, `first_major`:
    present exactly when the sweeps' faults are). A side read from a result of
    schema 1 or 2 has no runs and no first run."""

    var rows: Int64
    var ms: Float64
    var ms_per_sweep: List[Float64]
    var spread_pct: Float64
    var runs_ms: List[List[Float64]]
    var minor_faults: List[List[Int64]]
    var major_faults: List[List[Int64]]
    var first: Optional[Float64]
    var first_minor: Optional[Int64]
    var first_major: Optional[Int64]

    def __init__(
        out self,
        rows: Int64,
        ms: Float64,
        var ms_per_sweep: List[Float64],
        spread_pct: Float64,
        var runs_ms: List[List[Float64]] = List[List[Float64]](),
        var minor_faults: List[List[Int64]] = List[List[Int64]](),
        var major_faults: List[List[Int64]] = List[List[Int64]](),
        var first: Optional[Float64] = Optional[Float64](),
        var first_minor: Optional[Int64] = Optional[Int64](),
        var first_major: Optional[Int64] = Optional[Int64](),
    ) raises:
        self.rows = rows
        self.ms = ms
        self.ms_per_sweep = ms_per_sweep^
        self.spread_pct = spread_pct
        self.runs_ms = runs_ms^
        self.minor_faults = minor_faults^
        self.major_faults = major_faults^
        self.first = first^
        self.first_minor = first_minor^
        self.first_major = first_major^
        if rows < 0:
            raise Error("a side cannot have a negative row count")
        if not isfinite(ms) or ms <= 0.0:
            raise Error("a side's time must be finite and positive")
        if ms != minimum(self.ms_per_sweep):
            raise Error("a side's time is not the least of its sweeps")
        if not _close(spread_pct, spread_of(self.ms_per_sweep)):
            raise Error("a side's spread does not match its sweeps")

    @staticmethod
    def from_sweeps(
        rows: Int64,
        var sweeps: List[List[Float64]],
        var first_ms: Optional[Float64] = Optional[Float64](),
        var minor_faults: List[List[Int64]] = List[List[Int64]](),
        var major_faults: List[List[Int64]] = List[List[Int64]](),
        var first_minor: Optional[Int64] = Optional[Int64](),
        var first_major: Optional[Int64] = Optional[Int64](),
    ) raises -> Side:
        """The side measured by `sweeps`, each the timings of one sweep's
        reps: all of them are kept as the side's runs, each sweep is reduced to
        the median of all its reps, and the cell's steady-state
        time is the least of those (see `STEADY_STATE_DEFINITION`). `first_ms`
        is the first run of the query on that engine, executed before the
        sweeps. The page faults of each run, when measured, are given in the
        shape of `sweeps`, and those of the first run as `first_minor` and
        `first_major`."""
        var medians = sweep_medians(sweeps)
        var ms = minimum(medians)
        var spread = spread_of(medians)
        return Side(
            rows, ms, medians^, spread, sweeps^, minor_faults^, major_faults^,
            first_ms^, first_minor^, first_major^,
        )

    def has_runs(self) -> Bool:
        """Whether the side carries its runs and its first run (a side read
        from schema 1 or 2 does not)."""
        return len(self.runs_ms) > 0 and Bool(self.first)

    def first_ms(self) -> Optional[Float64]:
        """The first run of the query on that engine (the run that checks the
        answer), or nothing when the side does not carry it."""
        return self.first.copy()


struct FirstRun(Copyable, Movable):
    """The first run of a query on one engine, when no side holds it: its time
    in milliseconds and the minor and major page faults the engine's process took
    during it (both present or both absent)."""

    var ms: Float64
    var minor: Optional[Int64]
    var major: Optional[Int64]

    def __init__(out self, ms: Float64, var minor: Optional[Int64], var major: Optional[Int64]):
        self.ms = ms
        self.minor = minor^
        self.major = major^


struct CheckRuns(Copyable, Movable):
    """The check runs of a cell that was not timed (the engine refused the
    query, or its answer was wrong): each engine's first run, where it was
    executed and its clock could resolve it. A timed cell holds its first runs in
    its sides and has none of these."""

    var komira: Optional[FirstRun]
    var duckdb: Optional[FirstRun]

    def __init__(out self, var komira: Optional[FirstRun], var duckdb: Optional[FirstRun]):
        self.komira = komira^
        self.duckdb = duckdb^


struct Cell(Copyable, Movable):
    """One query of one suite. `komira` is present exactly when the run ended
    in EXEC_OK. `ratio` is `komira.ms / duckdb.ms`, the steady-state ratio, and
    exists only for a cell whose values are IDENTICAL or a DEPARTURE; `verdict`
    is PASS, FAIL, DEPARTURE or NO_RATIO and follows `ratio`. `first_ratio` is
    komira's first run over DuckDB's, under the same conditions and only when
    both sides carry their runs."""

    var id: String
    var suite: String
    var reps: Int
    var stage: StageOutcome
    var komira: Optional[Side]
    var duckdb: Optional[Side]
    var value: ValueVerdict
    var ratio: Optional[Float64]
    var verdict: String
    var first_ratio: Optional[Float64]
    var check_runs: Optional[CheckRuns]

    def __init__(
        out self,
        var id: String,
        var suite: String,
        reps: Int,
        var stage: StageOutcome,
        var komira: Optional[Side],
        var duckdb: Optional[Side],
        var value: ValueVerdict,
        var ratio: Optional[Float64],
        var verdict: String,
        var first_ratio: Optional[Float64] = Optional[Float64](),
        var check_runs: Optional[CheckRuns] = Optional[CheckRuns](),
    ):
        self.id = id^
        self.suite = suite^
        self.reps = reps
        self.stage = stage^
        self.komira = komira^
        self.duckdb = duckdb^
        self.value = value^
        self.ratio = ratio^
        self.verdict = verdict^
        self.first_ratio = first_ratio^
        self.check_runs = check_runs^

    @staticmethod
    def build(
        var id: String,
        var suite: String,
        reps: Int,
        var stage: StageOutcome,
        var komira: Optional[Side],
        var duckdb: Optional[Side],
        var value: ValueVerdict,
        pass_max: Float64,
        var check_runs: Optional[CheckRuns] = Optional[CheckRuns](),
    ) raises -> Cell:
        """A cell with its ratios and verdict derived: the ratio only when the
        run ended in EXEC_OK, the values are IDENTICAL or a DEPARTURE and both
        sides are measured; the first-run ratio under the same conditions, when
        both sides also carry their runs."""
        var ratio = derive_ratio(stage, komira, duckdb, value)
        var first_ratio = derive_first_ratio(stage, komira, duckdb, value)
        var verdict = cell_verdict(ratio, pass_max, value.is_departure())
        return Cell(
            id^,
            suite^,
            reps,
            stage^,
            komira^,
            duckdb^,
            value^,
            ratio^,
            verdict^,
            first_ratio^,
            check_runs^,
        )


def derive_ratio(
    stage: StageOutcome,
    komira: Optional[Side],
    duckdb: Optional[Side],
    value: ValueVerdict,
) raises -> Optional[Float64]:
    """The ratio of a cell, or none when it must not be shown."""
    if not stage.is_ok() or not value.is_matched():
        return Optional[Float64]()
    if not komira or not duckdb:
        return Optional[Float64]()
    return Optional[Float64](ratio_of(komira.value().ms, duckdb.value().ms))


def derive_first_ratio(
    stage: StageOutcome,
    komira: Optional[Side],
    duckdb: Optional[Side],
    value: ValueVerdict,
) raises -> Optional[Float64]:
    """The first-run ratio of a cell, komira's first run over DuckDB's, or none
    when the cell has no ratio or a side has no runs."""
    if not Bool(derive_ratio(stage, komira, duckdb, value)):
        return Optional[Float64]()
    var k = komira.value().first_ms()
    var d = duckdb.value().first_ms()
    if not k or not d:
        return Optional[Float64]()
    return Optional[Float64](ratio_of(k.value(), d.value()))


struct DuckDbPin(Copyable, Movable):
    """The DuckDB the run was compared with: its version, the sha256 of the
    binary that ran, and `PINNED` or `UNPINNED:<reason>`."""

    var version: String
    var sha256: String
    var pin: String

    def __init__(
        out self, var version: String, var sha256: String, var pin: String
    ):
        self.version = version^
        self.sha256 = sha256^
        self.pin = pin^

    def is_pinned(self) -> Bool:
        return self.pin == String(PIN_PINNED)


struct Environment(Copyable, Movable):
    """The fingerprint of the machine and the inputs. `hostclass` is an opaque
    class label of the host, never a host name."""

    var hostclass: String
    var cpu_model: String
    var cores: Int64
    var mem_total_bytes: Int64
    var os: String
    var komira_version: String
    var duckdb: DuckDbPin
    var dataset_lock_sha256: String

    def __init__(
        out self,
        var hostclass: String,
        var cpu_model: String,
        cores: Int64,
        mem_total_bytes: Int64,
        var os: String,
        var komira_version: String,
        var duckdb: DuckDbPin,
        var dataset_lock_sha256: String,
    ):
        self.hostclass = hostclass^
        self.cpu_model = cpu_model^
        self.cores = cores
        self.mem_total_bytes = mem_total_bytes
        self.os = os^
        self.komira_version = komira_version^
        self.duckdb = duckdb^
        self.dataset_lock_sha256 = dataset_lock_sha256^


struct RunInfo(Copyable, Movable):
    """The settings of the run. `mode` is `both`, `komira` or `duckdb`; the
    scale is `sf` (a scale factor) or `rows`; `pass_max` is the ratio at or
    below which a cell passes."""

    var mode: String
    var scale_kind: String
    var scale_value: Int64
    var sweeps: Int
    var reps: Int
    var statistic: String
    var threads: Int64
    var pass_max: Float64

    def __init__(
        out self,
        var mode: String,
        var scale_kind: String,
        scale_value: Int64,
        sweeps: Int,
        reps: Int,
        var statistic: String,
        threads: Int64,
        pass_max: Float64,
    ):
        self.mode = mode^
        self.scale_kind = scale_kind^
        self.scale_value = scale_value
        self.sweeps = sweeps
        self.reps = reps
        self.statistic = statistic^
        self.threads = threads
        self.pass_max = pass_max


struct BenchResult(Copyable, Movable):
    """One run: its settings, its environment and its cells."""

    var run: RunInfo
    var env: Environment
    var cells: List[Cell]

    def __init__(
        out self,
        var run: RunInfo,
        var env: Environment,
        var cells: List[Cell],
    ):
        self.run = run^
        self.env = env^
        self.cells = cells^


def _validate_run(run: RunInfo) raises:
    if (
        run.mode != String("both")
        and run.mode != String("komira")
        and run.mode != String("duckdb")
    ):
        raise Error("run.mode must be both, komira or duckdb")
    if run.scale_kind != String("sf") and run.scale_kind != String("rows"):
        raise Error("run.scale must be sf or rows")
    if run.scale_value <= 0:
        raise Error("run.scale must be positive")
    if run.sweeps < 1:
        raise Error("run.sweeps must be at least 1")
    if run.reps < 1:
        raise Error("run.reps must be at least 1")
    if run.statistic != String(STATISTIC_MIN_OF_SWEEP_MEDIAN):
        raise Error("run.statistic must be " + String(STATISTIC_MIN_OF_SWEEP_MEDIAN))
    if run.threads < 1:
        raise Error("run.threads must be at least 1")
    if not isfinite(run.pass_max) or run.pass_max <= 0.0:
        raise Error("run.pass_max must be finite and positive")


def _validate_env(env: Environment) raises:
    if not _is_class_label(env.hostclass):
        raise Error(
            "environment.hostclass must be an opaque class label of"
            " lower-case letters, digits, '-' and '_'"
        )
    if env.cpu_model.byte_length() == 0 or env.os.byte_length() == 0:
        raise Error("environment.cpu_model and environment.os are required")
    if env.komira_version.byte_length() == 0:
        raise Error("environment.komira_version is required")
    _refuse_path_like(env.cpu_model, String("cpu_model"))
    _refuse_path_like(env.os, String("os"))
    _refuse_path_like(env.komira_version, String("komira_version"))
    _refuse_path_like(env.duckdb.version, String("duckdb.version"))
    _refuse_path_like(env.duckdb.pin, String("duckdb.pin"))
    if env.cores < 1 or env.mem_total_bytes < 1:
        raise Error("environment.cores and environment.mem_total_bytes must be positive")
    if env.duckdb.version.byte_length() == 0:
        raise Error("environment.duckdb.version is required")
    if env.duckdb.is_pinned():
        if not _is_sha256(env.duckdb.sha256):
            raise Error("a PINNED duckdb needs a 64-digit lower-case sha256")
    else:
        if not env.duckdb.pin.startswith(String(PIN_UNPINNED_PREFIX)):
            raise Error("environment.duckdb.pin must be PINNED or UNPINNED:<reason>")
        if env.duckdb.pin.byte_length() == String(PIN_UNPINNED_PREFIX).byte_length():
            raise Error("UNPINNED must give a reason")
        if env.duckdb.sha256.byte_length() != 0 and not _is_sha256(env.duckdb.sha256):
            raise Error("environment.duckdb.sha256 must be 64 lower-case hex digits or empty")
    if not _is_sha256(env.dataset_lock_sha256):
        raise Error("environment.dataset_lock_sha256 must be 64 lower-case hex digits")


def _check_counts(counts: List[List[Int64]], sweeps: Int, reps: Int, who: String, what: String) raises:
    if len(counts) != sweeps:
        raise Error(who + " has " + String(len(counts)) + " sweeps of " + what + ", the run has " + String(sweeps))
    for i in range(len(counts)):
        if len(counts[i]) != reps:
            raise Error(who + " " + what + " of sweep " + String(i) + " has " + String(len(counts[i])) + " runs, the run has " + String(reps) + " reps")
        for j in range(len(counts[i])):
            if counts[i][j] < 0:
                raise Error(who + " has a negative count in " + what)


def _validate_side(side: Side, sweeps: Int, reps: Int, who: String) raises:
    if len(side.ms_per_sweep) != sweeps:
        raise Error(who + " has " + String(len(side.ms_per_sweep)) + " sweeps, the run has " + String(sweeps))
    if len(side.runs_ms) == 0:
        # a side of schema 1 or 2: no runs, and so no faults and no first run
        if len(side.minor_faults) > 0 or len(side.major_faults) > 0:
            raise Error(who + " has page faults but no runs")
        if side.first or side.first_minor or side.first_major:
            raise Error(who + " has a first run but no runs")
        return
    if not side.first:
        raise Error(who + " has runs but no first run")
    if not isfinite(side.first.value()) or side.first.value() <= 0.0:
        raise Error(who + " has a first run whose time is not finite and positive")
    if len(side.runs_ms) != sweeps:
        raise Error(who + " has " + String(len(side.runs_ms)) + " sweeps of runs, the run has " + String(sweeps))
    for i in range(len(side.runs_ms)):
        if len(side.runs_ms[i]) != reps:
            raise Error(who + " sweep " + String(i) + " has " + String(len(side.runs_ms[i])) + " runs, the run has " + String(reps) + " reps")
        for j in range(len(side.runs_ms[i])):
            if not isfinite(side.runs_ms[i][j]) or side.runs_ms[i][j] <= 0.0:
                raise Error(who + " has a run whose time is not finite and positive")
    var medians = sweep_medians(side.runs_ms)
    for i in range(len(medians)):
        if not _close(medians[i], side.ms_per_sweep[i]):
            raise Error(who + ": the median of all the reps of sweep " + String(i) + " is not its ms_per_sweep")
    var swept = len(side.minor_faults) > 0 or len(side.major_faults) > 0
    var firsts = Bool(side.first_minor) or Bool(side.first_major)
    if swept != firsts:
        raise Error(who + ": the page faults of the first run and of the sweeps are measured together or not at all")
    if swept:
        _check_counts(side.minor_faults, sweeps, reps, who, String("minor faults"))
        _check_counts(side.major_faults, sweeps, reps, who, String("major faults"))
        if not side.first_minor or not side.first_major:
            raise Error(who + " has one count of the first run's page faults, not both")
        if side.first_minor.value() < 0 or side.first_major.value() < 0:
            raise Error(who + " has a negative count in the first run's page faults")


def _validate_first_run(run: Optional[FirstRun], who: String) raises:
    if not run:
        return
    if not isfinite(run.value().ms) or run.value().ms <= 0.0:
        raise Error(who + ": the time must be finite and positive")
    if Bool(run.value().minor) != Bool(run.value().major):
        raise Error(who + ": the page-fault counts are both present or both absent")
    if run.value().minor and (run.value().minor.value() < 0 or run.value().major.value() < 0):
        raise Error(who + ": a page-fault count is negative")


def validate_cell(cell: Cell, run: RunInfo) raises:
    """Check one cell against the run: its id names its suite, it has the
    run's reps and sweeps, a komira side exists exactly for EXEC_OK, a
    comparison happened only if komira ran, in a run of mode both, against a
    duckdb side (with the same row count when the values are IDENTICAL), the
    sides present agree with the mode, and the ratio and verdict are the
    derived ones."""
    if cell.suite.byte_length() == 0:
        raise Error("a cell needs a suite")
    var prefix = cell.suite + String("/")
    if not cell.id.startswith(prefix) or cell.id.byte_length() == prefix.byte_length():
        raise Error("cell id '" + cell.id + "' must be '" + prefix + "<name>'")
    if cell.reps != run.reps:
        raise Error("cell " + cell.id + " has reps " + String(cell.reps) + ", the run has " + String(run.reps))
    var id_bytes = cell.id.as_bytes()
    for i in range(len(id_bytes)):
        if id_bytes[i] < 0x20:
            raise Error("a cell id holds a control character")
    if cell.stage.is_ok() != Bool(cell.komira):
        raise Error("cell " + cell.id + ": a komira side exists exactly when the stage is EXEC_OK")
    if not cell.stage.is_ok() and (
        cell.value.kind != String("UNVERIFIED")
    ):
        raise Error("cell " + cell.id + ": values cannot be compared when komira did not run")
    var compared = (
        cell.value.kind == String("IDENTICAL")
        or cell.value.kind == String("DIVERGENT")
        or cell.value.kind == String("DEPARTURE")
    )
    if compared and run.mode != String("both"):
        raise Error("cell " + cell.id + ": values are compared only in a run of mode both")
    if compared and not cell.duckdb:
        raise Error("cell " + cell.id + ": values cannot be compared without a duckdb side")
    if (
        cell.value.is_matched()
        and cell.komira.value().rows != cell.duckdb.value().rows
    ):
        raise Error("cell " + cell.id + ": " + cell.value.kind + " values need equal row counts")
    if run.mode == String("komira") and cell.duckdb:
        raise Error("cell " + cell.id + ": a run of mode komira has no duckdb side")
    if run.mode == String("both") and cell.stage.is_ok() and not cell.duckdb:
        raise Error("cell " + cell.id + ": a run of mode both measures duckdb for every cell komira ran")
    if cell.komira:
        _validate_side(cell.komira.value(), run.sweeps, run.reps, cell.id + String(" komira"))
    if cell.duckdb:
        _validate_side(cell.duckdb.value(), run.sweeps, run.reps, cell.id + String(" duckdb"))
    var want = derive_ratio(cell.stage, cell.komira, cell.duckdb, cell.value)
    if Bool(want) != Bool(cell.ratio):
        raise Error("cell " + cell.id + ": a ratio exists exactly for a value-verified cell measured on both sides")
    if want and not _close(want.value(), cell.ratio.value()):
        raise Error("cell " + cell.id + ": the ratio is not komira.ms / duckdb.ms")
    var want_first = derive_first_ratio(cell.stage, cell.komira, cell.duckdb, cell.value)
    if Bool(want_first) != Bool(cell.first_ratio):
        raise Error("cell " + cell.id + ": a first-run ratio exists exactly for a cell with a ratio whose sides carry their runs")
    if want_first and not _close(want_first.value(), cell.first_ratio.value()):
        raise Error("cell " + cell.id + ": the first-run ratio is not komira's first run / duckdb's first run")
    if cell.check_runs:
        if Bool(cell.komira) or Bool(cell.duckdb):
            raise Error("cell " + cell.id + ": a timed cell holds its first runs in its sides, not in check_runs")
        _validate_first_run(cell.check_runs.value().komira, cell.id + String(" komira check run"))
        _validate_first_run(cell.check_runs.value().duckdb, cell.id + String(" duckdb check run"))
    if cell.verdict != cell_verdict(want, run.pass_max, cell.value.is_departure()):
        raise Error("cell " + cell.id + ": the verdict does not follow from the ratio and run.pass_max")


def validate_result(result: BenchResult) raises:
    """Raise unless `result` is a result the schema allows."""
    _validate_run(result.run)
    _validate_env(result.env)
    if len(result.cells) == 0:
        raise Error("a result needs at least one cell")
    var seen = List[String]()
    for i in range(len(result.cells)):
        var c = result.cells[i].copy()
        for j in range(len(seen)):
            if seen[j] == c.id:
                raise Error("cell id '" + c.id + "' appears twice")
        seen.append(c.id.copy())
        validate_cell(c, result.run)
