# Timing one query on both engines. Komira is timed on the host clock around
# the arm's run; DuckDB by its session, from marker to marker. Both run the
# same text. Reps alternate between the engines (komira, then DuckDB), so a
# slow drift of the host falls on both. A time the clock cannot resolve is not
# a measurement, and neither is a run that stopped completing.

from komira_bench_duckdb import BenchClock, DuckDbSession, DuckDbTransport

from .arm import EngineArm
from .cache import CacheDropper
from .query import QuerySpec
from .tables import TableBinding

comptime _NS_PER_MS: Float64 = 1_000_000.0


struct Sweeps(Copyable, Movable):
    """The timings of one query, in milliseconds: per engine, a list of
    sweeps, each a list of reps with rep 0 first."""

    var komira: List[List[Float64]]
    var duckdb: List[List[Float64]]

    def __init__(out self):
        self.komira = List[List[Float64]]()
        self.duckdb = List[List[Float64]]()


def time_komira[A: EngineArm](
    mut arm: A, query: QuerySpec, clock: BenchClock, rows: Int64
) raises -> Float64:
    """One timed run of `query` on `arm`, in milliseconds. Raises when the
    run does not complete (the check run did), returns a different number of
    rows than the verified check run (`rows`), or takes no measurable time."""
    var t0 = clock.now()
    var answer = arm.run(query, False)
    var t1 = clock.now()
    if not answer.completed():
        raise Error("the komira arm stopped completing " + query.key() + " after its check run passed")
    if answer.row_count != rows:
        raise Error(
            "the komira arm returned " + String(answer.row_count) + " rows for " + query.key()
            + " in a timed run, " + String(rows) + " in its verified run"
        )
    if t1 <= t0:
        raise Error("the komira time of " + query.key() + " is below the clock resolution; use a larger dataset")
    return Float64(t1 - t0) / _NS_PER_MS


def time_duckdb[T: DuckDbTransport](mut session: DuckDbSession[T], query: QuerySpec) raises -> Float64:
    """One timed run of `query` in `session`, in milliseconds. A timed DuckDB
    run renders nothing, so its row count is not seen: DuckDB's answer is
    checked only by the run that fetched it."""
    var t = session.run_timed(query.text)
    if not t.ok():
        raise Error("duckdb failed on " + query.key() + " in a timed run: " + t.error)
    if not t.resolved or t.elapsed_ns <= 0:
        raise Error("the duckdb time of " + query.key() + " is below the clock resolution; use a larger dataset")
    return Float64(t.elapsed_ns) / _NS_PER_MS


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
    komira run must return `rows` rows, the count of its verified run. When
    `cold`, the file cache is dropped before every rep of either engine and
    the komira arm is closed and prepared again before each of its reps, so
    what it caches in the process is gone. DuckDB's session is not restarted:
    what DuckDB caches in its process survives a cold rep."""
    var out = Sweeps()
    for _ in range(sweeps):
        var k = List[Float64]()
        var d = List[Float64]()
        for _ in range(reps):
            if cold:
                dropper.drop(files)
                arm.close()
                arm.prepare(tables, threads, memory_limit_bytes)
            k.append(time_komira(arm, query, clock, rows))
            if cold:
                dropper.drop(files)
            d.append(time_duckdb(session, query))
        out.komira.append(k^)
        out.duckdb.append(d^)
    return out^
