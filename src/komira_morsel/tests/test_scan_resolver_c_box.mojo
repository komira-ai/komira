# =============================================================================
# test_scan_resolver_c_box — the `void*` box an erased scan resolver crosses
# `komira.so`'s C ABI in (`komira_morsel/scan_resolver_c_box.mojo`).
#
# Plan-level, executor-free: no `EngineContext`, no query. What is under test
# is OWNERSHIP — the box moves the resolver in, the take moves it out, and the
# conformer's destructor runs exactly once across the round trip (never zero:
# a leaked store; never two: a double free) — and that the resolver that comes
# out is the one that went in, still callable through its trampolines.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow_ipc.c_data_interface import _null_ptr
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_collections.slab import Slab
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_EPOCH_NONE,
    SNAPSHOT_LIVE,
    scan_kind_id,
)
from komira_scan_source.scan_kind_registry import ScanKindDescriptor
from komira_scan_source.scan_params import ScanParams
from komira_morsel.scan_morsel_resolver import (
    ErasedScanMorselResolver,
    ScanMorselResolver,
    ScanOpened,
    ScanRequest,
)
from komira_morsel.scan_resolver_c_box import (
    SCAN_RESOLVER_C_BOX_NULL,
    scan_resolver_from_c_box,
    scan_resolver_into_c_box,
)


comptime _KIND: String = "komira.test.c_box"


struct _Tally(Movable):
    var drops: Int
    var opens: Int

    def __init__(out self):
        self.drops = 0
        self.opens = 0


def _schema() -> Schema:
    return Schema.from_fields_1(Field("x", DType.int64, True))


def _batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    return RecordBatch.from_typed_columns_1(
        _schema(), Column.from_primitive[DType.int64](arr^)
    )


struct _Stub(ScanMorselResolver, Movable, Deinitable):
    var _tally: ArcPointer[_Tally]

    def __init__(out self, tally: ArcPointer[_Tally]):
        self._tally = tally.copy()

    def __deinit__(deinit self):
        self._tally[].drops += 1

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

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        var fp = params.hash_into(UInt64(scan_kind_id(String(_KIND))))
        return ScanBinding(
            kind_id=scan_kind_id(String(_KIND)),
            kind_name=String(_KIND),
            name=String("c_box"),
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
        batches.append(_batch(4))
        return ScanOpened(ArcPointer(batches^), ScanParams())


def test_a_boxed_resolver_is_dropped_once_after_the_round_trip() raises:
    var tally = ArcPointer(_Tally())
    var box = scan_resolver_into_c_box(
        ErasedScanMorselResolver.erase(_Stub(tally))
    )
    assert_true(Int(box) != 0, "a box is a non-NULL address")
    assert_equal(tally[].drops, 0, "boxing MOVES the resolver; no drop yet")
    var back = scan_resolver_from_c_box(box)
    assert_equal(tally[].drops, 0, "taking it out MOVES it again; no drop yet")
    _ = back^
    assert_equal(tally[].drops, 1, "one resolver, one drop, after the round trip")


def test_the_resolver_out_of_the_box_is_the_one_that_went_in() raises:
    var tally = ArcPointer(_Tally())
    var back = scan_resolver_from_c_box(
        scan_resolver_into_c_box(ErasedScanMorselResolver.erase(_Stub(tally)))
    )
    assert_equal(back.kind_name(), String(_KIND))
    assert_equal(back.kind_id(), scan_kind_id(String(_KIND)))
    var b = back.build_binding(ScanParams())
    var opened = back.open_scan(ScanRequest(b^))
    assert_equal(opened.num_rows(), 4, "its open_scan still runs the stub's body")
    assert_equal(tally[].opens, 1, "through the SAME tally the stub was built on")


def test_a_null_box_is_refused_by_name() raises:
    var raised = False
    try:
        _ = scan_resolver_from_c_box(_null_ptr[NoneType, MutUntrackedOrigin]())
    except e:
        raised = True
        assert_true(
            String(SCAN_RESOLVER_C_BOX_NULL) in String(e),
            "the refusal names SCAN_RESOLVER_C_BOX_NULL",
        )
    assert_true(raised, "a NULL box raises rather than dereferencing NULL")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_boxed_resolver_is_dropped_once_after_the_round_trip]()
    suite.test[test_the_resolver_out_of_the_box_is_the_one_that_went_in]()
    suite.test[test_a_null_box_is_refused_by_name]()
    suite^.run()
