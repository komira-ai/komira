# The bloom latch (`komira_op_join_build.join_bloom_selectivity`) through the
# parallel composite probe: it disarms a bloom that admits every probe row,
# keeps one that rejects every row, never changes the answer, and is never
# reached when off; under both the batched and the row-at-a-time walk.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_join_build.join_bloom_selectivity import (
    bloomsel_configure,
    bloomsel_disarmed_count,
    bloomsel_kept_count,
    bloomsel_reset_config,
    bloomsel_saved_checks,
    reset_bloomsel_counters,
)
from komira_op_join_probe.join_multi_key import MultiKeyColumns
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_parallel import (
    parallel_multi_key_inner_probe_into,
)
from komira_op_join_probe.join_probe_settings import (
    mk_probe_configure,
    reset_join_probe_settings,
)


comptime I64 = DType.int64
comptime _ENC: Int = 1_000_000


def _clear_settings() raises:
    bloomsel_reset_config()
    reset_join_probe_settings()


def _i64_arr(imm values: List[Int64]) -> PrimitiveArray[I64]:
    var arr = PrimitiveArray[I64].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return arr^


def _mk_columns(imm cols: List[List[Int64]]) raises -> MultiKeyColumns:
    var n_keys = len(cols)
    var ik = Slab[PrimitiveArray[I64]].create(n_keys)
    var sk = Slab[Optional[StringArray[HeapRegion]]].create(n_keys)
    var dk = Slab[Optional[StringDictionaryArray]].create(n_keys)
    var fps = List[UInt64]()
    for k in range(n_keys):
        ik.append(_i64_arr(cols[k]))
        sk.append(Optional[StringArray[HeapRegion]](None))
        dk.append(Optional[StringDictionaryArray](None))
        fps.append(UInt64(0))
    return MultiKeyColumns(ik^, sk^, dk^, fps^, n_keys)


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v^


def _encode(var bm: List[Int], var pm: List[Int]) -> List[Int]:
    var enc = List[Int]()
    for i in range(len(bm)):
        enc.append((bm[i] + 1) * _ENC + (pm[i] + 1))
    return _sorted(enc^)


def _assert_lists_equal(
    imm a: List[Int], imm b: List[Int], msg: String
) raises:
    assert_equal(len(a), len(b), msg + " length")
    for i in range(len(a)):
        assert_equal(a[i], b[i], msg + " [" + String(i) + "]")


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _fixture() -> Tuple[List[List[Int64]], List[List[Int64]]]:
    """A build side that covers the WHOLE probe key domain, so the bloom admits
    every probe row and the latch must disarm. 600 probe rows over 20 keys.
    """
    var bk = List[Int64]()
    for i in range(20):
        bk.append(Int64(i))
        bk.append(Int64(i))
    var build = List[List[Int64]]()
    build.append(bk^)

    var pk = List[Int64]()
    for i in range(600):
        pk.append(Int64(i % 20))
    var probe = List[List[Int64]]()
    probe.append(pk^)
    return (build^, probe^)


def _disjoint_probe() -> List[List[Int64]] :
    """Probe keys DISJOINT from the build's [0,20) domain, so the bloom rejects
    (nearly) everything and the latch must KEEP it.
    """
    var pk = List[Int64]()
    for i in range(600):
        pk.append(Int64(1_000_000 + i))
    var probe = List[List[Int64]]()
    probe.append(pk^)
    return probe^


def _probe_pairs(
    mut dispatcher_owner: PerCoreAsyncRuntime[NoopSink],
    imm builder: MultiKeyHashJoinBuilder,
    imm probe: List[List[Int64]],
) raises -> List[Int]:
    ref dispatcher = dispatcher_owner.dispatcher()
    var pkc = _mk_columns(probe)
    var bm = List[Int]()
    var pm = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, pkc, bm, pm
    )
    _ = pkc^
    return _encode(bm^, pm^)


def test_disarm_is_value_invariant_and_actually_arms() raises:
    """With the latch on (16 rows, 25%), a probe the bloom admits entirely
    disarms it and skips checks, with the same answer as the latch off; a probe
    the bloom rejects entirely keeps it. Both walks."""
    reset_join_probe_settings()
    bloomsel_reset_config()
    var fx = _fixture()
    ref build = fx[0]
    ref probe = fx[1]
    var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))

    var batch_widths = List[Int]()
    batch_widths.append(0)
    batch_widths.append(64)

    for wi in range(len(batch_widths)):
        var w = batch_widths[wi]
        var tag = String("batch=") + String(w) + " "

        _clear_settings()
        mk_probe_configure(batch_width=w)
        bloomsel_configure(0)
        reset_bloomsel_counters()
        var rt_off = _runtime()
        var off = _probe_pairs(rt_off, builder, probe)
        assert_equal(
            bloomsel_disarmed_count() + bloomsel_kept_count(),
            0,
            tag + "OFF arm must never reach the latch",
        )
        assert_equal(
            bloomsel_saved_checks(),
            0,
            tag + "OFF arm must skip no bloom check",
        )

        bloomsel_configure(16, 25)
        reset_bloomsel_counters()
        var rt_on = _runtime()
        var on = _probe_pairs(rt_on, builder, probe)

        assert_true(
            bloomsel_disarmed_count() > 0,
            tag + "the latch must have DISARMED at least one worker — this"
            " fixture's build side covers the whole probe key domain",
        )
        assert_equal(
            bloomsel_kept_count(),
            0,
            tag + "no worker should have KEPT the bloom on a 100%-pass fixture",
        )
        assert_true(
            bloomsel_saved_checks() > 0,
            tag + "the disarmed workers must have SKIPPED bloom checks",
        )
        _assert_lists_equal(on, off, tag + "disarming must not change the answer")
        _ = rt_off^
        _ = rt_on^

    _clear_settings()
    mk_probe_configure(batch_width=64)
    bloomsel_configure(16, 25)
    reset_bloomsel_counters()
    var rt_keep = _runtime()
    var miss = _disjoint_probe()
    var kept_pairs = _probe_pairs(rt_keep, builder, miss)
    assert_equal(len(kept_pairs), 0, "disjoint probe must join nothing")
    assert_true(
        bloomsel_kept_count() > 0,
        "a bloom that rejects everything must be KEPT, not disarmed",
    )
    assert_equal(
        bloomsel_disarmed_count(),
        0,
        "no worker may disarm on a 0%-pass fixture",
    )
    assert_equal(
        bloomsel_saved_checks(),
        0,
        "a KEPT bloom must skip no check",
    )
    _ = rt_keep^
    _ = builder^
    reset_bloomsel_counters()
    _clear_settings()
    print("test_disarm_is_value_invariant_and_actually_arms OK")


def main() raises:
    var suite = TestSuite()
    suite.test[test_disarm_is_value_invariant_and_actually_arms]()
    suite^.run()
