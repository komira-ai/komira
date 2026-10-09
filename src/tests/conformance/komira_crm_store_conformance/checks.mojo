# =============================================================================
# komira_crm_store_conformance/checks.mojo -- the store's contract.
# =============================================================================
#
# Each check states the behaviour it holds the store to and the defect it
# catches. Refusals are compared by their exact text (komira_crm.ERR_*).
#
#   dataset_init        init creates the counter and the six-stage default
#                       pipeline once; a second init finds them.
#   external_id_per_kind  an account and a deal with one external id both
#                       insert; a second account, or a second deal, with it
#                       is refused and leaves no row a read returns. Catches
#                       one key spanning kinds and a key per row instead of
#                       per tuple.
#   org_card_not_unique two accounts naming one org card, with external ids
#                       E1 and E2, are both created and both readable.
#                       Catches a second key table guarding org_card_id.
#   version_cas         of two updates naming one version, of an account and
#                       of a deal, exactly one succeeds; the other gets the
#                       conflict text and changes nothing.
#   orphan_row_hidden   an account row with an external id and no key row
#                       (a create that stopped between its row and its key,
#                       planted through the database) is returned by no get
#                       or list; the next create of that external id wins
#                       the key and is the one account listed with it.
#                       Catches a read that skips the key check.
#   field_key_per_kind  a custom-field key is unique per entity kind and free
#                       in another; a value must have its definition's type.
#   system_activity     a stage change writes a STAGE_CHANGED system activity
#                       that refuses every update; a client cannot create one.
#   account_links       a card is linked to an account once; linking again
#                       changes the role.
#   archive_hides       an archived account and deal leave the lists and still
#                       resolve by id; a deal of an archived account resolves.
#   money_refused       an unknown currency, a negative amount and an amount
#                       without a currency are refused with their texts.
#   erasure             erasing one principal rewrites exactly its rows in
#                       the three tables (owner emptied or actor "erased",
#                       version + 1, body unchanged) and leaves every other
#                       row as it was, the same subject at another issuer
#                       included; a second call rewrites nothing. The rows
#                       are compared through the database, not the store.
#   feed_sequence       (transactional backends only) every write in one
#                       numbered sequence, a stage change's deal and activity
#                       on consecutive numbers, a page of one walking it.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.reactor import Reactor
from komira_db import DbValue, Filter, Order
from komira_proto_codec import decode_json, encode_json
from komira_wkt import Timestamp
from komira_crm_proto.crm import (
    Account,
    ActivityKind,
    Activity,
    CustomFieldDef,
    Deal,
    EntityKind,
    Principal,
)

from komira_crm import (
    ACCOUNTS,
    ACTIVITIES,
    CrmStore,
    DEALS,
    ERR_EXTERNAL_ID_TAKEN,
    ERR_FIELD_KEY_TAKEN,
    ERR_NOT_FOUND,
    ERR_SYSTEM_ACTIVITY,
    ERR_UNKNOWN_CURRENCY,
    ERR_VERSION_CONFLICT,
)
from komira_crm.rows import account_row
from komira_crm.schema import account_cols, strs

from komira_crm_store_conformance.targets import CrmTarget, Rt, new_rt

comptime OK = "ok"


def _at(seconds: Int64) -> Timestamp:
    return Timestamp(seconds, Int32(0))


def _who(issuer: StaticString, subject: StaticString) -> Principal:
    return Principal(issuer=String(issuer), subject=String(subject))


def _store[T: CrmTarget](mut t: T, mut reactor: Reactor[Rt.Sink]) raises -> CrmStore[T.DB]:
    var s = CrmStore[T.DB](t.fresh())
    _ = s.init_dataset[Rt](reactor)
    return s^


def _pid[T: CrmTarget](mut store: CrmStore[T.DB], mut reactor: Reactor[Rt.Sink]) raises -> String:
    return store.list_pipelines[Rt](reactor)[0].id


def _deal_json(pid: String, stage: StaticString, extra: String) -> String:
    return String('{"title":"T","pipelineId":"') + pid + '","stageKey":"' + stage + '"' + extra + "}"


def check_dataset_init[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = CrmStore[T.DB](t.fresh())
    assert_true(store.init_dataset[Rt](reactor), "the first init creates the dataset")
    assert_false(store.init_dataset[Rt](reactor), "the second finds it")
    var ps = store.list_pipelines[Rt](reactor)
    assert_equal(len(ps), 1)
    var keys = String()
    for s in ps[0].stages:
        keys += s.key + String(" ")
    assert_equal(keys, "qualification discovery proposal negotiation closed_won closed_lost ")


def _ext_ids[T: CrmTarget](mut store: CrmStore[T.DB], mut reactor: Reactor[Rt.Sink]) raises -> String:
    var out = String()
    var accts = store.list_accounts[Rt](reactor, True)
    var keys = List[String]()
    for a in accts:
        keys.append(a.external_id)
    for i in range(len(keys)):
        out += keys[i] + String(",")
    return out^


def check_external_id_per_kind[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var pid = _pid[T](store, reactor)
    var a = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o","externalId":"E"}'), _at(1))
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", ',"externalId":"E"')), _at(1))
    assert_equal(d.external_id, "E", "a deal may carry an account's external id")
    var err = String(OK)
    try:
        _ = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o2","externalId":"E"}'), _at(2))
    except e:
        err = String(e)
    assert_equal(err, ERR_EXTERNAL_ID_TAKEN, "a second account")
    err = String(OK)
    try:
        _ = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "proposal", ',"externalId":"E"')), _at(2))
    except e:
        err = String(e)
    assert_equal(err, ERR_EXTERNAL_ID_TAKEN, "a second deal")
    var accts = store.list_accounts[Rt](reactor, True)
    assert_equal(len(accts), 1, "the refused account is not read")
    assert_equal(accts[0].id, a.id)
    var deals = store.list_deals[Rt](reactor, String(), True)
    assert_equal(len(deals), 1, "the refused deal is not read")
    assert_equal(deals[0].id, d.id)


def check_org_card_not_unique[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var a1 = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"C","externalId":"E1"}'), _at(1))
    var a2 = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"C","externalId":"E2"}'), _at(1))
    assert_equal(store.get_account[Rt](reactor, a1.id).org_card_id, "C")
    assert_equal(store.get_account[Rt](reactor, a2.id).org_card_id, "C")
    assert_equal(len(store.list_accounts[Rt](reactor, False)), 2)


def check_version_cas[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var pid = _pid[T](store, reactor)
    var a = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"}'), _at(1))
    var won = store.update_account[Rt](reactor, a.id, a.version, decode_json[Account]('{"orgCardId":"first"}'), _at(2))
    var err = String(OK)
    try:
        _ = store.update_account[Rt](reactor, a.id, a.version, decode_json[Account]('{"orgCardId":"second"}'), _at(3))
    except e:
        err = String(e)
    assert_equal(err, ERR_VERSION_CONFLICT)
    assert_equal(encode_json(store.get_account[Rt](reactor, a.id)), encode_json(won), "the loser changed nothing")
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", "")), _at(1))
    var dwon = store.update_deal[Rt](reactor, _who("i", "s"), d.id, d.version, decode_json[Deal](_deal_json(pid, "discovery", ',"closeDate":"2026-12-31"')), _at(2))
    err = String(OK)
    try:
        _ = store.update_deal[Rt](reactor, _who("i", "s"), d.id, d.version, decode_json[Deal](_deal_json(pid, "proposal", "")), _at(3))
    except e:
        err = String(e)
    assert_equal(err, ERR_VERSION_CONFLICT)
    assert_equal(encode_json(store.get_deal[Rt](reactor, d.id)), encode_json(dwon))
    assert_equal(len(store.list_activities[Rt](reactor, EntityKind.DEAL, d.id)), 0, "the losing stage change wrote nothing")


def check_orphan_row_hidden[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var ghost = decode_json[Account]('{"orgCardId":"o","externalId":"E"}')
    ghost.id = String("ghost")
    ghost.version = 1
    ghost.modseq = 1
    _ = store.database().put[Rt](reactor, String(ACCOUNTS), account_cols(), account_row(ghost))
    var err = String(OK)
    try:
        _ = store.get_account[Rt](reactor, "ghost")
    except e:
        err = String(e)
    assert_equal(err, ERR_NOT_FOUND, "no key names the row")
    assert_equal(len(store.list_accounts[Rt](reactor, True)), 0)
    var b = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o","externalId":"E"}'), _at(1))
    var listed = store.list_accounts[Rt](reactor, True)
    assert_equal(len(listed), 1, "one account with E")
    assert_equal(listed[0].id, b.id, "the acknowledged create")


def check_field_key_per_kind[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    _ = store.create_field_def[Rt](reactor, decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"size","label":"S","type":"NUMBER"}'))
    _ = store.create_field_def[Rt](reactor, decode_json[CustomFieldDef]('{"entityKind":"DEAL","key":"size","label":"S"}'))
    var err = String(OK)
    try:
        _ = store.create_field_def[Rt](reactor, decode_json[CustomFieldDef]('{"entityKind":"ACCOUNT","key":"size","label":"T"}'))
    except e:
        err = String(e)
    assert_equal(err, ERR_FIELD_KEY_TAKEN)
    assert_equal(len(store.list_field_defs[Rt](reactor, EntityKind.ACCOUNT)), 1)
    _ = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o","customFields":{"size":"10"}}'), _at(1))
    err = String(OK)
    try:
        _ = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o","customFields":{"size":"ten"}}'), _at(1))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid customFields: a NUMBER value must be a decimal")


def check_system_activity[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var pid = _pid[T](store, reactor)
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", "")), _at(1))
    _ = store.update_deal[Rt](reactor, _who("i", "s"), d.id, d.version, decode_json[Deal](_deal_json(pid, "proposal", "")), _at(2))
    var acts = store.list_activities[Rt](reactor, EntityKind.DEAL, d.id)
    assert_equal(len(acts), 1)
    assert_equal(acts[0].kind.value, ActivityKind.STAGE_CHANGED)
    assert_true(acts[0].system)
    var on_deal = String('{"subjectKind":"DEAL","subjectId":"') + d.id + '"'
    var err = String(OK)
    try:
        _ = store.update_activity[Rt](reactor, acts[0].id, acts[0].version, decode_json[Activity](on_deal + ',"body":"x"}'))
    except e:
        err = String(e)
    assert_equal(err, ERR_SYSTEM_ACTIVITY)
    err = String(OK)
    try:
        _ = store.create_activity[Rt](reactor, _who("i", "s"), decode_json[Activity](on_deal + ',"kind":"STAGE_CHANGED"}'), _at(3))
    except e:
        err = String(e)
    assert_equal(err, "crm: invalid kind: STAGE_CHANGED is written by the service")


def check_account_links[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var a = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"}'), _at(1))
    _ = store.link_contact[Rt](reactor, a.id, "card", "buyer")
    _ = store.link_contact[Rt](reactor, a.id, "card", "champion")
    var links = store.list_contacts[Rt](reactor, a.id)
    assert_equal(len(links), 1, "linked once")
    assert_equal(links[0].role, "champion")
    assert_true(store.unlink_contact[Rt](reactor, a.id, "card"))
    assert_equal(len(store.list_contacts[Rt](reactor, a.id)), 0)


def check_archive_hides[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var pid = _pid[T](store, reactor)
    var a = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"}'), _at(1))
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", ',"accountId":"' + a.id + '"')), _at(1))
    _ = store.update_account[Rt](reactor, a.id, a.version, decode_json[Account]('{"orgCardId":"o","status":"ARCHIVED"}'), _at(2))
    assert_equal(len(store.list_accounts[Rt](reactor, False)), 0, "an archived account is not listed")
    assert_equal(store.get_account[Rt](reactor, a.id).id, a.id, "and resolves by id")
    assert_equal(store.get_deal[Rt](reactor, d.id).account_id, a.id, "its deal resolves")
    assert_equal(len(store.list_deals[Rt](reactor, pid, False)), 1, "and is listed")
    _ = store.update_deal[Rt](reactor, _who("i", "s"), d.id, d.version, decode_json[Deal](_deal_json(pid, "discovery", ',"status":"ARCHIVED"')), _at(3))
    assert_equal(len(store.list_deals[Rt](reactor, pid, False)), 0, "an archived deal is not listed")
    assert_equal(len(store.list_deals[Rt](reactor, pid, True)), 1)


def check_money_refused[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var pid = _pid[T](store, reactor)
    var got = String()
    for extra in [',"amountMinor":"100","currency":"XAU"', ',"amountMinor":"-1","currency":"EUR"', ',"amountMinor":"1"']:
        try:
            _ = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", String(extra))), _at(1))
            got += String(OK) + "|"
        except e:
            got += String(e) + "|"
    assert_equal(
        got,
        String(ERR_UNKNOWN_CURRENCY)
        + "|crm: invalid amountMinor: must not be negative|crm: invalid currency: required when amountMinor is not 0|",
    )
    var ok = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", ',"amountMinor":"125","currency":"JPY"')), _at(1))
    assert_equal(store.get_deal[Rt](reactor, ok.id).amount_minor, Int64(125))
    assert_equal(len(store.list_deals[Rt](reactor, String(), True)), 1, "the refused deals wrote nothing")


def _snapshot[
    T: CrmTarget
](mut store: CrmStore[T.DB], mut reactor: Reactor[Rt.Sink], table: StaticString, iss: StaticString, sub: StaticString) raises -> List[String]:
    """Every row of `table` as `id|iss|sub|version|body`, by id, read through
    the database."""
    var rows = store.database().query_rows[Rt](
        reactor, String(table), strs("id", iss, sub, "version", "body"), Filter.none(), List[Order](), Optional[UInt32]()
    )
    var lines = List[String]()
    for i in range(rows.__len__()):
        ref r = rows.row(i)
        lines.append(
            r.get_text(0) + "|" + r.get_text(1) + "|" + r.get_text(2) + "|" + String(r.get_int8(3)) + "|" + r.get_text(4)
        )
    for i in range(1, len(lines)):
        var j = i
        while j > 0 and lines[j - 1] > lines[j]:
            var x = lines[j - 1]
            lines[j - 1] = lines[j]
            lines[j] = x
            j -= 1
    return lines^


def _erased(line: String, new_sub: StaticString) raises -> String:
    """The snapshot line of a row after its principal is erased."""
    var parts = line.split("|")
    return (
        String(parts[0]) + "||" + String(new_sub) + "|" + String(Int(String(parts[3])) + 1) + "|" + String(parts[4])
    )


def check_erasure[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var pid = _pid[T](store, reactor)
    for iss in ["https://one", "https://two"]:
        var owner = String(',"owner":{"issuer":"') + iss + '","subject":"u"}'
        _ = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"' + owner + "}"), _at(1))
        var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", owner)), _at(1))
        _ = store.create_activity[Rt](
            reactor,
            Principal(issuer=String(iss), subject=String("u")),
            decode_json[Activity]('{"subjectKind":"DEAL","subjectId":"' + d.id + '"}'),
            _at(2),
        )
    var before_a = _snapshot[T](store, reactor, ACCOUNTS, "owner_iss", "owner_sub")
    var before_d = _snapshot[T](store, reactor, DEALS, "owner_iss", "owner_sub")
    var before_x = _snapshot[T](store, reactor, ACTIVITIES, "actor_iss", "actor_sub")
    var counts = store.erase_subject[Rt](reactor, "https://one", "u")
    assert_equal(encode_json(counts), '{"accounts":1,"deals":1,"activities":1}')
    var after_a = _snapshot[T](store, reactor, ACCOUNTS, "owner_iss", "owner_sub")
    var after_d = _snapshot[T](store, reactor, DEALS, "owner_iss", "owner_sub")
    var after_x = _snapshot[T](store, reactor, ACTIVITIES, "actor_iss", "actor_sub")
    _expect_erased(before_a, after_a, "")
    _expect_erased(before_d, after_d, "")
    _expect_erased(before_x, after_x, "erased")
    assert_equal(encode_json(store.erase_subject[Rt](reactor, "https://one", "u")), "{}", "a second call rewrites nothing")


def _expect_erased(before: List[String], after: List[String], new_sub: StaticString) raises:
    assert_equal(len(after), len(before), "no row added or removed")
    var rewritten = 0
    for i in range(len(before)):
        if "|https://one|u|" in before[i]:
            assert_equal(after[i], _erased(before[i], new_sub), "the erased principal's row")
            rewritten += 1
        else:
            assert_equal(after[i], before[i], "every other row is unchanged")
    assert_equal(rewritten, 1)


def _walk[T: CrmTarget](mut store: CrmStore[T.DB], mut reactor: Reactor[Rt.Sink]) raises -> String:
    var out = String()
    var since = UInt64(0)
    while True:
        var r = store.changes[Rt](reactor, since, 1)
        if len(r.changes) == 0:
            return out^
        out += r.changes[0].kind.json_name() + String("@") + String(r.modseq) + String(" ")
        since = r.modseq


def check_feed_sequence[T: CrmTarget](mut t: T) raises:
    var rt = new_rt()
    ref reactor = rt.reactor()
    var store = _store(t, reactor)
    var pid = _pid[T](store, reactor)
    var a = store.create_account[Rt](reactor, decode_json[Account]('{"orgCardId":"o"}'), _at(1))
    var d = store.create_deal[Rt](reactor, decode_json[Deal](_deal_json(pid, "discovery", "")), _at(1))
    _ = store.update_deal[Rt](reactor, _who("i", "s"), d.id, d.version, decode_json[Deal](_deal_json(pid, "proposal", "")), _at(2))
    _ = store.update_account[Rt](reactor, a.id, a.version, decode_json[Account]('{"orgCardId":"o2"}'), _at(3))
    comptime FULL = "PIPELINE@1 DEAL@4 ACTIVITY@5 ACCOUNT@6 "
    assert_equal(_walk[T](store, reactor), FULL)
    var page = store.changes[Rt](reactor, 3, 1)
    assert_equal(page.changes[0].kind.value, EntityKind.DEAL, "a page can end after the deal")
    var next = store.changes[Rt](reactor, page.modseq, 1)
    assert_equal(next.changes[0].kind.value, EntityKind.ACTIVITY, "and the next holds its activity")
