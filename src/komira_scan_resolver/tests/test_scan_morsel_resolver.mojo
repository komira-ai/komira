"""Tier-2 `ScanMorselResolver`: the erased facade and the per-context resolver
set (`komira_scan_resolver/scan_morsel_resolver.mojo`).

EXECUTOR-FREE by construction: a stub kind, a hand-built batch, no engine
context, no plan execution. What it pins:
  * erasing a conformer and dropping the facade runs the conformer's
    destructor EXACTLY ONCE (the drop trampoline is the single owner);
  * the resolver set refuses a second resolver for a kind, and `get` of a kind
    nothing serves raises `SCAN_KIND_NOT_EXECUTABLE` naming what is registered;
  * the facade refuses a FOREIGN kind's binding on resolve and on open, and a
    foreign binding a kind BUILDS;
  * `build_binding` refuses a params map missing a required key, by name;
  * the `resolved` side channel round-trips through the erased `open_scan`.
"""

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.slab import Slab
from komira_core.source.pushdown_gate import PushdownGate
from komira_core.source.scan_binding import (
    ScanBinding,
    SCAN_EPOCH_NONE,
    SNAPSHOT_LIVE,
    scan_kind_id,
)
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import resolve_for_execution
from komira_scan_resolver.scan_morsel_resolver import (
    ErasedScanMorselResolver,
    ScanMorselResolver,
    ScanMorselResolvers,
    ScanOpened,
    ScanRequest,
    SCAN_BINDING_MISSING_PARAMS,
    SCAN_KIND_ALREADY_REGISTERED,
    SCAN_KIND_NOT_EXECUTABLE,
    SCAN_REQUEST_NO_LIMIT,
    SCAN_RESOLVER_FOREIGN_KIND,
)


comptime _KIND_A: String = "komira.test.stub_a"
comptime _KIND_B: String = "komira.test.stub_b"


struct _Tally(Movable):
    """Shared counters, reached through an `ArcPointer` from `read self` — the
    interior-mutability shape a real kind uses for its store."""

    var drops: Int
    var resolves: Int
    var opens: Int

    def __init__(out self):
        self.drops = 0
        self.resolves = 0
        self.opens = 0


def _schema() -> Schema:
    return Schema.from_fields_1(Field("x", DType.int64, True))


def _batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


struct _StubKind(ScanMorselResolver, Movable, Deinitable):
    """A LIVE kind whose snapshot token advances on every resolve, and whose
    `open_scan` reports the token it was handed in the side channel."""

    var _tally: ArcPointer[_Tally]
    var _kind_name: String
    var _build_foreign: Bool

    def __init__(
        out self,
        tally: ArcPointer[_Tally],
        var kind_name: String,
        build_foreign: Bool = False,
    ):
        self._tally = tally.copy()
        self._kind_name = kind_name^
        self._build_foreign = build_foreign

    def __deinit__(deinit self):
        self._tally[].drops += 1

    def epoch(self) -> UInt64:
        return SCAN_EPOCH_NONE

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return False

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        self._tally[].resolves += 1
        return UInt64(100 + self._tally[].resolves)

    def descriptor(self) -> ScanKindDescriptor:
        var req = List[String]()
        req.append(String("topic"))
        return ScanKindDescriptor(
            kind_name=String(self._kind_name),
            gate=PushdownGate.reject_all(),
            snapshot_policy=SNAPSHOT_LIVE,
            required_params=req^,
        )

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        var name = String(self._kind_name)
        if self._build_foreign:
            name = String(_KIND_B)
        var fp = params.hash_into(UInt64(scan_kind_id(name)))
        return ScanBinding(
            kind_id=scan_kind_id(name),
            kind_name=String(name),
            name=params.get_str(String("topic")),
            params=params.copy(),
            schema=_schema(),
            fingerprint=fp,
            structural_id=fp,
            gate=PushdownGate.reject_all(),
            snapshot_policy=SNAPSHOT_LIVE,
        )

    def open_scan(self, req: ScanRequest) raises -> ScanOpened:
        self._tally[].opens += 1
        var batches = Slab[RecordBatch]()
        batches.append(_batch(3))
        batches.append(_batch(2))
        var resolved = ScanParams()
        resolved.put_u64(String("high_watermark"), req.binding.snapshot_token)
        resolved.put_i64(String("log_start_offset"), Int64(7))
        resolved.put_bool(String("aborted"), False)
        return ScanOpened(ArcPointer(batches^), resolved^)


def _params(topic: String) -> ScanParams:
    var p = ScanParams()
    p.put_str(String("topic"), String(topic))
    return p^


def test_erase_then_drop_runs_the_destructor_exactly_once() raises:
    var tally = ArcPointer(_Tally())
    var erased = ErasedScanMorselResolver.erase(
        _StubKind(tally, String(_KIND_A))
    )
    assert_equal(tally[].drops, 0, "erasing MOVES the conformer; no drop yet")
    assert_equal(erased.kind_name(), String(_KIND_A))
    assert_equal(erased.kind_id(), scan_kind_id(String(_KIND_A)))
    _ = erased^
    assert_equal(tally[].drops, 1, "one facade drop = one conformer drop")


def test_the_resolver_set_drops_each_member_once() raises:
    var tally = ArcPointer(_Tally())
    var set = ScanMorselResolvers()
    set.register(
        ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
    )
    set.register(
        ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_B)))
    )
    assert_equal(set.num_kinds(), 2)
    assert_equal(tally[].drops, 0, "registering moves; nothing dropped")
    _ = set^
    assert_equal(tally[].drops, 2, "each member dropped exactly once")


def test_a_second_resolver_for_a_kind_is_refused_by_name() raises:
    var tally = ArcPointer(_Tally())
    var set = ScanMorselResolvers()
    set.register(
        ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
    )
    var raised = False
    try:
        set.register(
            ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
        )
    except e:
        raised = True
        var msg = String(e)
        assert_true(String(SCAN_KIND_ALREADY_REGISTERED) in msg, msg)
        assert_true(String(_KIND_A) in msg, msg)
    assert_true(raised, "a duplicate kind_id must be refused")
    # The refused one was dropped on the raise path; the first is still held.
    # (`set` is used AFTER this assertion on purpose: Mojo destroys a value at
    # its last use, so asserting after the last use would count its drop too.)
    assert_equal(tally[].drops, 1)
    assert_equal(set.num_kinds(), 1, "the refused resolver is not added")
    _ = set^
    assert_equal(tally[].drops, 2, "and the held one drops exactly once")


def test_an_unregistered_kind_is_not_executable_by_name() raises:
    var tally = ArcPointer(_Tally())
    var set = ScanMorselResolvers()
    set.register(
        ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
    )
    assert_true(set.contains(scan_kind_id(String(_KIND_A))))
    assert_false(set.contains(scan_kind_id(String(_KIND_B))))
    var raised = False
    try:
        _ = set.get(scan_kind_id(String(_KIND_B))).kind_name()
    except e:
        raised = True
        var msg = String(e)
        assert_true(String(SCAN_KIND_NOT_EXECUTABLE) in msg, msg)
        assert_true(String(_KIND_A) in msg, "names what IS registered: " + msg)
    assert_true(raised, "get of an unregistered kind must raise")
    # And an empty set says so rather than printing an empty list.
    var empty = ScanMorselResolvers()
    assert_true("none registered" in empty.render_kinds())


def test_a_foreign_binding_is_refused_on_resolve_and_open() raises:
    var tally = ArcPointer(_Tally())
    var a = ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
    var b = ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_B)))
    var b_binding = b.build_binding(_params(String("orders")))
    var raised_resolve = False
    try:
        _ = a.resolve_snapshot(b_binding)
    except e:
        raised_resolve = True
        assert_true(String(SCAN_RESOLVER_FOREIGN_KIND) in String(e), String(e))
    assert_true(raised_resolve, "resolving a foreign kind must raise")
    var raised_open = False
    try:
        _ = a.open_scan(ScanRequest(b_binding.copy()))
    except e:
        raised_open = True
        assert_true(String(SCAN_RESOLVER_FOREIGN_KIND) in String(e), String(e))
    assert_true(raised_open, "opening a foreign kind must raise")
    assert_equal(tally[].resolves, 0, "the kind was never reached")
    assert_equal(tally[].opens, 0, "the kind was never reached")
    assert_false(a.is_bound(b_binding.kind_id, 0))


def test_a_kind_that_builds_a_foreign_binding_is_refused() raises:
    var tally = ArcPointer(_Tally())
    var liar = ErasedScanMorselResolver.erase(
        _StubKind(tally, String(_KIND_A), build_foreign=True)
    )
    var raised = False
    try:
        _ = liar.build_binding(_params(String("orders")))
    except e:
        raised = True
        assert_true(String(SCAN_RESOLVER_FOREIGN_KIND) in String(e), String(e))
    assert_true(raised, "a binding for another kind must not escape")


def test_a_missing_required_param_is_refused_before_the_kind_runs() raises:
    var tally = ArcPointer(_Tally())
    var a = ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
    var p = ScanParams()
    p.put_str(String("topik"), String("orders"))
    var raised = False
    try:
        _ = a.build_binding(p)
    except e:
        raised = True
        var msg = String(e)
        assert_true(String(SCAN_BINDING_MISSING_PARAMS) in msg, msg)
        assert_true("topic" in msg, "names the missing key: " + msg)
    assert_true(raised, "a params typo must be a build-time error")


def test_the_resolved_side_channel_round_trips() raises:
    var tally = ArcPointer(_Tally())
    var set = ScanMorselResolvers()
    set.register(
        ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
    )
    ref r = set.get(scan_kind_id(String(_KIND_A)))
    var cached = r.build_binding(_params(String("orders")))
    assert_equal(cached.snapshot_token, UInt64(0), "a LIVE binding carries 0")
    # The per-execution binding, through core's tier-1 entry point.
    var exec_binding = resolve_for_execution(r, cached)
    assert_equal(exec_binding.snapshot_token, UInt64(101))
    assert_equal(cached.snapshot_token, UInt64(0), "resolution returns a copy")
    var opened = r.open_scan(ScanRequest(exec_binding^))
    assert_equal(opened.num_batches(), 2)
    assert_equal(opened.num_rows(), 5)
    assert_equal(
        opened.resolved.get_u64(String("high_watermark")),
        UInt64(101),
        "the kind reports the snapshot it was handed",
    )
    assert_equal(opened.resolved.get_i64(String("log_start_offset")), Int64(7))
    assert_false(opened.resolved.get_bool(String("aborted"), True))
    assert_equal(tally[].resolves, 1)
    assert_equal(tally[].opens, 1)


def test_a_request_copy_is_deep_and_the_default_has_no_limit() raises:
    var tally = ArcPointer(_Tally())
    var a = ErasedScanMorselResolver.erase(_StubKind(tally, String(_KIND_A)))
    var proj = List[String]()
    proj.append(String("x"))
    var req = ScanRequest(
        a.build_binding(_params(String("orders"))), Optional(proj^)
    )
    assert_false(req.has_limit())
    assert_equal(req.limit, SCAN_REQUEST_NO_LIMIT)
    var c = req.copy()
    assert_true(Bool(c.projection))
    assert_equal(c.projection.value()[0], String("x"))
    assert_equal(c.binding.kind_id, req.binding.kind_id)
    assert_false(Bool(c.predicate))


def main() raises:
    var suite = TestSuite()
    suite.test[test_erase_then_drop_runs_the_destructor_exactly_once]()
    suite.test[test_the_resolver_set_drops_each_member_once]()
    suite.test[test_a_second_resolver_for_a_kind_is_refused_by_name]()
    suite.test[test_an_unregistered_kind_is_not_executable_by_name]()
    suite.test[test_a_foreign_binding_is_refused_on_resolve_and_open]()
    suite.test[test_a_kind_that_builds_a_foreign_binding_is_refused]()
    suite.test[test_a_missing_required_param_is_refused_before_the_kind_runs]()
    suite.test[test_the_resolved_side_channel_round_trips]()
    suite.test[test_a_request_copy_is_deep_and_the_default_has_no_limit]()
    suite^.run()
