# =============================================================================
# test_search_ff_wide_min.mojo
#   A numeric/date fast-field whose smallest value is far from zero: the
#   frame-of-reference base is stored zig-zag + ULEB128 and must round-trip.
# =============================================================================
#
# Defect caught: the base was zig-zagged into a signed Int, so a magnitude of
# 2^62 or more (a TIMESTAMP_NS cell for any date after the year 2116, or a
# value near Int64 min/max) came out negative, and the unsigned varint writer
# looped forever appending bytes until the process ran out of memory. Each case
# arms a SIGALRM watchdog, so that defect ends the process in seconds instead of
# hanging the build, and also asserts the encoded size is small.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType

from komira_search.analyzer import (
    AnalyzedField,
    Token,
    FIELD_CLASS_NUMERIC,
)
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import SplitView, serialize_split, DocStoreBuilder
from komira_search.fast_fields import (
    FastFieldReader,
    FastFieldSpec,
    NumericFastFieldBuilder,
    KeywordFastFieldBuilder,
    serialize_fastfields_region,
)

comptime _WATCHDOG_S = 60
comptime _MAX_I64: Int = 9223372036854775807
comptime _MIN_I64: Int = -9223372036854775807 - 1


def _fieldnorm(n: Int) -> NumericFastFieldBuilder:
    var fnb = NumericFastFieldBuilder(ArrowType.INT64.type_id, DType.int64)
    for _ in range(n):
        fnb.append_int(1, False)
    return fnb^


def _ff_region(at: ArrowType, values: List[Int]) raises -> List[UInt8]:
    var specs = List[FastFieldSpec]()
    specs.append(
        FastFieldSpec(
            String("f"), 2, FIELD_CLASS_NUMERIC, at.type_id, DType.int64
        )
    )
    var nb = NumericFastFieldBuilder(at.type_id, DType.int64)
    for i in range(len(values)):
        nb.append_int(values[i], False)
    var nums = List[NumericFastFieldBuilder]()
    nums.append(nb^)
    return serialize_fastfields_region(
        specs, nums, List[KeywordFastFieldBuilder](), _fieldnorm(len(values))
    )


def _split(var ff: List[UInt8], n: Int) raises -> List[UInt8]:
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder(compress=False)
    for d in range(n):
        var toks = List[Token]()
        toks.append(Token(String("w"), 0))
        b.add_document(d, AnalyzedField(toks^))
        ds.append(String("d").as_bytes())
    var fi = b.finalize()
    var uuid = InlineArray[UInt8, 16](fill=UInt8(3))
    return serialize_split(
        fi,
        TermDictBuilder.build_from_finalized(fi),
        ds,
        String("body"),
        uuid,
        0,
        n - 1,
        n,
        fastfields_region=ff^,
    )


def _round_trip(label: String, values: List[Int]) raises:
    _ = external_call["alarm", UInt32](UInt32(_WATCHDOG_S))
    var ff = _ff_region(ArrowType.TIMESTAMP_NS, values)
    _ = external_call["alarm", UInt32](UInt32(0))
    assert_true(
        len(ff) < 512,
        label + ": the encoded region is a few hundred bytes at most",
    )
    var bytes = _split(ff^, len(values))
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)
    for d in range(len(values)):
        var got = reader.fast_field_i64(view, String("f"), d)
        assert_true(Bool(got), label + ": cell present")
        assert_equal(
            Int(got.value()), values[d], label + ": cell " + String(d)
        )


def test_01_a_timestamp_past_the_year_2116_round_trips() raises:
    # 1788307200000 ms * 3 as nanoseconds: above 2^62, so zig-zag exceeds Int64.
    var v: List[Int] = [5364921600000000000, 5364921600000000000 + 7]
    _round_trip(String("1"), v)


def test_02_the_extreme_bases_round_trip() raises:
    _round_trip(String("2a max"), [_MAX_I64])
    _round_trip(String("2b min"), [_MIN_I64])
    _round_trip(String("2c near min"), [_MIN_I64 + 5, _MIN_I64])
    _round_trip(String("2d near max"), [_MAX_I64 - 3, _MAX_I64])
    _round_trip(String("2e just under 2^62"), [4611686018427387903, 4611686018427387904])
    _round_trip(String("2f just over -2^62"), [-4611686018427387905, -4611686018427387904])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
