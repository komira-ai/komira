# =============================================================================
# test_orc_arrow_write_primitive_null_drop.mojo
#   nullable primitive columns keep their nulls through the writers
# =============================================================================
#
# Silent-corruption guard. A nullable fixed-width PRIMITIVE column
# (INT64 / FLOAT64) built via `allocate_nullable` + `_set_null` must reach the
# ORC / arrow_ipc writers with a correct `null_count`: both writers gate
# validity emission on `null_count != 0` (ORC PRESENT-stream emit / arrow IPC
# validity-buffer emit), so a `_set_null` that cleared the validity BIT
# without bumping `null_count` would drop the nulls silently and read them
# back as 0 / -0.0. STRING + BOOL builders maintain `null_count` themselves.
#
# This test FAILS if `PrimitiveArray._set_null` does not increment
# `null_count` (nulls drop => is_null False at the null rows), for BOTH the
# ORC writer (write_orc_bytes -> read_orc_bytes) and the arrow IPC
# RecordBatch encoder (encode_record_batch_message ->
# decode_record_batch_message — the SAME validity-buffer emit pyarrow reads).
#
# It deliberately uses the LOW-LEVEL writer-bytes entry points (komira_orc +
# komira_core only), not the SDK.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    write_orc_file,
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)

from komira_core.arrow.ipc_encoder_dispatch import encode_record_batch_message
from komira_core.arrow.ipc_decoder_dispatch import decode_record_batch_message
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. Two runs of the same test may
# execute at once on one machine, and a fixed `/tmp` path is shared by every
# one of them. The test runner makes `TEST_TMPDIR` private to each run;
# `komira_runtime_paths.test_tmpdir` is the one helper that reads it (and
# raises when it is unset rather than falling back to a shared directory).
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# Nulls at rows 2 and 6 in a 7-row dataset; built with allocate_nullable +
# _set_null and NO manual null_count stamp (the usual producer shape).
def _make_i64() raises -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(7)
    a.set(0, Int64.MIN)
    a.set(1, Int64(-1))
    a._set_null(2)
    a.set(3, Int64(0))
    a.set(4, Int64(1))
    a.set(5, Int64.MAX)
    a._set_null(6)
    # The fix => producer-side null_count is correct WITHOUT a manual stamp.
    assert_equal(a.null_count, 2)
    return a^


def _make_f64() raises -> PrimitiveArray[DType.float64]:
    var d = PrimitiveArray[DType.float64].allocate_nullable(7)
    d.set(0, Float64(-1.5))
    d.set(1, Float64(-0.25))
    d._set_null(2)
    d.set(3, Float64(0.0))
    d.set(4, Float64(3.14159))
    d.set(5, Float64(2.5))
    d._set_null(6)
    assert_equal(d.null_count, 2)
    return d^


def _assert_i64_nulls(a: PrimitiveArray[DType.int64], label: String) raises:
    assert_true(not a.is_null(0), label + ": i64[0] valid")
    assert_equal(a.get(0), Int64.MIN, label + ": i64[0]=MIN")
    assert_equal(a.get(1), Int64(-1), label + ": i64[1]=-1")
    assert_true(a.is_null(2), label + ": i64[2] NULL")
    assert_equal(a.get(3), Int64(0), label + ": i64[3]=0")
    assert_equal(a.get(4), Int64(1), label + ": i64[4]=1")
    assert_equal(a.get(5), Int64.MAX, label + ": i64[5]=MAX")
    assert_true(a.is_null(6), label + ": i64[6] NULL")


def _assert_f64_nulls(d: PrimitiveArray[DType.float64], label: String) raises:
    assert_true(not d.is_null(0), label + ": f64[0] valid")
    assert_true(d.get(0) == Float64(-1.5), label + ": f64[0]=-1.5")
    assert_true(d.is_null(2), label + ": f64[2] NULL")
    assert_true(d.get(4) == Float64(3.14159), label + ": f64[4]=3.14159")
    assert_true(d.is_null(6), label + ": f64[6] NULL")


def _orc_check(codec: Int, label: String) raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](_make_i64()))
    rbb.add_column(Column.from_primitive[DType.float64](_make_f64()))
    var rb = rbb.build(sb.build())

    var opts = OrcWriterOptions(codec, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), 7, label + ": 7 rows")
    _assert_i64_nulls(back.column_as_primitive_int64(0), label)
    _assert_f64_nulls(back.column_as_primitive_float64(1), label)

    # Persist a complete ORC file (exercises the file-writing entry point).
    var path = (_scratch_dir() + String("/komira_orc_primnull_")) + label + ".orc"
    write_orc_file(rb, path, opts)


def test_orc_write_primitive_nulls_none() raises:
    _orc_check(ORC_COMPRESSION_NONE, "orc-none")


def test_orc_write_primitive_nulls_zstd() raises:
    _orc_check(ORC_COMPRESSION_ZSTD, "orc-zstd")


def test_arrow_ipc_write_primitive_nulls() raises:
    """The arrow IPC RecordBatch encoder emits the validity buffer (Buffer 0)
    exactly as pyarrow reads it; round-trip via decode preserves nulls."""
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](_make_i64()))
    cols.append(Column.from_primitive[DType.float64](_make_f64()))

    var frame = encode_record_batch_message(cols^)
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.FLOAT64]
    var back = decode_record_batch_message(frame^, types)
    assert_equal(len(back), 2, "arrow: 2 columns")
    _assert_i64_nulls(back[0].as_primitive[DType.int64](), "arrow")
    _assert_f64_nulls(back[1].as_primitive[DType.float64](), "arrow")


def main() raises:
    var suite = TestSuite()
    suite.test[test_orc_write_primitive_nulls_none]()
    suite.test[test_orc_write_primitive_nulls_zstd]()
    suite.test[test_arrow_ipc_write_primitive_nulls]()
    suite^.run()
