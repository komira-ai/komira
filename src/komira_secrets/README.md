# `komira_secrets`

## Responsibility

Komira holds handles, never secret values. The customer's own secret store holds
the values, and `SecretStore` (`komira_secret_store`) turns a handle into a
`SecretValue` at the moment of use. This package adds the catalog of those
handles and the write side of the seam:

- `SecretManager`: the persisted catalog row, a `komira_db` `DbStorable`. Every
  column is a name: an org (and optionally a workspace) scope, a catalog handle
  `name_handle`, which kind of store holds the value (`provider_kind`), the
  opaque `secret_ref` the store resolves, `reachability`, `status`, timestamps and
  a `version`. There is no value, key, token or ciphertext column.
- `SecretManagerStore[DB: Database]`: `register`, `get`, `list_for_org`,
  `set_status` and `update_secret_ref` over any `komira_db` backend. No method
  takes a value, so a value cannot reach the catalog.
- `secret_migrations`: the SQL schema chain (the table, then an `org_id` index).
- `SecretWriteStore`: the write trait, `put(name, value) -> handle`, the mirror
  of `SecretStore.resolve`. Kept apart from the read trait so code that only
  reveals secrets holds no writer. `InMemorySecretWriteStore` is a spyable
  double.
- `SharedMemorySecretStore`: an in-memory store that is both a `SecretStore` and
  a `SecretWriteStore` over one shared state, so a value put through one handle
  resolves through another. It is for tests and single-process use; it is not
  durable.

`SecretStore`, `StaticSecretStore`, `SecretValue`, `SecretMeta` and
`MAX_SECRET_LEN` live in `komira_secret_store`; import them from there.

No pointer crosses the package's API.

## API

Everything is exported from `komira_secrets`:

- The row: `SecretManager`, the ordinals `PROVIDER_*` (`PROVIDER_KIND_COUNT`
  of them), `REACHABILITY_CENTRAL_REACHABLE`,
  `REACHABILITY_CUSTOMER_BOUNDARY_ONLY`, `SECRET_STATUS_*`, and
  `provider_kind_str` / `secret_status_str` (a stable token; an unknown ordinal
  gets `unknown` / `unspecified`, never a concrete provider or `ready`).
- `SecretManagerStore[DB](db)`: every call takes the caller's reactor
  (`[RT](reactor, ...)`) and a `now_us` where it writes. `register` returns the
  new row's id at status `pending`, version 1. `update_secret_ref` applies only
  when the row is still at `expected_version`, and returns whether it did.
- `secret_migrations`, `SECRET_SCHEMA_V1`, `SECRET_SCHEMA_V2`.
- `SecretWriteStore`, `InMemorySecretWriteStore`, `SharedMemorySecretStore`.

## Examples

A value written to the shared store resolves from any handle onto it, and a
second `put` under the same name is a rotation. An unknown handle raises:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_raises, assert_true
-->
```mojo
from komira_secrets import SharedMemorySecretStore

var writer = SharedMemorySecretStore()
var reader = writer.share()

assert_equal(writer.put("acct/token", "t-1"), "acct/token")  # the handle
assert_true(reader.has("acct/token"))
var v = reader.resolve("acct/token")
assert_equal(v.len(), 3)
assert_equal(String(v), "SecretValue(<redacted:3B>)")  # printing never leaks

_ = writer.put("acct/token", "t-22")  # a rotation
assert_equal(reader.resolve("acct/token").len(), 4)

assert_false(reader.has("acct/other"))
with assert_raises(contains="no secret for acct/other"):
    _ = reader.resolve("acct/other")
```

The write double records what was put, so a test can check that a value was
written once and under which handle:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_secrets import InMemorySecretWriteStore

var store = InMemorySecretWriteStore()
var spy = store.share()
var handle = store.put("svc/key", "s3cret")
assert_equal(handle, "svc/key")
assert_equal(spy.put_count(), 1)
assert_equal(spy.value_for("svc/key"), "s3cret")
assert_true(spy.any_value_equals("s3cret"))
assert_false(spy.any_value_equals("another"))
```

The catalog row names no value. Its columns, in order, and the stable tokens of
its ordinals:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo
from komira_secrets import (
    PROVIDER_VAULT_KV,
    SECRET_STATUS_READY,
    SecretManager,
    provider_kind_str,
    secret_status_str,
)

var names = SecretManager.column_names()
assert_equal(len(names), 11)
assert_equal(names[3], "name_handle")
assert_equal(names[5], "secret_ref")  # a handle, never the value
assert_true("CREATE TABLE IF NOT EXISTS secret_manager" in SecretManager.create_table_ddl())

assert_equal(provider_kind_str(PROVIDER_VAULT_KV), "vault_kv")
assert_equal(provider_kind_str(Int32(99)), "unknown")
assert_equal(secret_status_str(SECRET_STATUS_READY), "ready")
assert_equal(secret_status_str(Int32(99)), "unspecified")
```

A store over SQLite, in outline (the package's own tests run every call this way,
with `komira_db_sqlite`):

```text
var runner = MigrationRunner[SqliteDatabase](SqliteDatabase(":memory:"))
_ = runner.run[RT](reactor, secret_migrations[SqliteDatabase]())
var store = SecretManagerStore[SqliteDatabase](runner^.into_db())
var id = store.register[RT](reactor, org_id, Optional[Uuid](), "prod-pg",
    PROVIDER_GCP_SECRET_MANAGER, "projects/p/secrets/prod-pg/versions/latest",
    REACHABILITY_CENTRAL_REACHABLE, now_us)
_ = store.set_status[RT](reactor, id, SECRET_STATUS_READY, now_us)
```
