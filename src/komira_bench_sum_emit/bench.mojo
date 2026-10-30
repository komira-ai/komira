# =============================================================================
# bench -- SQL sum() over INT32 and INT64 columns, timed through run_sql
# =============================================================================
#
# One table t(k INT64, v INT64, i INT32) of `rows` rows is generated in memory
# from fixed formulas, written as Parquet (`row_group_rows` rows per row
# group) into the output directory, registered in one engine context per
# thread count and queried with five statements:
#
#   sum_int64   select sum(v) from t
#   sum_int32   select sum(i) from t
#   group_int64 select k, sum(v) from t group by k   (16 groups)
#   group_int32 select k, sum(i) from t group by k
#   min_int64   select min(v) from t                  (control: no sum)
#
# Each statement runs once unrecorded (the file and the engine's caches warm)
# and then `runs` times, timed with the monotonic clock around `run_sql`
# alone. The values are small, so no statement overflows INT64 and every
# engine this bench is built against (INT64 sum, or DECIMAL(38, 0) sum) must
# give the same totals: the answer of every run is checked against totals the
# generator computes, whatever the declared type of the result, and the JSON
# records the declared type of each result column and whether every answer
# matched. The control statement moves with the machine, not with the sum, so
# it tells box drift from a real change.
#
# What the JSON holds per (statement, thread count): median, quartiles and
# range of the wall time in milliseconds, and every run.

from std.os import makedirs, remove
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_scalar_arithmetic.decimal_arith import I128
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import run_sql

from .stats import maximum, median, minimum, quantile

comptime SCHEMA: String = "komira-bench-sum-emit/1"
comptime GROUPS: Int = 16


struct BenchSettings(Copyable, Movable):
    var out_dir: String
    var label: String
    var threads: List[Int]
    var runs: Int
    var rows: Int
    var row_group_rows: Int
    var memory_budget_bytes: Int

    def __init__(
        out self,
        var out_dir: String,
        var label: String,
        var threads: List[Int],
        runs: Int,
        rows: Int,
        row_group_rows: Int,
        memory_budget_bytes: Int,
    ):
        self.out_dir = out_dir^
        self.label = label^
        self.threads = threads^
        self.runs = runs
        self.rows = rows
        self.row_group_rows = row_group_rows
        self.memory_budget_bytes = memory_budget_bytes


struct BenchResult(Movable):
    var json: String
    var answers_match: Bool

    def __init__(out self, var json: String, answers_match: Bool):
        self.json = json^
        self.answers_match = answers_match


struct _Query(Copyable, Movable):
    var name: String
    var sql: String
    var value_col: Int
    var grouped: Bool
    var expected: I128

    def __init__(
        out self,
        var name: String,
        var sql: String,
        value_col: Int,
        grouped: Bool,
        expected: I128,
    ):
        self.name = name^
        self.sql = sql^
        self.value_col = value_col
        self.grouped = grouped
        self.expected = expected


def _v_of(x: Int) -> Int64:
    return Int64((x * 7919) % 2000003 - 1000001)


def _i_of(x: Int) -> Int32:
    return Int32((x * 31) % 200003 - 100001)


def _wide(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _build_batch(rows: Int) raises -> RecordBatch:
    var k = PrimitiveArray[DType.int64].allocate_nullable(rows)
    var v = PrimitiveArray[DType.int64].allocate_nullable(rows)
    var i = PrimitiveArray[DType.int32].allocate_nullable(rows)
    for x in range(rows):
        k.set(x, Int64(x % GROUPS))
        v.set(x, _v_of(x))
        i.set(x, _i_of(x))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("i", ArrowType.INT32, True))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    rb.add_column(Column.from_primitive[DType.int32](i^))
    return rb.build(sb.build())


def _queries(rows: Int) -> List[_Query]:
    var sum_v = 0
    var sum_i = 0
    var min_v = 0
    for x in range(rows):
        var v = Int(_v_of(x))
        sum_v += v
        sum_i += Int(_i_of(x))
        if x == 0 or v < min_v:
            min_v = v
    var out = List[_Query]()
    out.append(_Query("sum_int64", "select sum(v) from t", 0, False, _wide(sum_v)))
    out.append(_Query("sum_int32", "select sum(i) from t", 0, False, _wide(sum_i)))
    out.append(
        _Query("group_int64", "select k, sum(v) from t group by k", 1, True, _wide(sum_v))
    )
    out.append(
        _Query("group_int32", "select k, sum(i) from t group by k", 1, True, _wide(sum_i))
    )
    out.append(_Query("min_int64", "select min(v) from t", 0, False, _wide(min_v)))
    return out^


def _type_name(t: ArrowType) -> String:
    if t == ArrowType.DECIMAL128:
        return "DECIMAL128"
    if t == ArrowType.INT64:
        return "INT64"
    return "other"


struct _Once(Movable):
    var ns: Int
    var ok: Bool
    var result_type: String

    def __init__(out self):
        self.ns = 0
        self.ok = False
        self.result_type = String("")


def _total_of(ref batch: RecordBatch, col: Int) raises -> I128:
    """The sum over the rows of result column `col` (an INT64 or a DECIMAL128
    column), in 128 bits."""
    ref c = batch.column_at(col)
    var is_decimal = batch.schema.field_arrow_type(col) == ArrowType.DECIMAL128
    var total = I128(0)
    for r in range(batch.num_rows()):
        if c.is_null_at(r):
            continue
        if is_decimal:
            total = total + c.as_decimal128().get_i128(r)
        else:
            total = total + c.as_primitive[DType.int64]().get(r).cast[DType.int128]()
    return total


def _run_once(mut ctx: EngineContext, ref q: _Query) raises -> _Once:
    var rec = _Once()
    var t0 = perf_counter_ns()
    var outcome = run_sql(ctx, q.sql)
    var t1 = perf_counter_ns()
    rec.ns = Int(t1 - t0)
    if outcome.refusal:
        raise Error(
            q.name
            + " was refused at "
            + outcome.refusal.value().step
            + ": "
            + outcome.refusal.value().reason
        )
    if len(outcome.batches) != 1:
        raise Error(q.name + " gave " + String(len(outcome.batches)) + " batches")
    ref batch = outcome.batches[0]
    rec.result_type = _type_name(batch.schema.field_arrow_type(q.value_col))
    var rows_ok = batch.num_rows() == (GROUPS if q.grouped else 1)
    rec.ok = rows_ok and _total_of(batch, q.value_col) == q.expected
    return rec^


def _ms(ns: Float64) -> String:
    return String(ns / 1000000.0)


def _query_json(
    ref q: _Query, threads: Int, ref ns: List[Int], ref result_type: String, ok: Bool
) -> String:
    var s = String('{"query":"') + q.name + '","sql":"' + q.sql + '"'
    s += ',"threads":' + String(threads)
    s += ',"result_type":"' + result_type + '"'
    s += ',"answers_match":' + String("true" if ok else "false")
    s += ',"median_ms":' + _ms(median(ns))
    s += ',"q1_ms":' + _ms(quantile(ns, 0.25))
    s += ',"q3_ms":' + _ms(quantile(ns, 0.75))
    s += ',"min_ms":' + _ms(Float64(minimum(ns)))
    s += ',"max_ms":' + _ms(Float64(maximum(ns)))
    s += ',"runs_ms":['
    for r in range(len(ns)):
        if r > 0:
            s += ","
        s += _ms(Float64(ns[r]))
    s += "]}"
    return s^


def run_bench(settings: BenchSettings) raises -> BenchResult:
    """Generate the table, run every statement at every thread count, return
    the JSON and whether every answer matched."""
    makedirs(settings.out_dir, exist_ok=True)
    var path = settings.out_dir + "/t.parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        _build_batch(settings.rows), max_rows_per_rg=settings.row_group_rows
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    var queries = _queries(settings.rows)
    var answers_match = True
    var entries = String("")
    var first = True
    for t in range(len(settings.threads)):
        var requested = settings.threads[t]
        var ctx = EngineContext(
            EngineOptions(
                worker_count=requested,
                memory_budget_bytes=settings.memory_budget_bytes,
            )
        )
        register_parquet(ctx, "t", path)
        for qi in range(len(queries)):
            ref q = queries[qi]
            var warm = _run_once(ctx, q)
            var ok = warm.ok
            var ns = List[Int]()
            var result_type = warm.result_type.copy()
            for _ in range(settings.runs):
                var one = _run_once(ctx, q)
                ns.append(one.ns)
                ok = ok and one.ok
            if not ok:
                answers_match = False
            if not first:
                entries += ","
            first = False
            entries += _query_json(q, requested, ns, result_type, ok)
    try:
        remove(path)
    except:
        pass
    var json = String('{"schema":"') + SCHEMA + '"'
    json += ',"label":"' + settings.label + '"'
    json += ',"rows":' + String(settings.rows)
    json += ',"row_group_rows":' + String(settings.row_group_rows)
    json += ',"groups":' + String(GROUPS)
    json += ',"warmup_runs_discarded":1'
    json += ',"runs":' + String(settings.runs)
    json += ',"answers_match_expected":' + String("true" if answers_match else "false")
    json += ',"results":[' + entries + "]}\n"
    var jf = open(settings.out_dir + "/sum_emit.json", "w")
    jf.write(json)
    jf.close()
    return BenchResult(json^, answers_match)
