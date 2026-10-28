# `mk_uniform_arm` and the uniform equality bodies: the arm resolution's
# precedence (same dictionary over string over integer), and fixtures built so
# a body that took the wrong arm answers wrong (an all-zero hash column, one
# repeated decoded string), through every probe kind and the parallel probe at
# several batch widths.

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
    MK_ARM_DICT,
    MK_ARM_INT,
    MK_ARM_MIXED,
    MK_ARM_STRING,
    MultiKeyColumns,
    mk_uniform_arm,
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
    mk_probe_configure,
    reset_join_probe_settings,
)


comptime I64 = DType.int64
comptime I32 = DType.int32
comptime _ENC: Int = 1_000_000


def _bools(imm v: List[Int]) -> List[Bool]:
    var out = List[Bool]()
    for i in range(len(v)):
        out.append(v[i] != 0)
    return out^


def _i64_arr(imm values: List[Int64]) -> PrimitiveArray[I64]:
    var arr = PrimitiveArray[I64].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return arr^


def _i32_arr(imm values: List[Int32]) -> PrimitiveArray[I32]:
    var arr = PrimitiveArray[I32].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return arr^


def _zeros(n: Int) -> List[Int64]:
    """The colliding hash column. See the header."""
    var v = List[Int64]()
    for _ in range(n):
        v.append(Int64(0))
    return v^


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


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _cols_string(
    imm hashes: List[Int64], imm values: List[String]
) raises -> MultiKeyColumns:
    """TWO STRING keys: `int_keys` = `hashes` (the caller's lie), side channel =
    `values` (the truth), the SAME column twice.
    """
    var ik = Slab[PrimitiveArray[I64]].create(2)
    var sk = Slab[Optional[StringArray[HeapRegion]]].create(2)
    var dk = Slab[Optional[StringDictionaryArray]].create(2)
    var fps = List[UInt64]()
    for _ in range(2):
        ik.append(_i64_arr(hashes))
        sk.append(Optional(StringArray.from_strings(values)))
        dk.append(Optional[StringDictionaryArray](None))
        fps.append(UInt64(0))
    return MultiKeyColumns(ik^, sk^, dk^, fps^, 2)


def _cols_dict(
    imm hashes: List[Int64],
    imm indices: List[Int32],
    imm decoded: List[String],
    imm dictionary: List[String],
    fingerprint: UInt64,
) raises -> MultiKeyColumns:
    """TWO DICT keys (the same column twice — see `_cols_string` for why one
    would leave the uniform-DICT body unreached). `dict_keys` carries the
    indices the same-dict arm must compare; `string_keys` carries the cross-dict
    fallback's decoded bytes, which this fixture makes deliberately UNIFORM so
    that a dispatch that falls to the STRING arm is loud rather than silent.
    """
    var ik = Slab[PrimitiveArray[I64]].create(2)
    var sk = Slab[Optional[StringArray[HeapRegion]]].create(2)
    var dk = Slab[Optional[StringDictionaryArray]].create(2)
    var fps = List[UInt64]()
    for _ in range(2):
        ik.append(_i64_arr(hashes))
        sk.append(Optional(StringArray.from_strings(decoded)))
        dk.append(
            Optional(
                StringDictionaryArray.from_parts(
                    _i32_arr(indices), StringArray.from_strings(dictionary)
                )
            )
        )
        fps.append(fingerprint)
    return MultiKeyColumns(ik^, sk^, dk^, fps^, 2)


def _cols_int_then_string(
    imm ints: List[Int64], imm hashes: List[Int64], imm values: List[String]
) raises -> MultiKeyColumns:
    """TWO keys: key0 a real INT64, key1 a STRING with a lying hash column. The
    vector is NOT uniform, so this exercises `MK_ARM_MIXED` — the arm that keeps
    the original three-way per-key body.
    """
    var ik = Slab[PrimitiveArray[I64]].create(2)
    var sk = Slab[Optional[StringArray[HeapRegion]]].create(2)
    var dk = Slab[Optional[StringDictionaryArray]].create(2)
    var fps = List[UInt64]()
    ik.append(_i64_arr(ints))
    sk.append(Optional[StringArray[HeapRegion]](None))
    dk.append(Optional[StringDictionaryArray](None))
    fps.append(UInt64(0))
    ik.append(_i64_arr(hashes))
    sk.append(Optional(StringArray.from_strings(values)))
    dk.append(Optional[StringDictionaryArray](None))
    fps.append(UInt64(0))
    return MultiKeyColumns(ik^, sk^, dk^, fps^, 2)


def test_uniform_arm_truth_table() raises:
    """`mk_uniform_arm` states which body the chain walk runs. Assert THAT, not
    only a consequence of it — a wrong classification that happens to agree on a
    given fixture is the failure this whole file is built around.
    """
    reset_join_probe_settings()
    assert_equal(
        mk_uniform_arm(_bools([0]), _bools([0]), 1), MK_ARM_MIXED, "1 int"
    )
    assert_equal(
        mk_uniform_arm(_bools([0]), _bools([1]), 1), MK_ARM_MIXED, "1 string"
    )
    assert_equal(
        mk_uniform_arm(_bools([1]), _bools([0]), 1), MK_ARM_MIXED, "1 dict"
    )
    assert_equal(
        mk_uniform_arm(_bools([1]), _bools([1]), 1), MK_ARM_MIXED, "1 both"
    )
    assert_equal(
        mk_uniform_arm(_bools([0]), _bools([0]), 0), MK_ARM_MIXED, "0 keys"
    )

    assert_equal(
        mk_uniform_arm(_bools([1, 1]), _bools([1, 1]), 2),
        MK_ARM_DICT,
        "same-dict must win over string, matching the general body's order",
    )

    assert_equal(
        mk_uniform_arm(_bools([0, 0]), _bools([0, 0]), 2), MK_ARM_INT, "2 int"
    )
    assert_equal(
        mk_uniform_arm(_bools([0, 0]), _bools([1, 1]), 2),
        MK_ARM_STRING,
        "2 string",
    )
    assert_equal(
        mk_uniform_arm(_bools([1, 1]), _bools([1, 1]), 2), MK_ARM_DICT, "2 dict"
    )

    assert_equal(
        mk_uniform_arm(_bools([0, 0]), _bools([1, 0]), 2),
        MK_ARM_MIXED,
        "string + int",
    )
    assert_equal(
        mk_uniform_arm(_bools([1, 0]), _bools([0, 0]), 2),
        MK_ARM_MIXED,
        "dict + int",
    )
    assert_equal(
        mk_uniform_arm(_bools([1, 0]), _bools([1, 1]), 2),
        MK_ARM_MIXED,
        "dict + string",
    )

    assert_equal(
        mk_uniform_arm(_bools([0, 0, 0]), _bools([1, 0, 1]), 3),
        MK_ARM_MIXED,
        "string, int, string",
    )
    assert_equal(
        mk_uniform_arm(_bools([0, 0, 0]), _bools([1, 1, 1]), 3),
        MK_ARM_STRING,
        "3 string",
    )

    assert_equal(
        mk_uniform_arm(_bools([0, 0, 0, 1]), _bools([1, 1, 1, 1]), 3),
        MK_ARM_STRING,
        "n_keys=3 must ignore key 3",
    )
    print("test_uniform_arm_truth_table OK")


def _string_fixture() raises -> Tuple[List[String], List[String]]:
    var build = List[String]()
    build.append(String("alpha"))
    build.append(String("beta"))
    build.append(String("alpha"))
    build.append(String("gamma"))
    var probe = List[String]()
    probe.append(String("beta"))
    probe.append(String("delta"))
    probe.append(String("alpha"))
    return (build^, probe^)


def _bf_string_inner(
    imm build: List[String], imm probe: List[String]
) -> List[Int]:
    var enc = List[Int]()
    for p in range(len(probe)):
        for b in range(len(build)):
            if build[b] == probe[p]:
                enc.append((b + 1) * _ENC + (p + 1))
    return _sorted(enc^)


def test_string_arm_compares_bytes_not_the_hash_column() raises:
    """`int_keys` is all zeros, so every build row is a
    candidate for every probe row and the hash can decide nothing. Only a body
    that actually calls `_string_bytes_equal` produces the nested-loop answer;
    the INT64 body produces the full 4x3 cross product.
    """
    reset_join_probe_settings()
    var fx = _string_fixture()
    ref build = fx[0]
    ref probe = fx[1]
    var expect = _bf_string_inner(build, probe)
    assert_true(
        len(expect) < len(build) * len(probe),
        "fixture must NOT be a full cross product, or the leg is vacuous",
    )

    var rt = _runtime()
    ref dispatcher = rt.dispatcher()
    var builder = MultiKeyHashJoinBuilder.build(
        _cols_string(_zeros(len(build)), build)
    )

    var widths = List[Int]()
    widths.append(0)  # explicit row-major arm
    widths.append(1)
    widths.append(64)
    for wi in range(len(widths)):
        mk_probe_configure(batch_width=widths[wi])
        var tag = String("string batch=") + String(widths[wi]) + " "

        var bm = List[Int]()
        var pm = List[Int]()
        builder.probe_inner_into(_cols_string(_zeros(len(probe)), probe), bm, pm)
        _assert_lists_equal(_encode(bm^, pm^), expect, tag + "serial INNER")

        var pkc = _cols_string(_zeros(len(probe)), probe)
        var qbm = List[Int]()
        var qpm = List[Int]()
        parallel_multi_key_inner_probe_into(
            dispatcher, CancellationToken.never(), builder, pkc, qbm, qpm
        )
        _assert_lists_equal(_encode(qbm^, qpm^), expect, tag + "parallel INNER")
        _ = pkc^

        var rbm = List[Int]()
        var rpm = List[Int]()
        multi_key_probe_right_into(
            builder, _cols_string(_zeros(len(probe)), probe), rbm, rpm
        )
        var r_matched = 0
        for i in range(len(rbm)):
            if rpm[i] >= 0:
                r_matched += 1
        assert_equal(r_matched, len(expect), tag + "RIGHT matched-pair count")

        var fbm = List[Int]()
        var fpm = List[Int]()
        multi_key_probe_full_into(
            builder, _cols_string(_zeros(len(probe)), probe), fbm, fpm
        )
        var f_matched = 0
        for i in range(len(fbm)):
            if fpm[i] >= 0 and fbm[i] >= 0:
                f_matched += 1
        assert_equal(f_matched, len(expect), tag + "FULL matched-pair count")

        var lbm = List[Int]()
        var lpm = List[Int]()
        builder.probe_left_into(
            _cols_string(_zeros(len(probe)), probe), lbm, lpm
        )
        var l_matched = 0
        for i in range(len(lbm)):
            if lbm[i] >= 0:
                l_matched += 1
        assert_equal(l_matched, len(expect), tag + "LEFT matched-pair count")

        var semi = multi_key_probe_semi(
            builder, _cols_string(_zeros(len(probe)), probe)
        )
        assert_equal(len(semi), 2, tag + "SEMI")
        var anti = multi_key_probe_anti(
            builder, _cols_string(_zeros(len(probe)), probe)
        )
        assert_equal(len(anti), 1, tag + "ANTI")
        _ = semi^
        _ = anti^
    _ = builder^
    reset_join_probe_settings()
    print("test_string_arm_compares_bytes_not_the_hash_column OK")


def test_dict_arm_compares_indices_not_hash_and_not_bytes() raises:
    """The same-dict arm's contract is `Int32 ==` on dictionary INDICES. This
    fixture makes both other arms wrong and loud: the hash column is all zeros
    (the INT64 arm would match everything) and the decoded side channel is one
    repeated string (the STRING arm would also match everything).
    """
    reset_join_probe_settings()
    var dictionary = List[String]()
    dictionary.append(String("A"))
    dictionary.append(String("B"))
    dictionary.append(String("C"))

    var b_idx = List[Int32]()
    b_idx.append(Int32(0))
    b_idx.append(Int32(1))
    b_idx.append(Int32(0))
    var p_idx = List[Int32]()
    p_idx.append(Int32(1))
    p_idx.append(Int32(2))
    p_idx.append(Int32(0))

    def _same(n: Int) -> List[String]:
        var v = List[String]()
        for _ in range(n):
            v.append(String("SAME"))
        return v^

    var expect = List[Int]()
    expect.append((1 + 1) * _ENC + (0 + 1))
    expect.append((0 + 1) * _ENC + (2 + 1))
    expect.append((2 + 1) * _ENC + (2 + 1))
    expect = _sorted(expect^)

    comptime FP: UInt64 = 0xD1C7_D1C7_D1C7_D1C7
    var builder = MultiKeyHashJoinBuilder.build(
        _cols_dict(_zeros(3), b_idx, _same(3), dictionary, FP)
    )
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(
        _cols_dict(_zeros(3), p_idx, _same(3), dictionary, FP), bm, pm
    )
    _assert_lists_equal(_encode(bm^, pm^), expect, "dict INNER")

    var rt = _runtime()
    ref dispatcher = rt.dispatcher()
    var pkc = _cols_dict(_zeros(3), p_idx, _same(3), dictionary, FP)
    var qbm = List[Int]()
    var qpm = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, pkc, qbm, qpm
    )
    _assert_lists_equal(_encode(qbm^, qpm^), expect, "dict parallel INNER")
    _ = pkc^

    var xbm = List[Int]()
    var xpm = List[Int]()
    builder.probe_inner_into(
        _cols_dict(_zeros(3), p_idx, _same(3), dictionary, UInt64(1)), xbm, xpm
    )
    assert_equal(
        len(xbm),
        9,
        "a fingerprint mismatch must fall to bytes, which this fixture makes"
        " match every pair — if it does not, the leg above proved nothing",
    )
    _ = xbm^
    _ = xpm^
    _ = builder^
    print("test_dict_arm_compares_indices_not_hash_and_not_bytes OK")


def test_mixed_vector_still_compares_every_key() raises:
    """A non-uniform vector (INT64 + STRING) must keep the original three-arm
    body. The INT64 half carries real, distinct values and the STRING half a
    lying hash, so dropping EITHER key from the compare over-matches.
    """
    reset_join_probe_settings()
    var b_int = List[Int64]()
    b_int.append(Int64(7))
    b_int.append(Int64(7))
    b_int.append(Int64(9))
    var b_str = List[String]()
    b_str.append(String("x"))
    b_str.append(String("y"))
    b_str.append(String("x"))

    var p_int = List[Int64]()
    p_int.append(Int64(7))
    p_int.append(Int64(9))
    p_int.append(Int64(9))
    var p_str = List[String]()
    p_str.append(String("y"))
    p_str.append(String("x"))
    p_str.append(String("y"))

    var expect = List[Int]()
    expect.append((1 + 1) * _ENC + (0 + 1))
    expect.append((2 + 1) * _ENC + (1 + 1))
    expect = _sorted(expect^)

    var builder = MultiKeyHashJoinBuilder.build(
        _cols_int_then_string(b_int, _zeros(3), b_str)
    )
    assert_equal(builder.num_keys(), 2, "fixture must be 2-key")

    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(
        _cols_int_then_string(p_int, _zeros(3), p_str), bm, pm
    )
    _assert_lists_equal(_encode(bm^, pm^), expect, "mixed INNER")

    var rt = _runtime()
    ref dispatcher = rt.dispatcher()
    var pkc = _cols_int_then_string(p_int, _zeros(3), p_str)
    var qbm = List[Int]()
    var qpm = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, pkc, qbm, qpm
    )
    _assert_lists_equal(_encode(qbm^, qpm^), expect, "mixed parallel INNER")
    _ = pkc^
    _ = builder^
    print("test_mixed_vector_still_compares_every_key OK")


def main() raises:
    var suite = TestSuite()
    suite.test[test_uniform_arm_truth_table]()
    suite.test[test_string_arm_compares_bytes_not_the_hash_column]()
    suite.test[test_dict_arm_compares_indices_not_hash_and_not_bytes]()
    suite.test[test_mixed_vector_still_compares_every_key]()
    suite^.run()
