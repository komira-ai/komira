# `SemiJoinHashSet` and the key INT64_MIN, the value that marks an empty slot.
# A probe key INT64_MIN must match exactly when the build side holds
# INT64_MIN, as any other key does (DuckDB: `SELECT ... WHERE k IN (...)`
# treats it as an ordinary BIGINT). Checked through every build (serial, and
# parallel above `_PARALLEL_BUILD_THRESHOLD` keys) and every probe: SEMI, ANTI,
# SEMI COUNT, the parallel SEMI (serial and work-stealing arms) and the
# parallel SEMI / ANTI COUNT.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken

from komira_op_join_probe.semi_join import SemiJoinHashSet
from komira_op_join_probe.semi_join_tasks import (
    SEMI_PROBE_PARALLEL_MIN_ROWS,
    _PARALLEL_BUILD_THRESHOLD,
)


comptime I64 = DType.int64
comptime _MIN: Int64 = Int64(-9223372036854775807 - 1)


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _arr(imm v: List[Int64]) -> PrimitiveArray[I64]:
    var a = PrimitiveArray[I64].allocate(len(v))
    var p = a._typed_ptr_mut()
    for i in range(len(v)):
        (p + i)[] = v[i]
    return a^


def _build_keys(n: Int, with_min: Bool) -> List[Int64]:
    """Keys 1..n (or 1..n-1 then INT64_MIN when `with_min`)."""
    var v = List[Int64]()
    for i in range(n):
        v.append(Int64(i + 1))
    if with_min:
        v[n - 1] = _MIN
    return v^


def _probe_keys(n: Int) -> List[Int64]:
    """n probe rows: INT64_MIN at row 0 and at row n - 1, the key 1 at row 1,
    the rest misses (negative keys other than INT64_MIN)."""
    var v = List[Int64]()
    for i in range(n):
        v.append(Int64(-(i + 1)))
    v[0] = _MIN
    v[1] = Int64(1)
    v[n - 1] = _MIN
    return v^


def _check(build_n: Int, probe_n: Int, with_min: Bool, what: String) raises:
    """Every probe agrees: the probe rows that match are row 1, plus rows 0
    and n - 1 exactly when the build holds INT64_MIN."""
    var want_semi = 3 if with_min else 1
    var want_anti = probe_n - want_semi
    var rt = _runtime()
    ref d = rt.dispatcher()
    var tag = what + (" with INT64_MIN" if with_min else " without INT64_MIN")
    var hs = SemiJoinHashSet(
        _arr(_build_keys(build_n, with_min)), d, CancellationToken.never()
    )
    var probe = _arr(_probe_keys(probe_n))

    var semi = hs.probe_semi(probe)
    assert_equal(len(semi), want_semi, tag + ": SEMI")
    assert_equal(semi[0], 0 if with_min else 1, tag + ": SEMI row")
    assert_equal(len(hs.probe_anti(probe)), want_anti, tag + ": ANTI")
    assert_equal(hs.probe_semi_count(probe), want_semi, tag + ": SEMI COUNT")

    var par = List[Int]()
    hs.probe_semi_parallel(d, CancellationToken.never(), probe, par)
    assert_equal(len(par), want_semi, tag + ": parallel SEMI")
    for i in range(len(par)):
        assert_equal(par[i], semi[i], tag + ": parallel SEMI row " + String(i))
    assert_equal(
        hs.probe_semi_count_parallel(d, CancellationToken.never(), probe),
        want_semi,
        tag + ": parallel SEMI COUNT",
    )
    assert_equal(
        hs.probe_anti_count_parallel(d, CancellationToken.never(), probe),
        want_anti,
        tag + ": parallel ANTI COUNT",
    )


def test_serial_build_serial_probes() raises:
    _check(100, 50, False, "small")
    _check(100, 50, True, "small")


def test_serial_set_constructor() raises:
    """The dispatcher-free constructor takes the serial build too."""
    var with_min = SemiJoinHashSet(_arr(_build_keys(10, True)))
    var without = SemiJoinHashSet(_arr(_build_keys(10, False)))
    var probe = _arr(_probe_keys(8))
    assert_equal(len(with_min.probe_semi(probe)), 3, "serial set with INT64_MIN")
    assert_equal(len(without.probe_semi(probe)), 1, "serial set without")


def test_parallel_build_and_parallel_probes() raises:
    """Above both thresholds: the partitioned parallel build and the
    work-stealing probes."""
    assert_true(_PARALLEL_BUILD_THRESHOLD <= 140_000, "fixture below the build threshold")
    assert_true(SEMI_PROBE_PARALLEL_MIN_ROWS < 300_000, "fixture below the probe threshold")
    _check(140_000, 300_000, False, "large")
    _check(140_000, 300_000, True, "large")


def main() raises:
    var suite = TestSuite()
    suite.test[test_serial_build_serial_probes]()
    suite.test[test_serial_set_constructor]()
    suite.test[test_parallel_build_and_parallel_probes]()
    suite^.run()
