# =============================================================================
# komira_plan_harness/fixtures.mojo -- hand-built columns for harness tests.
# =============================================================================
#
# Columns built from raw Arrow buffers, the shape the C-data importer hands
# over, for every type canon renders. A slot marked invalid still holds the
# value given for it, so a renderer that ignores validity renders that value
# and a test sees it. Not for production: these build columns field by field
# (children, decimal scale, union type ids), as komira_arrow_ipc does.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


def all_valid(n: Int) -> List[Bool]:
    var v = List[Bool](capacity=n)
    for _ in range(n):
        v.append(True)
    return v^


def validity_of(valid: List[Bool]) -> Optional[Bitmap[HeapRegion]]:
    var nulls = 0
    for v in valid:
        if not v:
            nulls += 1
    if nulls == 0:
        return None
    var bm = Bitmap.create_all_valid(len(valid))
    for i in range(len(valid)):
        if not valid[i]:
            bm.clear(i)
    return bm^


def _nulls(valid: List[Bool]) -> Int:
    var n = 0
    for v in valid:
        if not v:
            n += 1
    return n


def _buffer(var bytes: List[UInt8]) -> OwnedAlignedBuffer:
    var n = len(bytes)
    var buf = OwnedAlignedBuffer(max(n, 1))
    buf.zero()
    for i in range(n):
        buf.write_u8_at(i, bytes[i])
    buf.set_length(Int64(n))
    return buf^


def _le_into(mut res: List[UInt8], v: UInt64, width: Int):
    for k in range(width):
        res.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def bytes_column(t: ArrowType, var data: List[UInt8], valid: List[Bool]) -> Column[HeapRegion]:
    """A fixed-width column over `data` (len(valid) values)."""
    return Column[HeapRegion](
        arrow_type=t,
        data=_buffer(data^),
        offsets=None,
        validity=validity_of(valid),
        length=len(valid),
        null_count=_nulls(valid),
        offset=0,
    )


def fixed_column(
    t: ArrowType, width: Int, values: List[UInt64], valid: List[Bool]
) -> Column[HeapRegion]:
    """Values of 1, 2, 4 or 8 bytes: the low `width` bytes of each, little
    endian (a negative Int goes in as UInt64(Int64(v)), two's complement)."""
    var data = List[UInt8]()
    for v in values:
        _le_into(data, v, width)
    return bytes_column(t, data^, valid)


def ints(values: List[Int]) -> List[UInt64]:
    var res = List[UInt64]()
    for v in values:
        res.append(UInt64(Int64(v).cast[DType.uint64]()))
    return res^


def bool_column(values: List[Bool], valid: List[Bool]) -> Column[HeapRegion]:
    var data = List[UInt8]()
    for _ in range((len(values) + 7) // 8):
        data.append(0)
    for i in range(len(values)):
        if values[i]:
            data[i // 8] |= UInt8(1) << UInt8(i % 8)
    return bytes_column(ArrowType.BOOL, data^, valid)


def decimal_column(
    t: ArrowType, limbs: List[List[UInt64]], scale: Int, valid: List[Bool]
) -> Column[HeapRegion]:
    """DECIMAL128 (2 limbs a value) or DECIMAL256 (4 limbs), each value its
    little-endian 64-bit limbs of the two's complement unscaled integer."""
    var data = List[UInt8]()
    for v in limbs:
        for l in v:
            _le_into(data, l, 8)
    var col = bytes_column(t, data^, valid)
    col._decimal_p = 38 if t == ArrowType.DECIMAL128 else 76
    col._decimal_s = scale
    return col^


def small_decimal(v: Int, nlimbs: Int) -> List[UInt64]:
    """The limbs of a small (Int64-range) unscaled value, sign-extended."""
    var res = List[UInt64]()
    res.append(UInt64(Int64(v).cast[DType.uint64]()))
    var fill = UInt64(0xFFFFFFFFFFFFFFFF) if v < 0 else UInt64(0)
    for _ in range(nlimbs - 1):
        res.append(fill)
    return res^


def varlen_column(
    t: ArrowType, values: List[List[UInt8]], valid: List[Bool]
) -> Column[HeapRegion]:
    """STRING / BINARY (Int32 offsets) or LARGE_STRING / LARGE_BINARY
    (Int64 offsets)."""
    var wide = t == ArrowType.LARGE_STRING or t == ArrowType.LARGE_BINARY
    var w = 8 if wide else 4
    var offsets = List[UInt8]()
    var data = List[UInt8]()
    _le_into(offsets, 0, w)
    for v in values:
        for b in v:
            data.append(b)
        _le_into(offsets, UInt64(len(data)), w)
    return Column[HeapRegion](
        arrow_type=t,
        data=_buffer(data^),
        offsets=Optional[OwnedAlignedBuffer](_buffer(offsets^)),
        validity=validity_of(valid),
        length=len(valid),
        null_count=_nulls(valid),
        offset=0,
    )


def utf8(s: String) -> List[UInt8]:
    var res = List[UInt8]()
    for b in s.as_bytes():
        res.append(b)
    return res^


def string_column(values: List[String], valid: List[Bool]) -> Column[HeapRegion]:
    var raw = List[List[UInt8]]()
    for s in values:
        raw.append(utf8(s))
    return varlen_column(ArrowType.STRING, raw, valid)


def list_column(
    var child: Column[HeapRegion], offsets: List[Int], valid: List[Bool], large: Bool = False
) -> Column[HeapRegion]:
    """LIST (or LARGE_LIST) over `child`; len(offsets) == rows + 1."""
    var w = 8 if large else 4
    var off = List[UInt8]()
    for o in offsets:
        _le_into(off, UInt64(o), w)
    var col = Column[HeapRegion](
        arrow_type=ArrowType.LARGE_LIST if large else ArrowType.LIST,
        data=OwnedAlignedBuffer(0),
        offsets=Optional[OwnedAlignedBuffer](_buffer(off^)),
        validity=validity_of(valid),
        length=len(valid),
        null_count=_nulls(valid),
        offset=0,
    )
    col._children.append(child^)
    return col^


def struct_column(
    var a: Column[HeapRegion], a_name: String, var b: Column[HeapRegion], b_name: String, valid: List[Bool]
) -> Column[HeapRegion]:
    var col = Column[HeapRegion](
        arrow_type=ArrowType.STRUCT,
        data=OwnedAlignedBuffer(0),
        offsets=None,
        validity=validity_of(valid),
        length=len(valid),
        null_count=_nulls(valid),
        offset=0,
    )
    col._children.append(a^)
    col._children.append(b^)
    col._field_names.append(a_name)
    col._field_names.append(b_name)
    return col^


def map_column(
    var keys: Column[HeapRegion], var values: Column[HeapRegion], offsets: List[Int], valid: List[Bool]
) -> Column[HeapRegion]:
    var n_entries = keys.length()
    var entries = struct_column(keys^, "key", values^, "value", all_valid(n_entries))
    var off = List[UInt8]()
    for o in offsets:
        _le_into(off, UInt64(o), 4)
    var col = Column[HeapRegion](
        arrow_type=ArrowType.MAP,
        data=OwnedAlignedBuffer(0),
        offsets=Optional[OwnedAlignedBuffer](_buffer(off^)),
        validity=validity_of(valid),
        length=len(valid),
        null_count=_nulls(valid),
        offset=0,
    )
    col._children.append(entries^)
    return col^


def union_column(
    dense: Bool,
    codes: List[Int],
    child_offsets: List[Int],
    var a: Column[HeapRegion],
    var b: Column[HeapRegion],
    type_ids: List[Int],
) -> Column[HeapRegion]:
    """A two-child union; `child_offsets` is used for a dense one only."""
    var data = List[UInt8]()
    for c in codes:
        data.append(UInt8(c))
    var offsets = Optional[OwnedAlignedBuffer](None)
    if dense:
        var off = List[UInt8]()
        for o in child_offsets:
            _le_into(off, UInt64(o), 4)
        offsets = Optional[OwnedAlignedBuffer](_buffer(off^))
    var col = Column[HeapRegion](
        arrow_type=ArrowType.UNION_DENSE if dense else ArrowType.UNION_SPARSE,
        data=_buffer(data^),
        offsets=offsets^,
        validity=None,
        length=len(codes),
        null_count=0,
        offset=0,
    )
    col._children.append(a^)
    col._children.append(b^)
    col._type_ids = type_ids.copy()
    return col^


def sliced(var col: Column[HeapRegion], offset: Int) -> Column[HeapRegion]:
    """The same buffers seen from physical row `offset` on: a slice offset,
    as an imported Arrow array may carry one on any layout."""
    col._offset += offset
    col._length -= offset
    return col^


struct BatchBuilder(Movable):
    """Fields and columns added in order, then one RecordBatch."""

    var _schema: SchemaBuilder
    var _columns: RecordBatchBuilder

    def __init__(out self):
        self._schema = SchemaBuilder()
        self._columns = RecordBatchBuilder()

    def add(mut self, f: Field, var col: Column[HeapRegion]):
        self._schema.add_field(f.copy())
        self._columns.add_column(col^)

    def build(mut self) raises -> RecordBatch:
        return self._columns.build(self._schema.build())
