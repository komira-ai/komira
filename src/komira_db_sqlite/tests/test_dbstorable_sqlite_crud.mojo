# =============================================================================
# test_dbstorable_sqlite_crud.mojo: generated DbStorable CRUD through SQLite.
# =============================================================================
#
# The chain under test, end to end, with no hand-written row shape:
#
#   tests/records.proto
#     -> protoc-gen-mojo-db (the :records_db mojo_db_proto_library)
#     -> records_db.records_db.Record, a generated DbStorable
#     -> Store[SqliteDatabase] over an in-memory SQLite database
#     -> CREATE TABLE, INSERT, get by key, UPDATE, list, DELETE
#
# Every read compares the whole decoded Record with the one written, through
# `_render`, which prints every field (NULL distinct from an empty value). So
# a column the generator drops, misorders or mistypes in any of the outputs
# the test runs (DDL, column names, column types, INSERT, to_row, from_row)
# fails a comparison or a statement. Running at all proves the binary links
# SQLite, built from source by //third_party/sqlite:sqlite3 and linked
# statically.
#
# What each step catches:
#   schema  column_types() names each column with its field number, logical
#           type and nullability; a renamed column carries its new name.
#   create  the generated SQLite DDL is valid SQL and is idempotent.
#   insert  insert_sql and to_row agree in count, order and column names
#           (20 binds, one of them a renamed column).
#   get     from_row decodes every kind; NULL optionals read back as None and
#           present ones as their value; by-name decode survives a reordered
#           projection (col_index_for).
#   update  the full-row UPDATE built from column_names() and to_row()
#           persists, including NULL -> value, value -> NULL, and an empty
#           string or zero in an optional column, which stays apart from NULL.
#   list    several rows decode in ORDER BY order; a WHERE on the indexed
#           column selects the right subset.
#   delete  Store.delete removes exactly the keyed row; a second delete
#           affects nothing; the other rows remain.
#   DEFAULT a row that omits `state` reads the DDL default 'NEW'.
#   constraints  a duplicate slug or primary key is refused by the UNIQUE or
#           PRIMARY KEY constraint, and a NULL in a required column by
#           NOT NULL; each refusal is checked by its SQLite message, so an
#           insert that fails for another reason does not pass.
#   neutral the backend-neutral ops SqliteDatabase delegates to
#           sql_neutral_ops: put, create_if_absent (won, then lost),
#           conditional_update (a guarded hit with a COALESCE term and a
#           now() column, then a stale guard that matches nothing),
#           query_rows (Filter, Order, limit) and delete_where.
#
# Not covered: query_rows_locked, create_if_absent_composite, claim_rows,
# the array-contains and json-key filters, and transactions.
#
# Byte values avoid length 16: the driver reads every 16-byte BLOB back as a
# UUID, so a 16-byte `bytes` value does not round-trip today.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import (
    DbColVal,
    DbColumn,
    DbValue,
    Filter,
    LOGICAL_TEXT,
    Order,
    Pred,
    Store,
    Timestamptz,
    Uuid,
    col_index_for,
    from_hyphenated,
    to_proto_json,
)
from komira_db_sqlite import SqliteDatabase

from records_db.records_db import Record

comptime _RT = BlockingRuntime[NoopSink]

comptime _ID_A = "0190a3b4-0000-7000-8000-00000000000a"
comptime _ID_B = "0190a3b4-0000-7000-8000-00000000000b"
comptime _ID_C = "0190a3b4-0000-7000-8000-00000000000c"
comptime _ID_D = "0190a3b4-0000-7000-8000-00000000000d"
comptime _ID_E = "0190a3b4-0000-7000-8000-00000000000e"
comptime _ID_F = "0190a3b4-0000-7000-8000-00000000000f"
comptime _ID_G = "0190a3b4-0000-7000-8000-000000000010"
comptime _PARENT = "0190a3b4-0000-7000-8000-0000000000ff"


# ---- fixtures ---------------------------------------------------------------


def _bytes(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def _strings(*vals: StaticString) -> List[String]:
    var out = List[String]()
    for v in vals:
        out.append(String(v))
    return out^


def _full(id: StaticString, owner: String, priority: Int32, slug: String) raises -> Record:
    """A row with every optional column present."""
    var attrs = Dict[String, String]()
    attrs["env"] = String("prod")
    attrs["region"] = String("eu-west-1")
    return Record(
        id=from_hyphenated(String(id)),
        owner=owner,
        priority=priority,
        size_bytes=Int64(9_223_372_036_854_775_807),
        done=True,
        # An embedded NUL and bytes that are not UTF-8.
        payload=_bytes(0x00, 0xFF, 0x10, 0x80, 0x7F),
        created_at=Timestamptz(Int64(1_700_000_000_123_456)),
        attrs=attrs^,
        tags=_strings("batch", "gpu"),
        note=Optional[String](String("first draft")),
        retries=Optional[Int32](Int32(-7)),
        quota=Optional[Int64](Int64(5_000_000_000)),
        flagged=Optional[Bool](False),
        digest=Optional[List[UInt8]](_bytes(0xDE, 0xAD, 0xBE)),
        finished_at=Optional[Timestamptz](Timestamptz(Int64(-1))),
        parent_id=Optional[Uuid](from_hyphenated(String(_PARENT))),
        state=String("RUNNING"),
        slug=slug,
        kind=String("KIND_BATCH"),
        display_name=String("Full row"),
    )


def _sparse(id: StaticString, owner: String, priority: Int32, slug: String) raises -> Record:
    """A row with every optional column NULL and the plain columns at their
    empty or false values."""
    return Record(
        id=from_hyphenated(String(id)),
        owner=owner,
        priority=priority,
        size_bytes=Int64(0),
        done=False,
        payload=List[UInt8](),
        created_at=Timestamptz(Int64(0)),
        attrs=Dict[String, String](),
        tags=List[String](),
        note=Optional[String](),
        retries=Optional[Int32](),
        quota=Optional[Int64](),
        flagged=Optional[Bool](),
        digest=Optional[List[UInt8]](),
        finished_at=Optional[Timestamptz](),
        parent_id=Optional[Uuid](),
        state=String("NEW"),
        slug=slug,
        kind=String("KIND_UNSPECIFIED"),
        display_name=String(),
    )


# ---- rendering: every field, NULL distinct from empty ------------------------


def _nibble(n: Int) -> String:
    if n < 10:
        return String(n)
    return chr(ord("a") + n - 10)


def _hex(b: List[UInt8]) -> String:
    var out = String("0x")
    for i in range(len(b)):
        out += _nibble(Int(b[i] >> 4)) + _nibble(Int(b[i] & 0xF))
    return out^


def _list(xs: List[String]) -> String:
    var out = String("[") + String(len(xs)) + String(":")
    for i in range(len(xs)):
        if i > 0:
            out += "|"
        out += xs[i]
    return out + "]"


def _render(r: Record) -> String:
    var s = String("id=") + r.id.to_hyphenated()
    s += String(" owner=") + r.owner
    s += String(" priority=") + String(Int(r.priority))
    s += String(" size_bytes=") + String(Int(r.size_bytes))
    s += String(" done=") + String(r.done)
    s += String(" payload=") + _hex(r.payload)
    s += String(" created_at=") + String(Int(r.created_at.unix_micros()))
    s += String(" attrs=") + to_proto_json(r.attrs)
    s += String(" tags=") + _list(r.tags)
    s += String(" note=")
    s += (String("'") + r.note.value() + String("'")) if r.note else String("NULL")
    s += String(" retries=")
    s += String(Int(r.retries.value())) if r.retries else String("NULL")
    s += String(" quota=")
    s += String(Int(r.quota.value())) if r.quota else String("NULL")
    s += String(" flagged=")
    s += String(r.flagged.value()) if r.flagged else String("NULL")
    s += String(" digest=")
    s += _hex(r.digest.value()) if r.digest else String("NULL")
    s += String(" finished_at=")
    s += String(Int(r.finished_at.value().unix_micros())) if r.finished_at else String("NULL")
    s += String(" parent_id=")
    s += r.parent_id.value().to_hyphenated() if r.parent_id else String("NULL")
    s += String(" state=") + r.state
    s += String(" slug=") + r.slug
    s += String(" kind=") + r.kind
    s += String(" display_name='") + r.display_name + String("'")
    return s^


# ---- SQL built from the generated schema -------------------------------------


def _col_list(names: List[String]) -> String:
    var out = String()
    for i in range(len(names)):
        if i > 0:
            out += ", "
        out += names[i]
    return out^


def _select_all() -> String:
    return String("SELECT ") + _col_list(Record.column_names()) + String(" FROM ") + Record.TABLE


def _by_id_sql() -> String:
    return _select_all() + String(" WHERE ") + Record.PK + String(" = ") + SqliteDatabase.placeholder(0)


def _pk(id: StaticString) raises -> DbValue:
    return DbValue.uuid(from_hyphenated(String(id)).bytes())


def _update_sql() -> String:
    """`UPDATE records SET <every column> = ?n WHERE id = ?(n+1)`."""
    var names = Record.column_names()
    var sql = String("UPDATE ") + Record.TABLE + String(" SET ")
    for i in range(len(names)):
        if i > 0:
            sql += ", "
        sql += names[i] + String(" = ") + SqliteDatabase.placeholder(i)
    sql += String(" WHERE ") + Record.PK + String(" = ") + SqliteDatabase.placeholder(len(names))
    return sql^


def _get(
    mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink], id: StaticString
) raises -> Optional[Record]:
    var params = List[DbValue]()
    params.append(_pk(id))
    return store.query_opt[_RT, Record](reactor, _by_id_sql(), params)


def _count(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises -> Int:
    return len(store.query[_RT, Record](reactor, _select_all(), List[DbValue]()))


# ---- the steps ---------------------------------------------------------------


def _schema() raises:
    # name:field_number:logical_type:nullable, in column order. Logical types:
    # 0 UUID, 1 TEXT, 2 INT4, 3 INT8, 6 BOOL, 7 BYTES, 8 TIMESTAMPTZ,
    # 9 JSONB, 10 TEXT_ARRAY (komira_db LOGICAL_*).
    var cols = Record.column_types()
    var got = String()
    for i in range(len(cols)):
        got += cols[i].name + String(":") + String(cols[i].field_number) + String(":")
        got += String(cols[i].logical_type) + String(":") + String("T" if cols[i].nullable else "F")
        got += String(" ")
    var want = String(
        "id:1:0:F owner:2:1:F priority:3:2:F size_bytes:4:3:F done:5:6:F"
        " payload:6:7:F created_at:7:8:F attrs:8:9:F tags:9:10:F note:10:1:T"
        " retries:11:2:T quota:12:3:T flagged:13:6:T digest:14:7:T"
        " finished_at:15:8:T parent_id:16:0:T state:17:1:F slug:18:1:F"
        " kind:19:1:F caption:20:1:F "
    )
    assert_equal(got, want, "schema: column_types()")
    assert_equal(_col_list(Record.column_names()), _col_list(_names_of(cols)), "schema: names agree")


def _names_of(cols: List[DbColumn]) -> List[String]:
    var out = List[String]()
    for i in range(len(cols)):
        out.append(cols[i].name)
    return out^


def _create(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    _ = store.db().execute[_RT](reactor, Record.create_table_ddl_sqlite(), List[DbValue]())
    # IF NOT EXISTS: a second run is a no-op, not an error.
    _ = store.db().execute[_RT](reactor, Record.create_table_ddl_sqlite(), List[DbValue]())
    assert_equal(_count(store, reactor), 0, "create: a new table is empty")


def _insert_and_get(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    var a = _full(_ID_A, String("owner-ü"), Int32(2), String("slug-a"))
    var b = _sparse(_ID_B, String("owner-ü"), Int32(1), String("slug-b"))
    assert_equal(store.insert[_RT, Record](reactor, a), UInt64(1), "insert a")
    assert_equal(store.insert[_RT, Record](reactor, b), UInt64(1), "insert b")
    assert_equal(_count(store, reactor), 2, "insert: two rows")

    var got_a = _get(store, reactor, _ID_A)
    assert_true(Bool(got_a), "get a: present")
    assert_equal(_render(got_a.value()), _render(a), "get a: every column")

    var got_b = _get(store, reactor, _ID_B)
    assert_true(Bool(got_b), "get b: present")
    assert_equal(_render(got_b.value()), _render(b), "get b: every column")
    # The NULLs are real NULLs, not empty values that render alike.
    assert_false(Bool(got_b.value().note), "get b: note is NULL")
    assert_false(Bool(got_b.value().flagged), "get b: flagged is NULL")
    assert_false(Bool(got_b.value().digest), "get b: digest is NULL")
    assert_false(Bool(got_b.value().parent_id), "get b: parent_id is NULL")
    assert_equal(len(got_b.value().payload), 0, "get b: empty payload")
    assert_equal(len(got_b.value().tags), 0, "get b: empty tags")

    assert_false(Bool(_get(store, reactor, _ID_D)), "get: an absent key is None")

    # The backend-neutral get_by_key op, decoded by column name from a
    # projection in REVERSE order: col_index_for maps names, not positions.
    var names = Record.column_names()
    var reversed = List[String]()
    for i in range(len(names) - 1, -1, -1):
        reversed.append(names[i])
    var row = store.db().get_by_key[_RT](
        reactor, String(Record.TABLE), reversed, String(Record.PK), _pk(_ID_A)
    )
    assert_true(Bool(row), "get_by_key a: present")
    var decoded = Record.from_row(row.value(), col_index_for[Record](row.value()))
    assert_equal(_render(decoded), _render(a), "get_by_key a: reversed projection")


def _update(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    # a: every optional column goes to NULL; b: every one gets a value.
    var a2 = _sparse(_ID_A, String("owner-b"), Int32(5), String("slug-a2"))
    var b2 = _full(_ID_B, String("owner-ü"), Int32(1), String("slug-b"))
    b2.tags = _strings("one")
    b2.attrs["region"] = String("us-east-2")
    b2.flagged = Optional[Bool](True)
    # Present but empty or zero: must not read back as NULL.
    b2.note = Optional[String](String(""))
    b2.retries = Optional[Int32](Int32(0))
    b2.kind = String("KIND_SERVICE")

    var pa = a2.to_row()
    pa.append(_pk(_ID_A))
    assert_equal(store.db().execute[_RT](reactor, _update_sql(), pa), UInt64(1), "update a")
    var pb = b2.to_row()
    pb.append(_pk(_ID_B))
    assert_equal(store.db().execute[_RT](reactor, _update_sql(), pb), UInt64(1), "update b")

    var got_a = _get(store, reactor, _ID_A)
    assert_equal(_render(got_a.value()), _render(a2), "update a: value -> NULL")
    var got_b = _get(store, reactor, _ID_B)
    assert_equal(_render(got_b.value()), _render(b2), "update b: NULL -> value")
    assert_true(Bool(got_b.value().note), "update b: an empty note is not NULL")
    assert_true(Bool(got_b.value().retries), "update b: a zero retries is not NULL")
    assert_equal(_count(store, reactor), 2, "update: no row added or lost")


def _list_rows(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    var c = _full(_ID_C, String("owner-c"), Int32(3), String("slug-c"))
    assert_equal(store.insert[_RT, Record](reactor, c), UInt64(1), "insert c")

    var all = store.query[_RT, Record](
        reactor, _select_all() + String(" ORDER BY priority"), List[DbValue]()
    )
    assert_equal(len(all), 3, "list: three rows")
    assert_equal(all[0].id.to_hyphenated(), String(_ID_B), "list: priority 1 first")
    assert_equal(all[1].id.to_hyphenated(), String(_ID_C), "list: priority 3 second")
    assert_equal(all[2].id.to_hyphenated(), String(_ID_A), "list: priority 5 last")
    assert_equal(_render(all[1]), _render(c), "list: c decodes whole")

    var params = List[DbValue]()
    params.append(DbValue.text(String("owner-c")))
    var mine = store.query[_RT, Record](
        reactor,
        _select_all() + String(" WHERE owner = ") + SqliteDatabase.placeholder(0),
        params,
    )
    assert_equal(len(mine), 1, "list: WHERE owner selects one row")
    assert_equal(mine[0].id.to_hyphenated(), String(_ID_C), "list: the right row")


def _delete(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    assert_equal(store.delete[_RT, Record](reactor, _pk(_ID_C)), UInt64(1), "delete c")
    assert_false(Bool(_get(store, reactor, _ID_C)), "delete: c is gone")
    assert_equal(store.delete[_RT, Record](reactor, _pk(_ID_C)), UInt64(0), "delete c again: nothing")
    assert_equal(_count(store, reactor), 2, "delete: a and b remain")
    assert_true(Bool(_get(store, reactor, _ID_A)), "delete: a remains")


def _sql_default(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    # An INSERT of every column but `state`, built from the generated names
    # and values, so the column's DDL DEFAULT fills it.
    var d = _sparse(_ID_D, String("owner-c"), Int32(9), String("slug-d"))
    d.state = String("NOT-WRITTEN")
    var names = Record.column_names()
    var vals = d.to_row()
    var cols = List[String]()
    var params = List[DbValue]()
    for i in range(len(names)):
        if names[i] != "state":
            cols.append(names[i])
            params.append(vals[i].copy())
    assert_equal(len(cols), len(names) - 1, "default: `state` is a generated column")
    var sql = String("INSERT INTO ") + Record.TABLE + String(" (") + _col_list(cols) + String(") VALUES (")
    for i in range(len(cols)):
        if i > 0:
            sql += ", "
        sql += SqliteDatabase.placeholder(i)
    sql += ")"
    assert_equal(store.db().execute[_RT](reactor, sql, params), UInt64(1), "default: insert d")
    var got = _get(store, reactor, _ID_D)
    assert_equal(got.value().state, String("NEW"), "default: state reads 'NEW'")


def _refusal(
    mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink], row: Record
) raises -> String:
    """The error text of an insert that must fail; empty if it succeeded."""
    try:
        _ = store.insert[_RT, Record](reactor, row)
    except e:
        return String(e)
    return String()


def _constraints(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    var before = _count(store, reactor)
    # A new primary key with the slug row a already holds.
    var err = _refusal(store, reactor, _sparse(_ID_C, String("x"), Int32(0), String("slug-a2")))
    assert_true(
        "UNIQUE constraint failed: records.slug" in err,
        String("constraints: a duplicate slug is refused by UNIQUE, got: ") + err,
    )
    # A new slug with the primary key row a already holds.
    err = _refusal(store, reactor, _sparse(_ID_A, String("x"), Int32(0), String("slug-new")))
    assert_true(
        "UNIQUE constraint failed: records.id" in err,
        String("constraints: a duplicate primary key is refused, got: ") + err,
    )
    # A NULL in a required column, through the generated INSERT.
    var vals = _sparse(_ID_C, String("x"), Int32(0), String("slug-null")).to_row()
    var names = Record.column_names()
    for i in range(len(names)):
        if names[i] == "owner":
            vals[i] = DbValue.null(vals[i].logical_type)
    err = String()
    try:
        _ = store.db().execute[_RT](reactor, Record.insert_sql[SqliteDatabase](), vals)
    except e:
        err = String(e)
    assert_true(
        "NOT NULL constraint failed: records.owner" in err,
        String("constraints: a NULL owner is refused by NOT NULL, got: ") + err,
    )
    assert_equal(_count(store, reactor), before, "constraints: nothing was written")


def _owner_is(owner: StaticString) -> Filter:
    return Filter.just(Pred.eq(String("owner"), DbValue.text(String(owner))))


def _neutral(mut store: Store[SqliteDatabase], mut reactor: Reactor[_RT.Sink]) raises:
    """The ops a consumer of SqliteDatabase reaches without writing SQL."""
    var table = String(Record.TABLE)
    var names = Record.column_names()
    var e = _full(_ID_E, String("owner-n"), Int32(4), String("slug-e"))
    var f = _sparse(_ID_F, String("owner-n"), Int32(6), String("slug-f"))

    # put: the plain INSERT of every column.
    assert_equal(store.db().put[_RT](reactor, table, names, e.to_row()), UInt64(1), "put e")
    assert_equal(_render(_get(store, reactor, _ID_E).value()), _render(e), "put e: every column")

    # create_if_absent: the first insert of a slug wins; a second with the
    # same slug loses and writes nothing.
    assert_true(
        store.db().create_if_absent[_RT](
            reactor, table, String("slug"), DbValue.text(String("slug-f")), names, f.to_row()
        ),
        "create_if_absent f: won",
    )
    var f_again = _sparse(_ID_G, String("owner-n"), Int32(7), String("slug-f"))
    assert_false(
        store.db().create_if_absent[_RT](
            reactor, table, String("slug"), DbValue.text(String("slug-f")), names, f_again.to_row()
        ),
        "create_if_absent f again: lost",
    )
    assert_false(Bool(_get(store, reactor, _ID_G)), "create_if_absent: the loser wrote nothing")
    assert_equal(_render(_get(store, reactor, _ID_F).value()), _render(f), "create_if_absent f: every column")

    # conditional_update: guarded on id AND state, so it is a compare-and-set.
    var guard_preds = List[Pred]()
    guard_preds.append(Pred.eq(String("id"), _pk(_ID_F)))
    guard_preds.append(Pred.eq(String("state"), DbValue.text(String("NEW"))))
    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("state"), DbValue.text(String("DONE"))))
    updates.append(DbColVal.coalesce(String("note"), DbValue.text(String("set by cas"))))
    updates.append(DbColVal.coalesce(String("caption"), DbValue.null(LOGICAL_TEXT)))
    var now_cols = List[String]()
    now_cols.append(String("finished_at"))
    assert_equal(
        store.db().conditional_update[_RT](
            reactor, table, Filter.all_of(guard_preds.copy()), updates.copy(), False, Optional[String](), now_cols
        ),
        UInt64(1),
        "conditional_update f: the guard matches",
    )
    var got_f = _get(store, reactor, _ID_F).value().copy()
    var want_f = f.copy()
    want_f.state = String("DONE")
    want_f.note = Optional[String](String("set by cas"))
    # COALESCE(NULL, caption) keeps the old caption; finished_at is now().
    assert_true(Bool(got_f.finished_at), "conditional_update f: finished_at is set")
    assert_true(got_f.finished_at.value().unix_micros() > Int64(0), "conditional_update f: finished_at is after the epoch")
    want_f.finished_at = got_f.finished_at.copy()
    assert_equal(_render(got_f), _render(want_f), "conditional_update f: every column")
    # The same guard again: state is no longer NEW, so nothing matches.
    assert_equal(
        store.db().conditional_update[_RT](
            reactor, table, Filter.all_of(guard_preds^), updates^, False, Optional[String](), List[String]()
        ),
        UInt64(0),
        "conditional_update f again: a stale guard matches nothing",
    )

    # query_rows: Filter + Order + limit, decoded by name.
    var order = List[Order]()
    order.append(Order.descending(String("priority")))
    var rows = store.db().query_rows[_RT](
        reactor, table, names, _owner_is("owner-n"), order, Optional[UInt32](UInt32(5))
    )
    assert_equal(rows.__len__(), 2, "query_rows: two rows of owner-n")
    var first = store.decode_row[Record](rows.row(0))
    assert_equal(first.id.to_hyphenated(), String(_ID_F), "query_rows: priority 6 first")
    assert_equal(_render(first), _render(want_f), "query_rows: f decodes whole")
    var limited = store.db().query_rows[_RT](
        reactor, table, names, _owner_is("owner-n"), order, Optional[UInt32](UInt32(1))
    )
    assert_equal(limited.__len__(), 1, "query_rows: limit 1")

    # delete_where: removes exactly the filtered rows.
    var before = _count(store, reactor)
    assert_equal(store.db().delete_where[_RT](reactor, table, _owner_is("owner-n")), UInt64(2), "delete_where owner-n")
    assert_equal(_count(store, reactor), before - 2, "delete_where: the other rows remain")
    assert_equal(store.db().delete_where[_RT](reactor, table, _owner_is("owner-n")), UInt64(0), "delete_where again: nothing")


def main() raises:
    _schema()
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var store = Store[SqliteDatabase](SqliteDatabase(String(":memory:")))
    _create(store, reactor)
    _insert_and_get(store, reactor)
    _update(store, reactor)
    _list_rows(store, reactor)
    _delete(store, reactor)
    _sql_default(store, reactor)
    _constraints(store, reactor)
    _neutral(store, reactor)
    print("test_dbstorable_sqlite_crud: PASS")
