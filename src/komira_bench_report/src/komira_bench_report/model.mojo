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

comptime RESULT_SCHEMA = "komira-bench-result/2"
# The schema before `n_departure` and the DEPARTURE verdict; the reader refuses it by name.
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
    time `ms` (the least of the per-sweep medians, in milliseconds), those
    per-sweep medians, and their spread in percent."""

    var rows: Int64
    var ms: Float64
    var ms_per_sweep: List[Float64]
    var spread_pct: Float64

    def __init__(
        out self,
        rows: Int64,
        ms: Float64,
        var ms_per_sweep: List[Float64],
        spread_pct: Float64,
    ) raises:
        self.rows = rows
        self.ms = ms
        self.ms_per_sweep = ms_per_sweep^
        self.spread_pct = spread_pct
        if rows < 0:
            raise Error("a side cannot have a negative row count")
        if not isfinite(ms) or ms <= 0.0:
            raise Error("a side's time must be finite and positive")
        if ms != minimum(self.ms_per_sweep):
            raise Error("a side's time is not the least of its sweeps")
        if not _close(spread_pct, spread_of(self.ms_per_sweep)):
            raise Error("a side's spread does not match its sweeps")

    @staticmethod
    def from_sweeps(rows: Int64, sweeps: List[List[Float64]]) raises -> Side:
        """The side measured by `sweeps`, each the timings of one sweep's
        reps, rep 0 first: rep 0 is dropped, each sweep is reduced to its
        median, and the cell's time is the least of those."""
        var medians = sweep_medians(sweeps)
        var ms = minimum(medians)
        var spread = spread_of(medians)
        return Side(rows, ms, medians^, spread)


struct Cell(Copyable, Movable):
    """One query of one suite. `komira` is present exactly when the run ended
    in EXEC_OK. `ratio` is `komira.ms / duckdb.ms` and exists only for a cell
    whose values are IDENTICAL or a DEPARTURE; `verdict` is PASS, FAIL,
    DEPARTURE or NO_RATIO."""

    var id: String
    var suite: String
    var reps: Int
    var stage: StageOutcome
    var komira: Optional[Side]
    var duckdb: Optional[Side]
    var value: ValueVerdict
    var ratio: Optional[Float64]
    var verdict: String

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
    ) raises -> Cell:
        """A cell with its ratio and verdict derived: the ratio only when the
        run ended in EXEC_OK, the values are IDENTICAL or a DEPARTURE and both
        sides are measured."""
        var ratio = derive_ratio(stage, komira, duckdb, value)
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
    if run.reps < 2:
        raise Error("run.reps must be at least 2 (rep 0 is dropped)")
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


def _validate_side(side: Side, sweeps: Int, who: String) raises:
    if len(side.ms_per_sweep) != sweeps:
        raise Error(who + " has " + String(len(side.ms_per_sweep)) + " sweeps, the run has " + String(sweeps))


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
        _validate_side(cell.komira.value(), run.sweeps, cell.id + String(" komira"))
    if cell.duckdb:
        _validate_side(cell.duckdb.value(), run.sweeps, cell.id + String(" duckdb"))
    var want = derive_ratio(cell.stage, cell.komira, cell.duckdb, cell.value)
    if Bool(want) != Bool(cell.ratio):
        raise Error("cell " + cell.id + ": a ratio exists exactly for a value-verified cell measured on both sides")
    if want and not _close(want.value(), cell.ratio.value()):
        raise Error("cell " + cell.id + ": the ratio is not komira.ms / duckdb.ms")
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
