# The row-indexed entry space against brute force: every probe kind (INNER,
# LEFT, SEMI, ANTI, RIGHT, FULL) over the serial build and the parallel build,
# on fixtures with NULL-keyed build rows at the head, middle and tail; RIGHT and
# FULL emit every build row.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_async_api.parallel_dispatch import NoDispatch

from komira_op_join_build.hash_chain_build_settings import (
    JOIN_PARALLEL_BUILD_FORCE,
    join_parallel_build_configure,
    reset_hash_chain_build_settings,
)
from komira_op_join_probe.join_multi_key import (
    MultiKeyColumns,
    _NAN_SENTINEL_BITS,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_anti,
    multi_key_probe_semi,
)
from komira_op_join_probe.join_multi_key_outer import (
    multi_key_probe_full_into,
    multi_key_probe_right_into,
)
from komira_op_join_probe.join_multi_key_parallel_build import (
    multi_key_hash_join_build_parallel,
)


comptime I64 = DType.int64

comptime _ENC: Int = 1_000_000



def _i64_arr(imm values: List[Int64]) -> PrimitiveArray[I64]:
    var n = len(values)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    return arr^


def _mk_columns(imm cols: List[List[Int64]]) raises -> MultiKeyColumns:
    """A pure-INT64 `MultiKeyColumns` over N key columns."""
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


def _assert_lists_equal(
    imm a: List[Int], imm b: List[Int], msg: String
) raises:
    assert_equal(len(a), len(b), msg + " length")
    for i in range(len(a)):
        assert_equal(a[i], b[i], msg + " [" + String(i) + "]")


def _encode(var bm: List[Int], var pm: List[Int]) -> List[Int]:
    var enc = List[Int]()
    for i in range(len(bm)):
        enc.append((bm[i] + 1) * _ENC + (pm[i] + 1))
    return _sorted(enc^)


def _has_sentinel(imm cols: List[List[Int64]], row: Int) -> Bool:
    for k in range(len(cols)):
        if cols[k][row] == _NAN_SENTINEL_BITS:
            return True
    return False


def _rows_equal(
    imm a: List[List[Int64]], ai: Int, imm b: List[List[Int64]], bi: Int
) -> Bool:
    for k in range(len(a)):
        if a[k][ai] != b[k][bi]:
            return False
    return True


def _bf_inner(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Int]:
    """Sorted encoded (build_idx, probe_idx) multiset of the INNER join."""
    var nb = len(build[0])
    var npr = len(probe[0])
    var enc = List[Int]()
    for p in range(npr):
        if _has_sentinel(probe, p):
            continue
        for b in range(nb):
            if _has_sentinel(build, b):
                continue
            if _rows_equal(build, b, probe, p):
                enc.append((b + 1) * _ENC + (p + 1))
    return _sorted(enc^)


def _bf_probe_matched(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Bool]:
    var nb = len(build[0])
    var npr = len(probe[0])
    var out = List[Bool]()
    for p in range(npr):
        var hit = False
        if not _has_sentinel(probe, p):
            for b in range(nb):
                if _has_sentinel(build, b):
                    continue
                if _rows_equal(build, b, probe, p):
                    hit = True
                    break
        out.append(hit)
    return out^


def _bf_build_matched(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Bool]:
    var nb = len(build[0])
    var npr = len(probe[0])
    var out = List[Bool]()
    for b in range(nb):
        var hit = False
        if not _has_sentinel(build, b):
            for p in range(npr):
                if _has_sentinel(probe, p):
                    continue
                if _rows_equal(build, b, probe, p):
                    hit = True
                    break
        out.append(hit)
    return out^


def _bf_left(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Int]:
    """INNER pairs plus (-1, probe_idx) for every unmatched PROBE row."""
    var enc = _bf_inner(build, probe)
    var pmatched = _bf_probe_matched(build, probe)
    for p in range(len(pmatched)):
        if not pmatched[p]:
            enc.append(0 * _ENC + (p + 1))
    return _sorted(enc^)


def _bf_right(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Int]:
    """INNER pairs plus (build_idx, -1) for every unmatched BUILD row."""
    var enc = _bf_inner(build, probe)
    var bmatched = _bf_build_matched(build, probe)
    for b in range(len(bmatched)):
        if not bmatched[b]:
            enc.append((b + 1) * _ENC + 0)
    return _sorted(enc^)


def _bf_full(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Int]:
    var enc = _bf_inner(build, probe)
    var bmatched = _bf_build_matched(build, probe)
    for b in range(len(bmatched)):
        if not bmatched[b]:
            enc.append((b + 1) * _ENC + 0)
    var pmatched = _bf_probe_matched(build, probe)
    for p in range(len(pmatched)):
        if not pmatched[p]:
            enc.append(0 * _ENC + (p + 1))
    return _sorted(enc^)


def _bf_semi(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Int]:
    var pmatched = _bf_probe_matched(build, probe)
    var out = List[Int]()
    for p in range(len(pmatched)):
        if pmatched[p]:
            out.append(p)
    return _sorted(out^)


def _bf_anti(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Int]:
    var pmatched = _bf_probe_matched(build, probe)
    var out = List[Int]()
    for p in range(len(pmatched)):
        if not pmatched[p]:
            out.append(p)
    return _sorted(out^)


comptime _S: Int64 = _NAN_SENTINEL_BITS


def _fixture(name: String) raises -> List[List[List[Int64]]]:
    """Returns `[build_cols, probe_cols]` for the named fixture."""
    var b = List[List[Int64]]()
    var p = List[List[Int64]]()

    if name == "dup_fanout":
        var b0 = List[Int64]()
        var b1 = List[Int64]()
        for i in range(120):
            b0.append(Int64(i % 23))
            b1.append(Int64((i % 23) * 7))
        b.append(b0^)
        b.append(b1^)
        var p0 = List[Int64]()
        var p1 = List[Int64]()
        for i in range(97):
            p0.append(Int64(i % 29))
            p1.append(Int64((i % 29) * 7))
        p.append(p0^)
        p.append(p1^)
    elif name == "sentinel_key0":
        var sk_b0: List[Int64] = [1, _S, 3, _S, 5]
        var sk_b1: List[Int64] = [10, 20, 30, 40, 50]
        var sk_p0: List[Int64] = [1, 3, _S, 5]
        var sk_p1: List[Int64] = [10, 30, 40, 50]
        b.append(sk_b0^)
        b.append(sk_b1^)
        p.append(sk_p0^)
        p.append(sk_p1^)
    elif name == "sentinel_later_key":
        var sl_b0: List[Int64] = [1, 2, 3, 4, 5, 6]
        var sl_b1: List[Int64] = [10, _S, 30, _S, 50, 60]
        var sl_p0: List[Int64] = [1, 2, 3, 4, 5, 6]
        var sl_p1: List[Int64] = [10, _S, 30, 40, 50, 60]
        b.append(sl_b0^)
        b.append(sl_b1^)
        p.append(sl_p0^)
        p.append(sl_p1^)
    elif name == "all_sentinel_build":
        var as_b0: List[Int64] = [_S, _S, _S, _S]
        var as_b1: List[Int64] = [_S, _S, _S, _S]
        var as_p0: List[Int64] = [1, 2, 3]
        var as_p1: List[Int64] = [1, 2, 3]
        b.append(as_b0^)
        b.append(as_b1^)
        p.append(as_p0^)
        p.append(as_p1^)
    elif name == "empty_build":
        var eb_b0 = List[Int64]()
        var eb_p0: List[Int64] = [1, 2, 3]
        b.append(eb_b0^)
        p.append(eb_p0^)
    elif name == "single_row_build":
        var sr_b0: List[Int64] = [42]
        var sr_p0: List[Int64] = [42, 43, 42]
        b.append(sr_b0^)
        p.append(sr_p0^)
    elif name == "zero_match":
        var zm_b0: List[Int64] = [1, 2, 3]
        var zm_p0: List[Int64] = [7, 8, 9]
        b.append(zm_b0^)
        p.append(zm_p0^)
    elif name == "negative_keys":
        var nk_b0: List[Int64] = [-1, -2, -3, 0, -2]
        var nk_b1: List[Int64] = [-100, -200, -300, 0, -200]
        var nk_p0: List[Int64] = [-2, 0, -3, -9]
        var nk_p1: List[Int64] = [-200, 0, -300, -9]
        b.append(nk_b0^)
        b.append(nk_b1^)
        p.append(nk_p0^)
        p.append(nk_p1^)
    elif name == "skew_one_bucket":
        var s0 = List[Int64]()
        for _ in range(40):
            s0.append(Int64(77))
        b.append(s0^)
        var sk_p: List[Int64] = [77, 77, 1, 77]
        p.append(sk_p^)
    elif name == "arity_three":
        var a3_b0: List[Int64] = [1, 1, 2, 2, 3]
        var a3_b1: List[Int64] = [1, 1, 2, 3, 3]
        var a3_b2: List[Int64] = [1, 2, 2, 3, 3]
        var a3_p0: List[Int64] = [1, 2, 3, 1]
        var a3_p1: List[Int64] = [1, 3, 3, 1]
        var a3_p2: List[Int64] = [2, 3, 3, 9]
        b.append(a3_b0^)
        b.append(a3_b1^)
        b.append(a3_b2^)
        p.append(a3_p0^)
        p.append(a3_p1^)
        p.append(a3_p2^)
    else:
        raise Error("unknown fixture: " + name)

    var out = List[List[List[Int64]]]()
    out.append(b^)
    out.append(p^)
    return out^


def _fixture_names() -> List[String]:
    var n = List[String]()
    n.append(String("dup_fanout"))
    n.append(String("sentinel_key0"))
    n.append(String("sentinel_later_key"))
    n.append(String("all_sentinel_build"))
    n.append(String("empty_build"))
    n.append(String("single_row_build"))
    n.append(String("zero_match"))
    n.append(String("negative_keys"))
    n.append(String("skew_one_bucket"))
    n.append(String("arity_three"))
    return n^


def test_inner_and_left_match_brute_force() raises:
    """`probe_inner_into` / `probe_left_into` must emit
    exactly the pair multiset a nested-loop join over the same key values
    produces, on every fixture.
    """
    var names = _fixture_names()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))

        var bm = List[Int]()
        var pm = List[Int]()
        builder.probe_inner_into(_mk_columns(probe), bm, pm)
        _assert_lists_equal(
            _encode(bm^, pm^), _bf_inner(build, probe), name + " INNER"
        )

        var lbm = List[Int]()
        var lpm = List[Int]()
        builder.probe_left_into(_mk_columns(probe), lbm, lpm)
        _assert_lists_equal(
            _encode(lbm^, lpm^), _bf_left(build, probe), name + " LEFT"
        )
        _ = builder^
    print("test_inner_and_left_match_brute_force OK")


def test_semi_and_anti_match_brute_force() raises:
    """The two FILTER arms read the same three arrays as the
    two join arms and are otherwise unpinned by any structure-neutral test.
    """
    var names = _fixture_names()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))

        var semi = multi_key_probe_semi(builder, _mk_columns(probe))
        _assert_lists_equal(
            _sorted(semi^), _bf_semi(build, probe), name + " SEMI"
        )

        var anti = multi_key_probe_anti(builder, _mk_columns(probe))
        _assert_lists_equal(
            _sorted(anti^), _bf_anti(build, probe), name + " ANTI"
        )
        _ = builder^
    print("test_semi_and_anti_match_brute_force OK")


def test_right_and_full_match_brute_force() raises:
    """RIGHT and FULL answer brute force."""
    var names = _fixture_names()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))

        var rbm = List[Int]()
        var rpm = List[Int]()
        multi_key_probe_right_into(builder, _mk_columns(probe), rbm, rpm)
        _assert_lists_equal(
            _encode(rbm^, rpm^), _bf_right(build, probe), name + " RIGHT"
        )

        var fbm = List[Int]()
        var fpm = List[Int]()
        multi_key_probe_full_into(builder, _mk_columns(probe), fbm, fpm)
        _assert_lists_equal(
            _encode(fbm^, fpm^), _bf_full(build, probe), name + " FULL"
        )
        _ = builder^
    print("test_right_and_full_match_brute_force OK")


def test_every_build_row_is_emitted_by_right_and_full() raises:
    """RIGHT and FULL emit every build row, NULL-keyed rows included."""
    var names = _fixture_names()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var nb = len(build[0])
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))

        assert_equal(
            builder.num_rows(), nb, name + " num_rows is full build extent"
        )

        var rbm = List[Int]()
        var rpm = List[Int]()
        multi_key_probe_right_into(builder, _mk_columns(probe), rbm, rpm)
        var seen = List[Bool]()
        for _ in range(nb):
            seen.append(False)
        for j in range(len(rbm)):
            seen[rbm[j]] = True
        for r in range(nb):
            assert_true(
                seen[r],
                name + " RIGHT dropped build row " + String(r),
            )

        var fbm = List[Int]()
        var fpm = List[Int]()
        multi_key_probe_full_into(builder, _mk_columns(probe), fbm, fpm)
        var fseen = List[Bool]()
        for _ in range(nb):
            fseen.append(False)
        for j in range(len(fbm)):
            if fbm[j] >= 0:
                fseen[fbm[j]] = True
        for r in range(nb):
            assert_true(
                fseen[r],
                name + " FULL dropped build row " + String(r),
            )
        _ = builder^
    print("test_every_build_row_is_emitted_by_right_and_full OK")


def test_parallel_build_matches_brute_force() raises:
    """The parallel build (under FORCE) answers brute force."""
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var names = _fixture_names()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var _nd = NoDispatch()
        comptime nd_o = origin_of(_nd)
        var builder = multi_key_hash_join_build_parallel[
            False, NoDispatch, nd_o
        ](_mk_columns(build), Optional[Pointer[NoDispatch, nd_o]](None))

        assert_equal(
            builder.num_rows(),
            len(build[0]),
            name + " parallel num_rows is full build extent",
        )

        var bm = List[Int]()
        var pm = List[Int]()
        builder.probe_inner_into(_mk_columns(probe), bm, pm)
        _assert_lists_equal(
            _encode(bm^, pm^),
            _bf_inner(build, probe),
            name + " parallel INNER",
        )

        var rbm = List[Int]()
        var rpm = List[Int]()
        multi_key_probe_right_into(builder, _mk_columns(probe), rbm, rpm)
        _assert_lists_equal(
            _encode(rbm^, rpm^),
            _bf_right(build, probe),
            name + " parallel RIGHT",
        )
        _ = builder^
        _ = _nd^
    reset_hash_chain_build_settings()
    print("test_parallel_build_matches_brute_force OK")


def main() raises:
    var suite = TestSuite()
    suite.test[test_inner_and_left_match_brute_force]()
    suite.test[test_semi_and_anti_match_brute_force]()
    suite.test[test_right_and_full_match_brute_force]()
    suite.test[test_every_build_row_is_emitted_by_right_and_full]()
    suite.test[test_parallel_build_matches_brute_force]()
    suite^.run()
