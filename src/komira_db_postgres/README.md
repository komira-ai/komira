# komira_db_postgres

The Postgres driver for `komira_db`, over its own pgwire v3 client.

- `PgDatabase` conforms to `komira_db`'s `SqlDatabase` (and to
  `PooledResource`): `execute`, `query`, the nine structured operations
  (rendered through `komira_db`'s shared `render_*`, with `$1`, `$2`, ...
  placeholders), transactions and `claim_pending`. Parameters are bound in
  Postgres's binary format through the extended protocol.
- `to_pg_params` maps `komira_db` `DbValue`s to `PgValue` bind parameters
  (UUID, int4, int8, timestamptz, jsonb, text[], bool and bytea get their own
  OIDs; anything else binds as text), and `pg_rows_to_db_rows` renders a
  binary-format `PgRows` result into `komira_db`'s `DbRows`. These two are the
  bridge for callers that drive a query with the poll-shaped `PgQueryOp`
  instead of the blocking `PgDatabase.query`.
- `PgPool` is `komira_db`'s `Pool` over `PgDatabase`.
- `komira_db_postgres.wire` is the client: `PgConfig`, `PgConnection`
  (TCP, the SSLRequest preamble and TLS, SCRAM-SHA-256 authentication,
  simple and extended-protocol queries), `PgRow` / `PgRows` / `PgValue` over
  a closed set of OIDs, `PgError`, and the reactor-driven `PgQueryOp` and
  `PgTxAsyncOp`.

`PgConfig` requires TLS by default and does not verify the server's
certificate unless `verify_cert` is set to `True`; a deployment that must
authenticate its server sets it.

Talking to a server needs one, so the examples below run only the parts that
need no server: SQL rendering, parameter encoding and result decoding.

## Examples

The SQL the structured operations send to Postgres, and how a parameter list
binds:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_db import DbValue, Filter, LOGICAL_INT4, Order, Pred, render_query_rows
from komira_db_postgres import PgDatabase, to_pg_params
from komira_db_postgres.wire import OID_INT4, OID_INT8, OID_TEXT, OID_UUID

var preds = List[Pred]()
preds.append(Pred.eq("owner", DbValue.text("ana")))
preds.append(Pred.lt("attempts", DbValue.int4(Int32(3))))
var order = List[Order]()
order.append(Order.descending("created_at"))
var next_bind = 0
var sql = render_query_rows[PgDatabase](
    "tasks", ["id", "state"], Filter.all_of(preds^), order, True, next_bind
)
assert_equal(
    sql,
    "SELECT id, state FROM tasks WHERE owner = $1 AND attempts < $2"
    + " ORDER BY created_at DESC LIMIT $3",
)
assert_equal(next_bind, 3)

var params = List[DbValue]()
params.append(DbValue.text("ana"))
params.append(DbValue.int4(Int32(3)))
params.append(DbValue.int8(Int64(-2)))
params.append(DbValue.null(LOGICAL_INT4))
var pg = to_pg_params(params)
assert_equal(pg[0].oid, OID_TEXT)
assert_equal(pg[1].oid, OID_INT4)
assert_equal(pg[3].is_null, True)

# int8 binds as 8 big-endian bytes; a NULL has no body.
var body = pg[2].binary_body()
assert_equal(len(body), 8)
assert_equal(body[0], 0xFF)
assert_equal(body[7], 0xFE)
assert_equal(len(pg[3].binary_body()), 0)
```

A binary-format result row, as the server sends it, rendered to `DbRows`:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_db_postgres import pg_rows_to_db_rows
from komira_db_postgres.wire import OID_INT8, OID_TEXT, PgRow, PgRows

# Two columns: int8 42 (8 big-endian bytes) and the text "done".
var data: List[UInt8] = [0, 0, 0, 0, 0, 0, 0, 42, 0x64, 0x6F, 0x6E, 0x65]
var offsets: List[Int] = [0, 8, 12]
var nulls: List[Bool] = [False, False]
var oids: List[UInt32] = [OID_INT8, OID_TEXT]
var rows = List[PgRow]()
rows.append(PgRow(data^, offsets^, nulls^, oids.copy(), True))
var pg_rows = PgRows(rows^, ["n", "state"])

var db_rows = pg_rows_to_db_rows(pg_rows, oids, ["n", "state"])
assert_equal(db_rows.__len__(), 1)
assert_equal(db_rows.row(0).get_int8(0), Int64(42))
assert_equal(db_rows.row(0).get_text(db_rows.column_index("state")), "done")
```
