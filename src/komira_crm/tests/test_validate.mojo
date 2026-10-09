# =============================================================================
# test_validate.mojo -- what a client may write (validate.mojo).
# =============================================================================
#
# Every refusal is compared by its exact text, and every limit is tried at
# the bound and one past it, so a check whose comparison is off by one fails
# here:
#
#   lines      a required field empty, a field one byte too long, a control
#              character, a DEL
#   principal  an issuer without a subject and the other way round
#   keys       a-z, 0-9 and _ only, 1 to 64 bytes
#   dates      the format, month 0 and 13, day 0, 31 in a 30-day month,
#              29 February in leap and common years (1900 and 2000 too)
#   pipeline   no stages, 50 and 51 stages, a duplicate key, an empty label
#   deal       money (via check_money), a bad close date
#   activity   STAGE_CHANGED from a client, a subject kind that is not
#              ACCOUNT, DEAL or CARD, an empty subject, an occurred_at at the
#              epoch, a body of 64 KiB and one byte more
#   values     NUMBER, DATE and BOOL text forms; a TEXT value one byte too
#              long
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import decode_json
from komira_crm_proto.crm import Account, Activity, CustomFieldDef, Deal, FieldType, Pipeline, Principal, Stage

from komira_crm import (
    check_account,
    check_activity,
    check_custom_field_def,
    check_date,
    check_deal,
    check_field_value,
    check_key,
    check_pipeline,
    check_principal,
)

comptime OK = "ok"


def _x(n: Int) -> String:
    var s = String()
    for _ in range(n):
        s += "x"
    return s^


def _date(s: String) -> String:
    try:
        check_date(s, "closeDate")
        return String(OK)
    except e:
        return String(e)


def test_dates() raises:
    comptime BAD = "crm: invalid closeDate: must be a date, YYYY-MM-DD"
    comptime NO_DAY = "crm: invalid closeDate: no such day"
    assert_equal(_date("2026-09-30"), OK)
    assert_equal(_date("0001-01-01"), OK, "the first year")
    assert_equal(_date("9999-12-31"), OK, "the last day")
    assert_equal(_date("0000-01-01"), BAD, "year 0")
    assert_equal(_date("2026-00-10"), BAD, "month 0")
    assert_equal(_date("2026-13-10"), BAD, "month 13")
    assert_equal(_date("2026-12-00"), BAD, "day 0")
    assert_equal(_date("2026-12-31"), OK)
    assert_equal(_date("2026-12-32"), NO_DAY)
    assert_equal(_date("2026-09-31"), NO_DAY, "September has 30 days")
    assert_equal(_date("2026-04-31"), NO_DAY)
    assert_equal(_date("2026-06-31"), NO_DAY)
    assert_equal(_date("2026-11-31"), NO_DAY)
    assert_equal(_date("2026-11-30"), OK)
    assert_equal(_date("2026-10-31"), OK, "October has 31")
    assert_equal(_date("2028-02-29"), OK, "a leap year")
    assert_equal(_date("2026-02-29"), NO_DAY, "a common year")
    assert_equal(_date("2026-02-28"), OK)
    assert_equal(_date("1900-02-29"), NO_DAY, "a century is not leap")
    assert_equal(_date("2000-02-29"), OK, "every fourth century is")
    assert_equal(_date("2028-02-30"), NO_DAY)
    for s in ["2026-9-30", "2026/09/30", "2026-09-3a", "20260930", "2026-09-30T00", "", "a026-09-30"]:
        assert_equal(_date(String(s)), BAD, s)


def _line_account(json: String) -> String:
    try:
        check_account(decode_json[Account](json))
        return String(OK)
    except e:
        return String(e)


def test_lines_and_principal() raises:
    assert_equal(_line_account('{"orgCardId":"c1"}'), OK)
    assert_equal(_line_account("{}"), "crm: invalid orgCardId: required")
    assert_equal(_line_account('{"orgCardId":"' + _x(512) + '"}'), OK, "512 bytes")
    assert_equal(_line_account('{"orgCardId":"' + _x(513) + '"}'), "crm: invalid orgCardId: too long")
    comptime CTRL = "crm: invalid domain: must be one line with no control characters"
    assert_equal(_line_account('{"orgCardId":"c","domain":"a\\nb"}'), CTRL)
    assert_equal(_line_account('{"orgCardId":"c","domain":"a\\u001fb"}'), CTRL, "0x1F")
    assert_equal(_line_account('{"orgCardId":"c","domain":"a\\u007fb"}'), CTRL, "DEL")
    assert_equal(_line_account('{"orgCardId":"c","domain":"a b~"}'), OK, "space and ~ are printable")
    comptime HALF = "crm: invalid owner: issuer and subject are both set or both empty"
    assert_equal(_line_account('{"orgCardId":"c","owner":{"issuer":"i"}}'), HALF)
    assert_equal(_line_account('{"orgCardId":"c","owner":{"subject":"s"}}'), HALF)
    assert_equal(_line_account('{"orgCardId":"c","owner":{"issuer":"i","subject":"s"}}'), OK)
    assert_equal(_line_account('{"orgCardId":"c","owner":{}}'), OK, "an empty owner is nobody")
    assert_equal(
        _line_account('{"orgCardId":"c","owner":{"issuer":"i","subject":"s\\t"}}'),
        "crm: invalid owner: must be one line with no control characters",
    )
    assert_equal(
        _line_account('{"orgCardId":"c","owner":{"issuer":"i\\t","subject":"s"}}'),
        "crm: invalid owner: must be one line with no control characters",
    )
    assert_equal(
        _line_account('{"orgCardId":"c","externalId":"e\\r"}'),
        "crm: invalid externalId: must be one line with no control characters",
    )


def _key(k: String) -> String:
    try:
        check_key(k, "key")
        return String(OK)
    except e:
        return String(e)


def test_keys() raises:
    comptime BAD = "crm: invalid key: must be 1 to 64 bytes of a-z, 0-9 and _"
    assert_equal(_key("closed_won"), OK)
    assert_equal(_key("az09_"), OK, "every allowed class and its ends")
    assert_equal(_key(_x(64)), OK)
    assert_equal(_key(_x(65)), BAD)
    assert_equal(_key(""), BAD)
    for k in ["A", "a-b", "a b", "`", "{", "/", ":", "^"]:
        assert_equal(_key(String(k)), BAD, k)


def _pipeline(n_stages: Int, dup: Bool) raises -> String:
    var stages = List[Stage]()
    for i in range(n_stages):
        stages.append(decode_json[Stage]('{"key":"s' + String(i) + '","label":"S"}'))
    if dup:
        stages.append(decode_json[Stage]('{"key":"s0","label":"S"}'))
    var p = decode_json[Pipeline]('{"name":"P"}')
    p.stages = stages^
    try:
        check_pipeline(p)
        return String(OK)
    except e:
        return String(e)


def test_pipeline() raises:
    comptime COUNT = "crm: invalid stages: a pipeline has 1 to 50 stages"
    assert_equal(_pipeline(0, False), COUNT)
    assert_equal(_pipeline(1, False), OK)
    assert_equal(_pipeline(50, False), OK)
    assert_equal(_pipeline(51, False), COUNT)
    assert_equal(_pipeline(2, True), "crm: invalid stages.key: keys must be unique within a pipeline")
    assert_equal(_pipeline(1, True), "crm: invalid stages.key: keys must be unique within a pipeline", "the first two")
    var no_name = decode_json[Pipeline]('{"stages":[{"key":"a","label":"A"}]}')
    var got = String(OK)
    try:
        check_pipeline(no_name)
    except e:
        got = String(e)
    assert_equal(got, "crm: invalid name: required")
    var no_label = decode_json[Pipeline]('{"name":"P","stages":[{"key":"a"}]}')
    try:
        check_pipeline(no_label)
    except e:
        got = String(e)
    assert_equal(got, "crm: invalid stages.label: required")
    var bad_key = decode_json[Pipeline]('{"name":"P","stages":[{"key":"A","label":"A"}]}')
    try:
        check_pipeline(bad_key)
    except e:
        got = String(e)
    assert_equal(got, "crm: invalid stages.key: must be 1 to 64 bytes of a-z, 0-9 and _")


def _deal(json: String) -> String:
    try:
        check_deal(decode_json[Deal](json))
        return String(OK)
    except e:
        return String(e)


def test_deal() raises:
    comptime BASE = '{"title":"T","pipelineId":"p","stageKey":"s"'
    assert_equal(_deal(BASE + "}"), OK)
    assert_equal(_deal('{"pipelineId":"p","stageKey":"s"}'), "crm: invalid title: required")
    assert_equal(_deal('{"title":"T","stageKey":"s"}'), "crm: invalid pipelineId: required")
    assert_equal(_deal('{"title":"T","pipelineId":"p"}'), "crm: invalid stageKey: must be 1 to 64 bytes of a-z, 0-9 and _")
    assert_equal(
        _deal(BASE + ',"accountId":"a\\n"}'), "crm: invalid accountId: must be one line with no control characters"
    )
    assert_equal(
        _deal(BASE + ',"primaryContactCardId":"' + _x(513) + '"}'), "crm: invalid primaryContactCardId: too long"
    )
    assert_equal(_deal(BASE + ',"amountMinor":"5"}'), "crm: invalid currency: required when amountMinor is not 0")
    assert_equal(_deal(BASE + ',"amountMinor":"5","currency":"EUR"}'), OK)
    assert_equal(_deal(BASE + ',"closeDate":"2026-02-30"}'), "crm: invalid closeDate: no such day")
    assert_equal(_deal(BASE + ',"closeDate":"2026-12-31"}'), OK)
    assert_equal(
        _deal(BASE + ',"owner":{"subject":"s"}}'), "crm: invalid owner: issuer and subject are both set or both empty"
    )
    assert_equal(_deal(BASE + ',"externalId":"' + _x(513) + '"}'), "crm: invalid externalId: too long")


def _activity(json: String) -> String:
    try:
        check_activity(decode_json[Activity](json))
        return String(OK)
    except e:
        return String(e)


def test_activity() raises:
    assert_equal(_activity('{"subjectKind":"DEAL","subjectId":"d"}'), OK)
    assert_equal(_activity('{"subjectKind":"ACCOUNT","subjectId":"a","kind":"CALL"}'), OK)
    assert_equal(_activity('{"subjectKind":"CARD","subjectId":"c","kind":"EMAIL_LOGGED"}'), OK)
    assert_equal(
        _activity('{"subjectKind":"DEAL","subjectId":"d","kind":"STAGE_CHANGED"}'),
        "crm: invalid kind: STAGE_CHANGED is written by the service",
    )
    comptime SUBJECT = "crm: invalid subjectKind: must be ACCOUNT, DEAL or CARD"
    for kind in ["ENTITY_KIND_UNSPECIFIED", "ACTIVITY", "PIPELINE", "CUSTOM_FIELD_DEF"]:
        assert_equal(_activity('{"subjectKind":"' + String(kind) + '","subjectId":"x"}'), SUBJECT, kind)
    assert_equal(_activity('{"subjectKind":"DEAL"}'), "crm: invalid subjectId: required")
    assert_equal(
        _activity('{"subjectKind":"DEAL","subjectId":"d","occurredAt":"1970-01-01T00:00:00Z"}'),
        "crm: invalid occurredAt: must be after 1970-01-01T00:00:00Z",
    )
    assert_equal(_activity('{"subjectKind":"DEAL","subjectId":"d","occurredAt":"1970-01-01T00:00:01Z"}'), OK)
    var a = decode_json[Activity]('{"subjectKind":"DEAL","subjectId":"d"}')
    a.body = _x(65536)
    var got = String(OK)
    try:
        check_activity(a)
    except e:
        got = String(e)
    assert_equal(got, OK, "64 KiB of body")
    a.body += "x"
    try:
        check_activity(a)
    except e:
        got = String(e)
    assert_equal(got, "crm: invalid body: too long")


def _field_def(json: String) -> String:
    try:
        check_custom_field_def(decode_json[CustomFieldDef](json))
        return String(OK)
    except e:
        return String(e)


def test_field_def() raises:
    assert_equal(_field_def('{"entityKind":"CARD","key":"tier","label":"Tier"}'), OK)
    assert_equal(
        _field_def('{"entityKind":"PIPELINE","key":"tier","label":"Tier"}'),
        "crm: invalid entityKind: must be ACCOUNT, DEAL or CARD",
    )
    assert_equal(
        _field_def('{"entityKind":"DEAL","key":"Tier","label":"Tier"}'),
        "crm: invalid key: must be 1 to 64 bytes of a-z, 0-9 and _",
    )
    assert_equal(_field_def('{"entityKind":"ACCOUNT","key":"tier"}'), "crm: invalid label: required")


def _value(t: Int, v: String) -> String:
    try:
        check_field_value(t, v)
        return String(OK)
    except e:
        return String(e)


def test_field_values() raises:
    comptime NUM = "crm: invalid customFields: a NUMBER value must be a decimal"
    for v in ["0", "-12", "12.5", "-0.25", "123456789"]:
        assert_equal(_value(FieldType.NUMBER, String(v)), OK, v)
    for v in ["", "-", "1.", ".5", "1.2.3", "1e3", "+1", "1-", "--1", "1 "]:
        assert_equal(_value(FieldType.NUMBER, String(v)), NUM, v)
    assert_equal(_value(FieldType.DATE, "2026-10-09"), OK)
    assert_equal(_value(FieldType.DATE, "2026-10-32"), "crm: invalid customFields: no such day")
    assert_equal(_value(FieldType.BOOL, "true"), OK)
    assert_equal(_value(FieldType.BOOL, "false"), OK)
    assert_equal(_value(FieldType.BOOL, "True"), "crm: invalid customFields: a BOOL value must be true or false")
    assert_equal(_value(FieldType.TEXT, "any text, even\nlines"), OK)
    assert_equal(_value(FieldType.TEXT, _x(4096)), OK)
    assert_equal(_value(FieldType.TEXT, _x(4097)), "crm: invalid customFields: a value is too long")


def test_principal_none() raises:
    check_principal(Optional[Principal](), "owner")


def main() raises:
    test_dates()
    test_lines_and_principal()
    test_keys()
    test_pipeline()
    test_deal()
    test_activity()
    test_field_def()
    test_field_values()
    test_principal_none()
    print("PASS komira_crm test_validate")
