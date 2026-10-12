# =============================================================================
# komira_crm/accounts.mojo -- accounts and the cards linked to them.
# =============================================================================
#
# An account with an `external_id` is guarded by its key row (ACCOUNT,
# external_id) in crm_external_ids, written after the account row (the write
# order of core.mojo). An account without one has no key and is always live.
# `org_card_id` is not unique: several accounts may name one org card.
#
# A link (account, card) is one key row of crm_account_contacts holding the
# role; linking a pair again updates its role.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbValue, Filter, Order, Pred, generate_uuidv7
from komira_wkt import Timestamp

from komira_crm_proto.crm import Account, AccountContact, EntityKind, Status

from komira_crm.core import (
    cas,
    claim_key,
    key_filter,
    key_holder,
    load,
    next_modseq,
    no_limit,
    order_of,
    row_updates,
)
from komira_crm.errors import ERR_EXTERNAL_ID_TAKEN, invalid, not_found
from komira_crm.fields import check_custom_fields
from komira_crm.rows import account_from_row, account_row, kind_name, text, to_micro
from komira_crm.schema import (
    ACCOUNTS,
    ACCOUNT_CONTACTS,
    EXTERNAL_IDS,
    account_cols,
    account_contact_cols,
    strs,
)
from komira_crm.validate import MAX_LINE, check_account, check_line


def external_id_live[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], kind: Int, external_id: String, id: String) raises -> Bool:
    """Whether row `id` of `kind` is live: it has no external id, or the key
    row of its external id names it."""
    if external_id.byte_length() == 0:
        return True
    var holder = key_holder[DB, RT](
        db, reactor, EXTERNAL_IDS, "entity_kind", kind_name(kind), "external_id", external_id, "entity_id"
    )
    return holder == id


def claim_external_id[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], kind: Int, external_id: String, id: String) raises:
    """Create the key row of a new row's external id; a lost create is a
    conflict (the caller rolls back)."""
    var won = claim_key[DB, RT](
        db, reactor, EXTERNAL_IDS, "entity_kind", kind_name(kind), "external_id", external_id, "entity_id", id
    )
    if not won:
        raise Error(String(ERR_EXTERNAL_ID_TAKEN))


def create_account[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], account: Account, now: Timestamp) raises -> Account:
    check_account(account)
    var a = account.copy()
    a.id = generate_uuidv7().to_hyphenated()
    a.version = UInt64(1)
    a.created_at = Optional[Timestamp](to_micro(now))
    a.updated_at = Optional[Timestamp](to_micro(now))
    db.begin[RT](reactor)
    try:
        check_custom_fields[DB, RT](db, reactor, EntityKind.ACCOUNT, a.custom_fields)
        a.modseq = next_modseq[DB, RT](db, reactor)
        _ = db.put[RT](reactor, String(ACCOUNTS), account_cols(), account_row(a))
        if a.external_id.byte_length() > 0:
            claim_external_id[DB, RT](db, reactor, EntityKind.ACCOUNT, a.external_id, a.id)
        db.commit[RT](reactor)
        return a^
    except e:
        db.rollback[RT](reactor)
        raise e^


def find_account[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], id: String) raises -> Optional[Account]:
    """A live account, archived or not; None when there is none."""
    var got = load[DB, RT](db, reactor, ACCOUNTS, account_cols(), id)
    if not got:
        return Optional[Account]()
    var a = account_from_row(got.take())
    if not external_id_live[DB, RT](db, reactor, EntityKind.ACCOUNT, a.external_id, a.id):
        return Optional[Account]()
    return Optional[Account](a^)


def get_account[DB: Database, RT: Runtime](mut db: DB, mut reactor: Reactor[RT.Sink], id: String) raises -> Account:
    """A live account, archived or not."""
    var got = find_account[DB, RT](db, reactor, id)
    if not got:
        raise not_found()
    return got.take()


def list_accounts[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], include_archived: Bool) raises -> List[Account]:
    """The live accounts, by id; the archived ones only when
    asked."""
    var filter = Filter.none() if include_archived else Filter.just(
        Pred.eq(String("status"), text(Status(Status.ACTIVE).json_name()))
    )
    var rows = db.query_rows[RT](reactor, String(ACCOUNTS), account_cols(), filter, List[Order](), no_limit())
    var live = List[Account]()
    var keys = List[String]()
    for i in range(rows.__len__()):
        var a = account_from_row(rows.row(i))
        if external_id_live[DB, RT](db, reactor, EntityKind.ACCOUNT, a.external_id, a.id):
            keys.append(a.id)
            live.append(a^)
    var out = List[Account]()
    for i in order_of(keys):
        out.append(live[i].copy())
    return out^


def update_account[
    DB: Database, RT: Runtime
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    id: String,
    expected_version: UInt64,
    account: Account,
    now: Timestamp,
) raises -> Account:
    """Replace a live account's fields (archiving is `status`) if its version
    is still `expected_version`. `external_id` cannot change (an empty one
    keeps it)."""
    check_account(account)
    db.begin[RT](reactor)
    try:
        var cur = get_account[DB, RT](db, reactor, id)
        if account.external_id.byte_length() > 0 and account.external_id != cur.external_id:
            raise invalid("externalId", "cannot change")
        check_custom_fields[DB, RT](db, reactor, EntityKind.ACCOUNT, account.custom_fields)
        var a = account.copy()
        a.id = String(id)
        a.external_id = cur.external_id
        a.created_at = cur.created_at
        a.updated_at = Optional[Timestamp](to_micro(now))
        a.version = expected_version + 1
        a.modseq = next_modseq[DB, RT](db, reactor)
        cas[DB, RT](db, reactor, ACCOUNTS, id, expected_version, row_updates(account_cols(), account_row(a), strs()))
        db.commit[RT](reactor)
        return a^
    except e:
        db.rollback[RT](reactor)
        raise e^


# ---- linked cards -----------------------------------------------------------


def link_contact[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], account_id: String, card_id: String, role: String) raises -> AccountContact:
    """Link a card to a live account with `role`; a pair already linked gets
    the new role."""
    check_line(card_id, "cardId", True, MAX_LINE)
    check_line(role, "role", False, MAX_LINE)
    db.begin[RT](reactor)
    try:
        _ = get_account[DB, RT](db, reactor, account_id)
        var vals = List[DbValue]()
        vals.append(text(account_id))
        vals.append(text(card_id))
        vals.append(text(role))
        var won = db.create_if_absent_composite[RT](
            reactor, String(ACCOUNT_CONTACTS), strs("account_id", "card_id"), account_contact_cols(), vals^
        )
        if not won:
            var updates = List[DbColVal]()
            updates.append(DbColVal.bind(String("role"), text(role)))
            _ = db.conditional_update[RT](
                reactor,
                String(ACCOUNT_CONTACTS),
                key_filter("account_id", account_id, "card_id", card_id),
                updates^,
                False,
                Optional[String](),
                List[String](),
            )
        db.commit[RT](reactor)
        return AccountContact(account_id=String(account_id), card_id=String(card_id), role=String(role))
    except e:
        db.rollback[RT](reactor)
        raise e^


def unlink_contact[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], account_id: String, card_id: String) raises -> Bool:
    """Remove a link; False when the pair was not linked."""
    var n = db.delete_where[RT](
        reactor, String(ACCOUNT_CONTACTS), key_filter("account_id", account_id, "card_id", card_id)
    )
    return n > 0


def list_contacts[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], account_id: String) raises -> List[AccountContact]:
    """The cards linked to an account, by card id."""
    var rows = db.query_rows[RT](
        reactor,
        String(ACCOUNT_CONTACTS),
        account_contact_cols(),
        Filter.just(Pred.eq(String("account_id"), text(account_id))),
        List[Order](),
        no_limit(),
    )
    var keys = List[String]()
    for i in range(rows.__len__()):
        keys.append(rows.row(i).get_text(1))
    var out = List[AccountContact]()
    for i in order_of(keys):
        ref r = rows.row(i)
        out.append(AccountContact(account_id=r.get_text(0), card_id=r.get_text(1), role=r.get_text(2)))
    return out^
