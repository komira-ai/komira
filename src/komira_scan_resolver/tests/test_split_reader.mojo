"""Split plans and split readers (`komira_scan_resolver/scan_split.mojo`,
`drain_scan.mojo`), over the erased facades.

EXECUTOR-FREE by construction: a stub kind whose splits are lists of batch
sizes in a shared in-memory store, no engine context, no plan execution. What
it pins:
  * `drain_scan` reads splits in `after` order, and plan order otherwise;
  * `drain_scan` refuses, by name and before opening anything, a split with no
    stop and a plan that may still grow; and a split that goes IDLE before its
    stop;
  * the row limit and the byte budget cut the drain between polls, and the
    drain reports where each split stopped (a cut split its last position,
    a split it never opened its start) through `resolve_drained`;
  * resume: poll k times, reopen at the position, and the rest equals the tail
    of a full read;
  * a split with no stop answers IDLE at the head, ROWS once its source grows,
    and END once it has a stop; a poll after END is refused by name;
  * a foreign or mis-versioned position is refused on the way in and out,
    including one a reader POLLS (and a refused END does not end the split);
  * each erased reader and resolver is dropped exactly once;
  * a reader facade built at another ABI is refused by name;
  * `split_read_order` refuses a duplicate key, an unknown `after` key and a
    cycle.
"""

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_EPOCH_NONE,
    SNAPSHOT_LIVE,
    scan_kind_id,
)
from komira_scan_source.scan_kind_registry import ScanKindDescriptor
from komira_scan_source.scan_params import ScanParams
from komira_scan_resolver.drain_scan import (
    drain_scan,
    split_read_order,
    SCAN_READ_MODE_UNBOUNDED_DRAIN,
    SCAN_SPLIT_PLAN_INVALID,
    SCAN_SPLIT_STALLED,
)
from komira_scan_resolver.scan_source_resolver import (
    ErasedScanSourceResolver,
    ScanRequest,
    ScanSourceResolver,
    refuse_discover_splits,
)
from komira_scan_resolver.scan_split import (
    DrainedSplit,
    ErasedSplitReader,
    ScanSplit,
    ScanSplitPlan,
    SplitDelta,
    SplitPoll,
    SplitPosition,
    SplitReader,
    SCAN_RESOLVER_ABI_MISMATCH,
    SCAN_RESOLVER_ABI_VERSION,
    SCAN_RESOLVER_FOREIGN_KIND,
    SCAN_SPLIT_POLLED_AFTER_END,
    SCAN_SPLIT_POSITION_VERSION,
)


comptime _KIND: String = "komira.test.splits"
comptime _VERSION: UInt8 = 1

# Store split indexes.
comptime _S_A = 0  # units [3, 4]
comptime _S_B = 1  # units [2]
comptime _S_TAIL = 2  # starts empty; the test appends
comptime _S_R = 3  # units [1, 2, 3, 4]

# Plan layouts.
comptime _L_AFTER = 0  # a (after b), b; complete
comptime _L_UNSTOPPED = 1  # a, tail with no stop; complete
comptime _L_INCOMPLETE = 2  # a; may still grow
comptime _L_RESUME = 3  # r
comptime _L_TAIL = 4  # tail with no stop; may still grow
comptime _L_STALLED = 5  # tail with stop 2 (the store holds 1 unit)
comptime _L_SHORT = 6  # a (after r), r with stop 4 whose reader ENDs at 2


struct _Tally(Movable):
    var kind_drops: Int
    var reader_drops: Int
    var plans: Int
    var opens: Int
    var polls: Int

    def __init__(out self):
        self.kind_drops = 0
        self.reader_drops = 0
        self.plans = 0
        self.opens = 0
        self.polls = 0


struct _Store(Movable):
    """Per split, the row count of each unit (batch), in order. `tail_stop` is
    the stop the tail split learns after it is opened (-1: none yet)."""

    var units: List[List[Int]]
    var tail_stop: Int

    def __init__(out self):
        self.units = List[List[Int]]()
        var a = List[Int]()
        a.append(3)
        a.append(4)
        self.units.append(a^)
        var b = List[Int]()
        b.append(2)
        self.units.append(b^)
        self.units.append(List[Int]())
        var r = List[Int]()
        for n in range(1, 5):
            r.append(n)
        self.units.append(r^)
        self.tail_stop = -1


def _schema() -> Schema:
    return Schema.from_fields_1(Field("x", DType.int64, True))


def _batch(rows: Int, first: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(rows):
        vals.append(Scalar[DType.int64](Int64(first + i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


def _pos(
    unit: Int, version: UInt8 = _VERSION, kind: String = String(_KIND)
) -> SplitPosition:
    var b = List[UInt8]()
    b.append(UInt8(unit))
    return SplitPosition(scan_kind_id(kind), version, b^)


def _first(batch: RecordBatch) raises -> Int:
    return Int(batch.column_value(0, 0))


struct _Reader(SplitReader, Movable, Deinitable):
    """Reads the units of one store split, one unit per poll. Unit `u` of split
    `s` holds the values `s*1000 + u*10 + i`, so a batch's first value names the
    unit it came from. Each unit costs `10 * rows` source bytes."""

    var _tally: ArcPointer[_Tally]
    var _store: ArcPointer[_Store]
    var _split: Int
    var _at: Int
    var _stop: Int
    # The encoding the positions this reader POLLS carry (a lying reader
    # writes another kind's, or another version).
    var _out_kind: String
    var _out_version: UInt8
    # A stop the READER enforces (-1: none), like a per-split byte budget: it
    # answers END there, short of the split's stop.
    var _end_at: Int

    def __init__(
        out self,
        tally: ArcPointer[_Tally],
        store: ArcPointer[_Store],
        split: Int,
        at: Int,
        stop: Int,
        var out_kind: String,
        out_version: UInt8,
        end_at: Int = -1,
    ):
        self._tally = tally.copy()
        self._store = store.copy()
        self._split = split
        self._at = at
        self._stop = stop
        self._out_kind = out_kind^
        self._out_version = out_version
        self._end_at = end_at

    def _out(self) -> SplitPosition:
        return _pos(self._at, self._out_version, self._out_kind)

    def __deinit__(deinit self):
        self._tally[].reader_drops += 1

    def poll(mut self, max_rows: Int64, max_bytes: Int64) raises -> SplitPoll:
        self._tally[].polls += 1
        var stop = self._stop
        if stop < 0:
            stop = self._store[].tail_stop
        if stop >= 0 and self._at >= stop:
            return SplitPoll.end(self._out())
        if self._end_at >= 0 and self._at >= self._end_at:
            return SplitPoll.end(self._out())
        if self._at < len(self._store[].units[self._split]):
            var rows = self._store[].units[self._split][self._at]
            var first = self._split * 1000 + self._at * 10
            self._at += 1
            return SplitPoll.rows(
                _batch(rows, first), self._out(), source_bytes=Int64(10 * rows)
            )
        return SplitPoll.idle(self._out())


struct _Kind(ScanSourceResolver, Movable, Deinitable):
    comptime Reader = _Reader

    var _tally: ArcPointer[_Tally]
    var _store: ArcPointer[_Store]
    var _layout: Int
    var _emit_version: UInt8
    var _poll_kind: String
    var _poll_version: UInt8

    def __init__(
        out self,
        tally: ArcPointer[_Tally],
        store: ArcPointer[_Store],
        layout: Int,
        emit_version: UInt8 = _VERSION,
        var poll_kind: String = String(_KIND),
        poll_version: UInt8 = _VERSION,
    ):
        self._tally = tally.copy()
        self._store = store.copy()
        self._layout = layout
        self._emit_version = emit_version
        self._poll_kind = poll_kind^
        self._poll_version = poll_version

    def __deinit__(deinit self):
        self._tally[].kind_drops += 1

    def epoch(self) -> UInt64:
        return SCAN_EPOCH_NONE

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return False

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        return UInt64(1)

    def descriptor(self) -> ScanKindDescriptor:
        return ScanKindDescriptor(
            kind_name=String(_KIND),
            gate=PushdownGate.reject_all(),
            snapshot_policy=SNAPSHOT_LIVE,
        )

    def position_version(self) -> UInt8:
        return _VERSION

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        var id = scan_kind_id(String(_KIND))
        var fp = params.hash_into(UInt64(id))
        return ScanBinding(
            kind_id=id,
            kind_name=String(_KIND),
            name=String("t"),
            params=params.copy(),
            schema=_schema(),
            fingerprint=fp,
            structural_id=fp,
            gate=PushdownGate.reject_all(),
            snapshot_policy=SNAPSHOT_LIVE,
        )

    def _split(self, key: String, stop: Int, var after: List[String] = List[String]()) -> ScanSplit:
        var s: Optional[SplitPosition] = None
        if stop >= 0:
            s = Optional(_pos(stop, self._emit_version))
        return ScanSplit(key, _pos(0, self._emit_version), s^, after^)

    def plan_splits(self, req: ScanRequest) raises -> ScanSplitPlan:
        self._tally[].plans += 1
        var splits = List[ScanSplit]()
        var complete = True
        if self._layout == _L_AFTER:
            var after = List[String]()
            after.append(String("b"))
            splits.append(self._split(String("a"), 2, after^))
            splits.append(self._split(String("b"), 1))
        elif self._layout == _L_UNSTOPPED:
            splits.append(self._split(String("a"), 2))
            splits.append(self._split(String("tail"), -1))
        elif self._layout == _L_INCOMPLETE:
            splits.append(self._split(String("a"), 2))
            complete = False
        elif self._layout == _L_RESUME:
            splits.append(self._split(String("r"), 4))
        elif self._layout == _L_TAIL:
            splits.append(self._split(String("tail"), -1))
            complete = False
        elif self._layout == _L_SHORT:
            var after = List[String]()
            after.append(String("r"))
            splits.append(self._split(String("a"), 2, after^))
            splits.append(self._split(String("r"), 4))
        else:
            splits.append(self._split(String("tail"), 2))
        var resolved = ScanParams()
        resolved.put_str(String("layout"), String(self._layout))
        return ScanSplitPlan(splits^, complete, resolved^)

    def discover_splits(
        self, req: ScanRequest, known: List[String]
    ) raises -> SplitDelta:
        return refuse_discover_splits(String(_KIND))

    def open_split(self, req: ScanRequest, split: ScanSplit) raises -> _Reader:
        self._tally[].opens += 1
        var idx = _S_TAIL
        if split.split_key == String("a"):
            idx = _S_A
        elif split.split_key == String("b"):
            idx = _S_B
        elif split.split_key == String("r"):
            idx = _S_R
        var stop = -1
        if split.stop:
            stop = Int(split.stop.value().bytes[0])
        var end_at = -1
        if self._layout == _L_SHORT and split.split_key == String("r"):
            end_at = 2
        return _Reader(
            self._tally,
            self._store,
            idx,
            Int(split.start.bytes[0]),
            stop,
            String(self._poll_kind),
            self._poll_version,
            end_at,
        )

    def resolve_drained(
        self,
        req: ScanRequest,
        var resolved: ScanParams,
        stopped: List[DrainedSplit],
    ) raises -> ScanParams:
        """Like a log's per-partition next offset: `at.<key>` is the unit the
        drain stopped at in each split, `cut.<key>` whether it stopped short."""
        for i in range(len(stopped)):
            resolved.put_i64(
                String("at.") + stopped[i].split_key,
                Int64(stopped[i].position.bytes[0]),
            )
            resolved.put_bool(String("cut.") + stopped[i].split_key, stopped[i].cut)
        return resolved^


def _erased(
    tally: ArcPointer[_Tally],
    store: ArcPointer[_Store],
    layout: Int,
    emit_version: UInt8 = _VERSION,
    poll_kind: String = String(_KIND),
    poll_version: UInt8 = _VERSION,
) -> ErasedScanSourceResolver:
    return ErasedScanSourceResolver(
        _Kind(tally, store, layout, emit_version, String(poll_kind), poll_version)
    )


def _request(r: ErasedScanSourceResolver, limit: Int64 = -1) raises -> ScanRequest:
    return ScanRequest(r.build_binding(ScanParams()), limit=limit)


def _assert_raises_named(msg: String, token: String, label: String) raises:
    assert_true(token in msg, label + String(": ") + msg)


# ---- drain ------------------------------------------------------------------


def test_the_drain_reads_splits_in_after_order() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_AFTER)
    var opened = drain_scan(r, _request(r))
    # b (planned second) must END before a, which reads after it.
    assert_equal(opened.num_batches(), 3)
    assert_equal(_first(opened.batches[][0]), _S_B * 1000)
    assert_equal(_first(opened.batches[][1]), _S_A * 1000)
    assert_equal(_first(opened.batches[][2]), _S_A * 1000 + 10)
    assert_equal(opened.num_rows(), 9)
    assert_equal(opened.resolved.get_str(String("layout")), String(_L_AFTER))
    assert_equal(tally[].plans, 1, "ONE plan per drain")
    assert_equal(tally[].opens, 2)
    assert_equal(tally[].reader_drops, 2, "each reader dropped once")


def test_the_drain_refuses_a_split_with_no_stop_by_name() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_UNSTOPPED)
    var raised = False
    try:
        _ = drain_scan(r, _request(r))
    except e:
        raised = True
        var msg = String(e)
        _assert_raises_named(msg, String(SCAN_READ_MODE_UNBOUNDED_DRAIN), "unstopped")
        _assert_raises_named(msg, String("'tail'"), "names the split")
    assert_true(raised, "a split with no stop cannot be drained")
    assert_equal(tally[].opens, 0, "refused before ANY split is opened")


def test_the_drain_refuses_a_plan_that_may_still_grow() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_INCOMPLETE)
    var raised = False
    try:
        _ = drain_scan(r, _request(r))
    except e:
        raised = True
        _assert_raises_named(
            String(e), String(SCAN_READ_MODE_UNBOUNDED_DRAIN), "incomplete"
        )
    assert_true(raised, "an incomplete plan cannot be drained")
    assert_equal(tally[].opens, 0)


def test_the_drain_refuses_a_split_that_stalls_before_its_stop() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    store[].units[_S_TAIL].append(5)
    var r = _erased(tally, store, _L_STALLED)
    var raised = False
    try:
        _ = drain_scan(r, _request(r))
    except e:
        raised = True
        _assert_raises_named(String(e), String(SCAN_SPLIT_STALLED), "stalled")
    assert_true(raised, "a split that is IDLE before its stop stalls the drain")
    assert_equal(tally[].reader_drops, 1, "the stalled reader is still dropped")


def test_the_row_limit_and_the_byte_budget_cut_between_polls() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_AFTER)
    # Limit 3: b's 2 rows, then a's first unit (3 rows, returned whole).
    var by_rows = drain_scan(r, _request(r, limit=3))
    assert_equal(by_rows.num_batches(), 2)
    assert_equal(by_rows.num_rows(), 5)
    # Budget 25 bytes: b costs 20, a's first unit 30 (whole); then cut.
    var by_bytes = drain_scan(r, _request(r), max_bytes=25)
    assert_equal(by_bytes.num_batches(), 2)
    assert_equal(by_bytes.num_rows(), 5)
    # No bound: everything.
    var everything = drain_scan(r, _request(r))
    assert_equal(everything.num_rows(), 9)


def _assert_stopped(
    opened_resolved: ScanParams, key: String, at: Int, cut: Bool, label: String
) raises:
    assert_equal(
        opened_resolved.get_i64(String("at.") + key),
        Int64(at),
        label + String(": where '") + key + String("' stopped"),
    )
    assert_equal(
        opened_resolved.get_bool(String("cut.") + key),
        cut,
        label + String(": whether '") + key + String("' was cut"),
    )


def test_the_drain_reports_where_each_split_stopped() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_AFTER)
    # Row cut, mid-split: b (2 rows) reads to its stop; a's first unit (3
    # rows) passes limit 3, so a stops at unit 1 of its 2, cut.
    var by_rows = drain_scan(r, _request(r, limit=3))
    _assert_stopped(by_rows.resolved, String("b"), 1, False, "row cut")
    _assert_stopped(by_rows.resolved, String("a"), 1, True, "row cut")
    assert_equal(
        by_rows.resolved.get_str(String("layout")),
        String(_L_AFTER),
        "the plan's own keys survive",
    )
    # Byte cut before a split is opened: b costs 20 of a 15-byte budget, so a
    # is never opened and reports its start.
    var opens_before = tally[].opens
    var by_bytes = drain_scan(r, _request(r), max_bytes=15)
    assert_equal(tally[].opens - opens_before, 1, "a is never opened")
    assert_equal(by_bytes.num_rows(), 2)
    _assert_stopped(by_bytes.resolved, String("b"), 1, False, "byte cut")
    _assert_stopped(by_bytes.resolved, String("a"), 0, True, "byte cut")
    # No bound: every split at its stop, none cut.
    var everything = drain_scan(r, _request(r))
    _assert_stopped(everything.resolved, String("b"), 1, False, "no cut")
    _assert_stopped(everything.resolved, String("a"), 2, False, "no cut")


def test_a_reader_end_short_of_the_stop_is_a_cut() raises:
    """END short of the split's stop (a stop the reader enforces, such as a
    per-split byte budget) is a cut: the split reports where its rest starts,
    and a split that reads after it is not opened."""
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_SHORT)
    var opened = drain_scan(r, _request(r))
    # r's units 0 and 1 (1 + 2 rows), then END at unit 2 of its 4.
    assert_equal(opened.num_rows(), 3)
    _assert_stopped(opened.resolved, String("r"), 2, True, "reader stop")
    assert_equal(tally[].opens, 1, "a, after a cut r, is never opened")
    _assert_stopped(opened.resolved, String("a"), 0, True, "after a cut")


# ---- resume, follow, positions ------------------------------------------------


def _read_to_end(mut reader: ErasedSplitReader) raises -> List[Int]:
    """The first value of every batch the reader returns, until END."""
    var firsts = List[Int]()
    while True:
        var p = reader.poll(-1, -1)
        if p.batch:
            firsts.append(_first(p.batch.value()))
        if p.is_end():
            break
        assert_false(p.is_idle(), "a bounded split never idles here")
    return firsts^


def test_a_resumed_split_reads_exactly_the_tail_of_a_full_read() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_RESUME)
    var req = _request(r)
    var plan = r.plan_splits(req)
    var full_reader = r.open_split(req, plan.splits[0])
    var full = _read_to_end(full_reader)
    assert_equal(len(full), 4)
    var k = 2
    var reader = r.open_split(req, plan.splits[0])
    var at = plan.splits[0].start.copy()
    for _ in range(k):
        var p = reader.poll(-1, -1)
        assert_true(p.is_rows())
        at = p.position.copy()
    _ = reader^
    var resumed_reader = r.open_split(req, plan.splits[0].resumed_at(at^))
    var rest = _read_to_end(resumed_reader)
    assert_equal(len(rest), len(full) - k)
    for i in range(len(rest)):
        assert_equal(rest[i], full[k + i], "the remainder is the tail")


def test_a_split_with_no_stop_goes_idle_then_rows_then_end() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_TAIL)
    var req = _request(r)
    var plan = r.plan_splits(req)
    assert_false(plan.complete)
    assert_false(plan.splits[0].is_bounded())
    var reader = r.open_split(req, plan.splits[0])
    var p0 = reader.poll(-1, -1)
    assert_true(p0.is_idle(), "nothing at the head yet")
    assert_true(p0.position == _pos(0), "IDLE does not move the position")
    store[].units[_S_TAIL].append(5)
    var p1 = reader.poll(-1, -1)
    assert_true(p1.is_rows(), "the source grew")
    assert_equal(p1.num_rows(), 5)
    assert_true(p1.position == _pos(1))
    assert_true(reader.poll(-1, -1).is_idle(), "caught up again")
    store[].tail_stop = 1
    assert_true(reader.poll(-1, -1).is_end(), "END once it has a stop")
    var raised = False
    try:
        _ = reader.poll(-1, -1)
    except e:
        raised = True
        _assert_raises_named(String(e), String(SCAN_SPLIT_POLLED_AFTER_END), "after END")
        _assert_raises_named(String(e), String("'tail'"), "names the split")
    assert_true(raised, "END is final")


def test_a_foreign_or_misversioned_position_is_refused() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_RESUME)
    var req = _request(r)
    var plan = r.plan_splits(req)
    # In: a start encoded by another kind.
    var foreign = SplitPosition(scan_kind_id(String("komira.test.other")), _VERSION, List[UInt8]())
    var raised_foreign = False
    try:
        _ = r.open_split(req, plan.splits[0].resumed_at(foreign^))
    except e:
        raised_foreign = True
        _assert_raises_named(String(e), String(SCAN_RESOLVER_FOREIGN_KIND), "foreign")
    assert_true(raised_foreign, "a foreign position must be refused")
    # In: a start at another encoding version (an old checkpoint).
    var raised_version = False
    try:
        _ = r.open_split(req, plan.splits[0].resumed_at(_pos(1, version=9)))
    except e:
        raised_version = True
        var msg = String(e)
        _assert_raises_named(msg, String(SCAN_SPLIT_POSITION_VERSION), "version")
        _assert_raises_named(msg, String("version 9"), "names the version")
    assert_true(raised_version, "a mis-versioned position must be refused")
    assert_equal(tally[].opens, 0, "the kind was never reached")
    # Out: a kind that plans positions at a version it does not read.
    var liar = _erased(tally, store, _L_RESUME, emit_version=2)
    var raised_out = False
    try:
        _ = liar.plan_splits(_request(liar))
    except e:
        raised_out = True
        _assert_raises_named(String(e), String(SCAN_SPLIT_POSITION_VERSION), "out")
    assert_true(raised_out, "a plan carrying a foreign version must not escape")


def _refuse_polls(mut reader: ErasedSplitReader, token: String, label: String) raises:
    var raised = False
    try:
        _ = reader.poll(-1, -1)
    except e:
        raised = True
        var msg = String(e)
        _assert_raises_named(msg, token, label)
        _assert_raises_named(msg, String("polled 'r'"), label + String(": names it"))
    assert_true(raised, label + String(": the polled position must not escape"))


def _check_polled_refusal(r: ErasedScanSourceResolver, token: String) raises:
    var req = _request(r)
    var plan = r.plan_splits(req)
    # A ROWS poll.
    var reader = r.open_split(req, plan.splits[0])
    _refuse_polls(reader, token, token + String(" ROWS"))
    # An END poll (opened at its stop), refused twice: a refused END does not
    # end the split, so the second poll is refused for the position again and
    # NOT as a poll after END.
    var at_stop = r.open_split(req, plan.splits[0].resumed_at(_pos(4)))
    _refuse_polls(at_stop, token, token + String(" END"))
    _refuse_polls(at_stop, token, token + String(" END again"))


def test_a_polled_foreign_or_misversioned_position_is_refused() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var foreign = _erased(
        tally, store, _L_RESUME, poll_kind=String("komira.test.other")
    )
    _check_polled_refusal(foreign, String(SCAN_RESOLVER_FOREIGN_KIND))
    var misversioned = _erased(tally, store, _L_RESUME, poll_version=7)
    _check_polled_refusal(misversioned, String(SCAN_SPLIT_POSITION_VERSION))


# ---- ownership and ABI ----------------------------------------------------------


def test_each_erased_box_is_dropped_exactly_once() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_AFTER)
    var req = _request(r)
    var plan = r.plan_splits(req)
    var a = r.open_split(req, plan.splits[0])
    var b = r.open_split(req, plan.splits[1])
    assert_equal(a.split_key(), String("a"))
    assert_equal(tally[].reader_drops, 0, "opening moves; nothing dropped")
    _ = a^
    assert_equal(tally[].reader_drops, 1)
    _ = b^
    assert_equal(tally[].reader_drops, 2, "each reader dropped exactly once")
    assert_equal(tally[].kind_drops, 0)
    _ = r^
    assert_equal(tally[].kind_drops, 1, "the resolver dropped exactly once")
    assert_equal(tally[].reader_drops, 2, "and no reader dropped twice")


def test_a_reader_facade_at_another_abi_is_refused_by_name() raises:
    var tally = ArcPointer(_Tally())
    var store = ArcPointer(_Store())
    var r = _erased(tally, store, _L_RESUME)
    var req = _request(r)
    var plan = r.plan_splits(req)
    var reader = r.open_split(req, plan.splits[0])
    assert_equal(reader.abi_version(), SCAN_RESOLVER_ABI_VERSION)
    reader.require_abi(SCAN_RESOLVER_ABI_VERSION)
    var raised = False
    try:
        reader.require_abi(SCAN_RESOLVER_ABI_VERSION + 1)
    except e:
        raised = True
        _assert_raises_named(String(e), String(SCAN_RESOLVER_ABI_MISMATCH), "abi")
    assert_true(raised, "a host at another ABI must refuse the reader")


# ---- split_read_order -----------------------------------------------------------


def _bare(key: String, var after: List[String] = List[String]()) -> ScanSplit:
    return ScanSplit(key, _pos(0), Optional(_pos(1)), after^)


def test_split_read_order_refuses_a_bad_plan_by_name() raises:
    var dup = List[ScanSplit]()
    dup.append(_bare(String("x")))
    dup.append(_bare(String("x")))
    var unknown = List[ScanSplit]()
    var u_after = List[String]()
    u_after.append(String("nope"))
    unknown.append(_bare(String("x"), u_after^))
    var cycle = List[ScanSplit]()
    var x_after = List[String]()
    x_after.append(String("y"))
    var y_after = List[String]()
    y_after.append(String("x"))
    cycle.append(_bare(String("x"), x_after^))
    cycle.append(_bare(String("y"), y_after^))
    var bad = List[List[ScanSplit]]()
    bad.append(dup^)
    bad.append(unknown^)
    bad.append(cycle^)
    var names = List[String]()
    names.append(String("share the key 'x'"))
    names.append(String("'nope'"))
    names.append(String("cycle"))
    for i in range(len(bad)):
        var raised = False
        try:
            _ = split_read_order(bad[i])
        except e:
            raised = True
            _assert_raises_named(String(e), String(SCAN_SPLIT_PLAN_INVALID), names[i])
            _assert_raises_named(String(e), names[i], names[i])
        assert_true(raised, names[i])
    # And a valid plan keeps plan order where `after` does not decide.
    var ok = List[ScanSplit]()
    var c_after = List[String]()
    c_after.append(String("d"))
    ok.append(_bare(String("c"), c_after^))
    ok.append(_bare(String("e")))
    ok.append(_bare(String("d")))
    var order = split_read_order(ok)
    assert_equal(order[0], 1, "e is ready first in plan order")
    assert_equal(order[1], 2, "then d")
    assert_equal(order[2], 0, "then c, after d")


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_drain_reads_splits_in_after_order]()
    suite.test[test_the_drain_refuses_a_split_with_no_stop_by_name]()
    suite.test[test_the_drain_refuses_a_plan_that_may_still_grow]()
    suite.test[test_the_drain_refuses_a_split_that_stalls_before_its_stop]()
    suite.test[test_the_row_limit_and_the_byte_budget_cut_between_polls]()
    suite.test[test_the_drain_reports_where_each_split_stopped]()
    suite.test[test_a_reader_end_short_of_the_stop_is_a_cut]()
    suite.test[test_a_resumed_split_reads_exactly_the_tail_of_a_full_read]()
    suite.test[test_a_split_with_no_stop_goes_idle_then_rows_then_end]()
    suite.test[test_a_foreign_or_misversioned_position_is_refused]()
    suite.test[test_a_polled_foreign_or_misversioned_position_is_refused]()
    suite.test[test_each_erased_box_is_dropped_exactly_once]()
    suite.test[test_a_reader_facade_at_another_abi_is_refused_by_name]()
    suite.test[test_split_read_order_refuses_a_bad_plan_by_name]()
    suite^.run()
