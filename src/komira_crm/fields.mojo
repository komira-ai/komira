# =============================================================================
# komira_crm/fields.mojo -- custom-field definitions, and the check of an
#   entity's custom-field values against them.
# =============================================================================
#
# A definition is a row of crm_custom_field_defs guarded by its key row
# (entity_kind, key) in crm_custom_field_keys, written in the order core.mojo
# describes: the row, then the key. `key`, `entity_kind` and `type` never
# change; only `label` does.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbValue, Filter, Order, Pred, generate_uuidv7

from komira_crm_proto.crm import CustomFieldDef, EntityKind

from komira_crm.core import cas, claim_key, key_holder, load, next_modseq, no_limit, order_of, row_updates
from komira_crm.errors import ERR_FIELD_KEY_TAKEN, invalid, not_found
from komira_crm.rows import field_def_from_row, field_def_row, kind_name, text
from komira_crm.schema import FIELD_DEFS, FIELD_KEYS, field_def_cols, strs
from komira_crm.validate import check_custom_field_def, check_field_value


def _keyed[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], f: CustomFieldDef) raises -> Bool:
    """Whether the definition's key row names it (it is live)."""
    var holder = key_holder[DB, RT](
        db, reactor, FIELD_KEYS, "entity_kind", kind_name(f.entity_kind.value), "field_key", f.key, "def_id"
    )
    return holder == f.id


def create_field_def[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], field: CustomFieldDef) raises -> CustomFieldDef:
    check_custom_field_def(field)
    var f = field.copy()
    f.id = generate_uuidv7().to_hyphenated()
    f.version = UInt64(1)
    db.begin[RT](reactor)
    try:
        f.modseq = next_modseq[DB, RT](db, reactor)
        _ = db.put[RT](reactor, String(FIELD_DEFS), field_def_cols(), field_def_row(f))
        var won = claim_key[DB, RT](
            db, reactor, FIELD_KEYS, "entity_kind", kind_name(f.entity_kind.value), "field_key", f.key, "def_id", f.id
        )
        if not won:
            raise Error(String(ERR_FIELD_KEY_TAKEN))
        db.commit[RT](reactor)
        return f^
    except e:
        db.rollback[RT](reactor)
        raise e^


def get_field_def[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], id: String) raises -> CustomFieldDef:
    var got = load[DB, RT](db, reactor, FIELD_DEFS, field_def_cols(), id)
    if not got:
        raise not_found()
    var f = field_def_from_row(got.take())
    if not _keyed[DB, RT](db, reactor, f):
        raise not_found()
    return f^


def list_field_defs[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], entity_kind: Int) raises -> List[CustomFieldDef]:
    """The live definitions of one entity kind, by key."""
    var rows = db.query_rows[RT](
        reactor,
        String(FIELD_DEFS),
        field_def_cols(),
        Filter.just(Pred.eq(String("entity_kind"), text(kind_name(entity_kind)))),
        List[Order](),
        no_limit(),
    )
    var live = List[CustomFieldDef]()
    var keys = List[String]()
    for i in range(rows.__len__()):
        var f = field_def_from_row(rows.row(i))
        if _keyed[DB, RT](db, reactor, f):
            keys.append(f.key)
            live.append(f^)
    var out = List[CustomFieldDef]()
    for i in order_of(keys):
        out.append(live[i].copy())
    return out^


def update_field_def[
    DB: Database, RT: Runtime
](
    mut db: DB, mut reactor: Reactor[RT.Sink], id: String, expected_version: UInt64, field: CustomFieldDef
) raises -> CustomFieldDef:
    """Change a definition's label; its entity kind, key and type cannot
    change."""
    check_custom_field_def(field)
    db.begin[RT](reactor)
    try:
        var cur = get_field_def[DB, RT](db, reactor, id)
        if field.entity_kind.value != cur.entity_kind.value:
            raise invalid("entityKind", "cannot change")
        if field.key != cur.key:
            raise invalid("key", "cannot change")
        if field.type.value != cur.type.value:
            raise invalid("type", "cannot change")
        var f = cur.copy()
        f.label = field.label
        f.version = expected_version + 1
        f.modseq = next_modseq[DB, RT](db, reactor)
        cas[DB, RT](db, reactor, FIELD_DEFS, id, expected_version, row_updates(field_def_cols(), field_def_row(f), strs()))
        db.commit[RT](reactor)
        return f^
    except e:
        db.rollback[RT](reactor)
        raise e^


def check_custom_fields[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], entity_kind: Int, fields: Dict[String, String]) raises:
    """Every key names a live definition of `entity_kind`, and every value
    has its definition's type."""
    for entry in fields.items():
        var def_id = key_holder[DB, RT](
            db, reactor, FIELD_KEYS, "entity_kind", kind_name(entity_kind), "field_key", entry.key, "def_id"
        )
        var got = load[DB, RT](db, reactor, FIELD_DEFS, field_def_cols(), def_id)
        if not got:
            raise invalid("customFields", "no custom field with this key for this kind")
        check_field_value(field_def_from_row(got.take()).type.value, entry.value)
