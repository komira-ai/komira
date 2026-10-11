# =============================================================================
# test_semi_anti_count_byte_equiv -- the SEMI and ANTI COUNT fast paths
# =============================================================================
#
# A count-only SEMI/ANTI join (a 0-key `COUNT(*)` over it) sums the scalar
# kernels `HashJoinBuilder.probe_semi_count` / `probe_anti_count` instead of
# gathering the survivor list. This pins those kernels TWO ways so a bug cannot
# pass vacuously:
#   1. SELF-CONSISTENCY: `probe_semi_count(k) == len(probe_semi(k))` and
#      `probe_anti_count(k) == len(probe_anti(k))`.
#   2. INDEPENDENT ORACLE: a hash-free nested-loop membership count. Self-
#      consistency alone is BLIND to a bug in the SHARED chain walk.
#
# Fixtures exercise BOTH probe arms: the small-build (<= 4096, no bloom) arm and
# the large-build (two-stage prefetch + bloom) arm, plus 1:N duplicate build
# keys, all-hit / all-miss, empty build/probe, and a NULLABLE probe (a NULL
# probe key matches nothing: excluded by SEMI, KEPT by ANTI).
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder


def _assert_eq(actual: Int, expected: Int, imm msg: String) raises:
    if actual != expected:
        raise Error(
            msg + ": expected " + String(expected) + ", got " + String(actual)
        )


def _pa(var keys: List[Int64]) raises -> PrimitiveArray[DType.int64]:
    var n = len(keys)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    return arr^


def _pa_nullable(
    var keys: List[Int64], var nulls: List[Bool]
) raises -> PrimitiveArray[DType.int64]:
    var n = len(keys)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p[i] = keys[i]
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _naive_semi_count(
    imm build: List[Int64], imm probe: List[Int64], imm probe_nulls: List[Bool]
) -> Int:
    """INDEPENDENT oracle: count probe rows (non-null) whose key is in the build
    set, via a naive nested-loop membership scan (no hashing, no chain walk)."""
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
    """INDEPENDENT oracle: count probe rows with NO match; a NULL probe key is
    KEPT by ANTI (matches nothing)."""
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


def _check(
    var build: List[Int64], var probe: List[Int64], var probe_nulls: List[Bool]
) raises:
    """Pin probe_semi_count / probe_anti_count against BOTH the self-consistency
    invariant (== len(probe_semi/anti)) AND the independent naive oracle."""
    var has_nulls = False
    for i in range(len(probe_nulls)):
        if probe_nulls[i]:
            has_nulls = True
            break

    var build_arr = _pa(build.copy())
    var builder = HashJoinBuilder.build(build_arr^)

    var probe_arr: PrimitiveArray[DType.int64]
    if has_nulls:
        probe_arr = _pa_nullable(probe.copy(), probe_nulls.copy())
    else:
        probe_arr = _pa(probe.copy())

    var semi_idx = builder.probe_semi(probe_arr)
    var anti_idx = builder.probe_anti(probe_arr)
    var semi_count = builder.probe_semi_count(probe_arr)
    var anti_count = builder.probe_anti_count(probe_arr)

    var naive_semi = _naive_semi_count(build, probe, probe_nulls)
    var naive_anti = _naive_anti_count(build, probe, probe_nulls)

    # 1. SELF-CONSISTENCY: the scalar count == what the full survivor-list path
    #    would gather (the count-only join sink's load-bearing invariant).
    _assert_eq(semi_count, len(semi_idx), "probe_semi_count vs len(probe_semi)")
    _assert_eq(anti_count, len(anti_idx), "probe_anti_count vs len(probe_anti)")
    # 2. INDEPENDENT ORACLE: catches a shared chain-walk bug that (1) is blind to.
    _assert_eq(semi_count, naive_semi, "probe_semi_count vs naive oracle")
    _assert_eq(anti_count, naive_anti, "probe_anti_count vs naive oracle")
    # Every probe row is either a SEMI survivor or an ANTI survivor.
    _assert_eq(semi_count + anti_count, len(probe), "semi + anti == probe rows")

    _ = builder
    _ = probe_arr
    _ = semi_idx
    _ = anti_idx


def test_semi_anti_count_empty_build() raises:
    var build = List[Int64]()
    var probe: List[Int64] = [1, 2, 3]
    var nulls: List[Bool] = [False, False, False]
    _check(build^, probe^, nulls^)


def test_semi_anti_count_all_match() raises:
    var build: List[Int64] = [1, 2, 3]
    var probe: List[Int64] = [1, 2, 3, 1, 2]
    var nulls: List[Bool] = [False, False, False, False, False]
    _check(build^, probe^, nulls^)


def test_semi_anti_count_all_miss() raises:
    var build: List[Int64] = [1, 2, 3]
    var probe: List[Int64] = [7, 8, 9, 100]
    var nulls: List[Bool] = [False, False, False, False]
    _check(build^, probe^, nulls^)


def test_semi_anti_count_mixed() raises:
    var build: List[Int64] = [1, 2, 3, 5]
    var probe: List[Int64] = [3, 99, 5, 1, 4]
    var nulls: List[Bool] = [False, False, False, False, False]
    _check(build^, probe^, nulls^)


def test_semi_anti_count_duplicate_build_keys() raises:
    # 1:N build side — SEMI/ANTI count each probe row AT MOST once regardless of
    # how many build rows share its key.
    var build: List[Int64] = [1, 1, 2, 2, 2, 3]
    var probe: List[Int64] = [1, 2, 3, 4]
    var nulls: List[Bool] = [False, False, False, False]
    _check(build^, probe^, nulls^)


def test_semi_anti_count_empty_probe() raises:
    var build: List[Int64] = [1, 2, 3]
    var probe = List[Int64]()
    var nulls = List[Bool]()
    _check(build^, probe^, nulls^)


def test_semi_anti_count_nullable_probe() raises:
    # NULL probe key (value 0) matches nothing -> excluded by SEMI, KEPT by ANTI.
    # Value 0 would spuriously match a build 0 without the SW-C null guard, so the
    # build deliberately does NOT contain 0.
    var build: List[Int64] = [1, 2, 3]
    var probe: List[Int64] = [1, 0, 3, 0, 7]
    var nulls: List[Bool] = [False, True, False, True, False]
    _check(build^, probe^, nulls^)


def test_semi_anti_count_large_build_bloom_arm() raises:
    # Build side > 4096 -> the large-build probe arm (two-stage prefetch + bloom
    # pre-check). Half the probe keys hit, half miss.
    var build = List[Int64]()
    for i in range(5000):
        build.append(Int64(i))
    var probe = List[Int64]()
    var nulls = List[Bool]()
    for i in range(300):
        if i % 2 == 0:
            probe.append(Int64(i))          # hit ([0, 5000) range)
        else:
            probe.append(Int64(1_000_000 + i))  # miss (out of build range)
        nulls.append(False)
    _check(build^, probe^, nulls^)


def main() raises:
    test_semi_anti_count_empty_build()
    test_semi_anti_count_all_match()
    test_semi_anti_count_all_miss()
    test_semi_anti_count_mixed()
    test_semi_anti_count_duplicate_build_keys()
    test_semi_anti_count_empty_probe()
    test_semi_anti_count_nullable_probe()
    test_semi_anti_count_large_build_bloom_arm()
    print("test_semi_anti_count_byte_equiv OK (8 cases)")
