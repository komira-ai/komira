# `SemiJoinHashSet` under skew, NULLs and cancellation, against a sorted-list
# oracle: a build side whose distinct keys all hash to ONE of the set's 8
# partitions (serial and parallel builds, which must still terminate and answer
# every lookup), NULL build keys (a NULL row's value is not a member) and NULL
# probe keys on the work-stealing arms (the index list equals the serial
# probe's, in probe order), and a token cancelled before a parallel build or
# probe, which raises and leaves the pool usable. The pool is four workers by
# construction, never the host's core count.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import (
    SITE_SEMI_PROBE_COUNT,
    SITE_SEMI_PROBE_INDEX,
)
from komira_async_api.token import CancellationToken
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_MORSELS,
    GRAIN_F_WORKERS,
    grain_geometry_field,
    grain_geometry_reset,
)

from komira_op_join_probe.semi_join import SemiJoinHashSet
from komira_op_join_probe.semi_join_tasks import (
    SEMI_PROBE_PARALLEL_MIN_ROWS,
    _PARALLEL_BUILD_THRESHOLD,
)


comptime I64 = DType.int64
comptime _FIB: UInt64 = 0x9E3779B97F4A7C15


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _partition_of_key(key: Int64) -> Int:
    """The set's partition of `key`: the top 3 bits of its hash."""
    var h = UInt64(key) * _FIB
    h = h ^ (h >> 32)
    return Int(h >> 61)


def _column(imm keys: List[Int64], imm nulls: List[Bool]) -> PrimitiveArray[I64]:
    var n = len(keys)
    var any_null = False
    for i in range(len(nulls)):
        if nulls[i]:
            any_null = True
    var arr: PrimitiveArray[I64]
    if any_null:
        arr = PrimitiveArray[I64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    for i in range(len(nulls)):
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _partition_keys(partition: Int, skip: Int, count: Int) -> List[Int64]:
    """`count` distinct keys of `partition`, skipping the first `skip`."""
    var out = List[Int64]()
    var seen = 0
    var k = Int64(1)
    while len(out) < count:
        if _partition_of_key(k) == partition:
            if seen >= skip:
                out.append(k)
            seen += 1
        k += 1
    return out^


def _members(imm build: List[Int64], imm build_nulls: List[Bool]) -> List[Int64]:
    """The distinct non-NULL build keys, sorted."""
    var vals = List[Int64]()
    for i in range(len(build)):
        if len(build_nulls) == 0 or not build_nulls[i]:
            vals.append(build[i])
    sort(vals)
    return vals^


def _is_member(imm sorted_keys: List[Int64], key: Int64) -> Bool:
    var lo = 0
    var hi = len(sorted_keys)
    while lo < hi:
        var mid = (lo + hi) // 2
        if sorted_keys[mid] < key:
            lo = mid + 1
        else:
            hi = mid
    return lo < len(sorted_keys) and sorted_keys[lo] == key


def _expected(
    imm sorted_keys: List[Int64],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
    anti: Bool,
) -> List[Int]:
    var out = List[Int]()
    for i in range(len(probe)):
        var is_null = len(probe_nulls) > 0 and probe_nulls[i]
        var hit = (not is_null) and _is_member(sorted_keys, probe[i])
        if hit != anti:
            out.append(i)
    return out^


def _assert_rows(imm got: List[Int], imm want: List[Int], imm what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(got)):
        if got[i] != want[i]:
            raise Error(
                what + ": entry " + String(i) + " is " + String(got[i])
                + ", expected " + String(want[i])
            )


def _check_all_probes(
    mut hs: SemiJoinHashSet,
    mut disp: LocalDispatcher[NoopSink],
    imm build: List[Int64],
    imm build_nulls: List[Bool],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
    imm what: String,
) raises:
    var keys = _members(build, build_nulls)
    var want_semi = _expected(keys, probe, probe_nulls, False)
    var want_anti = _expected(keys, probe, probe_nulls, True)
    var col = _column(probe, probe_nulls)

    _assert_rows(hs.probe_semi(col), want_semi, what + " SEMI")
    _assert_rows(hs.probe_anti(col), want_anti, what + " ANTI")
    assert_equal(hs.probe_semi_count(col), len(want_semi), what + " SEMI COUNT")
    var par = List[Int]()
    hs.probe_semi_parallel(disp, CancellationToken.never(), col, par)
    _assert_rows(par, want_semi, what + " parallel SEMI")
    assert_equal(
        hs.probe_semi_count_parallel(disp, CancellationToken.never(), col),
        len(want_semi),
        what + " parallel SEMI COUNT",
    )
    assert_equal(
        hs.probe_anti_count_parallel(disp, CancellationToken.never(), col),
        len(want_anti),
        what + " parallel ANTI COUNT",
    )


def _skewed_probe(
    imm members: List[Int64], imm absent: List[Int64], n: Int
) -> List[Int64]:
    """n probe rows alternating a member and a same-partition absent key, in an
    order unrelated to the build's."""
    var out = List[Int64]()
    for i in range(n):
        if i % 2 == 0:
            out.append(members[(i * 7) % len(members)])
        else:
            out.append(absent[(i * 5) % len(absent)])
    return out^


def test_serial_build_with_every_key_in_one_partition() raises:
    """More distinct keys than one partition's share of a table sized for the
    whole build: the build must neither hang nor drop a key."""
    var rt = _runtime()
    ref d = rt.dispatcher()
    var members = _partition_keys(3, 0, 1000)
    var absent = _partition_keys(3, 1000, 300)
    var probe = _skewed_probe(members, absent, 2000)
    var hs = SemiJoinHashSet(_column(members, List[Bool]()))
    _check_all_probes(
        hs, d, members, List[Bool](), probe, List[Bool](), "serial skew"
    )


def test_dispatcher_constructor_below_the_parallel_threshold_with_skew() raises:
    var rt = _runtime()
    ref d = rt.dispatcher()
    var members = _partition_keys(0, 0, 5000)
    var absent = _partition_keys(0, 5000, 400)
    var probe = _skewed_probe(members, absent, 6000)
    var hs = SemiJoinHashSet(
        _column(members, List[Bool]()), d, CancellationToken.never()
    )
    _check_all_probes(
        hs, d, members, List[Bool](), probe, List[Bool](), "small skew"
    )


def test_parallel_build_with_every_key_in_one_partition() raises:
    assert_true(
        _PARALLEL_BUILD_THRESHOLD <= 140_000, "fixture below the build threshold"
    )
    var rt = _runtime()
    ref d = rt.dispatcher()
    var members = _partition_keys(5, 0, 140_000)
    var absent = _partition_keys(5, 140_000, 500)
    var probe = _skewed_probe(members, absent, 20_000)
    var hs = SemiJoinHashSet(
        _column(members, List[Bool]()), d, CancellationToken.never()
    )
    _check_all_probes(
        hs, d, members, List[Bool](), probe, List[Bool](), "parallel skew"
    )


def test_null_build_keys_are_not_members() raises:
    """Rows whose key value is also held by a valid row, and rows whose value
    is held by no valid row: probing those values finds only the valid ones."""
    var rt = _runtime()
    ref d = rt.dispatcher()
    var build = List[Int64]()
    var nulls = List[Bool]()
    for i in range(1000):
        build.append(Int64(i % 400))
        nulls.append(i >= 400 and i % 3 != 0)
    for i in range(200):  # values only NULL rows hold
        build.append(Int64(10_000 + i))
        nulls.append(True)
    var probe = List[Int64]()
    for i in range(2000):
        probe.append(Int64((i * 13) % 11_000))
    var hs = SemiJoinHashSet(_column(build, nulls))
    _check_all_probes(hs, d, build, nulls, probe, List[Bool](), "null build")


def test_null_build_keys_through_the_parallel_build() raises:
    var rt = _runtime()
    ref d = rt.dispatcher()
    var n = 150_000
    var build = List[Int64]()
    var nulls = List[Bool]()
    for i in range(n):
        build.append(Int64(i))
        nulls.append(i % 4 == 1)
    var probe = List[Int64]()
    for i in range(1000):
        probe.append(Int64((i * 997) % (n + 500)))
    var hs = SemiJoinHashSet(
        _column(build, nulls), d, CancellationToken.never()
    )
    _check_all_probes(
        hs, d, build, nulls, probe, List[Bool](), "parallel null build"
    )


def test_null_probe_keys_through_the_work_stealing_arms() raises:
    """Above the probe threshold, NULL probe rows that hold member values: the
    parallel index list equals the serial probe's, row for row."""
    assert_true(
        SEMI_PROBE_PARALLEL_MIN_ROWS < 300_000, "fixture below the probe threshold"
    )
    var rt = _runtime()
    ref d = rt.dispatcher()
    var build = List[Int64]()
    for i in range(0, 5000, 2):
        build.append(Int64(i))
    var probe = List[Int64]()
    var nulls = List[Bool]()
    for i in range(300_000):
        probe.append(Int64((i * 31) % 5000))
        nulls.append(i % 5 == 2)
    var hs = SemiJoinHashSet(_column(build, List[Bool]()))
    grain_geometry_reset()
    _check_all_probes(hs, d, build, List[Bool](), probe, nulls, "null probe")
    # The stealing arms ran: more than one morsel, more than one task.
    assert_true(
        grain_geometry_field(SITE_SEMI_PROBE_INDEX, GRAIN_F_MORSELS) > 1,
        "the index probe ran as one morsel",
    )
    assert_true(
        grain_geometry_field(SITE_SEMI_PROBE_INDEX, GRAIN_F_WORKERS) > 1,
        "the index probe ran on one task",
    )
    assert_true(
        grain_geometry_field(SITE_SEMI_PROBE_COUNT, GRAIN_F_MORSELS) > 1,
        "the count probe ran as one morsel",
    )


def test_empty_sides() raises:
    var rt = _runtime()
    ref d = rt.dispatcher()
    var some: List[Int64] = [4, 5, 6]
    var none = List[Int64]()
    var hs_empty = SemiJoinHashSet(_column(none, List[Bool]()))
    _check_all_probes(
        hs_empty, d, none, List[Bool](), some, List[Bool](), "empty build"
    )
    var hs_some = SemiJoinHashSet(_column(some, List[Bool]()))
    _check_all_probes(
        hs_some, d, some, List[Bool](), none, List[Bool](), "empty probe"
    )


def _raises_naming_cancel(imm what: String, raised: Bool, imm message: String) raises:
    assert_true(raised, what + ": a cancelled token did not raise")
    assert_true(
        message.find("ancel") >= 0,
        what + ": the error does not name the cancellation: " + message,
    )


def test_a_cancelled_token_raises_and_leaves_the_pool_usable() raises:
    var rt = _runtime()
    ref d = rt.dispatcher()
    var members = List[Int64]()
    for i in range(140_000):
        members.append(Int64(i * 3))

    var token = CancellationToken.new()
    token.cancel(String("stop"))
    var raised = False
    var message = String("")
    try:
        var built = SemiJoinHashSet(_column(members, List[Bool]()), d, token.clone())
        _ = built^
    except e:
        raised = True
        message = String(e)
    _raises_naming_cancel("parallel build", raised, message)

    var hs = SemiJoinHashSet(
        _column(members, List[Bool]()), d, CancellationToken.never()
    )
    var probe = List[Int64]()
    for i in range(300_000):
        probe.append(Int64(i))
    var col = _column(probe, List[Bool]())

    raised = False
    message = String("")
    try:
        var out = List[Int]()
        hs.probe_semi_parallel(d, token.clone(), col, out)
        assert_equal(len(out), 0, "a cancelled probe appended rows")
    except e:
        raised = True
        message = String(e)
    _raises_naming_cancel("parallel probe", raised, message)

    raised = False
    message = String("")
    try:
        _ = hs.probe_semi_count_parallel(d, token.clone(), col)
    except e:
        raised = True
        message = String(e)
    _raises_naming_cancel("parallel count", raised, message)

    var want = _expected(_members(members, List[Bool]()), probe, List[Bool](), False)
    var after = List[Int]()
    hs.probe_semi_parallel(d, CancellationToken.never(), col, after)
    _assert_rows(after, want, "after the cancel")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
