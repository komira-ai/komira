# =============================================================================
# test_crm_field_numbers.mojo
# =============================================================================
#
# THE WIRE CENSUS for `komira.crm.v1`: field numbers as binary bytes, field
# names as proto3 JSON keys, enum numbers as their names.
#
# A stored row body and a client's request are only as stable as these
# numbers and names. Renumbering or renaming a field is legal to protoc and
# compiles clean, so this file is the guard.
#
# BINARY. For Account, Deal, Activity, Pipeline (with its Stage) and
# CustomFieldDef, a byte stream is written by hand here, field by field, with
# the number and wire type the proto declares and a value no other field of
# the message holds. Then:
#   1. it is decoded and every field is read back BY NAME, which catches two
#      fields of one wire type swapping numbers;
#   2. the decoded message is encoded again and must give the hand-written
#      bytes back exactly (the encoder writes fields in number order), which
#      catches a field moved to an unused number and a changed wire type.
# A map entry is a nested message with the key as field 1 and the value as
# field 2.
#
# JSON. The same messages, an AccountContact, a ChangesResponse, an
# EraseSubjectResponse and an ErrorResponse, are encoded as proto3 JSON and
# compared with literal documents: every key (lowerCamel), a 64-bit integer
# as a string, an enum as its name, a Timestamp as RFC 3339.
#
# ENUMS. Each value's number and name, both ways.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from komira_crm_proto.crm import (
    Account,
    AccountContact,
    Activity,
    ActivityKind,
    ChangesResponse,
    CustomFieldDef,
    Deal,
    EntityKind,
    EraseSubjectResponse,
    ErrorResponse,
    FieldType,
    Pipeline,
    StageKind,
    Status,
)


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    """A varint record: tag (wire type 0), then the value."""
    _varint(b, UInt64(field << 3))
    _varint(b, v)


def _len(mut b: List[UInt8], field: Int, payload: List[UInt8]):
    """A length-delimited record (wire type 2)."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(len(payload)))
    for c in payload:
        b.append(c)


def _str(mut b: List[UInt8], field: Int, s: String):
    var p = List[UInt8]()
    for c in s.as_bytes():
        p.append(c)
    _len(b, field, p)


def _principal(issuer: String, subject: String) -> List[UInt8]:
    """Principal: 1 issuer, 2 subject."""
    var b = List[UInt8]()
    _str(b, 1, issuer)
    _str(b, 2, subject)
    return b^


def _timestamp(seconds: UInt64, nanos: UInt64) -> List[UInt8]:
    """google.protobuf.Timestamp: 1 seconds, 2 nanos (komira_wkt writes both)."""
    var b = List[UInt8]()
    _uint(b, 1, seconds)
    _uint(b, 2, nanos)
    return b^


def _entry(key: String, value: String) -> List[UInt8]:
    """A map<string, string> entry: 1 key, 2 value."""
    var b = List[UInt8]()
    _str(b, 1, key)
    _str(b, 2, value)
    return b^


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef").as_bytes()
    var out = String()
    for i in range(len(b)):
        out += chr(Int(digits[Int(b[i]) >> 4]))
        out += chr(Int(digits[Int(b[i]) & 15]))
    return out^


def _account_bytes() -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, "a1")
    _str(b, 2, "org1")
    _len(b, 3, _principal("iss", "sub"))
    _str(b, 4, "example.org")
    _uint(b, 5, 1)  # ARCHIVED
    _str(b, 6, "ext-a")
    _len(b, 7, _entry("tier", "gold"))
    _uint(b, 8, 4)
    _uint(b, 9, 12)
    _len(b, 10, _timestamp(1790000000, 5))
    _len(b, 11, _timestamp(1790000100, 6))
    return b^


comptime _ACCOUNT_JSON = (
    '{"id":"a1","orgCardId":"org1","owner":{"issuer":"iss","subject":"sub"},'
    '"domain":"example.org","status":"ARCHIVED","externalId":"ext-a",'
    '"customFields":{"tier":"gold"},"version":"4","modseq":"12",'
    '"createdAt":"2026-09-21T14:13:20.000000005Z","updatedAt":"2026-09-21T14:15:00.000000006Z"}'
)


def test_account() raises:
    var want = _account_bytes()
    var a = decode_proto[Account](want.copy())
    assert_equal(a.id, "a1")
    assert_equal(a.org_card_id, "org1")
    assert_equal(a.owner.value().issuer, "iss")
    assert_equal(a.owner.value().subject, "sub")
    assert_equal(a.domain, "example.org")
    assert_equal(a.status.value, Status.ARCHIVED)
    assert_equal(a.external_id, "ext-a")
    assert_equal(a.custom_fields["tier"], "gold")
    assert_equal(a.version, UInt64(4))
    assert_equal(a.modseq, UInt64(12))
    assert_equal(a.created_at.value().seconds, Int64(1790000000))
    assert_equal(a.created_at.value().nanos, Int32(5))
    assert_equal(a.updated_at.value().seconds, Int64(1790000100))
    assert_equal(_hex(encode_proto(a)), _hex(want), "Account re-encodes to the hand-written bytes")
    assert_equal(encode_json(a), String(_ACCOUNT_JSON))
    var back = decode_json[Account](String(_ACCOUNT_JSON))
    assert_equal(_hex(encode_proto(back)), _hex(want), "Account JSON decodes to the same message")


def _deal_bytes() -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, "d1")
    _str(b, 2, "p1")
    _str(b, 3, "proposal")
    _str(b, 4, "Renewal")
    _str(b, 5, "a1")
    _str(b, 6, "c1")
    _uint(b, 7, 123456)
    _str(b, 8, "EUR")
    _str(b, 9, "2026-12-31")
    _len(b, 10, _principal("iss", "owner"))
    _str(b, 11, "ext-d")
    _uint(b, 12, 1)  # ARCHIVED
    _len(b, 13, _entry("source", "web"))
    _len(b, 14, _timestamp(1790000200, 7))
    _uint(b, 15, 3)
    _uint(b, 16, 21)
    _len(b, 17, _timestamp(1790000000, 8))
    _len(b, 18, _timestamp(1790000300, 9))
    return b^


comptime _DEAL_JSON = (
    '{"id":"d1","pipelineId":"p1","stageKey":"proposal","title":"Renewal","accountId":"a1",'
    '"primaryContactCardId":"c1","amountMinor":"123456","currency":"EUR","closeDate":"2026-12-31",'
    '"owner":{"issuer":"iss","subject":"owner"},"externalId":"ext-d","status":"ARCHIVED",'
    '"customFields":{"source":"web"},"lastActivityAt":"2026-09-21T14:16:40.000000007Z",'
    '"version":"3","modseq":"21","createdAt":"2026-09-21T14:13:20.000000008Z",'
    '"updatedAt":"2026-09-21T14:18:20.000000009Z"}'
)


def test_deal() raises:
    var want = _deal_bytes()
    var d = decode_proto[Deal](want.copy())
    assert_equal(d.id, "d1")
    assert_equal(d.pipeline_id, "p1")
    assert_equal(d.stage_key, "proposal")
    assert_equal(d.title, "Renewal")
    assert_equal(d.account_id, "a1")
    assert_equal(d.primary_contact_card_id, "c1")
    assert_equal(d.amount_minor, Int64(123456))
    assert_equal(d.currency, "EUR")
    assert_equal(d.close_date, "2026-12-31")
    assert_equal(d.owner.value().subject, "owner")
    assert_equal(d.external_id, "ext-d")
    assert_equal(d.status.value, Status.ARCHIVED)
    assert_equal(d.custom_fields["source"], "web")
    assert_equal(d.last_activity_at.value().nanos, Int32(7))
    assert_equal(d.version, UInt64(3))
    assert_equal(d.modseq, UInt64(21))
    assert_equal(d.created_at.value().nanos, Int32(8))
    assert_equal(d.updated_at.value().nanos, Int32(9))
    assert_equal(_hex(encode_proto(d)), _hex(want), "Deal re-encodes to the hand-written bytes")
    assert_equal(encode_json(d), String(_DEAL_JSON))
    var back = decode_json[Deal](String(_DEAL_JSON))
    assert_equal(_hex(encode_proto(back)), _hex(want), "Deal JSON decodes to the same message")


def test_activity() raises:
    var want = List[UInt8]()
    _str(want, 1, "act1")
    _uint(want, 2, 4)  # STAGE_CHANGED
    _uint(want, 3, 2)  # DEAL
    _str(want, 4, "d1")
    _str(want, 5, "moved")
    _len(want, 6, _principal("iss", "actor"))
    _len(want, 7, _timestamp(1790000400, 1))
    _uint(want, 8, 1)
    _uint(want, 9, 2)
    _uint(want, 10, 22)
    _str(want, 11, "discovery")
    _str(want, 12, "proposal")
    var a = decode_proto[Activity](want.copy())
    assert_equal(a.id, "act1")
    assert_equal(a.kind.value, ActivityKind.STAGE_CHANGED)
    assert_equal(a.subject_kind.value, EntityKind.DEAL)
    assert_equal(a.subject_id, "d1")
    assert_equal(a.body, "moved")
    assert_equal(a.actor.value().subject, "actor")
    assert_equal(a.occurred_at.value().seconds, Int64(1790000400))
    assert_true(a.system)
    assert_equal(a.version, UInt64(2))
    assert_equal(a.modseq, UInt64(22))
    assert_equal(a.from_stage_key, "discovery")
    assert_equal(a.to_stage_key, "proposal")
    assert_equal(_hex(encode_proto(a)), _hex(want), "Activity re-encodes to the hand-written bytes")
    assert_equal(
        encode_json(a),
        '{"id":"act1","kind":"STAGE_CHANGED","subjectKind":"DEAL","subjectId":"d1","body":"moved",'
        + '"actor":{"issuer":"iss","subject":"actor"},"occurredAt":"2026-09-21T14:20:00.000000001Z",'
        + '"system":true,"version":"2","modseq":"22","fromStageKey":"discovery","toStageKey":"proposal"}',
    )


def test_pipeline() raises:
    var stage = List[UInt8]()
    _str(stage, 1, "closed_won")
    _str(stage, 2, "Won")
    _uint(stage, 3, 1)  # WON
    var want = List[UInt8]()
    _str(want, 1, "p1")
    _str(want, 2, "Sales")
    _len(want, 3, stage)
    _uint(want, 4, 6)
    _uint(want, 5, 30)
    var p = decode_proto[Pipeline](want.copy())
    assert_equal(p.id, "p1")
    assert_equal(p.name, "Sales")
    assert_equal(p.stages[0].key, "closed_won")
    assert_equal(p.stages[0].label, "Won")
    assert_equal(p.stages[0].kind.value, StageKind.WON)
    assert_equal(p.version, UInt64(6))
    assert_equal(p.modseq, UInt64(30))
    assert_equal(_hex(encode_proto(p)), _hex(want), "Pipeline re-encodes to the hand-written bytes")
    assert_equal(
        encode_json(p),
        '{"id":"p1","name":"Sales","stages":[{"key":"closed_won","label":"Won","kind":"WON"}],'
        + '"version":"6","modseq":"30"}',
    )


def test_custom_field_def() raises:
    var want = List[UInt8]()
    _str(want, 1, "f1")
    _uint(want, 2, 3)  # CARD
    _str(want, 3, "tier")
    _str(want, 4, "Tier")
    _uint(want, 5, 2)  # DATE
    _uint(want, 6, 8)
    _uint(want, 7, 40)
    var f = decode_proto[CustomFieldDef](want.copy())
    assert_equal(f.id, "f1")
    assert_equal(f.entity_kind.value, EntityKind.CARD)
    assert_equal(f.key, "tier")
    assert_equal(f.label, "Tier")
    assert_equal(f.type.value, FieldType.DATE)
    assert_equal(f.version, UInt64(8))
    assert_equal(f.modseq, UInt64(40))
    assert_equal(_hex(encode_proto(f)), _hex(want), "CustomFieldDef re-encodes to the hand-written bytes")
    assert_equal(
        encode_json(f),
        '{"id":"f1","entityKind":"CARD","key":"tier","label":"Tier","type":"DATE","version":"8","modseq":"40"}',
    )


def test_small_messages_json() raises:
    var link = List[UInt8]()
    _str(link, 1, "a1")
    _str(link, 2, "c1")
    _str(link, 3, "buyer")
    var ac = decode_proto[AccountContact](link.copy())
    assert_equal(ac.account_id, "a1")
    assert_equal(ac.card_id, "c1")
    assert_equal(ac.role, "buyer")
    assert_equal(_hex(encode_proto(ac)), _hex(link), "AccountContact re-encodes to the hand-written bytes")
    comptime changes = '{"changes":[{"kind":"PIPELINE","id":"p1","modseq":"7"}],"modseq":"7"}'
    assert_equal(encode_json(decode_json[ChangesResponse](changes)), changes)
    var feed = List[UInt8]()
    var entry = List[UInt8]()
    _uint(entry, 1, 5)  # PIPELINE
    _str(entry, 2, "p1")
    _uint(entry, 3, 7)
    _len(feed, 1, entry)
    _uint(feed, 2, 7)
    assert_equal(_hex(encode_proto(decode_json[ChangesResponse](changes))), _hex(feed))
    comptime erased = '{"accounts":1,"deals":2,"activities":3}'
    var counts = decode_json[EraseSubjectResponse](erased)
    assert_equal(counts.deals, UInt32(2))
    assert_equal(encode_json(counts), erased)
    var counts_bytes = List[UInt8]()
    _uint(counts_bytes, 1, 1)
    _uint(counts_bytes, 2, 2)
    _uint(counts_bytes, 3, 3)
    assert_equal(_hex(encode_proto(counts)), _hex(counts_bytes))
    comptime err = '{"error":{"code":"not_found","message":"not found","field":"dealId"}}'
    assert_equal(encode_json(decode_json[ErrorResponse](err)), err)


def test_enums() raises:
    assert_equal(Status.ACTIVE, 0)
    assert_equal(Status.ARCHIVED, 1)
    assert_equal(StageKind.OPEN, 0)
    assert_equal(StageKind.WON, 1)
    assert_equal(StageKind.LOST, 2)
    assert_equal(ActivityKind.NOTE, 0)
    assert_equal(ActivityKind.CALL, 1)
    assert_equal(ActivityKind.MEETING, 2)
    assert_equal(ActivityKind.EMAIL_LOGGED, 3)
    assert_equal(ActivityKind.STAGE_CHANGED, 4)
    assert_equal(EntityKind.ENTITY_KIND_UNSPECIFIED, 0)
    assert_equal(EntityKind.ACCOUNT, 1)
    assert_equal(EntityKind.DEAL, 2)
    assert_equal(EntityKind.CARD, 3)
    assert_equal(EntityKind.ACTIVITY, 4)
    assert_equal(EntityKind.PIPELINE, 5)
    assert_equal(EntityKind.CUSTOM_FIELD_DEF, 6)
    assert_equal(FieldType.TEXT, 0)
    assert_equal(FieldType.NUMBER, 1)
    assert_equal(FieldType.DATE, 2)
    assert_equal(FieldType.BOOL, 3)
    assert_equal(ActivityKind(ActivityKind.EMAIL_LOGGED).json_name(), "EMAIL_LOGGED")
    assert_equal(EntityKind(EntityKind.CUSTOM_FIELD_DEF).json_name(), "CUSTOM_FIELD_DEF")
    assert_equal(EntityKind.from_json_name("ACTIVITY").value, 4)
    assert_equal(StageKind.from_json_name("LOST").value, 2)
    assert_equal(FieldType.from_json_name("BOOL").value, 3)
    assert_equal(Status.from_json_name("ARCHIVED").value, 1)


def main() raises:
    test_account()
    test_deal()
    test_activity()
    test_pipeline()
    test_custom_field_def()
    test_small_messages_json()
    test_enums()
    print("PASS komira_crm_proto field numbers")
