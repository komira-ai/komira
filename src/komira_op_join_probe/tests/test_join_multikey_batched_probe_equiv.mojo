# The parallel composite probe's batched chain walk against brute force and
# against the row-at-a-time walk, at widths 0 (row-at-a-time), 1, 2, 3, 7 (a
# batch boundary mid-chain on the deep fixtures) and 64: the same pairs, every
# pair's keys equal, and the serial INNER / LEFT / RIGHT / FULL / SEMI / ANTI
# probes untouched by the setting.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

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
from komira_op_join_probe.join_multi_key_parallel import (
    parallel_multi_key_inner_probe_into,
)
from komira_op_join_probe.join_probe_settings import (
    MK_PROBE_BATCH_DEFAULT,
    mk_probe_batch_width,
    mk_probe_configure,
    reset_join_probe_settings,
)


comptime I64 = DType.int64

comptime _ENC: Int = 1_000_000



def _set_width(w: Int) raises:
    """Width 0 selects the row-at-a-time walk."""
    mk_probe_configure(batch_width=w if w > 0 else 0)


def _widths() -> List[Int]:
    var w = List[Int]()
    w.append(0)  # the row-at-a-time walk
    w.append(1)  # one row per batch
    w.append(2)
    w.append(3)
    w.append(7)  # 2/3/7 put a batch boundary MID-CHAIN on the deep fixtures
    w.append(64)
    return w^


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
    var enc = _bf_inner(build, probe)
    var pmatched = _bf_probe_matched(build, probe)
    for p in range(len(pmatched)):
        if not pmatched[p]:
            enc.append(0 * _ENC + (p + 1))
    return _sorted(enc^)


def _bf_right(
    imm build: List[List[Int64]], imm probe: List[List[Int64]]
) -> List[Int]:
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
    elif name == "deep_chain_300":
        var d0 = List[Int64]()
        for _ in range(300):
            d0.append(Int64(11))
        b.append(d0^)
        var dp = List[Int64]()
        for i in range(20):
            dp.append(Int64(11) if i % 2 == 0 else Int64(999))
        p.append(dp^)
    elif name == "bloom_reject_heavy":
        var br_b0 = List[Int64]()
        for i in range(64):
            br_b0.append(Int64(i))
        b.append(br_b0^)
        var br_p0 = List[Int64]()
        for i in range(50):
            br_p0.append(Int64(1_000_000 + i))
        p.append(br_p0^)
    elif name == "null_only_probe":
        var no_b0: List[Int64] = [1, 2, 3, 4]
        var no_p0: List[Int64] = [_S, _S, _S, _S, _S]
        b.append(no_b0^)
        p.append(no_p0^)
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
    n.append(String("deep_chain_300"))
    n.append(String("bloom_reject_heavy"))
    n.append(String("null_only_probe"))
    return n^


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    """A small mock runtime. BACKEND_MOCK avoids per-worker epoll fds; the
    probe dispatch uses only the worker-pool fan-out.
    """
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def test_batched_inner_matches_brute_force_at_every_width() raises:
    """The parallel INNER pairs equal brute force at every width."""
    var rt = _runtime()
    ref dispatcher = rt.dispatcher()
    var names = _fixture_names()
    var widths = _widths()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var expect = _bf_inner(build, probe)
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))
        for wi in range(len(widths)):
            var w = widths[wi]
            _set_width(w)
            var pkc = _mk_columns(probe)
            var bm = List[Int]()
            var pm = List[Int]()
            parallel_multi_key_inner_probe_into(
                dispatcher, CancellationToken.never(), builder, pkc, bm, pm
            )
            _assert_lists_equal(
                _encode(bm^, pm^),
                expect,
                name + " parallel INNER batch=" + String(w),
            )
            _ = pkc^
        _ = builder^
    reset_join_probe_settings()
    print("test_batched_inner_matches_brute_force_at_every_width OK")


def test_pairing_keys_are_equal_at_every_width() raises:
    """Every emitted pair has equal keys, at every width."""
    var rt = _runtime()
    ref dispatcher = rt.dispatcher()
    var names = _fixture_names()
    var widths = _widths()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var nb = len(build[0])
        var npr = len(probe[0])
        var n_keys = len(build)
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))
        for wi in range(len(widths)):
            var w = widths[wi]
            _set_width(w)
            var pkc = _mk_columns(probe)
            var bm = List[Int]()
            var pm = List[Int]()
            parallel_multi_key_inner_probe_into(
                dispatcher, CancellationToken.never(), builder, pkc, bm, pm
            )
            var tag = name + " batch=" + String(w)
            assert_equal(len(bm), len(pm), tag + " paired lengths")
            for r in range(len(bm)):
                var bi = bm[r]
                var pi = pm[r]
                assert_true(
                    bi >= 0 and bi < nb,
                    tag + " build index out of range: " + String(bi),
                )
                assert_true(
                    pi >= 0 and pi < npr,
                    tag + " probe index out of range: " + String(pi),
                )
                for k in range(n_keys):
                    assert_equal(
                        build[k][bi],
                        probe[k][pi],
                        tag + " key " + String(k) + " mismatch at pair "
                        + String(r),
                    )
            _ = pkc^
        _ = builder^
    reset_join_probe_settings()
    print("test_pairing_keys_are_equal_at_every_width OK")


def test_all_six_arms_unmoved_at_every_width() raises:
    """The serial probes answer brute force whatever the width setting."""
    var names = _fixture_names()
    var widths = _widths()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var e_inner = _bf_inner(build, probe)
        var e_left = _bf_left(build, probe)
        var e_right = _bf_right(build, probe)
        var e_full = _bf_full(build, probe)
        var e_semi = _bf_semi(build, probe)
        var e_anti = _bf_anti(build, probe)
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))
        for wi in range(len(widths)):
            var w = widths[wi]
            _set_width(w)
            var tag = name + " batch=" + String(w) + " "

            var bm = List[Int]()
            var pm = List[Int]()
            builder.probe_inner_into(_mk_columns(probe), bm, pm)
            _assert_lists_equal(_encode(bm^, pm^), e_inner, tag + "INNER")

            var lbm = List[Int]()
            var lpm = List[Int]()
            builder.probe_left_into(_mk_columns(probe), lbm, lpm)
            _assert_lists_equal(_encode(lbm^, lpm^), e_left, tag + "LEFT")

            var rbm = List[Int]()
            var rpm = List[Int]()
            multi_key_probe_right_into(builder, _mk_columns(probe), rbm, rpm)
            _assert_lists_equal(_encode(rbm^, rpm^), e_right, tag + "RIGHT")

            var fbm = List[Int]()
            var fpm = List[Int]()
            multi_key_probe_full_into(builder, _mk_columns(probe), fbm, fpm)
            _assert_lists_equal(_encode(fbm^, fpm^), e_full, tag + "FULL")

            var semi = multi_key_probe_semi(builder, _mk_columns(probe))
            _assert_lists_equal(_sorted(semi^), e_semi, tag + "SEMI")

            var anti = multi_key_probe_anti(builder, _mk_columns(probe))
            _assert_lists_equal(_sorted(anti^), e_anti, tag + "ANTI")
        _ = builder^
    reset_join_probe_settings()
    print("test_all_six_arms_unmoved_at_every_width OK")


def test_semi_anti_partition_probe_rows_at_every_width() raises:
    """SEMI and ANTI partition the probe rows, each row once."""
    var names = _fixture_names()
    var widths = _widths()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var npr = len(probe[0])
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))
        for wi in range(len(widths)):
            var w = widths[wi]
            _set_width(w)
            var tag = name + " batch=" + String(w) + " "
            var semi = _sorted(multi_key_probe_semi(builder, _mk_columns(probe)))
            var anti = _sorted(multi_key_probe_anti(builder, _mk_columns(probe)))

            for j in range(1, len(semi)):
                assert_true(
                    semi[j] > semi[j - 1],
                    tag + "SEMI emitted probe row " + String(semi[j]) + " twice",
                )
            for j in range(1, len(anti)):
                assert_true(
                    anti[j] > anti[j - 1],
                    tag + "ANTI emitted probe row " + String(anti[j]) + " twice",
                )

            var seen = List[Int]()
            for _ in range(npr):
                seen.append(0)
            for j in range(len(semi)):
                seen[semi[j]] += 1
            for j in range(len(anti)):
                seen[anti[j]] += 1
            for r in range(npr):
                assert_equal(
                    seen[r],
                    1,
                    tag + "probe row " + String(r)
                    + " is in " + String(seen[r]) + " of {SEMI, ANTI}",
                )
        _ = builder^
    reset_join_probe_settings()
    print("test_semi_anti_partition_probe_rows_at_every_width OK")


def test_batched_widths_agree_with_row_major_arm() raises:
    """Every batched width agrees with the row-at-a-time walk."""
    var rt = _runtime()
    ref dispatcher = rt.dispatcher()
    var names = _fixture_names()
    var widths = _widths()
    for i in range(len(names)):
        var name = names[i]
        var fx = _fixture(name)
        ref build = fx[0]
        ref probe = fx[1]
        var builder = MultiKeyHashJoinBuilder.build(_mk_columns(build))

        _set_width(0)
        var base_pkc = _mk_columns(probe)
        var base_b = List[Int]()
        var base_p = List[Int]()
        parallel_multi_key_inner_probe_into(
            dispatcher, CancellationToken.never(), builder, base_pkc,
            base_b, base_p,
        )
        var base = _encode(base_b^, base_p^)
        _ = base_pkc^

        for wi in range(len(widths)):
            var w = widths[wi]
            if w == 0:
                continue
            _set_width(w)
            var pkc = _mk_columns(probe)
            var bm = List[Int]()
            var pm = List[Int]()
            parallel_multi_key_inner_probe_into(
                dispatcher, CancellationToken.never(), builder, pkc, bm, pm
            )
            _assert_lists_equal(
                _encode(bm^, pm^),
                base,
                name + " batched(" + String(w) + ") vs row-major arm",
            )
            _ = pkc^
        _ = builder^
    reset_join_probe_settings()
    print("test_batched_widths_agree_with_row_major_arm OK")


def test_unset_selects_the_batched_default_not_the_row_major_arm() raises:
    """Unconfigured is the shipped batched width; an explicit 0 is the
    row-at-a-time walk; a negative width is refused."""
    reset_join_probe_settings()
    assert_equal(mk_probe_batch_width(), MK_PROBE_BATCH_DEFAULT)
    mk_probe_configure(batch_width=0)
    assert_equal(mk_probe_batch_width(), 0)
    mk_probe_configure(batch_width=64)
    assert_equal(mk_probe_batch_width(), 64)
    var refused = False
    try:
        mk_probe_configure(batch_width=-1)
    except:
        refused = True
    assert_true(refused, "a negative width must be refused")
    reset_join_probe_settings()


def main() raises:
    var suite = TestSuite()
    suite.test[test_unset_selects_the_batched_default_not_the_row_major_arm]()
    suite.test[test_batched_inner_matches_brute_force_at_every_width]()
    suite.test[test_pairing_keys_are_equal_at_every_width]()
    suite.test[test_all_six_arms_unmoved_at_every_width]()
    suite.test[test_semi_anti_partition_probe_rows_at_every_width]()
    suite.test[test_batched_widths_agree_with_row_major_arm]()
    suite^.run()
