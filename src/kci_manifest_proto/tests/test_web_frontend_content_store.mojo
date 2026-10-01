# =============================================================================
# test_web_frontend_content_store.mojo
# =============================================================================
#
# `WebFrontendSpec.content_store` (field 12) on the wire, both encodings.
#
# WHAT IS ASSERTED, AND WHAT EACH ONE CATCHES:
#   1. The protobuf-binary record of `content_store` is written out literally:
#      tag 0x62 is field 12, wire type 2. The codec writes fields in number
#      order, so the record is the tail of the encoding. A renumber is
#      protoc-legal and round-trips cleanly through the same generated code, so
#      only a literal statement of the NUMBER fails on one.
#   2. Binary round trip: the value written is the value read, and it lands in
#      `content_store`, not in a neighbouring string field.
#   3. proto3 JSON: the key is `contentStore`, and the value round-trips.
#   4. The field is additive: an encoding with the field-12 record removed
#      (the bytes a writer without the field produces) decodes with an EMPTY
#      `content_store` and every other field intact. The old bytes are built by
#      cutting the known record off a NON-empty store's encoding, so the test
#      does not depend on whether the codec writes a default-valued field.
# =============================================================================

from komira_serde import decode_json, decode_proto, encode_json, encode_proto
from std.testing import assert_equal, assert_true

from kci_manifest_proto.full_manifest import (
    WebFrontendSpec,
    WebRouteRule,
    WebRuntimeConfigEntry,
)


comptime _STORE = "build-once-content"


def _spec(content_store: String, content_digest: String = "") -> WebFrontendSpec:
    """A spec with every other field at its proto3 default."""
    return WebFrontendSpec(
        web_slug=String(""),
        domain=String(""),
        additional_domains=List[String](),
        content_bucket=String(""),
        spa_fallback_document=String(""),
        api_path_prefixes=List[String](),
        api_service_logical_id=String(""),
        cdn_enabled=False,
        content_digest=content_digest,
        runtime_config=List[WebRuntimeConfigEntry](),
        route_rules=List[WebRouteRule](),
        content_store=content_store,
    )


def test_field_12_wire_bytes() raises:
    var got = encode_proto(_spec(String(_STORE)))
    var want = List[UInt8]()
    want.append(0x62)  # (12 << 3) | 2: field 12, length-delimited
    want.append(UInt8(String(_STORE).byte_length()))
    for b in String(_STORE).as_bytes():
        want.append(b)
    var start = len(got) - len(want)
    assert_true(start >= 0, "encoding shorter than the field-12 record")
    for i in range(len(want)):
        assert_equal(
            got[start + i], want[i], "field-12 record: byte " + String(i)
        )


def test_binary_round_trip() raises:
    var spec = _spec(String(_STORE), String("content-sha256:00"))
    var back = decode_proto[WebFrontendSpec](encode_proto(spec))
    assert_equal(back.content_store, _STORE)
    assert_equal(back.content_digest, "content-sha256:00")


def test_json_round_trip() raises:
    var spec = _spec(String(_STORE))
    var text = encode_json(spec)
    assert_true(
        String('"contentStore":"') + _STORE + '"' in text,
        "proto3 JSON key for field 12 is contentStore; got: " + text,
    )
    var back = decode_json[WebFrontendSpec](text)
    assert_equal(back.content_store, _STORE)


def test_absent_field_decodes_empty() raises:
    # Encode a non-empty store, check that the tail is exactly the field-12
    # record (0x62, length, payload), and cut it off: the bytes a writer
    # without field 12 produces.
    var full = encode_proto(_spec(String(_STORE), String("content-sha256:00")))
    var payload = String(_STORE).as_bytes()
    var rec_len = 2 + len(payload)
    var n = len(full)
    assert_true(n >= rec_len, "encoding shorter than the field-12 record")
    var start = n - rec_len
    assert_equal(full[start], UInt8(0x62), "tail record is field 12")
    assert_equal(
        full[start + 1], UInt8(len(payload)), "field-12 record length"
    )
    for i in range(len(payload)):
        assert_equal(
            full[start + 2 + i], payload[i], "field-12 payload byte " + String(i)
        )
    var old = List[UInt8]()
    for i in range(start):
        old.append(full[i])
    var back = decode_proto[WebFrontendSpec](old^)
    assert_equal(back.content_store, "")
    assert_equal(back.content_digest, "content-sha256:00")


def main() raises:
    print("test_field_12_wire_bytes")
    test_field_12_wire_bytes()
    print("test_binary_round_trip")
    test_binary_round_trip()
    print("test_json_round_trip")
    test_json_round_trip()
    print("test_absent_field_decodes_empty")
    test_absent_field_decodes_empty()
    print("test_web_frontend_content_store: PASS")
