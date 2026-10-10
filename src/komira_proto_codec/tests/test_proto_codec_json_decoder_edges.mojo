# =============================================================================
# test_proto_codec_json_decoder_edges.mojo — the proto3-JSON codec's edges:
# misuse of a decode cursor, values of the wrong JSON kind, the signed and
# empty enum strings, and map keys that are not strings.
# =============================================================================
#
#   J1  a document that is not a JSON object is refused once, by
#       `next_field()`, at the top and inside a repeated message. Catches:
#       `expect_fields` refusing it first with another message.
#   J2  a read before the first `next_field()` or after the last is refused
#       as a misuse, not an out-of-bounds read.
#   J3  a hand-written decode (no `expect_fields`) refuses an unknown key in
#       `skip()`, naming the key and the line of the key; a `skip()` before
#       any `next_field()` names the key `"?"` and no line. Catches: a line
#       lost from the refusal, and a `line 0` printed for a missing one.
#   J4  a repeated field whose value is not an array, and a map field whose
#       value is not an object, are refused. Catches: a reader that iterates
#       whatever children the value has.
#   J5  an enum string is an integer only when it is digits after at most
#       one sign: "-1" is the integer form, "" "-" "+" are names
#       (and, undeclared, refused). Catches: an empty or a lone-sign string
#       taken for a number, and a sign not accepted.
#   J6  an int32, uint32 and bool map KEY is written as a JSON string while
#       the same scalar as a map VALUE is not. Catches: a key written bare
#       (an invalid JSON object) or a value quoted.
#   J7  `_vocab_group_text` returns the group asked for (first, middle and
#       last), and the empty string for a group past the end of the
#       vocabulary.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    ProtoEnum,
    Serializable,
    WireEncoder,
    WireDecoder,
    JsonEncoder,
    JsonDecoder,
    decode_json,
)
from komira_proto_codec.proto3_json import _vocab_group_text


@fieldwise_init
struct Mode(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):
    var value: Int

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        return String("MODE_ON") if self.value == 1 else String("MODE_UNSET")

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(1) if s == "MODE_ON" else Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "MODE_ON" or s == "MODE_UNSET"

    @staticmethod
    def known_json_names() -> String:
        return String("MODE_UNSET,MODE_ON")


@fieldwise_init
struct Item(Serializable, Copyable, Movable):
    var label: String

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "label", self.label)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("t.Item", "label")
        var label = String("")
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.json_name == "label":
                label = dec.read_string()
            else:
                dec.skip()
        return Item(label^)


@fieldwise_init
struct Holder(Serializable, Copyable, Movable):
    """Generated shape: `expect_fields` first."""

    var mode: Mode
    var items: List[Item]
    var tags: Dict[String, String]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("t.Holder", "mode,items,tags")
        var mode = Mode(0)
        var items = List[Item]()
        var tags = Dict[String, String]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.json_name == "mode":
                mode = dec.read_enum[Mode]()
            elif key.json_name == "items":
                dec.read_into_repeated_message[Item](items)
            elif key.json_name == "tags":
                dec.read_into_string_string_map(tags)
            else:
                dec.skip()
        return Holder(mode, items^, tags^)


@fieldwise_init
struct HandWritten(Serializable, Copyable, Movable):
    """A hand-written conformer: no `expect_fields`, so `skip()` is the only
    thing that can refuse an unknown key."""

    var name: String

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var name = String("")
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.json_name == "name":
                name = dec.read_string()
            else:
                dec.skip()
        return HandWritten(name^)


def _refusal_of[T: Serializable & Deinitable](doc: String) raises -> String:
    try:
        _ = decode_json[T](doc)
    except e:
        return String(e)
    return String("")


# =============================================================================
# J1
# =============================================================================


def test_j1_a_non_object_document_is_refused_by_next_field() raises:
    comptime WANT = "JsonError: decode source is not a JSON object"
    assert_equal(_refusal_of[Holder](String("[1]")), String(WANT), "top")
    assert_equal(
        _refusal_of[Holder](String('{"items":[{"label":"a"},7]}')),
        String(WANT),
        "a repeated message element that is a number",
    )
    print("  test_j1_a_non_object_document_is_refused_by_next_field: PASS")


# =============================================================================
# J2
# =============================================================================


def test_j2_a_read_outside_a_field_is_refused() raises:
    comptime WANT = "JsonError: read_* before next_field()"
    var before = JsonDecoder.from_text(String('{"name":"x"}'))
    var got = String("")
    try:
        _ = before.read_string()
    except e:
        got = String(e)
    assert_equal(got, String(WANT), "a read before the first next_field()")

    var after = JsonDecoder.from_text(String('{"name":"x"}'))
    _ = after.next_field()
    assert_true(after.next_field().end, "one key, then the end")
    got = String("")
    try:
        _ = after.read_string()
    except e:
        got = String(e)
    assert_equal(got, String(WANT), "a read after the last next_field()")
    print("  test_j2_a_read_outside_a_field_is_refused: PASS")


# =============================================================================
# J3
# =============================================================================


def test_j3_skip_refuses_an_unknown_key_naming_its_line() raises:
    var got = _refusal_of[HandWritten](String('{"name":"a",\n  "nmae":"b"}'))
    assert_true(
        got.startswith(
            String('JsonError: unknown field "nmae" at $ (line 2) — ')
        ),
        String("the refusal names the key and its line; got: ") + got,
    )
    assert_equal(
        _refusal_of[HandWritten](String('{"name":"a"}')),
        String(""),
        "the same document without the unknown key is admitted",
    )

    var early = JsonDecoder.from_text(String('{"name":"x"}'))
    got = String("")
    try:
        early.skip()
    except e:
        got = String(e)
    assert_true(
        got.startswith(String('JsonError: unknown field "?" at $ — ')),
        String("a skip before next_field() names no key and no line; got: ")
        + got,
    )
    print("  test_j3_skip_refuses_an_unknown_key_naming_its_line: PASS")


# =============================================================================
# J4
# =============================================================================


def test_j4_a_value_of_the_wrong_kind_is_refused() raises:
    assert_equal(
        _refusal_of[Holder](String('{"items":{"label":"a"}}')),
        String("JsonError: expected a JSON array for repeated field"),
        "a repeated field given an object",
    )
    assert_equal(
        _refusal_of[Holder](String('{"tags":["a"]}')),
        String("JsonError: expected a JSON object for map field"),
        "a map field given an array",
    )
    var ok = decode_json[Holder](
        String('{"items":[{"label":"a"}],"tags":{"k":"v"}}')
    )
    assert_equal(ok.items[0].label, String("a"), "the inversion: an array")
    assert_equal(ok.tags["k"], String("v"), "the inversion: an object")
    print("  test_j4_a_value_of_the_wrong_kind_is_refused: PASS")


# =============================================================================
# J5
# =============================================================================


def test_j5_signed_and_empty_enum_strings() raises:
    assert_equal(
        decode_json[Holder](String('{"mode":"-1"}')).mode.value,
        -1,
        "a negative numeric string is the integer form",
    )
    var empty = _refusal_of[Holder](String('{"mode":""}'))
    assert_true(
        empty.startswith(String('JsonError: unknown enum value "" at $.mode')),
        String("an empty string is an (undeclared) name; got: ") + empty,
    )
    for sign in [String("-"), String("+")]:
        var got = _refusal_of[Holder](String('{"mode":"') + sign + '"}')
        assert_true(
            got.startswith(
                String('JsonError: unknown enum value "') + sign + '" at $.mode'
            ),
            String("a lone sign is an (undeclared) name; got: ") + got,
        )
    print("  test_j5_signed_and_empty_enum_strings: PASS")


# =============================================================================
# J6
# =============================================================================


def test_j6_non_string_map_keys_are_quoted() raises:
    var enc = JsonEncoder()
    enc.begin_map_field(1, "byI32")
    enc.begin_map_entry()
    enc.write_i32_field(1, "key", Int32(-7))
    enc.write_i32_field(2, "value", Int32(3))
    enc.end_map_entry()
    enc.end_map_field()
    enc.begin_map_field(2, "byU32")
    enc.begin_map_entry()
    enc.write_u32_field(1, "key", UInt32(4294967295))
    enc.write_u32_field(2, "value", UInt32(5))
    enc.end_map_entry()
    enc.end_map_field()
    enc.begin_map_field(3, "byBool")
    enc.begin_map_entry()
    enc.write_bool_field(1, "key", True)
    enc.write_bool_field(2, "value", False)
    enc.end_map_entry()
    enc.begin_map_entry()
    enc.write_bool_field(1, "key", False)
    enc.write_bool_field(2, "value", True)
    enc.end_map_entry()
    enc.end_map_field()
    enc.finish()
    assert_equal(
        enc^.into_string(),
        String(
            '{"byI32":{"-7":3},"byU32":{"4294967295":5},'
            '"byBool":{"true":false,"false":true}}'
        ),
        "a key is a JSON string; a value is the bare scalar",
    )
    print("  test_j6_non_string_map_keys_are_quoted: PASS")


# =============================================================================
# J7
# =============================================================================


def test_j7_vocab_group_text() raises:
    var vocab = "a|b,c,dd|e"
    assert_equal(_vocab_group_text(vocab, 0), String("a|b"), "group 0")
    assert_equal(_vocab_group_text(vocab, 1), String("c"), "a middle group")
    assert_equal(_vocab_group_text(vocab, 2), String("dd|e"), "the last group")
    assert_equal(_vocab_group_text(vocab, 3), String(""), "one past the end")
    assert_equal(_vocab_group_text("", 1), String(""), "an empty vocabulary")
    print("  test_j7_vocab_group_text: PASS")


def main() raises:
    test_j1_a_non_object_document_is_refused_by_next_field()
    test_j2_a_read_outside_a_field_is_refused()
    test_j3_skip_refuses_an_unknown_key_naming_its_line()
    test_j4_a_value_of_the_wrong_kind_is_refused()
    test_j5_signed_and_empty_enum_strings()
    test_j6_non_string_map_keys_are_quoted()
    test_j7_vocab_group_text()
