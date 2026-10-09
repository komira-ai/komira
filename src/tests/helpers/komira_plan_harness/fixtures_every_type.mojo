# =============================================================================
# komira_plan_harness/fixtures_every_type.mojo -- one batch of every type.
# =============================================================================
#
# Three rows, one column per type canon renders. Every column but the
# unions (which have no validity of their own) holds a NULL, and the value
# stored under it is a real, renderable value, so a renderer that ignores
# validity prints it. EVERY_TYPE_CELLS (in the tests) spells what
# canon must print for each cell.
# =============================================================================

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from .fixtures import (
    BatchBuilder,
    validity_of,
    all_valid,
    bool_column,
    bytes_column,
    decimal_column,
    fixed_column,
    ints,
    list_column,
    map_column,
    small_decimal,
    string_column,
    struct_column,
    union_column,
    utf8,
    varlen_column,
)


def _mid_null() -> List[Bool]:
    var v: List[Bool] = [True, False, True]
    return v^


def _int_col(t: ArrowType, width: Int, a: Int, b: Int) -> Column[HeapRegion]:
    var v: List[Int] = [a, 99, b]
    return fixed_column(t, width, ints(v), _mid_null())


def _u64s(a: UInt64, b: UInt64, c: UInt64) -> List[UInt64]:
    var v: List[UInt64] = [a, b, c]
    return v^


def _day_time(days: Int, ms: Int) -> UInt64:
    return UInt64(UInt32(Int32(days).cast[DType.uint32]())) | (
        UInt64(UInt32(Int32(ms).cast[DType.uint32]())) << 32
    )


def _mdn_into(mut res: List[UInt8], m: Int, d: Int, ns: Int):
    for v in [m, d]:
        var u = UInt32(Int32(v).cast[DType.uint32]())
        for k in range(4):
            res.append(UInt8((u >> UInt32(8 * k)) & 0xFF))
    var n = UInt64(Int64(ns).cast[DType.uint64]())
    for k in range(8):
        res.append(UInt8((n >> UInt64(8 * k)) & 0xFF))


def every_type_batch() raises -> RecordBatch:
    var bb = BatchBuilder()
    var mid = _mid_null()

    var bvals: List[Bool] = [True, True, False]
    bb.add(Field("b", ArrowType.BOOL, True), bool_column(bvals, mid))
    bb.add(Field("i8", ArrowType.INT8, True), _int_col(ArrowType.INT8, 1, -128, 127))
    bb.add(Field("i16", ArrowType.INT16, True), _int_col(ArrowType.INT16, 2, -32768, 32767))
    bb.add(
        Field("i32", ArrowType.INT32, True),
        _int_col(ArrowType.INT32, 4, -2147483648, 2147483647),
    )
    bb.add(
        Field("i64", ArrowType.INT64, True),
        _int_col(ArrowType.INT64, 8, Int(Int64.MIN), Int(Int64.MAX)),
    )
    bb.add(Field("u8", ArrowType.UINT8, True), _int_col(ArrowType.UINT8, 1, 0, 255))
    bb.add(Field("u16", ArrowType.UINT16, True), _int_col(ArrowType.UINT16, 2, 0, 65535))
    bb.add(
        Field("u32", ArrowType.UINT32, True),
        _int_col(ArrowType.UINT32, 4, 0, 4294967295),
    )
    bb.add(
        Field("u64", ArrowType.UINT64, True),
        fixed_column(ArrowType.UINT64, 8, _u64s(0, 99, UInt64.MAX), mid),
    )
    # float16 1.0, garbage 2.0, -inf
    bb.add(
        Field("f16", ArrowType.FLOAT16, True),
        fixed_column(ArrowType.FLOAT16, 2, _u64s(0x3C00, 0x4000, 0xFC00), mid),
    )
    # float32 0.1f, garbage 2.0f, NaN
    bb.add(
        Field("f32", ArrowType.FLOAT32, True),
        fixed_column(
            ArrowType.FLOAT32, 4, _u64s(0x3DCCCCCD, 0x40000000, 0x7FC00000), mid
        ),
    )
    # float64 1.5, garbage 2.0, -0.0
    bb.add(
        Field("f64", ArrowType.FLOAT64, True),
        fixed_column(
            ArrowType.FLOAT64,
            8,
            _u64s(0x3FF8000000000000, 0x4000000000000000, 0x8000000000000000),
            mid,
        ),
    )
    bb.add(Field("d32", ArrowType.DATE32, True), _int_col(ArrowType.DATE32, 4, -1, 19000))
    bb.add(
        Field("d64", ArrowType.DATE64, True),
        _int_col(ArrowType.DATE64, 8, 86400000, -1),
    )
    bb.add(Field("t32s", ArrowType.TIME32_S, True), _int_col(ArrowType.TIME32_S, 4, 0, 86399))
    bb.add(Field("t32ms", ArrowType.TIME32_MS, True), _int_col(ArrowType.TIME32_MS, 4, 1, 2))
    bb.add(Field("t64us", ArrowType.TIME64_US, True), _int_col(ArrowType.TIME64_US, 8, 3, 4))
    bb.add(Field("t64ns", ArrowType.TIME64_NS, True), _int_col(ArrowType.TIME64_NS, 8, 5, 6))
    bb.add(
        Field("ts_s", ArrowType.TIMESTAMP_S, True),
        _int_col(ArrowType.TIMESTAMP_S, 8, -1, 1700000000),
    )
    bb.add(
        Field("ts_ms", ArrowType.TIMESTAMP_MS, True),
        _int_col(ArrowType.TIMESTAMP_MS, 8, 7, 8),
    )
    bb.add(
        Field.timestamp("ts_us", ArrowType.TIMESTAMP_US, "UTC", True),
        _int_col(ArrowType.TIMESTAMP_US, 8, 9, 10),
    )
    bb.add(
        Field("ts_ns", ArrowType.TIMESTAMP_NS, True),
        _int_col(ArrowType.TIMESTAMP_NS, 8, 11, 12),
    )
    bb.add(
        Field("ts", ArrowType.TIMESTAMP, True),
        _int_col(ArrowType.TIMESTAMP, 8, 13, 14),
    )
    bb.add(Field("dur_s", ArrowType.DURATION_S, True), _int_col(ArrowType.DURATION_S, 8, -15, 16))
    bb.add(Field("dur_ms", ArrowType.DURATION_MS, True), _int_col(ArrowType.DURATION_MS, 8, 17, 18))
    bb.add(Field("dur_us", ArrowType.DURATION_US, True), _int_col(ArrowType.DURATION_US, 8, 19, 20))
    bb.add(Field("dur_ns", ArrowType.DURATION_NS, True), _int_col(ArrowType.DURATION_NS, 8, 21, 22))
    bb.add(
        Field("iym", ArrowType.INTERVAL_YEAR_MONTH, True),
        _int_col(ArrowType.INTERVAL_YEAR_MONTH, 4, -13, 14),
    )
    bb.add(
        Field("idt", ArrowType.INTERVAL_DAY_TIME, True),
        fixed_column(
            ArrowType.INTERVAL_DAY_TIME,
            8,
            _u64s(_day_time(1, 500), _day_time(9, 9), _day_time(-2, -1)),
            mid,
        ),
    )
    var mdn = List[UInt8]()
    _mdn_into(mdn, 1, 2, 3)
    _mdn_into(mdn, 9, 9, 9)
    _mdn_into(mdn, -1, -2, -3)
    bb.add(
        Field("imdn", ArrowType.INTERVAL_MONTH_DAY_NANO, True),
        bytes_column(ArrowType.INTERVAL_MONTH_DAY_NANO, mdn^, mid),
    )

    var dec = List[List[UInt64]]()
    dec.append(small_decimal(12345, 2))
    dec.append(small_decimal(99, 2))
    dec.append(small_decimal(-5, 2))
    bb.add(
        Field.decimal128("dec", 38, 2, True),
        decimal_column(ArrowType.DECIMAL128, dec, 2, mid),
    )
    var big = List[List[UInt64]]()
    var two64: List[UInt64] = [0, 1]
    var min128: List[UInt64] = [0, 0x8000000000000000]
    big.append(two64^)
    big.append(small_decimal(99, 2))
    big.append(min128^)
    bb.add(
        Field.decimal128("dec_big", 38, 0, True),
        decimal_column(ArrowType.DECIMAL128, big, 0, mid),
    )
    var d256 = List[List[UInt64]]()
    var two192: List[UInt64] = [0, 0, 0, 1]
    d256.append(small_decimal(-1, 4))
    d256.append(small_decimal(99, 4))
    d256.append(two192^)
    bb.add(
        Field.decimal256("dec256", 76, 4, True),
        decimal_column(ArrowType.DECIMAL256, d256, 4, mid),
    )

    var svals: List[String] = ["héllo", "garbage", "\\N"]
    bb.add(Field("s", ArrowType.STRING, True), string_column(svals, mid))
    var lsvals = List[List[UInt8]]()
    lsvals.append(utf8("a\tb"))
    lsvals.append(utf8("zz"))
    lsvals.append(utf8(""))
    bb.add(
        Field("ls", ArrowType.LARGE_STRING, True),
        varlen_column(ArrowType.LARGE_STRING, lsvals, mid),
    )
    var bins = List[List[UInt8]]()
    var b0: List[UInt8] = [0x00, 0xFF]
    var b1: List[UInt8] = [0x01]
    bins.append(b0^)
    bins.append(b1^)
    bins.append(List[UInt8]())
    bb.add(Field("bin", ArrowType.BINARY, True), varlen_column(ArrowType.BINARY, bins, mid))
    var lbins = List[List[UInt8]]()
    var l0: List[UInt8] = [0xAB]
    var l1: List[UInt8] = [0x01]
    var l2: List[UInt8] = [0x01, 0x02]
    lbins.append(l0^)
    lbins.append(l1^)
    lbins.append(l2^)
    bb.add(
        Field("lbin", ArrowType.LARGE_BINARY, True),
        varlen_column(ArrowType.LARGE_BINARY, lbins, mid),
    )
    var fsb_bytes: List[UInt8] = [0xDE, 0xAD, 0x11, 0x11, 0xBE, 0xEF]
    var fsb_buf = OwnedAlignedBuffer(6)
    for i in range(6):
        fsb_buf.write_u8_at(i, fsb_bytes[i])
    bb.add(
        Field("fsb", ArrowType.FIXED_SIZE_BINARY, True),
        Column.from_fixed_size_binary(fsb_buf^, 2, 3, validity_of(mid), 1),
    )
    bb.add(
        Field("nul", ArrowType.NULL, True),
        Column[HeapRegion](
            arrow_type=ArrowType.NULL,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=None,
            length=3,
            null_count=3,
            offset=0,
        ),
    )

    var codes64: List[Int64] = [1, 0, 0]
    var dvals: List[String] = ["x", "y"]
    bb.add(
        Field.dictionary("dict_s", ArrowType.INT64, True),
        Column.from_int64_dict_indices(codes64^, dvals^, validity_of(mid), 1),
    )
    var codes = PrimitiveArray[DType.int32].allocate_nullable(3)
    codes.set(0, 0)
    codes.set(1, 1)
    codes.set(2, 1)
    codes.validity = validity_of(mid)
    codes.null_count = 1
    var fvals: List[Int64] = [
        bitcast[DType.int64](Float64(2.5)),
        bitcast[DType.int64](Float64(-1.0)),
    ]
    bb.add(
        Field.dictionary("dict_f", ArrowType.INT32, True),
        Column.from_numeric_dict[DType.int32, DType.float64](codes^, fvals^),
    )

    # list<int32>: [1, NULL, 3], NULL (over [7]), []
    var item_valid: List[Bool] = [True, False, True, True]
    var items: List[Int] = [1, 99, 3, 7]
    var loff: List[Int] = [0, 3, 4, 4]
    bb.add(
        Field.list_of("lst", ArrowType.INT32, True),
        list_column(fixed_column(ArrowType.INT32, 4, ints(items), item_valid), loff, mid),
    )
    # large_list<string>: ["a,b"], [], NULL (over ["[x]"])
    var lstr: List[String] = ["a,b", "[x]"]
    var llo: List[Int] = [0, 1, 1, 2]
    var last_null: List[Bool] = [True, True, False]
    var llf = Field("llst", ArrowType.LARGE_LIST, True)
    llf.add_child("item", ArrowType.STRING, True)
    bb.add(llf, list_column(string_column(lstr, all_valid(2)), llo, last_null, True))
    # fixed_size_list<int16, 2>: [1, 2], NULL (over [9, 9]), [-3, NULL]
    var fitems: List[Int] = [1, 2, 9, 9, -3, 99]
    var fvalid: List[Bool] = [True, True, True, True, True, False]
    var fslf = Field("fsl", ArrowType.FIXED_SIZE_LIST, True)
    fslf.add_child("item", ArrowType.INT16, True)
    bb.add(
        fslf,
        Column.from_fixed_size_list(
            fixed_column(ArrowType.INT16, 2, ints(fitems), fvalid), 2, 3, validity_of(mid), 1
        ),
    )
    # struct{a: int32, b: string}: {1, x}, NULL, {3, NULL}
    var sa: List[Int] = [1, 9, 3]
    var sb: List[String] = ["x", "y", "w"]
    var stf = Field("st", ArrowType.STRUCT, True)
    stf.add_child("a", ArrowType.INT32, False)
    stf.add_child("b", ArrowType.STRING, True)
    bb.add(
        stf,
        struct_column(
            fixed_column(ArrowType.INT32, 4, ints(sa), all_valid(3)),
            "a",
            string_column(sb, last_null),
            "b",
            mid,
        ),
    )
    # map<string, int64>: {b: 2, a: NULL} (rendered sorted), NULL (over
    # {c: 7}), {}
    var mk: List[String] = ["b", "a", "c"]
    var mv: List[Int] = [2, 99, 7]
    var mvalid: List[Bool] = [True, False, True]
    var moff: List[Int] = [0, 2, 3, 3]
    var mpf = Field("mp", ArrowType.MAP, True)
    mpf.add_child("entries", ArrowType.STRUCT, False)
    bb.add(
        mpf,
        map_column(
            string_column(mk, all_valid(3)),
            fixed_column(ArrowType.INT64, 8, ints(mv), mvalid),
            moff,
            mid,
        ),
    )
    # union_sparse(5, 7) of int32 / string: (5:10), (7:q), (5:NULL)
    var ua: List[Int] = [10, 11, 12]
    var ub: List[String] = ["p", "q", "r"]
    var ucodes: List[Int] = [5, 7, 5]
    var uids: List[Int] = [5, 7]
    bb.add(
        Field.union("us", ArrowType.UNION_SPARSE, uids, True),
        union_column(
            False,
            ucodes,
            List[Int](),
            fixed_column(ArrowType.INT32, 4, ints(ua), last_null),
            string_column(ub, all_valid(3)),
            uids,
        ),
    )
    # union_dense(0, 1) of int64 / bool: (1:true), (0:100), (1:false)
    var da: List[Int] = [100]
    var dbv: List[Bool] = [True, False]
    var dcodes: List[Int] = [1, 0, 1]
    var doffs: List[Int] = [0, 0, 1]
    var dids: List[Int] = [0, 1]
    bb.add(
        Field.union("ud", ArrowType.UNION_DENSE, dids, True),
        union_column(
            True,
            dcodes,
            doffs,
            fixed_column(ArrowType.INT64, 8, ints(da), all_valid(1)),
            bool_column(dbv, all_valid(2)),
            dids,
        ),
    )
    return bb.build()
