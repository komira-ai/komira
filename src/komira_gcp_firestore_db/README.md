# komira_gcp_firestore_db

The komira_db `Database` conformer over Google Cloud Firestore, and an
in-memory Firestore to test it against.

- `FirestoreDatabase[C, S]` implements the backend-neutral `Database`
  operations (get by key, put, create-if-absent, conditional update, query,
  delete, and `begin`/`commit`/`rollback`) on Firestore documents through
  komira_gcp_firestore's document client, which sends with the generated
  Firestore REST client. It is not SQL: a table is a collection, a row a
  document keyed on its primary-key column (`id` unless a `TableKeys`
  declares another). A conditional update is a compare-and-set on the
  document's update time. A transaction journals its creates and rolls back
  by deleting them; each write is its own one-write Commit.
- The composite-index guard: a `FirestoreDatabase` carries the composite
  indexes its caller declared (`DeclaredIndexSet`) and refuses, before
  sending, a query shape Firestore cannot serve without one (Firestore would
  answer FAILED_PRECONDITION). A database built with no declarations refuses
  every such shape.
- `MockFirestore` is a stateful in-memory Firestore that answers the
  client's BatchGetDocuments, Commit and RunQuery at the HTTP boundary
  behind a `MockFirestoreConnector`, with Firestore's create-if-absent and
  update-time preconditions and a structured-query filter evaluator. No
  network, no credentials, no emulator.

## Examples

Every example runs on `MockFirestore`. A row round-trips through a document,
an absent key is `None` rather than an error, and of two creates of the same
key exactly one wins:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbColVal, DbValue, Filter, Order, Pred
from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import DeclaredIndexSet, FirestoreDatabase, MockFirestore, MockFirestoreConnector

comptime Runtime = BlockingRuntime[NoopSink]
comptime Db = FirestoreDatabase[MockFirestoreConnector]

def mock_db(var declared: DeclaredIndexSet) -> Db:
    var client = FirestoreClient[MockFirestoreConnector](
        MockFirestore().connector(), String("demo"), String("(default)"), String("test-bearer")
    )
    return Db(client^, declared^)

def columns() -> List[String]:
    return [String("id"), String("owner"), String("phase"), String("version")]

def row(id: String, owner: String, phase: String) -> List[DbValue]:
    return [DbValue.text(id), DbValue.text(owner), DbValue.text(phase), DbValue.int8(Int64(1))]

var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var db = mock_db(DeclaredIndexSet())

assert_equal(db.put[Runtime](reactor, "widget", columns(), row("w-1", "ana", "PENDING")), UInt64(1))
var got = db.get_by_key[Runtime](reactor, "widget", columns(), "id", DbValue.text("w-1"))
assert_true(Bool(got))
var r = got.take()
assert_equal(r.get_text(r.column_index("phase")), "PENDING")
assert_false(Bool(db.get_by_key[Runtime](reactor, "widget", columns(), "id", DbValue.text("w-9"))))

assert_true(db.create_if_absent[Runtime](
    reactor, "widget", "id", DbValue.text("w-2"), columns(), row("w-2", "ana", "PENDING")
))
assert_false(db.create_if_absent[Runtime](
    reactor, "widget", "id", DbValue.text("w-2"), columns(), row("w-2", "ana", "PENDING")
))
```

A conditional update applies only while its guard still matches, and bumps
the version column; the same guard issued again is stale and affects no
row, which a caller reports as a concurrent change:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var db = mock_db(DeclaredIndexSet())
_ = db.put[Runtime](reactor, "widget", columns(), row("w-1", "ana", "PENDING"))

def pending_guard() raises -> Filter:
    return Filter.all_of([
        Pred.eq("id", DbValue.text("w-1")), Pred.eq("phase", DbValue.text("PENDING"))
    ])

var to_running: List[DbColVal] = [DbColVal.bind("phase", DbValue.text("RUNNING"))]
var hit = db.conditional_update[Runtime](
    reactor, "widget", pending_guard(), to_running, False, Optional[String]("version"), List[String]()
)
assert_equal(hit, UInt64(1))
var found = db.get_by_key[Runtime](reactor, "widget", columns(), "id", DbValue.text("w-1"))
var after = found.take()
assert_equal(after.get_text(after.column_index("phase")), "RUNNING")
assert_equal(after.get_int8(after.column_index("version")), Int64(2))

var miss = db.conditional_update[Runtime](
    reactor, "widget", pending_guard(), to_running, False, Optional[String]("version"), List[String]()
)
assert_equal(miss, UInt64(0))
```

A query filters on the server's side: only the rows the filter matches come
back. An equality filter with an ORDER BY on another field needs a composite
index, so without a declaration it is refused before it is sent, naming the
collection and the fields; once declared, it runs:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var db = mock_db(DeclaredIndexSet())
_ = db.put[Runtime](reactor, "widget", columns(), row("w-1", "ana", "PENDING"))
_ = db.put[Runtime](reactor, "widget", columns(), row("w-2", "ana", "DONE"))
_ = db.put[Runtime](reactor, "widget", columns(), row("w-3", "bo", "PENDING"))

def owned_by(owner: String) raises -> Filter:
    return Filter.just(Pred.eq("owner", DbValue.text(owner)))

var anas = db.query_rows[Runtime](
    reactor, "widget", columns(), owned_by("ana"), List[Order](), Optional[UInt32]()
)
assert_equal(anas.__len__(), 2)

var by_phase: List[Order] = [Order.asc("phase")]
var refused = String()
try:
    _ = db.query_rows[Runtime](
        reactor, "widget", columns(), owned_by("ana"), by_phase.copy(), Optional[UInt32]()
    )
except e:
    refused = String(e)
assert_true("widget" in refused and "owner" in refused and "phase" in refused)

var declared = DeclaredIndexSet()
declared.declare_asc("widget", "owner", "phase")
var indexed = mock_db(declared^)
_ = indexed.put[Runtime](reactor, "widget", columns(), row("w-1", "ana", "PENDING"))
var ordered = indexed.query_rows[Runtime](
    reactor, "widget", columns(), owned_by("ana"), by_phase.copy(), Optional[UInt32]()
)
assert_equal(ordered.__len__(), 1)
```
