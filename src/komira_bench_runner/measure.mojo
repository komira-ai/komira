# Timing one query on both engines. Komira is timed on the host clock around
# the arm's run; DuckDB by its session, from marker to marker. Both run the
# same text. Reps alternate between the engines (komira, then DuckDB), so a
# slow drift of the host falls on both. A time the clock cannot resolve is not
# a measurement, and neither is a run that stopped completing.
#
# Every run is kept: nothing is run to be thrown away, and no run is dropped
# from the data (the report decides what "steady state" means, from all of
# them). Around each timed run the page faults of the engine's process are
# read before and after (the arm's for komira, the DuckDB child process's for
# DuckDB) and the difference is recorded with the run.
#
# The run that checks the answer (DuckDB's fetch, the arm's run with rows)
# executes before any sweep, so it is the first time the query runs on each
# engine and where first-touch costs land. It is timed and counted like the
# others and recorded as the side's first run (`CheckRun`). It differs from a
# timed run in one way: it materializes its rows (the arm converts its batches,
# DuckDB renders JSON), which a timed run does not.

from komira_bench_duckdb import BenchClock, DuckDbSession, DuckDbTransport, FaultCount

from komira_bench_duckdb import FetchResult

from .arm import ArmAnswer, EngineArm
from .cache import CacheDropper
from .query import QuerySpec
from .tables import TableBinding

comptime _NS_PER_MS: Float64 = 1_000_000.0


struct Timed(Copyable, Movable):
    """One timed run: its time in milliseconds and the page faults the
    engine's process took during it (none where they cannot be read)."""

    var ms: Float64
    var faults: Optional[FaultCount]

    def __init__(out self, ms: Float64, var faults: Optional[FaultCount]):
        self.ms = ms
        self.faults = faults^


struct CheckRun(Copyable, Movable):
    """The run that checked an answer, as the first run of its engine: its
    time in milliseconds (`resolved` is False when the clock could not tell its
    start from its end, and `ms` is then 0) and the page faults the engine's
    process took during it (none where they cannot be read)."""

    var ms: Float64
    var resolved: Bool
    var faults: Optional[FaultCount]

    def __init__(out self, ms: Float64, resolved: Bool, var faults: Optional[FaultCount]):
        self.ms = ms
        self.resolved = resolved
        self.faults = faults^


struct KomiraCheck(Movable):
    """The arm's answer to the check run, and that run as a `CheckRun`."""

    var answer: ArmAnswer
    var run: CheckRun

    def __init__(out self, var answer: ArmAnswer, var run: CheckRun):
        self.answer = answer^
        self.run = run^


def check_komira[A: EngineArm](mut arm: A, query: QuerySpec, clock: BenchClock) raises -> KomiraCheck:
    """Run `query` on `arm` with its rows materialized, timed on the host clock
    with the arm's fault counters read around it exactly as `time_komira` does."""
    var f0 = arm.faults()
    var t0 = clock.now()
    var answer = arm.run(query, True)
    var t1 = clock.now()
    var f1 = arm.faults()
    var delta = Optional[FaultCount]()
    if Bool(f0) and Bool(f1):
        delta = Optional[FaultCount](f1.value().minus(f0.value()))
    var resolved = t1 > t0
    var ms = Float64(t1 - t0) / _NS_PER_MS if resolved else 0.0
    return KomiraCheck(answer^, CheckRun(ms, resolved, delta^))


def duckdb_check_run(fetched: FetchResult) -> CheckRun:
    """The fetch that gave DuckDB's answer as a `CheckRun`: marker to marker,
    with the faults of the DuckDB process around it."""
    var ok = fetched.resolved and fetched.elapsed_ns > 0
    var ms = Float64(fetched.elapsed_ns) / _NS_PER_MS if ok else 0.0
    return CheckRun(ms, ok, fetched.faults.copy())


struct EngineRuns(Copyable, Movable):
    """What one engine produced for one query: per sweep, the time of each rep
    in milliseconds (rep 0 first) and, when the engine's process counters can
    be read, the minor and major page faults of each rep in the same shape.
    The fault lists stay empty when any run of the side could not be read."""

    var ms: List[List[Float64]]
    var minor: List[List[Int64]]
    var major: List[List[Int64]]

    def __init__(out self):
        self.ms = List[List[Float64]]()
        self.minor = List[List[Int64]]()
        self.major = List[List[Int64]]()


struct Sweeps(Copyable, Movable):
    """The runs of one query: per engine, a list of sweeps, each a list of
    reps with rep 0 first."""

    var komira: EngineRuns
    var duckdb: EngineRuns

    def __init__(out self):
        self.komira = EngineRuns()
        self.duckdb = EngineRuns()


def time_komira[A: EngineArm](
    mut arm: A, query: QuerySpec, clock: BenchClock, rows: Int64
) raises -> Timed:
    """One timed run of `query` on `arm`, in milliseconds, with the page faults
    the arm's process took during it. Raises when the run does not complete
    (the check run did), returns a different number of rows than the verified
    check run (`rows`), or takes no measurable time."""
    var f0 = arm.faults()
    var t0 = clock.now()
    var answer = arm.run(query, False)
    var t1 = clock.now()
    var f1 = arm.faults()
    if not answer.completed():
        raise Error("the komira arm stopped completing " + query.key() + " after its check run passed")
    if answer.row_count != rows:
        raise Error(
            "the komira arm returned " + String(answer.row_count) + " rows for " + query.key()
            + " in a timed run, " + String(rows) + " in its verified run"
        )
    if t1 <= t0:
        raise Error("the komira time of " + query.key() + " is below the clock resolution; use a larger dataset")
    var delta = Optional[FaultCount]()
    if Bool(f0) and Bool(f1):
        delta = Optional[FaultCount](f1.value().minus(f0.value()))
    return Timed(Float64(t1 - t0) / _NS_PER_MS, delta^)


def time_duckdb[T: DuckDbTransport](mut session: DuckDbSession[T], query: QuerySpec) raises -> Timed:
    """One timed run of `query` in `session`, in milliseconds, with the page
    faults the DuckDB process took between the markers' readings. A timed
    DuckDB run renders nothing, so its row count is not seen: DuckDB's answer
    is checked only by the run that fetched it."""
    var t = session.run_timed(query.text)
    if not t.ok():
        raise Error("duckdb failed on " + query.key() + " in a timed run: " + t.error)
    if not t.resolved or t.elapsed_ns <= 0:
        raise Error("the duckdb time of " + query.key() + " is below the clock resolution; use a larger dataset")
    return Timed(Float64(t.elapsed_ns) / _NS_PER_MS, t.faults.copy())


struct _SweepRecord(Movable):
    """The runs of one sweep of one side while it is being collected."""

    var ms: List[Float64]
    var minor: List[Int64]
    var major: List[Int64]
    var counted: Bool
    """False once any run of the sweep had no fault reading."""

    def __init__(out self):
        self.ms = List[Float64]()
        self.minor = List[Int64]()
        self.major = List[Int64]()
        self.counted = True

    def add(mut self, run: Timed):
        self.ms.append(run.ms)
        if run.faults:
            self.minor.append(run.faults.value().minor)
            self.major.append(run.faults.value().major)
        else:
            self.counted = False


def _store(mut side: EngineRuns, sweep: _SweepRecord, mut all_counted: Bool):
    if not sweep.counted:
        all_counted = False
    side.ms.append(sweep.ms.copy())
    side.minor.append(sweep.minor.copy())
    side.major.append(sweep.major.copy())


def _without_faults_unless(mut side: EngineRuns, all_counted: Bool):
    if not all_counted:
        side.minor = List[List[Int64]]()
        side.major = List[List[Int64]]()


def measure[
    T: DuckDbTransport, A: EngineArm, D: CacheDropper
](
    mut session: DuckDbSession[T],
    mut arm: A,
    mut dropper: D,
    clock: BenchClock,
    query: QuerySpec,
    files: List[String],
    tables: List[TableBinding],
    threads: Int,
    memory_limit_bytes: Int,
    rows: Int64,
    sweeps: Int,
    reps: Int,
    cold: Bool,
) raises -> Sweeps:
    """`sweeps` sweeps of `reps` reps of `query` on both engines; every timed
    komira run must return `rows` rows, the count of its verified run. Every
    run is recorded, the first rep of each sweep and the first sweep included.
    When `cold`, the file cache is dropped before every rep of either engine
    and the komira arm is closed and prepared again before each of its reps,
    so what it caches in the process is gone. DuckDB's session is not
    restarted: what DuckDB caches in its process survives a cold rep."""
    var out = Sweeps()
    var komira_counted = True
    var duckdb_counted = True
    for _ in range(sweeps):
        var k = _SweepRecord()
        var d = _SweepRecord()
        for _ in range(reps):
            if cold:
                dropper.drop(files)
                arm.close()
                arm.prepare(tables, threads, memory_limit_bytes)
            k.add(time_komira(arm, query, clock, rows))
            if cold:
                dropper.drop(files)
            d.add(time_duckdb(session, query))
        _store(out.komira, k, komira_counted)
        _store(out.duckdb, d, duckdb_counted)
    _without_faults_unless(out.komira, komira_counted)
    _without_faults_unless(out.duckdb, duckdb_counted)
    return out^
