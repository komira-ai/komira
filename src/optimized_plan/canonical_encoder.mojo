# =============================================================================
# canonical_encoder.mojo — the canonical protobuf encoding of a plan message
# (docs/design/optimized_plan.md §7.1).
# =============================================================================
#
# `CanonicalPbEncoder` is a `WireEncoder` whose bytes are the same for equal
# messages whoever produced them, so a digest of them means the same thing on
# every producer:
#
#   - fields in ascending field-number order. The generated `encode` writes
#     in declaration order and puts oneof arms last, so each field is kept as
#     a record and the records are emitted sorted by number (stable) when the
#     message ends. A nested message is encoded by a child encoder, so it is
#     sorted too;
#   - an implicit-presence scalar at its default is omitted
#     (`OMITS_IMPLICIT_DEFAULTS`); a set message field is written even when
#     empty (tag and a zero length), an unset one is not written at all (the
#     generated code does not call the encoder for it);
#   - a repeated numeric scalar (varint, enum, bool, fixed, float, double,
#     sint) is packed into one length-delimited record, and omitted when
#     empty; a repeated string, bytes or message is one record per element,
#     in list order;
#   - varints are minimal;
#   - every NaN is written as one bit pattern (double 0x7FF8000000000000,
#     float 0x7FC00000); -0.0 stays distinct from +0.0;
#   - a oneof writes exactly the arm that is set (the generated code's choice).
#
# These are the bytes protoc's ordinary serializer gives, except for NaN.
#
# Maps: no message of the plan protos has a map field, and protoc does not
# fix a map's entry order, so no canonical form of one is defined here. Every
# map method refuses with `CANONICAL_MAP_UNSUPPORTED`.
# =============================================================================

from std.memory import bitcast

from proto_codec import ProtoEnum, Serializable, WireEncoder
from protobuf import (
    PB_WIRE_FIXED32,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_VARINT,
    pb_write_tag,
    pb_write_varint,
    zigzag_encode,
    zigzag_encode32,
)

comptime CANONICAL_MAP_UNSUPPORTED = "CANONICAL_MAP_UNSUPPORTED"
"""A map field reached the canonical encoder, which defines no form for it."""

comptime _NAN64: UInt64 = 0x7FF8000000000000
comptime _NAN32: UInt32 = 0x7FC00000


def _bits64(v: Float64) -> UInt64:
    """The bits of `v`, with every NaN as one pattern."""
    if v != v:
        return _NAN64
    return bitcast[DType.uint64, 1](v)


def _bits32(v: Float32) -> UInt32:
    """The bits of `v`, with every NaN as one pattern."""
    if v != v:
        return _NAN32
    return bitcast[DType.uint32, 1](v)


def _put_le(mut out: List[UInt8], bits: UInt64, width: Int):
    for k in range(width):
        out.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))


def _enum_bits(number: Int) -> UInt64:
    """An enum's int32 value as a varint payload (negatives sign-extend)."""
    return UInt64(Int64(Int32(number)))


def _refuse_map() -> Error:
    return Error(
        CANONICAL_MAP_UNSUPPORTED
        + ": a map field has no canonical encoding (protoc leaves the order"
        " of its entries open)"
    )


struct CanonicalPbEncoder(WireEncoder):
    """The canonical protobuf-binary `WireEncoder` (module header)."""

    comptime OMITS_IMPLICIT_DEFAULTS = True

    # One message level: each field as a record of tag and payload bytes.
    # Record `i` is `_data[_ends[i - 1]:_ends[i]]` and has number `_nos[i]`.
    var _data: List[UInt8]
    var _nos: List[Int]
    var _ends: List[Int]
    # The open repeated field's packed payload, and its number.
    var _pack: List[UInt8]
    var _pack_no: Int

    def __init__(out self):
        self._data = List[UInt8]()
        self._nos = List[Int]()
        self._ends = List[Int]()
        self._pack = List[UInt8]()
        self._pack_no = 0

    def into_buf(mut self) -> List[UInt8]:
        """The message's bytes, records sorted by field number (stable), and
        the encoder emptied."""
        var out = List[UInt8]()
        var ascending = True
        for i in range(1, len(self._nos)):
            if self._nos[i] < self._nos[i - 1]:
                ascending = False
                break
        if ascending:
            swap(out, self._data)
        else:
            var distinct = List[Int]()
            for i in range(len(self._nos)):
                var n = self._nos[i]
                var seen = False
                for j in range(len(distinct)):
                    if distinct[j] == n:
                        seen = True
                        break
                if seen:
                    continue
                distinct.append(n)
                var at = len(distinct) - 1
                while at > 0 and distinct[at - 1] > n:
                    distinct[at] = distinct[at - 1]
                    at -= 1
                distinct[at] = n
            for d in range(len(distinct)):
                var start = 0
                for i in range(len(self._nos)):
                    if self._nos[i] == distinct[d]:
                        for k in range(start, self._ends[i]):
                            out.append(self._data[k])
                    start = self._ends[i]
        self._data.clear()
        self._nos.clear()
        self._ends.clear()
        self._pack.clear()
        return out^

    def _seal(mut self, field_no: Int):
        """The bytes appended to `_data` since the last record are one record
        of field `field_no`."""
        self._nos.append(field_no)
        self._ends.append(len(self._data))

    def _varint_record(mut self, field_no: Int, v: UInt64):
        pb_write_tag(self._data, field_no, PB_WIRE_VARINT)
        pb_write_varint(self._data, v)
        self._seal(field_no)

    def _fixed_record(mut self, field_no: Int, bits: UInt64, width: Int):
        if width == 8:
            pb_write_tag(self._data, field_no, PB_WIRE_FIXED64)
        else:
            pb_write_tag(self._data, field_no, PB_WIRE_FIXED32)
        _put_le(self._data, bits, width)
        self._seal(field_no)

    def _len_record(mut self, field_no: Int, payload: Span[UInt8, _]):
        pb_write_tag(self._data, field_no, PB_WIRE_LEN)
        pb_write_varint(self._data, UInt64(len(payload)))
        for i in range(len(payload)):
            self._data.append(payload[i])
        self._seal(field_no)

    # -- scalar fields ------------------------------------------------------

    def write_string_field(
        mut self, field_no: Int, json_name: StringSlice, v: String
    ) raises:
        self._len_record(field_no, v.as_bytes())

    def write_bytes_field(
        mut self, field_no: Int, json_name: StringSlice, v: List[UInt8]
    ) raises:
        self._len_record(field_no, Span(v))

    def write_i64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        self._varint_record(field_no, UInt64(v))

    def write_i32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        self._varint_record(field_no, UInt64(Int64(v)))

    def write_u64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        self._varint_record(field_no, v)

    def write_u32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        self._varint_record(field_no, UInt64(v))

    def write_f64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float64
    ) raises:
        self._fixed_record(field_no, _bits64(v), 8)

    def write_f32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float32
    ) raises:
        self._fixed_record(field_no, UInt64(_bits32(v)), 4)

    def write_sint64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        self._varint_record(field_no, zigzag_encode(v))

    def write_sint32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        self._varint_record(field_no, UInt64(zigzag_encode32(v)))

    def write_fixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        self._fixed_record(field_no, v, 8)

    def write_fixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        self._fixed_record(field_no, UInt64(v), 4)

    def write_sfixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        self._fixed_record(field_no, UInt64(v), 8)

    def write_sfixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        self._fixed_record(field_no, UInt64(Int64(v)) & 0xFFFFFFFF, 4)

    def write_bool_field(
        mut self, field_no: Int, json_name: StringSlice, v: Bool
    ) raises:
        self._varint_record(field_no, UInt64(1) if v else UInt64(0))

    def write_enum_field[
        En: ProtoEnum
    ](mut self, field_no: Int, json_name: StringSlice, v: En) raises:
        self._varint_record(field_no, _enum_bits(v.number()))

    def write_message_field[
        M: Serializable
    ](mut self, field_no: Int, json_name: StringSlice, v: M) raises:
        var child = CanonicalPbEncoder()
        v.encode[CanonicalPbEncoder](child)
        var body = child.into_buf()
        self._len_record(field_no, Span(body))

    # -- repeated fields ----------------------------------------------------
    #
    # A numeric element goes into the open field's packed payload; the payload
    # is one record when the list ends. A string, bytes or message element is
    # a record of its own, so the list order is the record order.

    def begin_list_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        self._pack_no = field_no
        self._pack.clear()

    def end_list_field(mut self) raises:
        if len(self._pack) > 0:
            var payload = List[UInt8]()
            swap(payload, self._pack)
            self._len_record(self._pack_no, Span(payload))

    def write_string_element(mut self, field_no: Int, v: String) raises:
        self._len_record(field_no, v.as_bytes())

    def write_bytes_element(mut self, field_no: Int, v: List[UInt8]) raises:
        self._len_record(field_no, Span(v))

    def write_i64_element(mut self, field_no: Int, v: Int64) raises:
        pb_write_varint(self._pack, UInt64(v))

    def write_i32_element(mut self, field_no: Int, v: Int32) raises:
        pb_write_varint(self._pack, UInt64(Int64(v)))

    def write_u64_element(mut self, field_no: Int, v: UInt64) raises:
        pb_write_varint(self._pack, v)

    def write_u32_element(mut self, field_no: Int, v: UInt32) raises:
        pb_write_varint(self._pack, UInt64(v))

    def write_f64_element(mut self, field_no: Int, v: Float64) raises:
        _put_le(self._pack, _bits64(v), 8)

    def write_f32_element(mut self, field_no: Int, v: Float32) raises:
        _put_le(self._pack, UInt64(_bits32(v)), 4)

    def write_sint64_element(mut self, field_no: Int, v: Int64) raises:
        pb_write_varint(self._pack, zigzag_encode(v))

    def write_sint32_element(mut self, field_no: Int, v: Int32) raises:
        pb_write_varint(self._pack, UInt64(zigzag_encode32(v)))

    def write_fixed64_element(mut self, field_no: Int, v: UInt64) raises:
        _put_le(self._pack, v, 8)

    def write_fixed32_element(mut self, field_no: Int, v: UInt32) raises:
        _put_le(self._pack, UInt64(v), 4)

    def write_sfixed64_element(mut self, field_no: Int, v: Int64) raises:
        _put_le(self._pack, UInt64(v), 8)

    def write_sfixed32_element(mut self, field_no: Int, v: Int32) raises:
        _put_le(self._pack, UInt64(Int64(v)) & 0xFFFFFFFF, 4)

    def write_bool_element(mut self, field_no: Int, v: Bool) raises:
        self._pack.append(UInt8(1) if v else UInt8(0))

    def write_enum_element[
        En: ProtoEnum
    ](mut self, field_no: Int, v: En) raises:
        pb_write_varint(self._pack, _enum_bits(v.number()))

    def write_message_element[
        M: Serializable
    ](mut self, field_no: Int, v: M) raises:
        var child = CanonicalPbEncoder()
        v.encode[CanonicalPbEncoder](child)
        var body = child.into_buf()
        self._len_record(field_no, Span(body))

    # -- maps ---------------------------------------------------------------

    def begin_map_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        raise _refuse_map()

    def end_map_field(mut self) raises:
        raise _refuse_map()

    def begin_map_entry(mut self) raises:
        raise _refuse_map()

    def end_map_entry(mut self) raises:
        raise _refuse_map()


def encode_canonical[T: Serializable](msg: T) raises -> List[UInt8]:
    """The canonical protobuf bytes of `msg` (module header)."""
    var enc = CanonicalPbEncoder()
    msg.encode[CanonicalPbEncoder](enc)
    return enc.into_buf()
