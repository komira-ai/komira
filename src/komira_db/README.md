# komira_db

The backend-generic database layer that generated row types and the
database drivers compile against. It holds no driver: the SQLite driver is
`komira_db_sqlite` and the Postgres driver is `komira_db_postgres`.

- **Values and rows.** `DbValue` is a logical value tagged with one of the
  `LOGICAL_*` types (UUID, text, int4/int8, float4/float8, bool, bytes,
  timestamptz, jsonb, text array) and carried in a canonical text form, or a
  typed NULL; it never carries a backend's type id. `DbRow` is one result row
  with typed getters (`get_text`, `get_int8`, `get_opt_int4`, ...);
  `DbRows` is a result set. `DbColumn` describes one column. `Uuid`
  (`from_hyphenated`, `generate_uuidv7`) and `Timestamptz` (microseconds
  since the Unix epoch) are the UUID and TIMESTAMPTZ field types.
- **Backends.** `Database` is the backend-neutral trait: transactions plus
  nine structured operations (get/put/delete by key, filtered and locked
  queries, conditional update, delete-where, create-if-absent, claim).
  `SqlDatabase` adds `execute`/`query`, the dialect, placeholder and `now()`
  spellings. The SQL text of the nine operations is rendered once, in
  `render_*`, and run by `sql_op_*`, so every SQL backend issues the same
  statements up to its placeholder and dialect spelling.
- **Structured-operation values.** `Pred` (`eq`, `ne`, `lt`, `le`, `gte`,
  `in_list`, `is_null`, `json_key_eq`, `array_contains`, ...), `Filter`
  (`all_of`, `any_of`, `just`, `none`), `Order` and `DbColVal` (a bound value,
  a `COALESCE` partial update, or a raw SQL expression).
  `classify_raw_expr` says what a raw expression means to a backend with no
  SQL evaluator: `<col> + 1`, `true`, `false`, `null` and a decimal integer,
  and nothing else.
- **Typed storage.** `DbStorable` (the generated row-type contract), `Store`
  (a typed store over a `SqlDatabase`), `DbSchema`, `Migration` and
  `MigrationRunner`, `Pool` and `PooledResource`, and `to_proto_json` /
  `from_proto_json` for nested fields stored as JSON.

## Examples

Values carry a canonical text form; a row built from them reads back through
the typed getters:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_db import DbRow, DbValue, LOGICAL_INT4, LOGICAL_TEXT_ARRAY, Timestamptz, from_hyphenated, logical_type_name

var id = from_hyphenated("0192f1c4-5e2a-7b3c-8d4e-0123456789ab")
assert_equal(id.to_hyphenated(), "0192f1c4-5e2a-7b3c-8d4e-0123456789ab")

var tags = DbValue.text_array(["red", "blue"])
assert_equal(tags.as_text(), "{red,blue}")
assert_equal(tags.logical_type, LOGICAL_TEXT_ARRAY)
assert_equal(String(logical_type_name(LOGICAL_INT4)), "INT4")

var values = List[DbValue]()
values.append(DbValue.uuid(id.bytes()))
values.append(DbValue.text("widget"))
values.append(DbValue.int8(Int64(42)))
values.append(DbValue.null(LOGICAL_INT4))
values.append(DbValue.timestamptz(Timestamptz.from_micros(Int64(1_500_000))))
values.append(tags^)
var row = DbRow.from_values(values, ["id", "name", "count", "rank", "seen_at", "tags"])

assert_equal(row.col_count(), 6)
assert_equal(row.get_uuid_hex(0), "0192f1c4-5e2a-7b3c-8d4e-0123456789ab")
assert_equal(row.get_text(row.column_index("name")), "widget")
assert_equal(row.get_int8(2), Int64(42))
assert_true(row.is_null(3))
assert_false(Bool(row.get_opt_int4(3)))
assert_equal(row.get_timestamptz_micros(4), Int64(1_500_000))
var back = row.get_text_array(5)
assert_equal(len(back), 2)
assert_equal(back[1], "blue")
```

Structured-operation values, the shared ORDER BY rendering, and what a
document backend may do with a raw expression:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_db import DbColVal, DbValue, Filter, Order, Pred, RAWEXPR_INCREMENT, RAWEXPR_LITERAL, RAWEXPR_UNEVALUABLE, classify_raw_expr, render_order

var preds = List[Pred]()
preds.append(Pred.eq("status", DbValue.text("pending")))
preds.append(Pred.is_null("claimed_by"))
var f = Filter.all_of(preds^)
assert_equal(len(f.preds), 2)

var order = List[Order]()
order.append(Order.descending("created_at"))
order.append(Order.asc("id"))
assert_equal(render_order(order), "created_at DESC, id")

var bump = DbColVal.raw_expr("version", "version + 1")
assert_true(bump.is_raw_expr())
assert_equal(classify_raw_expr("version", "version + 1").kind, RAWEXPR_INCREMENT)
var lit = classify_raw_expr("revoked", "TRUE")
assert_equal(lit.kind, RAWEXPR_LITERAL)
assert_equal(lit.literal.as_text(), "true")
# A cross-column read is not in the vocabulary: the backend must refuse it.
assert_equal(classify_raw_expr("version", "seen + 1").kind, RAWEXPR_UNEVALUABLE)
```
