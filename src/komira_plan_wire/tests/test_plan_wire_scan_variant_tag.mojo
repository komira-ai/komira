# =============================================================================
# test_plan_wire_scan_variant_tag.mojo — a binding's `variant_tag` is held to
# the numbers plan_vocabulary.proto puts on the wire.
# =============================================================================
#
# `SourceVariantTag` 1 (SOURCE_VARIANT_PARQUET) and 2 (SOURCE_VARIANT_IN_MEMORY)
# are reserved in the .proto: neither arm carries a `ScanBinding`. A
# `WireScanBinding` naming one used to decode into a `SourceVariant` whose tag
# says "concrete arm" while its payload sat in `_binding`, and the scan factory
# then read the empty concrete Optional: `plan_from_bytes` aborted the process
# (exit 132) on 300 bytes instead of raising.
#
# THE BYTES ARE protoc's. Each decode test starts from
# `golden/scan.canonical.hex` (protoc's encoding of `golden/scan.txtpb`, a
# binding scan with `variant_tag: SOURCE_VARIANT_ORC`) and rewrites the one
# byte holding the `variant_tag` value. Field 14, varint: the key byte is 0x70
# and the value is one byte, so the rewrite changes no length and the result
# is a well-formed `WirePlanEnvelope` that differs only in that enum value.
#
# WHAT EACH TEST PROVES, AND THE DEFECT IT CATCHES:
#
#   test_the_unedited_golden_decodes
#       The control: the bytes before the rewrite decode, and hold exactly one
#       `variant_tag` key/value pair to rewrite.
#       Catches: a refusal below that is about the fixture, not the tag.
#
#   test_variant_tag_parquet_is_refused / test_variant_tag_in_memory_is_refused
#       The rewritten bytes are refused with the reserved-number message.
#       Catches: the abort (the build fails, because the test binary dies),
#       and a decoder that accepts either reserved number.
#
#   test_a_reserved_variant_tag_is_not_encoded
#       `binding_to_bytes` refuses to write either reserved number, and still
#       writes SOURCE_VARIANT_BINDING.
#       Catches: an encoder that writes bytes this decoder refuses.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import SchemaBuilder
from komira_plan_wire import binding_to_bytes, plan_from_bytes
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import ScanBinding
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import (
    SOURCE_VARIANT_BINDING,
    SOURCE_VARIANT_IN_MEMORY,
    SOURCE_VARIANT_PARQUET,
)


comptime _SCAN_CANONICAL: String = "src/komira_plan_wire/tests/fixtures/golden/scan.canonical.hex"

# `WireScanBinding.variant_tag` is field 14, wire type 0: key (14 << 3) | 0.
comptime _VARIANT_TAG_KEY: UInt8 = 0x70
# SOURCE_VARIANT_ORC, the value scan.txtpb carries.
comptime _ORC_WIRE: UInt8 = 8


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    raise Error("scan.canonical.hex holds a non-hex byte " + String(Int(c)))


def _golden() raises -> List[UInt8]:
    var text: String
    with open(_SCAN_CANONICAL, "r") as f:
        text = f.read()
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(ord("\n")) or b[i] == UInt8(ord(" ")):
            continue
        nibbles.append(_hex_value(b[i]))
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _variant_tag_offsets(bytes: List[UInt8]) -> List[Int]:
    """Offsets of the value byte of every (0x70, 8) pair."""
    var out = List[Int]()
    for i in range(len(bytes) - 1):
        if bytes[i] == _VARIANT_TAG_KEY and bytes[i + 1] == _ORC_WIRE:
            out.append(i + 1)
    return out^


def _with_variant_tag(wire: UInt8) raises -> List[UInt8]:
    var bytes = _golden()
    var at = _variant_tag_offsets(bytes)
    assert_equal(len(at), 1, "one variant_tag pair in scan.canonical.hex")
    bytes[at[0]] = wire
    return bytes^


def _decode_error(var bytes: List[UInt8]) -> String:
    try:
        _ = plan_from_bytes(bytes^)
    except e:
        return String(e)
    return String()


def test_the_unedited_golden_decodes() raises:
    var bytes = _golden()
    assert_equal(len(_variant_tag_offsets(bytes)), 1, "one variant_tag pair")
    assert_equal(_decode_error(bytes^), String(), "the control decodes")


def test_variant_tag_parquet_is_refused() raises:
    var err = _decode_error(_with_variant_tag(1))
    assert_true(
        "SourceVariantTag: wire value 1 (SOURCE_VARIANT_PARQUET) is reserved"
        in err,
        "variant_tag 1 must be refused as reserved; got: " + err,
    )


def test_variant_tag_in_memory_is_refused() raises:
    var err = _decode_error(_with_variant_tag(2))
    assert_true(
        "SourceVariantTag: wire value 2 (SOURCE_VARIANT_IN_MEMORY) is reserved"
        in err,
        "variant_tag 2 must be refused as reserved; got: " + err,
    )


def _binding() -> ScanBinding:
    var sb = SchemaBuilder()
    return ScanBinding(
        kind_id=UInt32(0),
        kind_name=String(""),
        name=String(""),
        params=ScanParams(),
        schema=sb.build(),
        fingerprint=UInt64(0),
        structural_id=UInt64(0),
        gate=PushdownGate.reject_all(),
    )


def _encode_error(tag: UInt8) -> String:
    try:
        _ = binding_to_bytes(_binding(), tag)
    except e:
        return String(e)
    return String()


def test_a_reserved_variant_tag_is_not_encoded() raises:
    assert_equal(
        _encode_error(SOURCE_VARIANT_PARQUET),
        "SourceVariantTag: engine tag 0 (SOURCE_VARIANT_PARQUET) is reserved"
        + " on the wire: plan_vocabulary.proto keeps it off",
    )
    assert_equal(
        _encode_error(SOURCE_VARIANT_IN_MEMORY),
        "SourceVariantTag: engine tag 1 (SOURCE_VARIANT_IN_MEMORY) is reserved"
        + " on the wire: plan_vocabulary.proto keeps it off",
    )
    assert_equal(_encode_error(SOURCE_VARIANT_BINDING), String(), "the control")


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_unedited_golden_decodes]()
    suite.test[test_variant_tag_parquet_is_refused]()
    suite.test[test_variant_tag_in_memory_is_refused]()
    suite.test[test_a_reserved_variant_tag_is_not_encoded]()
    suite^.run()
