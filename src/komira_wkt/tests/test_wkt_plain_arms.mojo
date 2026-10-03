# =============================================================================
# test_wkt_plain_arms.mojo — a WKT is canonical through the PLAIN codec arms.
# =============================================================================
#
# There is one set of message arms on the codec: `write_message_field` /
# `write_message_element` and `read_message` / `read_into_repeated_message` /
# `read_into_string_message_map`, plus the top-level `encode_json` /
# `decode_json` / `decode_json_lenient`. A well-known type passed to any of
# them must come out in its CANONICAL proto3-JSON form ("1970-...Z", "3s", a
# free-form object, a bare wrapper scalar) and be read back from it, because
# a code generator that picks the plain arm, or a caller whose top-level
# message IS a WKT, has no other arm to pick. The binary wire must stay
# byte-identical to an ordinary embedded message (one golden, below).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    encode_json,
    decode_json,
    decode_json_lenient,
    encode_proto,
    decode_proto,
)
from komira_json import parse_json_value
from komira_wkt import (
    Any,
    Timestamp,
    Duration,
    Struct,
    Value,
    Int64Value,
    VALUE_KIND_NULL,
    VALUE_KIND_NUMBER,
    VALUE_KIND_STRING,
)


# =============================================================================
# Generated-equivalent messages, written with the PLAIN message arms only.
# =============================================================================


@fieldwise_init
struct ProbeMsg(Serializable, Copyable, Movable):
    """Singular WKT fields: Timestamp, Duration, Struct, a wrapper."""

    var ts: Optional[Timestamp]
    var d: Optional[Duration]
    var s: Optional[Struct]
    var w: Optional[Int64Value]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if self.ts:
            enc.write_message_field[Timestamp](1, "ts", self.ts.value())
        if self.d:
            enc.write_message_field[Duration](2, "d", self.d.value())
        if self.s:
            enc.write_message_field[Struct](3, "s", self.s.value())
        if self.w:
            enc.write_message_field[Int64Value](4, "w", self.w.value())

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("Probe", "ts,d,s,w")
        var out = Self(None, None, None, None)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "ts":
                out.ts = dec.read_message[Timestamp]()
            elif key.field_no == 2 or key.json_name == "d":
                out.d = dec.read_message[Duration]()
            elif key.field_no == 3 or key.json_name == "s":
                out.s = dec.read_message[Struct]()
            elif key.field_no == 4 or key.json_name == "w":
                out.w = dec.read_message[Int64Value]()
            else:
                dec.skip()
        return out^


@fieldwise_init
struct ShapesMsg(Serializable, Copyable, Movable):
    """The repeated, map-value and Any positions of a WKT, plain arms only."""

    var stamps: List[Timestamp]
    var attrs: Dict[String, Value]
    var payload: Optional[Any]
    var v: Optional[Value]

    @staticmethod
    def new() -> Self:
        return Self(List[Timestamp](), Dict[String, Value](), None, None)

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if len(self.stamps) > 0:
            enc.begin_list_field(1, "stamps")
            for i in range(len(self.stamps)):
                enc.write_message_element[Timestamp](1, self.stamps[i])
            enc.end_list_field()
        if len(self.attrs) > 0:
            enc.begin_map_field(2, "attrs")
            for entry in self.attrs.items():
                enc.begin_map_entry()
                enc.write_string_field(1, "key", entry.key)
                enc.write_message_field[Value](2, "value", entry.value)
                enc.end_map_entry()
            enc.end_map_field()
        if self.payload:
            enc.write_message_field[Any](3, "payload", self.payload.value())
        if self.v:
            enc.write_message_field[Value](4, "v", self.v.value())

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("Shapes", "stamps,attrs,payload,v")
        var out = Self.new()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "stamps":
                dec.read_into_repeated_message[Timestamp](out.stamps)
            elif key.field_no == 2 or key.json_name == "attrs":
                dec.read_into_string_message_map[Value](out.attrs)
            elif key.field_no == 3 or key.json_name == "payload":
                out.payload = dec.read_message[Any]()
            elif key.field_no == 4 or key.json_name == "v":
                out.v = dec.read_message[Value]()
            else:
                dec.skip()
        return out^


def _probe() -> ProbeMsg:
    var s = Struct.new()
    s.put(String("a"), Value.number(1.0))
    return ProbeMsg(
        Timestamp(Int64(1), Int32(2)),
        Duration(Int64(3), Int32(0)),
        s^,
        Int64Value(Int64(5)),
    )


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        var x = Int(b[i])
        out += _nibble(x >> 4) + _nibble(x & 15)
    return out^


def _nibble(n: Int) -> String:
    return chr(n + 48) if n < 10 else chr(n + 87)


# =============================================================================
# Singular fields.
# =============================================================================


def test_plain_message_field_writes_canonical_json() raises:
    assert_equal(
        encode_json[ProbeMsg](_probe()),
        String(
            '{"ts":"1970-01-01T00:00:01.000000002Z","d":"3s",'
            + '"s":{"a":1},"w":"5"}'
        ),
    )


def test_plain_read_message_reads_canonical_json() raises:
    var m = decode_json[ProbeMsg](
        String(
            '{"ts":"2026-10-01T00:00:00.5Z","d":"-1.25s",'
            + '"s":{"k":"x","n":2},"w":"-7"}'
        )
    )
    assert_equal(m.ts.value().seconds, Int64(1790812800))
    assert_equal(m.ts.value().nanos, Int32(500000000))
    assert_equal(m.d.value().seconds, Int64(-1))
    assert_equal(m.d.value().nanos, Int32(-250000000))
    assert_equal(len(m.s.value().keys), 2)
    assert_equal(m.s.value().keys[0], String("k"))
    assert_equal(m.s.value().values[0].kind, VALUE_KIND_STRING)
    assert_equal(m.s.value().values[1].number_value, 2.0)
    assert_equal(m.w.value().value, Int64(-7))
    # And the canonical bytes round-trip exactly.
    var text = encode_json[ProbeMsg](_probe())
    assert_equal(encode_json[ProbeMsg](decode_json[ProbeMsg](text)), text)


def test_plain_arms_binary_golden() raises:
    """A WKT is an ordinary embedded message on the binary wire: these are
    the bytes the message arms produced before WKTs were special-cased."""
    var bytes = encode_proto[ProbeMsg](_probe())
    assert_equal(
        _hex(bytes),
        String(
            "0a0408011002" + "120408031000" + "1a100a0e0a01611209"
            + "11000000000000f03f" + "22020805"
        ),
    )
    var back = decode_proto[ProbeMsg](bytes^)
    assert_equal(back.ts.value().nanos, Int32(2))
    assert_equal(back.s.value().values[0].number_value, 1.0)
    assert_equal(back.w.value().value, Int64(5))


# =============================================================================
# Repeated element, map value, Any.
# =============================================================================


def test_plain_element_and_map_value_are_canonical() raises:
    var m = ShapesMsg.new()
    m.stamps.append(Timestamp(Int64(0), Int32(0)))
    m.stamps.append(Timestamp(Int64(86400), Int32(1000000)))
    m.attrs[String("n")] = Value.number(1.5)
    m.payload = Any(
        String("type.googleapis.com/x.Y"),
        List[UInt8](),
        parse_json_value(String('{"k":true}')),
    )
    var text = encode_json[ShapesMsg](m)
    assert_equal(
        text,
        String(
            '{"stamps":["1970-01-01T00:00:00Z","1970-01-02T00:00:00.001Z"],'
            + '"attrs":{"n":1.5},'
            + '"payload":{"@type":"type.googleapis.com/x.Y","k":true}}'
        ),
    )
    var back = decode_json[ShapesMsg](text)
    assert_equal(len(back.stamps), 2)
    assert_equal(back.stamps[1].nanos, Int32(1000000))
    assert_equal(back.attrs[String("n")].kind, VALUE_KIND_NUMBER)
    assert_equal(back.payload.value().type_url, String("type.googleapis.com/x.Y"))
    assert_equal(encode_json[ShapesMsg](back), text)


def test_null_inside_a_struct_is_a_null_value() raises:
    """A null INSIDE a Struct / map<string, Value> is a NULL_VALUE entry."""
    var n = decode_json[ShapesMsg](String('{"attrs":{"z":null}}'))
    assert_equal(len(n.attrs), 1)
    assert_equal(n.attrs[String("z")].kind, VALUE_KIND_NULL)


# =============================================================================
# Top-level: the message IS a WKT.
# =============================================================================


def test_top_level_encode_json_is_canonical() raises:
    assert_equal(
        encode_json[Timestamp](Timestamp(Int64(1), Int32(2))),
        String('"1970-01-01T00:00:01.000000002Z"'),
    )
    assert_equal(
        encode_json[Duration](Duration(Int64(1), Int32(500000000))),
        String('"1.500s"'),
    )
    assert_equal(encode_json[Int64Value](Int64Value(Int64(5))), String('"5"'))
    assert_equal(encode_json[Struct](_probe().s.value()), String('{"a":1}'))
    assert_equal(encode_json[Value](Value.null()), String("null"))


def test_top_level_decode_json_is_canonical() raises:
    var lenient = decode_json_lenient[Struct](String('{"a":1}'))
    assert_equal(len(lenient.keys), 1)
    assert_equal(lenient.keys[0], String("a"))
    assert_equal(lenient.values[0].number_value, 1.0)
    var strict = decode_json[Struct](String('{"a":1,"b":"x"}'))
    assert_equal(len(strict.keys), 2)
    var ts = decode_json[Timestamp](String('"1970-01-01T00:00:01.000000002Z"'))
    assert_equal(ts.seconds, Int64(1))
    assert_equal(ts.nanos, Int32(2))
    var d = decode_json_lenient[Duration](String('"1.5s"'))
    assert_equal(d.nanos, Int32(500000000))
    assert_equal(decode_json[Int64Value](String('"5"')).value, Int64(5))
    var a = decode_json[Any](String('{"@type":"type.googleapis.com/x.Y","k":1}'))
    assert_equal(a.type_url, String("type.googleapis.com/x.Y"))
    with assert_raises(contains="Timestamp"):
        _ = decode_json[Timestamp](String('"not a time"'))


# =============================================================================
# Refusals.
# =============================================================================


def test_value_with_no_kind_refuses_to_write() raises:
    """A `Value` with no kind set is not a JSON value; the reference
    implementations refuse it rather than guess `null`."""
    # An empty binary `Value` decodes with no kind set.
    var unset = decode_proto[Value](List[UInt8]())
    with assert_raises(contains="no kind"):
        _ = encode_json[Value](unset)
    var m = ShapesMsg.new()
    m.v = unset.copy()
    with assert_raises(contains="no kind"):
        _ = encode_json[ShapesMsg](m)


def test_any_with_wkt_type_and_no_payload_refuses_json() raises:
    """A binary `Any` naming a well-known type with an empty payload (a zero
    Duration, an Empty) has the canonical JSON `{"@type":..,"value":..}`;
    writing it needs the type's JSON form, so with no registry it REFUSES
    rather than emit a form a reference parser rejects."""
    var a = Any(
        String("type.googleapis.com/google.protobuf.Duration"), List[UInt8]()
    )
    with assert_raises(contains="type registry"):
        _ = encode_json[Any](a)
    # A non-WKT type with no payload is still `{"@type": ...}`.
    assert_equal(
        encode_json[Any](Any(String("type.googleapis.com/x.Y"), List[UInt8]())),
        String('{"@type":"type.googleapis.com/x.Y"}'),
    )


def main() raises:
    test_plain_message_field_writes_canonical_json()
    test_plain_read_message_reads_canonical_json()
    test_plain_arms_binary_golden()
    test_plain_element_and_map_value_are_canonical()
    test_null_inside_a_struct_is_a_null_value()
    test_top_level_encode_json_is_canonical()
    test_top_level_decode_json_is_canonical()
    test_value_with_no_kind_refuses_to_write()
    test_any_with_wkt_type_and_no_payload_refuses_json()
    print("test_wkt_plain_arms: all tests passed")
