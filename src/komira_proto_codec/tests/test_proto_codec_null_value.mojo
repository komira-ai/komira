# =============================================================================
# test_proto_codec_null_value.mojo — a google.protobuf.NullValue field.
# =============================================================================
#
# The protobuf JSON mapping writes a field of the enum
# `google.protobuf.NullValue` as the JSON literal `null`, and reads `null`
# back as its one value, NULL_VALUE. Everywhere else proto3 JSON reads
# `null` as "absent", so a oneof whose arm is a NullValue (Firestore's
# `Value`: `{"nullValue": null}`) would decode with NO arm set unless the
# message names that key to the decoder (`keep_null_fields`), which the
# generator does for exactly these fields.
#
# The message below is hand-written as protoc-gen-mojo emits one (a oneof
# of a NullValue arm and a string arm), with a local stand-in for
# komira_wkt's NullValue: this package cannot import komira_wkt.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    ProtoNullValueEnum,
    Serializable,
    WireDecoder,
    WireEncoder,
    decode_json,
    decode_json_lenient,
    decode_proto,
    encode_json,
    encode_proto,
)


@fieldwise_init
struct Null(ProtoNullValueEnum, Copyable, Movable, ImplicitlyCopyable):
    var value: Int

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        return String("NULL_VALUE")

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "NULL_VALUE"

    @staticmethod
    def known_json_names() -> String:
        return String("NULL_VALUE")


@fieldwise_init
struct Val(Serializable, Copyable, Movable):
    """oneof kind { NullValue null_value = 1; string s = 2; }, plus a plain
    string `note = 3` whose `null` stays "absent"."""

    var note: String
    var _oneof0_case: Int
    var null_value: Optional[Null]
    var s: Optional[String]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(3, "note", self.note)
        if self._oneof0_case == 1:
            enc.write_enum_field[Null](1, "nullValue", self.null_value.value())
        elif self._oneof0_case == 2:
            enc.write_string_field(2, "s", self.s.value())

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("t.Val", "note,nullValue|null_value,s")
        dec.keep_null_fields("nullValue|null_value")
        var note = String("")
        var arm = 0
        var null_value: Optional[Null] = None
        var s: Optional[String] = None
        while True:
            var k = dec.next_field()
            if k.end:
                break
            if k.field_no == 3 or k.json_name == "note":
                note = dec.read_string()
            elif k.field_no == 1 or k.json_name == "nullValue" or k.json_name == "null_value":
                null_value = dec.read_enum[Null]()
                arm = 1
            elif k.field_no == 2 or k.json_name == "s":
                s = dec.read_string()
                arm = 2
            else:
                dec.skip()
        return Self(note^, arm, null_value, s^)


def test_null_arm_writes_json_null() raises:
    var v = Val(String("n"), 1, Null(0), None)
    assert_equal(encode_json(v), String('{"note":"n","nullValue":null}'))


def test_json_null_reads_back_as_the_arm() raises:
    for text in [
        String('{"nullValue":null}'),
        String('{"null_value":null}'),
        # The name form is accepted too, as for any enum.
        String('{"nullValue":"NULL_VALUE"}'),
        String('{"nullValue":0}'),
    ]:
        var v = decode_json[Val](text)
        assert_equal(v._oneof0_case, 1, text)
        assert_equal(v.null_value.value().value, 0)
    var lenient = decode_json_lenient[Val](String('{"nullValue":null,"x":1}'))
    assert_equal(lenient._oneof0_case, 1)


def test_another_fields_null_is_still_absent() raises:
    var v = decode_json[Val](String('{"note":null,"s":null}'))
    assert_equal(v.note, String(""))
    # `s`'s null is "not set": no arm.
    assert_equal(v._oneof0_case, 0)


def test_binary_wire_is_an_ordinary_enum() raises:
    var v = Val(String(""), 1, Null(0), None)
    var back = decode_proto[Val](encode_proto(v))
    assert_equal(back._oneof0_case, 1)
    # A zero enum in a oneof is still written, so the arm survives.
    assert_true(len(encode_proto(v)) > 0)


def main() raises:
    test_null_arm_writes_json_null()
    test_json_null_reads_back_as_the_arm()
    test_another_fields_null_is_still_absent()
    test_binary_wire_is_an_ordinary_enum()
    print("OK")
