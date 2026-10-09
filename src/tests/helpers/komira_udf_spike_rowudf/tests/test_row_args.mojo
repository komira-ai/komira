# python_row.so's call_batch against argument structs broken in one place,
# the host's cancel flag and deadline, and the context's thread, through the
# engine's probe (native/row_engine.c, rowe_probe: one call on the calling
# thread, under a scripted host clock whose reads are counted).
#
# What it proves, and the defect each part catches:
#   - each layout fault of a two-field argument struct (a child shorter than
#     the struct, a negative struct length, a nonzero struct offset, a NULL
#     child, a child with three buffers, a negative child offset, a child
#     with no values buffer) is refused with ERR_INTERNAL naming the field
#     and the fault, before any of it is read, and the args are still moved
#     and released (a runtime that reads past a short buffer, or keeps the
#     host's array); an empty batch with no values buffer is accepted;
#   - arrays on another device are refused with ERR_UNSUPPORTED, a short
#     call struct with ERR_ABI;
#   - the cancel flag set before the call fails it before the batch; set by
#     a clock read inside the call, it fails the batch at the next row
#     (a flag read only before the batch);
#   - the clock is read after row 0 and every 1024 rows (counted reads), and
#     a deadline fails the batch at the row after the read that passed it,
#     never at a read equal to it (a deadline checked only before the batch;
#     an off-by-one on either comparison);
#   - a call or open_instance from a thread other than the context's is
#     refused, and closes from another thread are ignored and logged at
#     level 2, while closes on the owner thread log nothing (a
#     sub-interpreter entered off its thread);
#   - every fault is reported with row -1; an OK output's device struct has
#     its reserved words zeroed (the probe hands in 0xFF bytes); a call with
#     no cancel flag runs;
#   - the ABI's struct sizes: a capabilities, spec, host or error struct
#     shorter than the runtime's is refused with ERR_ABI (an error struct
#     too short, or none, is left alone); init with no host, another major
#     or a second time is refused;
#   - the spec checks that need a schema the harness cannot write: no
#     argument struct, one with no format, a list, -1 children; a field
#     that is NULL, has no format, "" or "gg" as its format, a child, or no
#     name; no result type; a code object;
#   - the frame and aggregate entries refuse with ERR_UNSUPPORTED and still
#     release what was moved in and set nothing they hand back;
#   - 2000 validates refused after binding two fields leave the heap as they
#     found it (a field's name or the field array not freed);
#   - an array or stream moved in already released is not released again;
#   - init installed no signal handler (SIGINT, SIGPIPE, SIGXFSZ); the
#     library opened by an absolute path finds what is beside it; shutdown
#     off the init thread logs and does not finalize.
#
# Every single-point mutant of the runtime and the adapter was run against
# the runtime tests (the PR's mutation scorecard). Mutants planted
# by hand, each red: row_call.c's args_fit without the short-child check
# (the probe read past field 1's buffer: status OK); the adapter's per-row
# cancel check made `if False` (cancelled at row 1 came back OK).

from std.os.path import realpath
from std.testing import assert_equal, assert_false, assert_true

from komira_udf_spike_abi.contract import status_name
from komira_udf_spike_rowudf.engine import (
    MISUSE_AGG_FINISH,
    MISUSE_AGG_MERGE,
    MISUSE_AGG_OPEN,
    MISUSE_AGG_STATE,
    MISUSE_AGG_UPDATE,
    MISUSE_ARGS_LIST,
    MISUSE_ARGS_NEGATIVE,
    MISUSE_ARGS_NO_FORMAT,
    MISUSE_ARGS_NULL,
    MISUSE_AGG_UPDATE_RELEASED,
    MISUSE_FRAME_OPEN_RELEASED,
    MISUSE_CAPS_SMALL,
    MISUSE_CODE,
    MISUSE_ERR_NULL,
    MISUSE_ERR_SMALL,
    MISUSE_FIELD_CHILD,
    MISUSE_FIELD_EMPTY,
    MISUSE_FIELD_NO_FORMAT,
    MISUSE_FIELD_NO_NAME,
    MISUSE_FIELD_NULL,
    MISUSE_FIELD_TWO_CHARS,
    MISUSE_FRAME_NEXT,
    MISUSE_FRAME_OPEN,
    MISUSE_HOST_MAJOR,
    MISUSE_HOST_NULL,
    MISUSE_HOST_SMALL,
    MISUSE_INIT_AGAIN,
    MISUSE_LEAK,
    MISUSE_RESULT_NULL,
    MISUSE_SIGNALS,
    MISUSE_SPEC_SMALL,
    PROBE_CALL_SIZE,
    PROBE_CHILD_BUFFERS,
    PROBE_FOREIGN_CLOSE,
    PROBE_GOOD,
    PROBE_NEG_CHILD_OFFSET,
    PROBE_NEG_LENGTH,
    PROBE_NO_VALUES,
    PROBE_NOT_CPU,
    PROBE_NULL_CANCEL,
    PROBE_NULL_CHILD,
    PROBE_OTHER_THREAD,
    PROBE_SHORT_CHILD,
    PROBE_STRUCT_OFFSET,
    Probe,
    ProbeResult,
    RowEngine,
)

comptime ENTRY = "udf_rows:price_qty"


def pq() -> List[String]:
    return ["price", "qty"]


def expect(r: ProbeResult, status: String, words: String, row: Int64, what: String) raises:
    var w = what + ": " + status_name(r.status) + " " + r.message
    assert_equal(status_name(r.status), status, w)
    assert_true(words in r.message, w + " (wanted '" + words + "')")
    assert_equal(r.row, row, w)
    assert_true(r.moved, what + ": args not moved")
    assert_true(r.released, what + ": args not released")


def expect_ok(r: ProbeResult, rows: Int, what: String) raises:
    var w = what + ": " + status_name(r.status) + " " + r.message
    assert_equal(status_name(r.status), "OK", w)
    assert_equal(r.out_len, Int64(rows), w)
    assert_equal(r.out_nulls, 0, w)
    for i in range(len(r.out)):
        assert_equal(r.out[i], Float64((i + 1) * (i + 1) * 10), w + ": row " + String(i))
    assert_true(r.moved and r.released, what + ": args not moved and released")
    if rows > 0:
        assert_true(r.reserved_zero, what + ": the output's reserved words")


def test_layouts(mut e: RowEngine) raises:
    var good = e.probe(Probe.of(ENTRY, pq(), PROBE_GOOD, 3))
    expect_ok(good, 3, "well formed")
    assert_equal(good.logs, 0, "closes on the owner thread log nothing")
    var faults: List[Int32] = [
        PROBE_SHORT_CHILD, PROBE_NULL_CHILD, PROBE_CHILD_BUFFERS, PROBE_NEG_CHILD_OFFSET, PROBE_NO_VALUES,
    ]
    var words: List[String] = [
        "is shorter than the batch",
        "is not a primitive array",
        "is not a primitive array",
        "has a negative offset",
        "has no values buffer",
    ]
    var names: List[String] = ["price", "qty"]
    for f in range(2):
        for k in range(len(faults)):
            var p = Probe.of(ENTRY, pq(), faults[k], 3)
            p.field = Int32(f)
            var r = e.probe(p)
            var what = "field " + String(f) + " fault " + String(faults[k])
            expect(r, "ERR_INTERNAL", "read-set field " + names[f] + " " + words[k], -1, what)
            assert_equal(r.clock_reads, 0, what + ": refused before the batch")
    for kind in [PROBE_NEG_LENGTH, PROBE_STRUCT_OFFSET]:
        var r = e.probe(Probe.of(ENTRY, pq(), kind, 3))
        expect(r, "ERR_INTERNAL", "args has a ", -1, "struct fault " + String(kind))
        assert_false("read-set field" in r.message, r.message)
    expect(
        e.probe(Probe.of(ENTRY, pq(), PROBE_STRUCT_OFFSET, 3)), "ERR_INTERNAL",
        "args has a nonzero offset (the argument struct is at offset 0)", -1, "struct offset",
    )
    expect(e.probe(Probe.of(ENTRY, pq(), PROBE_NEG_LENGTH, 3)), "ERR_INTERNAL", "args has a negative length", -1, "length")
    # No values buffer: refused for one row, accepted for none.
    expect(e.probe(Probe.of(ENTRY, pq(), PROBE_NO_VALUES, 1)), "ERR_INTERNAL", "qty has no values buffer", -1, "1 row")
    expect_ok(e.probe(Probe.of(ENTRY, pq(), PROBE_NO_VALUES, 0)), 0, "empty, no values buffer")
    expect(e.probe(Probe.of(ENTRY, pq(), PROBE_NOT_CPU, 3)), "ERR_UNSUPPORTED", "not on the CPU", -1, "device")
    expect(e.probe(Probe.of(ENTRY, pq(), PROBE_CALL_SIZE, 3)), "ERR_ABI", "call struct_size", -1, "call size")
    expect_ok(e.probe(Probe.of(ENTRY, pq(), PROBE_NULL_CANCEL, 3)), 3, "no cancel flag")


def test_cancel(mut e: RowEngine) raises:
    var p = Probe.of(ENTRY, pq(), PROBE_GOOD, 3)
    p.cancel_now = True
    var r = e.probe(p)
    expect(r, "ERR_CANCELLED", "cancelled before the batch", -1, "flag set before the call")
    assert_equal(r.clock_reads, 0)
    # Row 0's clock read sets it: row 1 sees it.
    p = Probe.of(ENTRY, pq(), PROBE_GOOD, 3)
    p.cancel_at = 1
    expect(e.probe(p), "ERR_CANCELLED", "cancelled at row 1", 1, "flag set at row 0's clock read")
    # With a deadline the runtime reads the clock before the batch: row 0
    # sees the flag that read set.
    p.deadline = 100
    expect(e.probe(p), "ERR_CANCELLED", "cancelled at row 0", 0, "flag set before row 0")


def test_clock(mut e: RowEngine) raises:
    var r = e.probe(Probe.of(ENTRY, pq(), PROBE_GOOD, 3))
    assert_equal(r.clock_reads, 1, "no deadline: one read, after row 0")
    r = e.probe(Probe.of(ENTRY, pq(), PROBE_GOOD, 0))
    assert_equal(r.clock_reads, 0, "no rows: no read")
    r = e.probe(Probe.of(ENTRY, pq(), PROBE_GOOD, 2049))
    assert_equal(status_name(r.status), "OK", r.message)
    assert_equal(r.clock_reads, 3, "rows 0, 1024 and 2048")
    r = e.probe(Probe.of(ENTRY, pq(), PROBE_GOOD, 2048))
    assert_equal(r.clock_reads, 2, "rows 0 and 1024")


def test_deadline(mut e: RowEngine) raises:
    # Reads: 1 before the batch, 2 after row 0, 3 after row 1024, 4 after
    # row 2048. A deadline equal to a read has not passed.
    var p = Probe.of(ENTRY, pq(), PROBE_GOOD, 3)
    p.deadline = 1
    var r = e.probe(p)
    expect(r, "ERR_DEADLINE", "the deadline passed at row 1", 1, "deadline 1")
    assert_equal(r.clock_reads, 2)
    p = Probe.of(ENTRY, pq(), PROBE_GOOD, 2049)
    p.deadline = 3
    r = e.probe(p)
    expect(r, "ERR_DEADLINE", "the deadline passed at row 2049", 2049, "deadline 3")
    assert_equal(r.clock_reads, 4)
    p.deadline = 4
    r = e.probe(p)
    assert_equal(status_name(r.status), "OK", "deadline 4: " + r.message)
    assert_equal(r.clock_reads, 4)
    # Passed before the call: the first read is 6.
    p = Probe.of(ENTRY, pq(), PROBE_GOOD, 3)
    p.clock0 = 5
    p.deadline = 1
    r = e.probe(p)
    expect(r, "ERR_DEADLINE", "the deadline passed before the batch", -1, "deadline passed")
    assert_equal(r.clock_reads, 1)


def test_threads(mut e: RowEngine) raises:
    var r = e.probe(Probe.of(ENTRY, pq(), PROBE_OTHER_THREAD, 3))
    expect(r, "ERR_INTERNAL", "the context belongs to another thread (thread_affine)", -1, "call off the thread")
    assert_equal(status_name(r.open_status), "ERR_INTERNAL", r.open_message)
    assert_true("open_instance: the context belongs to another thread" in r.open_message, r.open_message)
    assert_equal(r.open_row, Int64(-1), r.open_message)
    r = e.probe(Probe.of(ENTRY, pq(), PROBE_FOREIGN_CLOSE, 3))
    assert_equal(r.logs, 2, "two closes off the thread, each logged")
    assert_equal(r.last_level, 2, "logged at level 2")
    expect_ok(r, 3, "a call after closes off the thread")


def misused(mut e: RowEngine, which: Int32, status: String, message: String) raises:
    var m = e.misuse(which)
    var w = "misuse " + String(which) + ": " + status_name(m.status) + " " + m.message
    assert_equal(status_name(m.status), status, w)
    assert_equal(m.message, message, w)
    assert_equal(m.row, Int64(-1), w)


def test_misuse(mut e: RowEngine) raises:
    assert_equal(status_name(e.misuse(MISUSE_CAPS_SMALL).status), "ERR_ABI")
    misused(e, MISUSE_SPEC_SMALL, "ERR_ABI", "spec struct_size is below this runtime's")
    var m = e.misuse(MISUSE_ERR_SMALL)
    assert_equal(status_name(m.status), "ERR_ABI")
    assert_equal(m.value, 1, "a short error struct is left unset")
    assert_equal(status_name(e.misuse(MISUSE_ERR_NULL).status), "ERR_ABI")
    for which in [MISUSE_HOST_NULL, MISUSE_HOST_SMALL, MISUSE_HOST_MAJOR]:
        misused(e, which, "ERR_ABI", "this runtime speaks ABI major 1")
    misused(e, MISUSE_INIT_AGAIN, "ERR_INTERNAL", "init runs once per process; CPython is not initialized twice here")
    for which in [MISUSE_ARGS_NULL, MISUSE_ARGS_NO_FORMAT, MISUSE_ARGS_LIST, MISUSE_ARGS_NEGATIVE]:
        misused(e, which, "ERR_UNSUPPORTED", "args is not a struct")
    for which in [
        MISUSE_FIELD_NULL, MISUSE_FIELD_NO_FORMAT, MISUSE_FIELD_EMPTY, MISUSE_FIELD_TWO_CHARS, MISUSE_FIELD_CHILD
    ]:
        misused(e, which, "ERR_UNSUPPORTED", "a read-set field's type is not int64 or float64")
    misused(
        e, MISUSE_FIELD_NO_NAME, "ERR_UNSUPPORTED",
        "the read set has a field with no name (OPTIMIZED_UDF_ROW_READ_SET_INVALID)",
    )
    misused(e, MISUSE_RESULT_NULL, "ERR_UNSUPPORTED", "the result type is not int64 or float64")
    misused(e, MISUSE_CODE, "ERR_UNSUPPORTED", "code objects are not read by this runtime (spike)")
    for which in [MISUSE_FRAME_OPEN, MISUSE_FRAME_NEXT]:
        misused(e, which, "ERR_UNSUPPORTED", "frames are not in this runtime's shapes")
        assert_equal(e.misuse(which).value, 1, "frame entry " + String(which) + ": moved and released")
    for which in [MISUSE_AGG_OPEN, MISUSE_AGG_UPDATE, MISUSE_AGG_MERGE, MISUSE_AGG_STATE, MISUSE_AGG_FINISH]:
        misused(e, which, "ERR_UNSUPPORTED", "aggregates are not in this runtime's shapes")
        assert_equal(e.misuse(which).value, 1, "aggregate entry " + String(which) + ": moved and released")
    m = e.misuse(MISUSE_LEAK)
    assert_equal(m.message, "a read-set field's type is not int64 or float64", m.message)
    assert_true(m.value < 4096, "2000 refused validates left " + String(m.value) + " heap bytes")
    assert_equal(e.misuse(MISUSE_SIGNALS).value, 1, "init left SIGINT's, SIGPIPE's and SIGXFSZ's handlers as they were")
    # Arrays already released are moved in too: nothing is called on them.
    misused(e, MISUSE_FRAME_OPEN_RELEASED, "ERR_UNSUPPORTED", "frames are not in this runtime's shapes")
    misused(e, MISUSE_AGG_UPDATE_RELEASED, "ERR_UNSUPPORTED", "aggregates are not in this runtime's shapes")


def main() raises:
    # By absolute path: the runtime finds python/ and pyrt/ beside it.
    var e = RowEngine(realpath(".") + "/python_row.so")
    assert_equal(e.status(), 0, e.message())
    test_layouts(e)
    test_cancel(e)
    test_clock(e)
    test_deadline(e)
    test_threads(e)
    test_misuse(e)
    assert_equal(e.shutdown_off_thread(), 1, "shutdown off the init thread logs once")
    assert_equal(e.last_log_level(), 2)
    print("test_row_args: ok")
