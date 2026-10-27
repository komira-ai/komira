# =============================================================================
# komira_crm/rows.mojo -- the messages as table rows, and back.
# =============================================================================
#
# Each `*_row` writes a message in its table's column order (schema.mojo);
# each `*_from_row` reads one back. `body` is the message's proto3 JSON with
# the fields that have a column of their own cleared, and the owner or actor
# never in it; on read the columns are written over the decoded body.
# Times are kept to the microsecond: `micros` and `timestamp` convert.
# =============================================================================

from komira_db import DbRow, DbValue
from komira_proto_codec import decode_json_lenient, encode_json
from komira_wkt import Timestamp

from komira_crm_proto.crm import (
    Account,
    Activity,
    CustomFieldDef,
    Deal,
    EntityKind,
    Pipeline,
    Principal,
    Status,
)


def text(s: String) -> DbValue:
    return DbValue.text(String(s))


def int8(v: UInt64) -> DbValue:
    return DbValue.int8(Int64(v))


def flag(b: Bool) -> DbValue:
    return DbValue.int8(Int64(1) if b else Int64(0))


def micros(t: Timestamp) -> Int64:
    return t.seconds * 1_000_000 + Int64(t.nanos // 1000)


def timestamp(us: Int64) -> Timestamp:
    """`us` (not negative) as a Timestamp."""
    return Timestamp(us // 1_000_000, Int32((us % 1_000_000) * 1000))


def to_micro(t: Timestamp) -> Timestamp:
    """`t` cut to the microsecond, as the store keeps every time."""
    return Timestamp(t.seconds, Int32((t.nanos // 1000) * 1000))


def issuer_of(p: Optional[Principal]) -> String:
    return p.value().issuer if p else String()


def subject_of(p: Optional[Principal]) -> String:
    return p.value().subject if p else String()


def principal(issuer: String, subject: String) -> Optional[Principal]:
    """None for nobody (both empty)."""
    if issuer.byte_length() == 0 and subject.byte_length() == 0:
        return Optional[Principal]()
    return Optional[Principal](Principal(issuer=String(issuer), subject=String(subject)))


def kind_name(kind: Int) -> String:
    return EntityKind(kind).json_name()


# ---- accounts ---------------------------------------------------------------


def account_row(a: Account) raises -> List[DbValue]:
    var body = a.copy()
    body.id = String()
    body.owner = Optional[Principal]()
    body.version = UInt64(0)
    body.modseq = UInt64(0)
    var out = List[DbValue]()
    out.append(text(a.id))
    out.append(text(a.org_card_id))
    out.append(text(issuer_of(a.owner)))
    out.append(text(subject_of(a.owner)))
    out.append(text(a.status.json_name()))
    out.append(text(a.external_id))
    out.append(int8(a.version))
    out.append(int8(a.modseq))
    out.append(text(encode_json(body)))
    return out^


def account_from_row(row: DbRow) raises -> Account:
    var a = decode_json_lenient[Account](row.get_text(8))
    a.id = row.get_text(0)
    a.org_card_id = row.get_text(1)
    a.owner = principal(row.get_text(2), row.get_text(3))
    a.status = Status.from_json_name(row.get_text(4))
    a.external_id = row.get_text(5)
    a.version = UInt64(row.get_int8(6))
    a.modseq = UInt64(row.get_int8(7))
    return a^


# ---- pipelines --------------------------------------------------------------


def pipeline_row(p: Pipeline) raises -> List[DbValue]:
    var body = p.copy()
    body.id = String()
    body.version = UInt64(0)
    body.modseq = UInt64(0)
    var out = List[DbValue]()
    out.append(text(p.id))
    out.append(int8(p.version))
    out.append(int8(p.modseq))
    out.append(text(encode_json(body)))
    return out^


def pipeline_from_row(row: DbRow) raises -> Pipeline:
    var p = decode_json_lenient[Pipeline](row.get_text(3))
    p.id = row.get_text(0)
    p.version = UInt64(row.get_int8(1))
    p.modseq = UInt64(row.get_int8(2))
    return p^


# ---- deals ------------------------------------------------------------------


def deal_row(d: Deal) raises -> List[DbValue]:
    var body = d.copy()
    body.id = String()
    body.owner = Optional[Principal]()
    body.last_activity_at = Optional[Timestamp]()
    body.version = UInt64(0)
    body.modseq = UInt64(0)
    var out = List[DbValue]()
    out.append(text(d.id))
    out.append(text(d.pipeline_id))
    out.append(text(d.stage_key))
    out.append(text(d.account_id))
    out.append(text(issuer_of(d.owner)))
    out.append(text(subject_of(d.owner)))
    out.append(text(d.status.json_name()))
    out.append(text(d.close_date))
    out.append(text(d.external_id))
    out.append(DbValue.int8(micros(d.last_activity_at.value()) if d.last_activity_at else Int64(0)))
    out.append(int8(d.version))
    out.append(int8(d.modseq))
    out.append(text(encode_json(body)))
    return out^


def deal_from_row(row: DbRow) raises -> Deal:
    var d = decode_json_lenient[Deal](row.get_text(12))
    d.id = row.get_text(0)
    d.pipeline_id = row.get_text(1)
    d.stage_key = row.get_text(2)
    d.account_id = row.get_text(3)
    d.owner = principal(row.get_text(4), row.get_text(5))
    d.status = Status.from_json_name(row.get_text(6))
    d.close_date = row.get_text(7)
    d.external_id = row.get_text(8)
    var last = row.get_int8(9)
    d.last_activity_at = Optional[Timestamp](timestamp(last)) if last > 0 else Optional[Timestamp]()
    d.version = UInt64(row.get_int8(10))
    d.modseq = UInt64(row.get_int8(11))
    return d^


# ---- activities -------------------------------------------------------------


def activity_row(a: Activity) raises -> List[DbValue]:
    var body = a.copy()
    body.id = String()
    body.actor = Optional[Principal]()
    body.version = UInt64(0)
    body.modseq = UInt64(0)
    var out = List[DbValue]()
    out.append(text(a.id))
    out.append(text(a.subject_kind.json_name()))
    out.append(text(a.subject_id))
    out.append(text(issuer_of(a.actor)))
    out.append(text(subject_of(a.actor)))
    out.append(DbValue.int8(micros(a.occurred_at.value())))
    out.append(flag(a.system))
    out.append(int8(a.version))
    out.append(int8(a.modseq))
    out.append(text(encode_json(body)))
    return out^


def activity_from_row(row: DbRow) raises -> Activity:
    var a = decode_json_lenient[Activity](row.get_text(9))
    a.id = row.get_text(0)
    a.subject_kind = EntityKind.from_json_name(row.get_text(1))
    a.subject_id = row.get_text(2)
    a.actor = principal(row.get_text(3), row.get_text(4))
    a.occurred_at = Optional[Timestamp](timestamp(row.get_int8(5)))
    a.system = row.get_int8(6) != 0
    a.version = UInt64(row.get_int8(7))
    a.modseq = UInt64(row.get_int8(8))
    return a^


# ---- custom-field definitions -----------------------------------------------


def field_def_row(f: CustomFieldDef) raises -> List[DbValue]:
    var body = f.copy()
    body.id = String()
    body.version = UInt64(0)
    body.modseq = UInt64(0)
    var out = List[DbValue]()
    out.append(text(f.id))
    out.append(text(f.entity_kind.json_name()))
    out.append(text(f.key))
    out.append(int8(f.version))
    out.append(int8(f.modseq))
    out.append(text(encode_json(body)))
    return out^


def field_def_from_row(row: DbRow) raises -> CustomFieldDef:
    var f = decode_json_lenient[CustomFieldDef](row.get_text(5))
    f.id = row.get_text(0)
    f.entity_kind = EntityKind.from_json_name(row.get_text(1))
    f.key = row.get_text(2)
    f.version = UInt64(row.get_int8(3))
    f.modseq = UInt64(row.get_int8(4))
    return f^