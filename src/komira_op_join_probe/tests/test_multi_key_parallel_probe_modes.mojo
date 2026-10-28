# The parallel composite INNER probe in every walk and every key arm, against
# the serial probe on the same data. Each join runs with the batched walk at
# its default width, at widths 1, 2 and 3 (the batch refills many times per
# morsel), with the row-at-a-time walk (width 0), and with the retile on; all
# of them must return the serial probe's pairs.
#
# The data puts rows that share a first key but differ in a later key onto the
# same hash chain (a small key domain against a table sized to the build), so
# an equality that stopped at the first key would return extra pairs. Build keys
# repeat, so a chain holds several true matches and the batched walk takes
# several rounds. NULL keys sit on both sides.
#
# Every join also runs with the bloom latch disarmed after one row, so rows the
# bloom would reject reach their chains.
#
# The bloom latch runs armed to disarm and armed to keep: the pairs do not
# change when the latch stops consulting the bloom.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken

from komira_op_join_build.join_bloom_selectivity import (
    bloomsel_configure,
    bloomsel_disarmed_count,
    bloomsel_reset_config,
    bloomsel_saved_checks,
    reset_bloomsel_counters,
)
from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
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

comptime _N_BUILD: Int = 2_000
comptime _N_PROBE: Int = 3_000
comptime _MORSEL: Int = 401


def _test_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _test_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_test_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _sorted_pairs(b: List[Int], p: List[Int]) -> List[Tuple[Int, Int]]:
    var n = len(b)
    var pairs = List[Tuple[Int, Int]](capacity=n)
    for i in range(n):
        pairs.append((b[i], p[i]))
    for i in range(1, n):
        var key = pairs[i]
        var j = i - 1
        while j >= 0:
            var cur = pairs[j]
            if cur[0] < key[0] or (cur[0] == key[0] and cur[1] <= key[1]):
                break
            pairs[j + 1] = cur
            j -= 1
        pairs[j + 1] = key
    return pairs^


def _assert_same_pairs(
    a_b: List[Int], a_p: List[Int], b_b: List[Int], b_p: List[Int]
) raises:
    assert_equal(len(a_b), len(a_p))
    assert_equal(len(b_b), len(b_p))
    assert_equal(len(a_b), len(b_b))
    var sa = _sorted_pairs(a_b, a_p)
    var sb = _sorted_pairs(b_b, b_p)
    for i in range(len(sa)):
        assert_equal(sa[i][0], sb[i][0])
        assert_equal(sa[i][1], sb[i][1])


def _int_col(
    n: Int, k0_mod: Int, mul: Int, k1_mod: Int, null_every: Int, which: Int
) raises -> Column[HeapRegion]:
    """INT64 column. `which` 0 is `i % k0_mod`; 1 is `(i * mul) % k1_mod`.
    Every `null_every`-th row is NULL (0 = none).
    """
    var arr = PrimitiveArray[I64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        var v = i % k0_mod if which == 0 else (i * mul) % k1_mod
        p.store[width=1](i, Int64(v))
        if null_every > 0 and i % null_every == 0:
            arr._set_null(i)
    return Column.from_primitive(arr^)


def _str_col(
    n: Int, prefix: String, mul: Int, modulus: Int
) raises -> Column[HeapRegion]:
    var vals = List[String](capacity=n)
    for i in range(n):
        vals.append(prefix + String((i * mul) % modulus))
    return Column.from_string(StringArray.from_strings(vals))


def _dict_col(
    n: Int, prefix: String, mul: Int, modulus: Int, dict_size: Int
) raises -> Column[HeapRegion]:
    var strs = List[String](capacity=dict_size)
    for i in range(dict_size):
        strs.append(prefix + String(i))
    var dict_arr = StringArray.from_strings(strs)
    var idx = PrimitiveArray[DType.int32].allocate(n)
    var ip = idx._typed_ptr_mut()
    for i in range(n):
        (ip + i)[] = Scalar[DType.int32](Int32((i * mul) % modulus))
    return Column.from_dictionary(
        StringDictionaryArray.from_parts(idx^, dict_arr^)
    )


def _batch(
    n0: String, t0: ArrowType, var c0: Column[HeapRegion],
    n1: String, t1: ArrowType, var c1: Column[HeapRegion],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(n0, t0, True))
    sb.add_field(Field(n1, t1, True))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(c0^)
    bldr.add_column(c1^)
    return bldr.build(schema^)


def _check_every_mode(build: RecordBatch, probe: RecordBatch) raises:
    """Serial pairs against the parallel probe in each walk configuration."""
    var bk = extract_join_key_columns_serial(build, ["k0", "k1"])
    var pk = extract_join_key_columns_serial(probe, ["k0", "k1"])
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    var seq_b = List[Int]()
    var seq_p = List[Int]()
    builder.probe_inner_into(pk, seq_b, seq_p)
    assert_true(len(seq_b) > 0)

    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()
    var widths: List[Int] = [512, 0, 1, 2, 3]
    # Pass 0 leaves the bloom as built. Pass 1 disarms it after each worker's
    # first row, so the rows the bloom would have rejected walk their chains and
    # the later-key equality decides them.
    for bypass in range(2):
        if bypass == 1:
            bloomsel_configure(window_rows=1, pass_pct=1)
        for w in range(len(widths)):
            mk_probe_configure(batch_width=widths[w], morsel_rows=_MORSEL)
            var par_b = List[Int]()
            var par_p = List[Int]()
            parallel_multi_key_inner_probe_into(
                dispatcher, CancellationToken.never(), builder, pk, par_b, par_p
            )
            _assert_same_pairs(seq_b, seq_p, par_b, par_p)
    bloomsel_reset_config()
    mk_probe_configure(batch_width=3, retile=True)
    var rt_b = List[Int]()
    var rt_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, pk, rt_b, rt_p
    )
    _assert_same_pairs(seq_b, seq_p, rt_b, rt_p)
    reset_join_probe_settings()
    reset_bloomsel_counters()


def _int_build() raises -> RecordBatch:
    return _batch(
        "k0", ArrowType.INT64, _int_col(_N_BUILD, 7, 1, 250, 31, 0),
        "k1", ArrowType.INT64, _int_col(_N_BUILD, 7, 1, 250, 0, 1),
    )


def _int_probe() raises -> RecordBatch:
    return _batch(
        "k0", ArrowType.INT64, _int_col(_N_PROBE, 7, 1, 500, 17, 0),
        "k1", ArrowType.INT64, _int_col(_N_PROBE, 7, 3, 500, 13, 1),
    )


def test_int_keys_every_walk_matches_serial() raises:
    """Two INT64 keys with repeated build keys, key-0 collisions and NULLs:
    every walk width, the row walk and the retile return the serial pairs; a
    later-key mismatch inside one chain is not a match.
    """
    _check_every_mode(_int_build(), _int_probe())


def test_string_keys_every_walk_matches_serial() raises:
    """Two STRING keys: the byte-equality arm in every walk."""
    var build = _batch(
        "k0", ArrowType.STRING, _str_col(_N_BUILD, "a", 1, 7),
        "k1", ArrowType.STRING, _str_col(_N_BUILD, "b", 1, 250),
    )
    var probe = _batch(
        "k0", ArrowType.STRING, _str_col(_N_PROBE, "a", 1, 7),
        "k1", ArrowType.STRING, _str_col(_N_PROBE, "b", 3, 500),
    )
    _check_every_mode(build, probe)


def test_int_and_string_keys_every_walk_matches_serial() raises:
    """An INT64 key with a STRING key: the mixed arm in every walk."""
    var build = _batch(
        "k0", ArrowType.INT64, _int_col(_N_BUILD, 7, 1, 250, 31, 0),
        "k1", ArrowType.STRING, _str_col(_N_BUILD, "b", 1, 250),
    )
    var probe = _batch(
        "k0", ArrowType.INT64, _int_col(_N_PROBE, 7, 1, 500, 17, 0),
        "k1", ArrowType.STRING, _str_col(_N_PROBE, "b", 3, 500),
    )
    _check_every_mode(build, probe)


def test_same_dictionary_keys_every_walk_matches_serial() raises:
    """Two keys that share one dictionary each across the sides: the dictionary
    index arm in every walk.
    """
    var n_build = 700
    var build = _batch(
        "k0", ArrowType.DICTIONARY, _dict_col(n_build, "x", 1, 7, 7),
        "k1", ArrowType.DICTIONARY, _dict_col(n_build, "y", 1, 50, 70),
    )
    var probe = _batch(
        "k0", ArrowType.DICTIONARY, _dict_col(_N_PROBE, "x", 1, 7, 7),
        "k1", ArrowType.DICTIONARY, _dict_col(_N_PROBE, "y", 3, 70, 70),
    )
    _check_every_mode(build, probe)


def _bloom_case(pass_pct: Int) raises:
    var bk = extract_join_key_columns_serial(_int_build(), ["k0", "k1"])
    var pk = extract_join_key_columns_serial(_int_probe(), ["k0", "k1"])
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    var seq_b = List[Int]()
    var seq_p = List[Int]()
    builder.probe_inner_into(pk, seq_b, seq_p)
    assert_true(len(seq_b) > 0)

    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()
    var widths: List[Int] = [512, 0, 3]
    for w in range(len(widths)):
        reset_bloomsel_counters()
        bloomsel_configure(window_rows=32, pass_pct=pass_pct)
        mk_probe_configure(batch_width=widths[w], morsel_rows=_MORSEL)
        var par_b = List[Int]()
        var par_p = List[Int]()
        parallel_multi_key_inner_probe_into(
            dispatcher, CancellationToken.never(), builder, pk, par_b, par_p
        )
        _assert_same_pairs(seq_b, seq_p, par_b, par_p)
        if pass_pct == 1:
            # The bloom admits more than 1% of the sampled rows, so the
            # workers stop asking it, and the rows after the window skip it.
            assert_true(bloomsel_disarmed_count() > 0)
            assert_true(bloomsel_saved_checks() > 0)
    bloomsel_reset_config()
    reset_bloomsel_counters()
    reset_join_probe_settings()


def test_bloom_latch_disarmed_keeps_every_pair() raises:
    """The latch disarms after its window: pairs equal the serial probe."""
    _bloom_case(1)


def test_bloom_latch_kept_keeps_every_pair() raises:
    """The latch samples and keeps the bloom: pairs equal the serial probe."""
    _bloom_case(100)


def main() raises:
    var suite = TestSuite()
    suite.test[test_int_keys_every_walk_matches_serial]()
    suite.test[test_string_keys_every_walk_matches_serial]()
    suite.test[test_int_and_string_keys_every_walk_matches_serial]()
    suite.test[test_same_dictionary_keys_every_walk_matches_serial]()
    suite.test[test_bloom_latch_disarmed_keeps_every_pair]()
    suite.test[test_bloom_latch_kept_keeps_every_pair]()
    suite^.run()
