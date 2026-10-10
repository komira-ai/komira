# =============================================================================
# test_selection_flatten_parallel -- the selection EGRESS on the worker pool
# =============================================================================
#
# WHAT IS UNDER TEST. `flatten_selection_table_parallel` -- the engine-boundary
# resolve of every selection-backed (numeric-dictionary) column back to flat,
# with the PER-CHUNK work dispatched across the pool instead of walked on the
# driver thread. It must return the SAME rows in the SAME order with the SAME
# schema as the serial `flatten_selection_table`, on every shape, including the
# ones that must NOT fork.
#
# ★ WHY IT EXISTS AT ALL IS A MEASUREMENT, and it is worth stating here because
# it is the only reason to accept a `run_with_state` on a result path. The
# serial spelling sits on the exit of a join whose own assembly is a 20-way
# fork, so it CROSSES a parallelism boundary. Measured at 20 workers with the
# scheduler trace (region `fj_output_assemble`, ms/rep, and the forked share
# of its own `self_ns`):
#
#     h2o/j1     gather arm  15.52 ms (66% forked)   slice arm  174.50 ms (2% forked)
#     high-card  gather arm 336.35 ms (66% forked)   slice arm 2282.43 ms (6% forked)
#
# The BYTES are identical -- `[defer-out] out_bytes_written` moves OUT of the
# assembly (4.80 GB -> 1.60 GB on the high-cardinality join) and the missing
# 3.20 GB is written by the
# egress instead. Same work, one thread.
#
# ⛔ THIS FILE DOES NOT CLAIM THE SELECTION CARRIER IS A WIN. It is not: with the
# egress fully parallel the carrier's ceiling is PARITY with the gather it
# replaced (same reads, same writes, one MORE pass over the codes, because the
# flatten resolves one column at a time where `_gather_pair_into_range_i32`
# walks the match index once for two). What is under test is that the egress is
# not itself a 20x serialisation artefact, so that a measurement of the carrier
# prices the CARRIER.
#
# ★ EVERY VALUE ASSERTION IS AGAINST AN ABSOLUTE ORACLE, NOT AGAINST THE SERIAL
# FUNCTION. The parallel and serial spellings share `flatten_selection_batch`,
# so a differential between them is blind to any defect inside it. §A computes
# `base[codes[r]]` in the test, from the Lists the fixture was built from, and
# compares cell by cell in order. §B THEN adds the serial differential, which is
# the weaker of the two and is stated as a consistency check, not as the oracle.
#
# ★ AND THE FIXTURE IS ASSERTED TO REACH THE FORK. A parallel path tested only
# through its serial fallback is green under either polarity. §A asserts BOTH
# `num_chunks() >= 2` AND `num_rows() >= SELECTION_FLATTEN_PARALLEL_MIN_ROWS`
# before it runs, so a threshold change that silently disarms the fork reds the
# test rather than quietly converting it into a test of the fallback.
#
# Cases
#   A  ROW-FOR-ROW against an ABSOLUTE oracle, 4 chunks x 4096 rows (16,384 --
#      twice the fork threshold), INT64 + FLOAT64 selection columns beside a
#      PLAIN INT64 column, with REPEATS and a non-monotone code order.
#   B  The parallel result equals the SERIAL result, cell for cell.
#   C  DISPOSITION + POSTCONDITION: the input really carried selection columns,
#      the output carries NONE, and the chunk count and row count are preserved.
#   D  THE CALLER SHAPES THAT MUST NOT FORK: a SINGLE-chunk table (the
#      `into_single_batch` caller's shape) and a multi-chunk table BELOW the row
#      threshold. Both must still be correct, against the same absolute oracle.
#   E  IDENTITY: a table with no selection column comes back untouched -- and
#      specifically the 0-COLUMN `count_only` carrier, whose own schema is
#      authoritative and must NOT be replaced by `flat_schema`.
#   F  RAISE: a chunk whose base tag disagrees with `flat_schema` propagates the
#      named error out of the fork (first-error-wins), rather than returning a
#      relabelled column.
#
# ★ THE MUTATIONS, RUN AND RECORDED, NOT PREDICTED (2026-09-03, 7/7 green
# unmutated). Each is a one-line edit to `selection_flatten_parallel.mojo`; the
# verdict is the actual run output.
#
#   M1  `_SelFlattenTask.execute`: write slot `0` instead of slot `i`
#       (`sp[].out[].replace(0, flat^)`).           ->  4 passed, 3 FAILED
#         §A / §B / §C. Surfaces as `Table.from_chunks: chunk 1 has 0 columns
#         but the table schema declares 3` -- the slots no task claimed still
#         hold their placeholders.
#   M2  `_SelFlattenTask.execute`: write slot `n-1-i` (reverse the output
#       order).                                     ->  4 passed, 3 FAILED
#         §A `i_sel[0][0]`, §B `i 0/0`, §C `chunk 0 landed in the wrong output
#         slot` -- the same rows in the wrong SEQUENCE, which is the failure a
#         commutative fold over the result cannot see.
#   M3  the identity early-return: `return Table.from_chunks(...)` stamped with
#       `flat_schema` instead of `return table^`.   ->  6 passed, 1 FAILED
#         §E only, and specifically its 0-column `count_only` leg:
#         `chunk 0 has 0 columns but the table schema declares 3`. §E1's flat
#         table passes under the mutation, so the count_only leg is the whole
#         of that case's power -- do not drop it as redundant.
#   M4  DELETE the `n_chunks < 2 or ... MIN_ROWS` serial fallback so the fork is
#       ALWAYS taken.                               ->  NOTHING, 7/7 green
#         RECORDED AS UNCOVERED, not as coverage. The fallback is a COST
#         decision (a barrier for one task, or for 48 rows) and it computes the
#         same answer by construction -- both arms call the same
#         `flatten_selection_batch` per chunk -- so no VALUE test can see it,
#         and one that appeared to would be asserting something else. §D asserts
#         the two shapes are CORRECT, which is what a value test can prove; that
#         they are also SERIAL is stated in the source and measured, not tested.
# =============================================================================

from std.memory import Pointer
from std.testing import (
    TestSuite, assert_equal, assert_false, assert_raises, assert_true,
)

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import (
    Field, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_arrow.selection_column import (
    batch_carries_selection,
    flatten_selection_table,
    make_selection_column,
)
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_arrow.table import Table
from komira_buffer.heap_region import HeapRegion

from komira_dispatch_join_kernels.selection_flatten_parallel import (
    SELECTION_FLATTEN_PARALLEL_MIN_ROWS,
    flatten_selection_table_parallel,
)


comptime I64 = DType.int64
comptime F64 = DType.float64

# 4 chunks x 4096 rows = 16,384 -- TWICE the fork threshold, so §A/§B/§C
# exercise the dispatch and not the fallback. Asserted, not assumed.
comptime N_CHUNKS = 4
comptime CHUNK_ROWS = 4096
comptime BASE_ROWS = 512


# =============================================================================
# Harness
# =============================================================================


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _i64_col(var v: List[Int64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate(len(v))
    for i in range(len(v)):
        arr.set(i, v[i])
    return Column.from_primitive[I64](arr^)


def _f64_col(var v: List[Float64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[F64].allocate(len(v))
    for i in range(len(v)):
        arr.set(i, v[i])
    return Column.from_primitive[F64](arr^)


def _codes_sab(
    imm codes: List[Int32]
) raises -> SharedAlignedBuffer[HeapRegion]:
    var buf = OwnedAlignedBuffer(max(len(codes) * 4, 1))
    for i in range(len(codes)):
        buf.set_typed[Scalar[DType.int32]](i, codes[i])
    buf.set_length(Int64(len(codes) * 4))
    return bridge_oab_to_sab[HeapRegion](buf^)


def _flat_schema() raises -> Schema:
    """`i_sel` INT64 (selection) | `f_sel` FLOAT64 (selection) | `plain` INT64."""
    var sb = SchemaBuilder()
    sb.add_field(Field("i_sel", ArrowType.INT64, False))
    sb.add_field(Field("f_sel", ArrowType.FLOAT64, False))
    sb.add_field(Field("plain", ArrowType.INT64, False))
    return sb.build()


def _dict_schema(code_at: ArrowType) raises -> Schema:
    """The schema a selection-backed chunk carries: the two sliced fields are
    DICTIONARY, the plain one is unchanged."""
    var sb = SchemaBuilder()
    sb.add_field(Field.dictionary("i_sel", code_at, False))
    sb.add_field(Field.dictionary("f_sel", code_at, False))
    sb.add_field(Field("plain", ArrowType.INT64, False))
    return sb.build()


# The CODE stream for chunk `k`, row `r`. Deliberately NOT monotone and with
# REPEATS: a carrier that could only express a filter (an ascending, no-repeat
# survivor mask) would pass a monotone fixture and be wrong on a real join,
# whose fan-out emits a probe row more than once.
def _code_at(k: Int, r: Int) -> Int32:
    return Int32((r * 7 + k * 13) % BASE_ROWS)


def _i_base_at(k: Int, i: Int) -> Int64:
    return Int64(1_000_000 * (k + 1) + i)


def _f_base_at(k: Int, i: Int) -> Float64:
    return Float64(i) * 0.5 - Float64(k)


def _plain_at(k: Int, r: Int) -> Int64:
    return Int64(-(1_000 * (k + 1) + r))


def _build_selection_table(
    n_chunks: Int, chunk_rows: Int
) raises -> Table:
    """`n_chunks` chunks, each `chunk_rows` rows, with TWO selection columns
    over that chunk's OWN bases plus one plain column.

    Each chunk names its own base -- which is the carrier's invariant (a
    selection column names exactly ONE base) and is what makes the chunks
    independent, i.e. what the per-chunk dispatch relies on.
    """
    var chunks = List[RecordBatch](capacity=n_chunks)
    for k in range(n_chunks):
        var ivals = List[Int64](capacity=BASE_ROWS)
        var fvals = List[Float64](capacity=BASE_ROWS)
        for i in range(BASE_ROWS):
            ivals.append(_i_base_at(k, i))
            fvals.append(_f_base_at(k, i))
        var ibase = _i64_col(ivals^)
        var fbase = _f64_col(fvals^)

        var codes = List[Int32](capacity=chunk_rows)
        for r in range(chunk_rows):
            codes.append(_code_at(k, r))
        var sab = _codes_sab(codes)

        var plain = List[Int64](capacity=chunk_rows)
        for r in range(chunk_rows):
            plain.append(_plain_at(k, r))

        var b = RecordBatchBuilder.with_capacity(3)
        b.add_column(make_selection_column(ibase, sab, 4, chunk_rows))
        b.add_column(make_selection_column(fbase, sab, 4, chunk_rows))
        b.add_column(_i64_col(plain^))
        chunks.append(b.build(_dict_schema(ArrowType.INT32)))
        _ = ibase^
        _ = fbase^
        _ = sab^
    return Table.from_chunks(chunks^, _dict_schema(ArrowType.INT32))


def _assert_matches_absolute_oracle(
    imm t: Table, n_chunks: Int, chunk_rows: Int, imm tag: String
) raises:
    """Every cell, in order, against `base[codes[r]]` recomputed HERE."""
    assert_equal(t.num_chunks(), n_chunks, tag + " chunk count")
    assert_equal(t.num_rows(), n_chunks * chunk_rows, tag + " row count")
    for k in range(n_chunks):
        ref ch = t.chunks()[k]
        assert_equal(ch.num_rows(), chunk_rows, tag + " chunk rows " + String(k))
        assert_equal(ch.num_columns(), 3, tag + " chunk cols " + String(k))
        # POSTCONDITION: nothing selection-backed may survive the egress.
        for c in range(3):
            assert_false(
                ch.column_at(c).is_numeric_dict(),
                tag + " column " + String(c) + " of chunk " + String(k)
                + " is STILL a selection column after the egress",
            )
        var ic = ch.column_at(0).as_primitive[I64]()
        var fc = ch.column_at(1).as_primitive[F64]()
        var pc = ch.column_at(2).as_primitive[I64]()
        for r in range(chunk_rows):
            var code = Int(_code_at(k, r))
            assert_equal(
                ic.get(r),
                _i_base_at(k, code),
                tag + " i_sel[" + String(k) + "][" + String(r) + "]",
            )
            assert_true(
                abs(fc.get(r) - _f_base_at(k, code)) < 1e-12,
                tag + " f_sel[" + String(k) + "][" + String(r) + "]",
            )
            assert_equal(
                pc.get(r),
                _plain_at(k, r),
                tag + " plain[" + String(k) + "][" + String(r) + "]",
            )


# =============================================================================
# §A -- row-for-row against an absolute oracle, ON THE FORKED PATH
# =============================================================================


def test_parallel_egress_matches_the_absolute_oracle() raises:
    var t = _build_selection_table(N_CHUNKS, CHUNK_ROWS)

    # NON-VACUITY: this fixture must actually reach the dispatch. Both clauses
    # of the fallback are asserted, so a threshold change that silently turns
    # this into a test of the SERIAL path reds here instead of passing quietly.
    assert_true(
        t.num_chunks() >= 2,
        "§A VACUOUS: a single-chunk fixture takes the serial fallback",
    )
    assert_true(
        t.num_rows() >= SELECTION_FLATTEN_PARALLEL_MIN_ROWS,
        "§A VACUOUS: "
        + String(t.num_rows())
        + " rows is below the fork threshold "
        + String(SELECTION_FLATTEN_PARALLEL_MIN_ROWS)
        + ", so the serial fallback would run",
    )
    assert_true(
        batch_carries_selection(t.chunks()[0]),
        "§A VACUOUS: the fixture carries no selection column, so the egress is"
        " the identity and proves nothing",
    )

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var out = flatten_selection_table_parallel(
        t^,
        _flat_schema(),
        Pointer(to=disp),
        CancellationToken.never(),
        4,
    )
    rt.shutdown()

    _assert_matches_absolute_oracle(out, N_CHUNKS, CHUNK_ROWS, String("§A"))
    # The FLAT schema, not the DICTIONARY one the input carried.
    assert_equal(
        String(out.schema().field_arrow_type(0)),
        String(ArrowType.INT64),
        "§A the result must carry the FLAT tag",
    )
    assert_equal(
        String(out.schema().field_arrow_type(1)),
        String(ArrowType.FLOAT64),
        "§A the result must carry the FLAT tag",
    )
    _ = out^


# =============================================================================
# §B -- and it agrees with the serial spelling, cell for cell
# =============================================================================


def test_parallel_egress_agrees_with_the_serial_spelling() raises:
    """The weaker check, stated as a consistency check and NOT as the oracle:
    both spellings call the same `flatten_selection_batch`, so this cannot see a
    defect inside it. §A is what pins the values."""
    var par_in = _build_selection_table(N_CHUNKS, CHUNK_ROWS)
    var ser_in = _build_selection_table(N_CHUNKS, CHUNK_ROWS)

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var par = flatten_selection_table_parallel(
        par_in^, _flat_schema(), Pointer(to=disp), CancellationToken.never(), 4
    )
    rt.shutdown()
    var ser = flatten_selection_table(ser_in^, _flat_schema())

    assert_equal(par.num_chunks(), ser.num_chunks(), "§B chunk count")
    assert_equal(par.num_rows(), ser.num_rows(), "§B row count")
    for k in range(par.num_chunks()):
        ref pch = par.chunks()[k]
        ref sch = ser.chunks()[k]
        assert_equal(pch.num_rows(), sch.num_rows(), "§B rows " + String(k))
        var pi = pch.column_at(0).as_primitive[I64]()
        var si = sch.column_at(0).as_primitive[I64]()
        var pf = pch.column_at(1).as_primitive[F64]()
        var sf = sch.column_at(1).as_primitive[F64]()
        for r in range(pch.num_rows()):
            assert_equal(pi.get(r), si.get(r), "§B i " + String(k) + "/" + String(r))
            assert_true(
                pf.get(r) == sf.get(r), "§B f " + String(k) + "/" + String(r)
            )
    _ = par^
    _ = ser^


# =============================================================================
# §C -- disposition: the chunk sequence is preserved, not merely the multiset
# =============================================================================


def test_parallel_egress_preserves_the_chunk_boundaries() raises:
    """A per-chunk dispatch that wrote its results into the WRONG slots would
    still produce the right rows in the wrong ORDER. The oracle in §A is
    per-(chunk, row) and would catch it; this states the invariant separately so
    the reason is on the record: chunk `i` in must be chunk `i` out."""
    var t = _build_selection_table(N_CHUNKS, CHUNK_ROWS)
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var out = flatten_selection_table_parallel(
        t^, _flat_schema(), Pointer(to=disp), CancellationToken.never(), 4
    )
    rt.shutdown()
    assert_equal(out.num_chunks(), N_CHUNKS, "§C chunk count preserved")
    for k in range(N_CHUNKS):
        # `plain` is chunk-identifying and is NOT selection-backed, so it pins
        # the slot independently of anything the resolve did.
        var pc = out.chunks()[k].column_at(2).as_primitive[I64]()
        assert_equal(
            pc.get(0),
            _plain_at(k, 0),
            "§C chunk " + String(k) + " landed in the wrong output slot",
        )
    _ = out^


# =============================================================================
# §D -- the shapes that must NOT fork, and must still be correct
# =============================================================================


def test_single_chunk_caller_takes_the_serial_path_and_is_correct() raises:
    """The `into_single_batch` caller's shape: ONE chunk. It must not fork (one
    task is a barrier for nothing) and it must be correct."""
    var t = _build_selection_table(1, CHUNK_ROWS)
    assert_equal(t.num_chunks(), 1, "§D the fixture must be single-chunk")
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var out = flatten_selection_table_parallel(
        t^, _flat_schema(), Pointer(to=disp), CancellationToken.never(), 4
    )
    rt.shutdown()
    _assert_matches_absolute_oracle(out, 1, CHUNK_ROWS, String("§D1"))
    # And it survives the single-batch entry point, which is what a non-chunked
    # caller actually does with it.
    var one = out^.into_single_batch()
    assert_equal(one.num_rows(), CHUNK_ROWS, "§D1 into_single_batch rows")
    assert_false(
        one.column_at(0).is_numeric_dict(),
        "§D1 a selection column reached a single-batch caller",
    )
    _ = one^


def test_below_threshold_multi_chunk_is_serial_and_correct() raises:
    """Multi-chunk but BELOW the row threshold: the fallback, and it is a cost
    decision only -- the values must be identical to the forked path's."""
    var small_rows = 16
    var t = _build_selection_table(3, small_rows)
    assert_true(
        t.num_rows() < SELECTION_FLATTEN_PARALLEL_MIN_ROWS,
        "§D2 the fixture must be BELOW the fork threshold",
    )
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var out = flatten_selection_table_parallel(
        t^, _flat_schema(), Pointer(to=disp), CancellationToken.never(), 4
    )
    rt.shutdown()
    _assert_matches_absolute_oracle(out, 3, small_rows, String("§D2"))
    _ = out^


# =============================================================================
# §E -- identity when nothing is selection-backed
# =============================================================================


def test_identity_when_no_chunk_carries_a_selection() raises:
    """Two shapes, and the SECOND is the one a schema substitution breaks."""
    # (1) an ordinary flat table -- returned untouched.
    var flat_chunks = List[RecordBatch](capacity=2)
    for k in range(2):
        var v = List[Int64](capacity=8)
        for r in range(8):
            v.append(Int64(100 * k + r))
        var b = RecordBatchBuilder.with_capacity(1)
        b.add_column(_i64_col(v^))
        var sb = SchemaBuilder()
        sb.add_field(Field("only", ArrowType.INT64, False))
        flat_chunks.append(b.build(sb.build()))
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("only", ArrowType.INT64, False))
    var flat_t = Table.from_chunks(flat_chunks^, sb2.build())

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var sb3 = SchemaBuilder()
    sb3.add_field(Field("only", ArrowType.INT64, False))
    var out = flatten_selection_table_parallel(
        flat_t^, sb3.build(), Pointer(to=disp), CancellationToken.never(), 4
    )
    assert_equal(out.num_chunks(), 2, "§E1 chunk count untouched")
    assert_equal(out.num_rows(), 16, "§E1 row count untouched")
    assert_equal(
        out.chunks()[1].column_at(0).as_primitive[I64]().get(3),
        Int64(103),
        "§E1 values untouched",
    )
    _ = out^

    # (2) THE 0-COLUMN `count_only` CARRIER. Its OWN schema is authoritative:
    # substituting `flat_schema` here makes `from_chunks` raise on a healthy
    # result, which is the exact failure the serial function's identity arm
    # documents.
    var co = Table.from_batch(RecordBatch.count_only(4242))
    assert_equal(co.num_columns(), 0, "§E2 the carrier must be 0-column")
    var out2 = flatten_selection_table_parallel(
        co^, _flat_schema(), Pointer(to=disp), CancellationToken.never(), 4
    )
    rt.shutdown()
    assert_equal(out2.num_rows(), 4242, "§E2 the count must survive")
    assert_equal(out2.num_columns(), 0, "§E2 the 0-column shape must survive")
    _ = out2^


# =============================================================================
# §F -- a per-chunk failure comes back out of the fork, named
# =============================================================================


def test_a_mislabelled_chunk_raises_out_of_the_fork() raises:
    """`flat_schema` declares INT32 where the base resolves to INT64. The serial
    spelling raises; so must the forked one, with the same message reaching the
    caller instead of a silently relabelled column."""
    var t = _build_selection_table(N_CHUNKS, CHUNK_ROWS)
    var wrong = SchemaBuilder()
    wrong.add_field(Field("i_sel", ArrowType.INT32, False))
    wrong.add_field(Field("f_sel", ArrowType.FLOAT64, False))
    wrong.add_field(Field("plain", ArrowType.INT64, False))

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    with assert_raises(contains="flatten_selection_batch"):
        var bad = flatten_selection_table_parallel(
            t^, wrong.build(), Pointer(to=disp), CancellationToken.never(), 4
        )
        _ = bad^
    rt.shutdown()


def main() raises:
    var suite = TestSuite()
    suite.test[test_parallel_egress_matches_the_absolute_oracle]()
    suite.test[test_parallel_egress_agrees_with_the_serial_spelling]()
    suite.test[test_parallel_egress_preserves_the_chunk_boundaries]()
    suite.test[test_single_chunk_caller_takes_the_serial_path_and_is_correct]()
    suite.test[test_below_threshold_multi_chunk_is_serial_and_correct]()
    suite.test[test_identity_when_no_chunk_carries_a_selection]()
    suite.test[test_a_mislabelled_chunk_raises_out_of_the_fork]()
    suite^.run()
