# =============================================================================
# test_proto_codec_binary_decoder_maps.mojo — the map readers of `PbDecoder`,
# nesting through map entries, and `copy`.
# =============================================================================
#
# Every input is a hex string written from the protobuf encoding spec, so the
# decoder is checked against the format and not against `PbEncoder`.
# `PbDecoder` is driven directly, reader by reader.
#
#   D6  the map readers: all five key / value shapes, a key repeated (the last
#       value wins), an entry missing its key or value (the default), an
#       unknown field inside an entry. Catches: key and value swapped, an
#       entry's bytes left unconsumed.
#   D7  a map entry counts as a nesting level, like a sub-message does.
#       Catches: a map-of-message chain that recurses without being counted.
#   D8  `copy` is a deep clone at the same position; `keep_null_fields` and
#       `expect_fields` do nothing on the binary wire. Catches: a clone that
#       shares or resets state.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import (
    PbDecoder,
    ProtoEnum,
    Serializable,
    WireDecoder,
    WireEncoder,
    PB_DECODE_TOO_DEEP,
)


def _nib(c: UInt8) -> Int:
    if c >= 0x61:
        return Int(c) - 0x61 + 10
    return Int(c) - 0x30


def _b(hex: String) -> List[UInt8]:
    """Bytes from a hex string; spaces are ignored."""
    var out = List[UInt8]()
    var bs = hex.as_bytes()
    var hi = -1
    for i in range(len(bs)):
        var c = bs[i]
        if c == 0x20:
            continue
        if hi < 0:
            hi = _nib(c)
        else:
            out.append(UInt8(hi * 16 + _nib(c)))
            hi = -1
    return out^


def _dec(hex: String) -> PbDecoder:
    return PbDecoder(_b(hex))


def _varint(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var x = n
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))
    return out^


def _len_rec(field: Int, payload: List[UInt8]) -> List[UInt8]:
    """Field `field` as a LEN record holding `payload`."""
    var out = _varint(field * 8 + 2)
    out.extend(_varint(len(payload)))
    out.extend(Span(payload))
    return out^


def _first(mut d: PbDecoder) raises -> Int:
    var k = d.next_field()
    assert_false(k.end, "a field was expected")
    assert_equal(k.json_name, String(""), "the binary wire carries no name")
    return k.field_no


@fieldwise_init
struct Level(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):
    var value: Int

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        return String("LEVEL")

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "LEVEL"

    @staticmethod
    def known_json_names() -> String:
        return String("LEVEL")


@fieldwise_init
struct Leaf(Serializable, Copyable, Movable):
    """`message Leaf { int64 n = 1; string tag = 2; }`."""

    var n: Int64
    var tag: String

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var n = Int64(0)
        var tag = String("")
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1:
                n = dec.read_i64()
            elif key.field_no == 2:
                tag = dec.read_string()
            else:
                dec.skip()
        return Leaf(n, tag^)


# =============================================================================
# D6, D7
# =============================================================================


def _entry(field: Int, key: List[UInt8], value: List[UInt8]) -> List[UInt8]:
    var body = List[UInt8]()
    body.extend(Span(key))
    body.extend(Span(value))
    return _len_rec(field, body^)


def _s(field: Int, text: String) -> List[UInt8]:
    var payload = List[UInt8]()
    payload.extend(text.as_bytes())
    return _len_rec(field, payload^)


def test_d6_map_readers() raises:
    # string -> string, the key repeated: the last value wins.
    var buf = _entry(7, _s(1, "a"), _s(2, "x"))
    buf.extend(_entry(7, _s(1, "b"), _s(2, "y")))
    buf.extend(_entry(7, _s(1, "a"), _s(2, "z")))
    var d = PbDecoder(buf^)
    var ss = Dict[String, String]()
    while True:
        if d.next_field().end:
            break
        d.read_into_string_string_map(ss)
    assert_equal(len(ss), 2)
    assert_equal(ss["a"], String("z"), "the last of a repeated key")
    assert_equal(ss["b"], String("y"))

    # value then key (order in an entry is free), and a missing value.
    buf = _entry(7, _s(2, "v"), _s(1, "k"))
    buf.extend(_entry(7, _s(1, "novalue"), List[UInt8]()))
    buf.extend(_entry(7, List[UInt8](), _s(2, "nokey")))
    d = PbDecoder(buf^)
    ss = Dict[String, String]()
    while True:
        if d.next_field().end:
            break
        d.read_into_string_string_map(ss)
    assert_equal(len(ss), 3)
    assert_equal(ss["k"], String("v"))
    assert_equal(ss["novalue"], String(""), "a missing value is the default")
    assert_equal(ss[""], String("nokey"), "a missing key is the default")

    # string -> int32 / int64
    buf = _entry(7, _s(1, "n"), _b("10 ff ff ff ff ff ff ff ff ff 01"))
    d = PbDecoder(buf^)
    var si32 = Dict[String, Int32]()
    _ = d.next_field()
    d.read_into_string_i32_map(si32)
    assert_equal(si32["n"], Int32(-1))
    buf = _entry(7, _s(1, "n"), _b("10 96 01"))
    buf.extend(_entry(7, _s(1, "m"), List[UInt8]()))
    d = PbDecoder(buf^)
    var si64 = Dict[String, Int64]()
    while True:
        if d.next_field().end:
            break
        d.read_into_string_i64_map(si64)
    assert_equal(si64["n"], Int64(150))
    assert_equal(si64["m"], Int64(0), "a missing value is zero")

    # int64 -> string
    buf = _entry(7, _b("08 ff ff ff ff ff ff ff ff ff 01"), _s(2, "neg"))
    buf.extend(_entry(7, _b("08 05"), _s(2, "five")))
    d = PbDecoder(buf^)
    var is_ = Dict[Int64, String]()
    while True:
        if d.next_field().end:
            break
        d.read_into_i64_string_map(is_)
    assert_equal(len(is_), 2)
    assert_equal(is_[Int64(-1)], String("neg"))
    assert_equal(is_[Int64(5)], String("five"))

    # string -> message, and a missing value field is a default message.
    buf = _entry(7, _s(1, "a"), _len_rec(2, _b("08 05 12 01 78")))
    buf.extend(_entry(7, _s(1, "b"), List[UInt8]()))
    d = PbDecoder(buf^)
    var sm = Dict[String, Leaf]()
    while True:
        if d.next_field().end:
            break
        d.read_into_string_message_map[Leaf](sm)
    assert_equal(len(sm), 2)
    assert_equal(sm["a"].n, Int64(5))
    assert_equal(sm["a"].tag, String("x"))
    assert_equal(sm["b"].n, Int64(0), "no value field: a message of defaults")
    assert_equal(sm["b"].tag, String(""))

    # An unknown field inside an entry, before and after the pair.
    buf = _entry(
        7,
        _b("18 07") + _s(1, "k"),
        _s(2, "v") + _b("20 09"),
    )
    d = PbDecoder(buf^)
    ss = Dict[String, String]()
    _ = d.next_field()
    d.read_into_string_string_map(ss)
    assert_equal(ss["k"], String("v"))
    assert_true(d.next_field().end, "the entry was consumed whole")

    # The same for the other four readers: an unknown field after the pair.
    d = PbDecoder(_entry(7, _s(1, "n") + _b("10 05"), _b("18 09")))
    var skip_i32 = Dict[String, Int32]()
    _ = d.next_field()
    d.read_into_string_i32_map(skip_i32)
    assert_equal(skip_i32["n"], Int32(5))
    d = PbDecoder(_entry(7, _s(1, "n") + _b("10 06"), _b("18 09")))
    var skip_i64 = Dict[String, Int64]()
    _ = d.next_field()
    d.read_into_string_i64_map(skip_i64)
    assert_equal(skip_i64["n"], Int64(6))
    d = PbDecoder(_entry(7, _b("08 07") + _s(2, "seven"), _b("18 09")))
    var skip_is = Dict[Int64, String]()
    _ = d.next_field()
    d.read_into_i64_string_map(skip_is)
    assert_equal(skip_is[Int64(7)], String("seven"))
    d = PbDecoder(
        _entry(7, _s(1, "m") + _len_rec(2, _b("08 08")), _b("18 09"))
    )
    var skip_sm = Dict[String, Leaf]()
    _ = d.next_field()
    d.read_into_string_message_map[Leaf](skip_sm)
    assert_equal(skip_sm["m"].n, Int64(8))
    print("  test_d6_map_readers: PASS")


@fieldwise_init
struct Node(Serializable, Copyable, Movable):
    """`message Node { map<string, Node> kids = 1; Node child = 2; }`:
    `levels` is the number of messages from here down the last chain."""

    var levels: Int

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var levels = 1
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1:
                var kids = Dict[String, Node]()
                dec.read_into_string_message_map[Node](kids)
                levels = kids["k"].levels + 1
            elif key.field_no == 2:
                levels = dec.read_message[Node]().levels + 1
            else:
                dec.skip()
        return Node(levels)


def _via_map(inner: List[UInt8]) -> List[UInt8]:
    """`inner` as the value of one entry of field 1 (key "k")."""
    return _entry(1, _s(1, "k"), _len_rec(2, inner))


def _chain(map_levels: Int, plain_first: Bool) -> List[UInt8]:
    """A `Node` holding `map_levels` nested Nodes through map entries,
    optionally under one plain nested Node."""
    var inner = List[UInt8]()
    for _ in range(map_levels):
        inner = _via_map(inner^)
    if plain_first:
        inner = _len_rec(2, inner^)
    return inner^


def _refusal(var bytes: List[UInt8]) raises -> String:
    var d = PbDecoder(bytes^)
    try:
        _ = Node.decode[PbDecoder](d)
    except e:
        return String(e)
    return String("")


def test_d7_a_map_entry_counts_as_a_nesting_level() raises:
    # Counting the outermost as 1: each map level costs two (entry, value).
    # 31 map levels = 32 messages, the deepest at depth 63: accepted.
    var d = PbDecoder(_chain(31, False))
    assert_equal(Node.decode[PbDecoder](d).levels, 32)
    # 32 map levels: the 33rd message needs a decoder at depth 65.
    assert_true(
        _refusal(_chain(32, False)).startswith(PB_DECODE_TOO_DEEP),
        "one map level too many",
    )
    # With one plain level on top, the deepest message sits at an even depth:
    # 31 map levels put it at depth 64 (accepted); 32 would have it open an
    # entry from depth 64.
    d = PbDecoder(_chain(31, True))
    assert_equal(Node.decode[PbDecoder](d).levels, 33)
    var msg = _refusal(_chain(32, True))
    assert_true(
        msg.startswith(PB_DECODE_TOO_DEEP + ": this message nests more than 64"),
        String("an entry opened from depth 64 is refused: ") + msg,
    )
    print("  test_d7_a_map_entry_counts_as_a_nesting_level: PASS")


# =============================================================================
# D8
# =============================================================================


def test_d8_copy_and_no_op_hooks() raises:
    var d = _dec("08 05 10 06")
    _ = _first(d)
    var c = d.copy()
    assert_equal(d.read_i64(), Int64(5))
    # The clone stands where the original stood when it was copied.
    assert_equal(c.pos, 1, "the copy keeps the position after the tag")
    assert_equal(c.read_i64(), Int64(5), "the copy reads the same field")
    assert_equal(_first(c), 2)
    assert_equal(c.read_i64(), Int64(6))
    # The original was not moved by reading the copy.
    assert_equal(_first(d), 2)
    assert_equal(d.read_i64(), Int64(6))

    d = _dec("08 05")
    d.keep_null_fields("a|b")
    d.expect_fields("m.Msg", "a,b")
    assert_equal(_first(d), 1, "the hooks leave the cursor alone")
    assert_equal(d.read_i64(), Int64(5))
    print("  test_d8_copy_and_no_op_hooks: PASS")


def main() raises:
    test_d6_map_readers()
    test_d7_a_map_entry_counts_as_a_nesting_level()
    test_d8_copy_and_no_op_hooks()
