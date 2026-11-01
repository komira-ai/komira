# `SemiJoinHashSet`'s parallel SEMI and ANTI COUNT probes against the chained
# hash join's counts and a nested-loop oracle: empty build or probe, all match,
# all miss, mixed, duplicate build keys, NULL probe keys, one hot key, and a
# fixture large enough for the parallel build and the work-stealing probe.

from komira_arrow.primitive_array import PrimitiveArray

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_probe.semi_join import SemiJoinHashSet


comptime I64 = DType.int64


def _assert_eq(actual: Int, expected: Int, imm msg: String) raises:
    if actual != expected:
        raise Error(
            msg + ": expected " + String(expected) + ", got " + String(actual)
        )


def _pa(var keys: List[Int64]) raises -> PrimitiveArray[I64]:
    var n = len(keys)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    return arr^


def _pa_nullable(
    var keys: List[Int64], var nulls: List[Bool]
) raises -> PrimitiveArray[I64]:
    var n = len(keys)
    var arr = PrimitiveArray[I64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p[i] = keys[i]
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _naive_semi_count(
    imm build: List[Int64], imm probe: List[Int64], imm probe_nulls: List[Bool]
) -> Int:
    var c = 0
    for pi in range(len(probe)):
        if probe_nulls[pi]:
            continue
        var found = False
        for bi in range(len(build)):
            if build[bi] == probe[pi]:
                found = True
                break
        if found:
            c += 1
    return c


def _naive_anti_count(
    imm build: List[Int64], imm probe: List[Int64], imm probe_nulls: List[Bool]
) -> Int:
    var c = 0
    for pi in range(len(probe)):
        if probe_nulls[pi]:
            c += 1
            continue
        var found = False
        for bi in range(len(build)):
            if build[bi] == probe[pi]:
                found = True
                break
        if not found:
            c += 1
    return c


def _check_impl(
    imm msg: String,
    var build: List[Int64],
    var probe: List[Int64],
    var probe_nulls: List[Bool],
    use_naive: Bool,
) raises:
    """Check the parallel count probes of `SemiJoinHashSet` against (1) the
    chained `HashJoinBuilder` counts, (2) a nested-loop oracle (skipped for the
    large fixture, where the chained kernel is the oracle), and (3) SEMI + ANTI
    covering every probe row once.
    """
    var has_nulls = False
    for i in range(len(probe_nulls)):
        if probe_nulls[i]:
            has_nulls = True
            break

    var chained = HashJoinBuilder.build(_pa(build.copy()))
    var probe_chained: PrimitiveArray[I64]
    if has_nulls:
        probe_chained = _pa_nullable(probe.copy(), probe_nulls.copy())
    else:
        probe_chained = _pa(probe.copy())
    var chained_semi = chained.probe_semi_count(probe_chained)
    var chained_anti = chained.probe_anti_count(probe_chained)
    _ = chained
    _ = probe_chained

    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()
    var build_arr = _pa(build.copy())
    var semi_ht = SemiJoinHashSet(build_arr, disp, ct.clone())
    _ = build_arr

    var probe_new: PrimitiveArray[I64]
    if has_nulls:
        probe_new = _pa_nullable(probe.copy(), probe_nulls.copy())
    else:
        probe_new = _pa(probe.copy())
    var new_semi = semi_ht.probe_semi_count_parallel(disp, ct.clone(), probe_new)
    var new_anti = semi_ht.probe_anti_count_parallel(disp, ct.clone(), probe_new)
    _ = semi_ht
    _ = probe_new

    _assert_eq(new_semi, chained_semi, msg + " SEMI new vs chained")
    _assert_eq(new_anti, chained_anti, msg + " ANTI new vs chained")
    if use_naive:
        var naive_semi = _naive_semi_count(build, probe, probe_nulls)
        var naive_anti = _naive_anti_count(build, probe, probe_nulls)
        _assert_eq(new_semi, naive_semi, msg + " SEMI new vs naive oracle")
        _assert_eq(new_anti, naive_anti, msg + " ANTI new vs naive oracle")
    _assert_eq(new_semi + new_anti, len(probe), msg + " semi+anti == probe rows")


def _check(
    imm msg: String,
    var build: List[Int64],
    var probe: List[Int64],
    var probe_nulls: List[Bool],
) raises:
    _check_impl(msg, build^, probe^, probe_nulls^, use_naive=True)


def test_salted_count_empty_build() raises:
    var probe: List[Int64] = [1, 2, 3]
    var nulls: List[Bool] = [False, False, False]
    _check("empty_build", List[Int64](), probe^, nulls^)


def test_salted_count_all_match() raises:
    var build: List[Int64] = [1, 2, 3]
    var probe: List[Int64] = [1, 2, 3, 1, 2]
    var nulls: List[Bool] = [False, False, False, False, False]
    _check("all_match", build^, probe^, nulls^)


def test_salted_count_all_miss() raises:
    var build: List[Int64] = [1, 2, 3]
    var probe: List[Int64] = [7, 8, 9, 100]
    var nulls: List[Bool] = [False, False, False, False]
    _check("all_miss", build^, probe^, nulls^)


def test_salted_count_mixed() raises:
    var build: List[Int64] = [1, 2, 3, 5]
    var probe: List[Int64] = [3, 99, 5, 1, 4]
    var nulls: List[Bool] = [False, False, False, False, False]
    _check("mixed", build^, probe^, nulls^)


def test_salted_count_duplicate_build_keys() raises:
    var build: List[Int64] = [1, 1, 2, 2, 2, 3]
    var probe: List[Int64] = [1, 2, 3, 4]
    var nulls: List[Bool] = [False, False, False, False]
    _check("dup_build", build^, probe^, nulls^)


def test_salted_count_empty_probe() raises:
    var build: List[Int64] = [1, 2, 3]
    _check("empty_probe", build^, List[Int64](), List[Bool]())


def test_salted_count_nullable_probe() raises:
    var build: List[Int64] = [1, 2, 3]
    var probe: List[Int64] = [1, 0, 3, 0, 7]
    var nulls: List[Bool] = [False, True, False, True, False]
    _check("nullable_probe", build^, probe^, nulls^)


def test_salted_count_skew_all_same_key() raises:
    var build = List[Int64]()
    for _ in range(2000):
        build.append(Int64(42))
    var probe: List[Int64] = [42, 42, 7, 42, 99]
    var nulls: List[Bool] = [False, False, False, False, False]
    _check("skew_all_same", build^, probe^, nulls^)


def test_salted_count_large_parallel() raises:
    var build = List[Int64]()
    var i = 0
    while i < 300000:
        build.append(Int64(i))
        i += 2
    var probe = List[Int64]()
    var nulls = List[Bool]()
    for k in range(300000):
        probe.append(Int64(k))
        nulls.append(False)
    _check_impl("large_parallel", build^, probe^, nulls^, use_naive=False)


def main() raises:
    test_salted_count_empty_build()
    test_salted_count_all_match()
    test_salted_count_all_miss()
    test_salted_count_mixed()
    test_salted_count_duplicate_build_keys()
    test_salted_count_empty_probe()
    test_salted_count_nullable_probe()
    test_salted_count_skew_all_same_key()
    test_salted_count_large_parallel()
    print("test_semi_salted_count_parallel_byte_equiv OK (9 cases)")
