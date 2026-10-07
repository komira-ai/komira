# komira_db_sqlite

The SQLite driver for `komira_db`. `SqliteDatabase` opens one connection to a
database file, or to an in-process `":memory:"` database, over libsqlite3,
which is built from source and linked statically. It conforms to
`komira_db`'s `SqlDatabase` trait: `execute` (returns the number of rows
changed), `query` / `query_opt` / `query_one` (return `DbRows` / `DbRow`), the
nine structured operations (`get_by_key`, `put`, `delete_by_key`,
`query_rows`, `query_rows_locked`, `conditional_update`, `delete_where`,
`create_if_absent`, `create_if_absent_composite`, `claim_rows`), and
transactions (`begin` issues `BEGIN IMMEDIATE`, then `commit` or `rollback`).
`arm_for_concurrent_use` sets the busy timeout for connections that share a
file.

Placeholders are `?1`, `?2`, ... (`SqliteDatabase.placeholder(i)`); the
structured operations render their SQL through `komira_db`'s shared
`render_*`. Calls are synchronous FFI: the reactor argument every method takes
is there for the trait's sake and is not used. A result cell's logical type
follows SQLite's storage class: an INTEGER reads back as int8, a 16-byte BLOB
as a UUID, any other BLOB as bytes, and TEXT and REAL as text.

## Examples

Create a table, insert through the structured `put`, read back with a filter,
an order and a limit, and update under a guard, all in an in-memory database:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbColVal, DbValue, Filter, Order, Pred
from komira_db_sqlite import SqliteDatabase

comptime RT = BlockingRuntime[NoopSink]

var rt = RT.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var db = SqliteDatabase(":memory:")

_ = db.execute[RT](
    reactor,
    "CREATE TABLE items (name TEXT PRIMARY KEY, qty INTEGER NOT NULL, state TEXT)",
    List[DbValue](),
)
var cols: List[String] = ["name", "qty", "state"]
var names: List[String] = ["bolt", "nut", "washer"]
var qtys: List[Int] = [40, 7, 12]
for i in range(3):
    var vals = List[DbValue]()
    vals.append(DbValue.text(names[i]))
    vals.append(DbValue.int8(Int64(qtys[i])))
    vals.append(DbValue.text("new"))
    assert_equal(db.put[RT](reactor, "items", cols, vals), UInt64(1))

# qty >= 10, largest first, at most one row.
var order = List[Order]()
order.append(Order.descending("qty"))
var rows = db.query_rows[RT](
    reactor,
    "items",
    cols,
    Filter.just(Pred.gte("qty", DbValue.int8(Int64(10)))),
    order,
    Optional[UInt32](UInt32(1)),
)
assert_equal(rows.__len__(), 1)
assert_equal(rows.row(0).get_text(0), "bolt")
assert_equal(rows.row(0).get_int8(1), Int64(40))

# Move "nut" from new to done only if it is still new: the guard is the filter.
var guard = List[Pred]()
guard.append(Pred.eq("name", DbValue.text("nut")))
guard.append(Pred.eq("state", DbValue.text("new")))
var updates = List[DbColVal]()
updates.append(DbColVal.bind("state", DbValue.text("done")))
var changed = db.conditional_update[RT](
    reactor, "items", Filter.all_of(guard.copy()), updates.copy(),
    False, Optional[String](), List[String](),
)
assert_equal(changed, UInt64(1))
var again = db.conditional_update[RT](
    reactor, "items", Filter.all_of(guard^), updates^,
    False, Optional[String](), List[String](),
)
assert_equal(again, UInt64(0))  # the guard no longer matches

var nut = db.get_by_key[RT](reactor, "items", cols, "name", DbValue.text("nut"))
assert_true(Bool(nut))
assert_equal(nut.value().get_text(2), "done")
assert_false(Bool(db.get_by_key[RT](reactor, "items", cols, "name", DbValue.text("gear"))))
```

A rolled-back transaction leaves nothing behind, and the SQL the structured
operations issue uses SQLite's placeholders:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbValue, Filter, Order, Pred, render_query_rows
from komira_db_sqlite import SqliteDatabase

comptime R = BlockingRuntime[NoopSink]

var rt = R.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var db = SqliteDatabase(":memory:")
_ = db.execute[R](reactor, "CREATE TABLE t (k TEXT)", List[DbValue]())

db.begin[R](reactor)
var params = List[DbValue]()
params.append(DbValue.text("draft"))
assert_equal(db.execute[R](reactor, "INSERT INTO t (k) VALUES (?1)", params), UInt64(1))
db.rollback[R](reactor)
var count = db.query_one[R](reactor, "SELECT COUNT(*) FROM t", List[DbValue]())
assert_equal(count.get_int8(0), Int64(0))

var next_bind = 0
var sql = render_query_rows[SqliteDatabase](
    "t", ["k"], Filter.just(Pred.eq("k", DbValue.text("x"))), List[Order](), True, next_bind
)
assert_equal(sql, "SELECT k FROM t WHERE k = ?1 LIMIT ?2")
assert_equal(next_bind, 2)
```
