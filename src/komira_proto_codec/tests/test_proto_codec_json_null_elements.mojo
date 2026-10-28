# =============================================================================
# test_proto_codec_json_null_elements.mojo — a repeated
# `google.protobuf.NullValue` field survives a JSON round trip.
# =============================================================================
#
# The protobuf JSON mapping writes a NullValue as the literal `null`, in a
# repeated field as in a singular one, and `JsonEncoder` does. Reading the
# array back must give one NULL_VALUE per `null` element: the array itself is
# the value of its key, so the decoder's skipping of null-valued keys is not
# in play.
#
#   N1  `{"nulls":[null,null]}` is what a repeated NullValue encodes to, and
#       it decodes to two elements. Catches: an element reader that has no
#       branch for `null` (it raised on text its own encoder wrote).
#   N2  null, the name and the number mix in one array. Catches: a reader that
#       handles `null` only when it comes first or alone.
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import (
    ProtoNullValueEnum,
    Serializable,
    WireDecoder,
    WireEncoder,
    decode_json,
    encode_json,
)


@fieldwise_init
struct Nothing(ProtoNullValueEnum, Copyable, Movable, ImplicitlyCopyable):
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
struct Nulls(Serializable, Copyable, Movable):
    """`message Nulls { repeated NullValue nulls = 1; }`."""

    var nulls: List[Nothing]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.begin_list_field(1, "nulls")
        for i in range(len(self.nulls)):
            enc.write_enum_element(1, self.nulls[i])
        enc.end_list_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("t.Nulls", "nulls")
        var nulls = List[Nothing]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "nulls":
                dec.read_into_repeated_enum[Nothing](nulls)
            else:
                dec.skip()
        return Nulls(nulls^)


def test_n1_a_repeated_null_value_round_trips() raises:
    var items = List[Nothing]()
    items.append(Nothing(0))
    items.append(Nothing(0))
    var msg = Nulls(items^)
    var text = encode_json(msg)
    assert_equal(text, String('{"nulls":[null,null]}'))
    var back = decode_json[Nulls](text)
    assert_equal(len(back.nulls), 2)
    assert_equal(back.nulls[0].value, 0)
    assert_equal(back.nulls[1].value, 0)
    print("  test_n1_a_repeated_null_value_round_trips: PASS")


def test_n2_null_name_and_number_mix() raises:
    var back = decode_json[Nulls](String('{"nulls":["NULL_VALUE",null,0,null]}'))
    assert_equal(len(back.nulls), 4)
    for i in range(4):
        assert_equal(back.nulls[i].value, 0)
    print("  test_n2_null_name_and_number_mix: PASS")


def main() raises:
    test_n1_a_repeated_null_value_round_trips()
    test_n2_null_name_and_number_mix()
