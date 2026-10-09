# =============================================================================
# komira_crm/validate.mojo -- what a client may write.
# =============================================================================
#
# Pure checks, no database: each raises `crm: invalid <field>: <why>`
# (errors.mojo) naming the proto3 JSON name of the refused field. The store
# runs them before it opens a transaction. What needs the database (a
# pipeline's stages for a deal's stage, a custom field's definition) is the
# store's.
#
#   check_principal        an owner or actor: both parts or neither
#   check_key              a stage key or a custom-field key: [a-z0-9_], 1 to
#                          64 bytes
#   check_date             `YYYY-MM-DD`, a real calendar day
#   check_pipeline         a name and 1 to 50 stages with unique keys
#   check_account          an account a client writes
#   check_deal             a deal a client writes (money included)
#   check_activity         an activity a client writes (never STAGE_CHANGED)
#   check_custom_field_def a definition a client writes
#   check_field_value      one custom-field value against its type
# =============================================================================

from komira_crm_proto.crm import (
    Account,
    Activity,
    ActivityKind,
    CustomFieldDef,
    Deal,
    EntityKind,
    FieldType,
    Pipeline,
    Principal,
)

from komira_crm.errors import invalid
from komira_crm.money import check_money

comptime MAX_LINE = 512
comptime MAX_BODY = 65536
comptime MAX_STAGES = 50
comptime MAX_KEY = 64
comptime MAX_FIELD_VALUE = 4096


def check_line(s: String, field: StaticString, required: Bool, max_bytes: Int) raises:
    """One line of at most `max_bytes` bytes: no control character."""
    if required and s.byte_length() == 0:
        raise invalid(field, "required")
    if s.byte_length() > max_bytes:
        raise invalid(field, "too long")
    for c in s.as_bytes():
        if c < 0x20 or c == 0x7F:
            raise invalid(field, "must be one line with no control characters")


def check_principal(p: Optional[Principal], field: StaticString) raises:
    """Empty (nobody), or an issuer and a subject, each one line."""
    if not p:
        return
    ref v = p.value()
    if (v.issuer.byte_length() == 0) != (v.subject.byte_length() == 0):
        raise invalid(field, "issuer and subject are both set or both empty")
    check_line(v.issuer, field, False, MAX_LINE)
    check_line(v.subject, field, False, MAX_LINE)


def check_key(key: String, field: StaticString) raises:
    var b = key.as_bytes()
    if len(b) == 0 or len(b) > MAX_KEY:
        raise invalid(field, "must be 1 to 64 bytes of a-z, 0-9 and _")
    for c in b:
        var ok = (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or (
            c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        ) or c == UInt8(ord("_"))
        if not ok:
            raise invalid(field, "must be 1 to 64 bytes of a-z, 0-9 and _")


def _digits(b: Span[UInt8, _], start: Int, n: Int) -> Int:
    """The decimal value of b[start:start+n], or -1 if a byte is not a digit."""
    var v = 0
    for i in range(start, start + n):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return -1
        v = v * 10 + Int(b[i]) - 48
    return v


def days_in_month(year: Int, month: Int) -> Int:
    if month == 2:
        var leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
        return 29 if leap else 28
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    return 31


def check_date(s: String, field: StaticString) raises:
    """`YYYY-MM-DD`, year 0001 to 9999, a day that exists."""
    var b = s.as_bytes()
    if len(b) != 10 or b[4] != UInt8(ord("-")) or b[7] != UInt8(ord("-")):
        raise invalid(field, "must be a date, YYYY-MM-DD")
    var year = _digits(b, 0, 4)
    var month = _digits(b, 5, 2)
    var day = _digits(b, 8, 2)
    if year < 1 or month < 1 or month > 12 or day < 1:
        raise invalid(field, "must be a date, YYYY-MM-DD")
    if day > days_in_month(year, month):
        raise invalid(field, "no such day")


def check_pipeline(p: Pipeline) raises:
    check_line(p.name, "name", True, MAX_LINE)
    if len(p.stages) == 0 or len(p.stages) > MAX_STAGES:
        raise invalid("stages", "a pipeline has 1 to 50 stages")
    for i in range(len(p.stages)):
        check_key(p.stages[i].key, "stages.key")
        check_line(p.stages[i].label, "stages.label", True, MAX_LINE)
        for j in range(i):
            if p.stages[j].key == p.stages[i].key:
                raise invalid("stages.key", "keys must be unique within a pipeline")


def check_account(a: Account) raises:
    check_line(a.org_card_id, "orgCardId", True, MAX_LINE)
    check_principal(a.owner, "owner")
    check_line(a.domain, "domain", False, MAX_LINE)
    check_line(a.external_id, "externalId", False, MAX_LINE)


def check_deal(d: Deal) raises:
    check_line(d.title, "title", True, MAX_LINE)
    check_line(d.pipeline_id, "pipelineId", True, MAX_LINE)
    check_key(d.stage_key, "stageKey")
    check_line(d.account_id, "accountId", False, MAX_LINE)
    check_line(d.primary_contact_card_id, "primaryContactCardId", False, MAX_LINE)
    check_money(d.amount_minor, d.currency)
    if d.close_date.byte_length() > 0:
        check_date(d.close_date, "closeDate")
    check_principal(d.owner, "owner")
    check_line(d.external_id, "externalId", False, MAX_LINE)


def check_subject_kind(kind: Int, field: StaticString) raises:
    """ACCOUNT, DEAL or CARD: what an activity is about, or what a custom
    field belongs to."""
    if kind != EntityKind.ACCOUNT and kind != EntityKind.DEAL and kind != EntityKind.CARD:
        raise invalid(field, "must be ACCOUNT, DEAL or CARD")


def check_activity(a: Activity) raises:
    if a.kind.value == ActivityKind.STAGE_CHANGED:
        raise invalid("kind", "STAGE_CHANGED is written by the service")
    check_subject_kind(a.subject_kind.value, "subjectKind")
    check_line(a.subject_id, "subjectId", True, MAX_LINE)
    if a.body.byte_length() > MAX_BODY:
        raise invalid("body", "too long")
    if a.occurred_at and a.occurred_at.value().seconds <= 0:
        raise invalid("occurredAt", "must be after 1970-01-01T00:00:00Z")


def check_custom_field_def(f: CustomFieldDef) raises:
    check_subject_kind(f.entity_kind.value, "entityKind")
    check_key(f.key, "key")
    check_line(f.label, "label", True, MAX_LINE)


def _is_number(b: Span[UInt8, _]) -> Bool:
    """-?digits(.digits)?"""
    var i = 0
    if len(b) > 0 and b[0] == UInt8(ord("-")):
        i = 1
    var whole = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        whole += 1
        i += 1
    if whole == 0:
        return False
    if i == len(b):
        return True
    if b[i] != UInt8(ord(".")):
        return False
    i += 1
    var frac = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        frac += 1
        i += 1
    return frac > 0 and i == len(b)


def check_field_value(field_type: Int, value: String) raises:
    """A custom-field value, as text, against its definition's type."""
    if value.byte_length() > MAX_FIELD_VALUE:
        raise invalid("customFields", "a value is too long")
    if field_type == FieldType.NUMBER:
        if not _is_number(value.as_bytes()):
            raise invalid("customFields", "a NUMBER value must be a decimal")
    elif field_type == FieldType.DATE:
        check_date(value, "customFields")
    elif field_type == FieldType.BOOL:
        if value != "true" and value != "false":
            raise invalid("customFields", "a BOOL value must be true or false")
