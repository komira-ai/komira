# =============================================================================
# test_secret_manager_store.mojo -- SecretManagerStore[DB] and the migration
#   chain on an in-memory SQLite database.
# =============================================================================
#
#   migrations  the chain has two steps with the declared versions and names; a
#               second run applies nothing; the index of the second step exists.
#   register    every name round-trips; a fresh row is pending at version 1;
#               an org-shared row reads back no workspace and a workspace row
#               reads back its workspace; an unknown id reads back None.
#   status      set_status sets the status and bumps the version; an unknown id
#               changes nothing and reports False.
#   CAS         update_secret_ref with the current version wins and bumps the
#               version; with a stale version it loses and changes nothing; an
#               unknown id loses.
#   catalog     list_for_org returns only that org's rows (org-shared and
#               workspace-scoped) in ascending id order, and an org with no
#               rows gets an empty list.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import (
    DbValue,
    MigrationRunner,
    Uuid,
    generate_uuidv7,
)
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase

from komira_secrets import (
    PROVIDER_GCP_SECRET_MANAGER,
    PROVIDER_VAULT_KV,
    REACHABILITY_CENTRAL_REACHABLE,
    REACHABILITY_CUSTOMER_BOUNDARY_ONLY,
    SECRET_SCHEMA_V1,
    SECRET_SCHEMA_V2,
    SECRET_STATUS_FAILED,
    SECRET_STATUS_PENDING,
    SECRET_STATUS_READY,
    SecretManager,
    SecretManagerStore,
    secret_migrations,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = SecretManagerStore[SqliteDatabase]
comptime NOW: Int64 = 1_800_000_000_000_000


def _rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def _store() raises -> Store:
    var rt = _rt()
    ref reactor = rt.reactor()
    var runner = MigrationRunner[SqliteDatabase](
        SqliteDatabase(String(":memory:"))
    )
    _ = runner.run[Rt](reactor, secret_migrations[SqliteDatabase]())
    return Store(runner^.into_db())


def _register(
    mut s: Store,
    org: Uuid,
    ws: Optional[Uuid],
    name: StaticString,
    ref_: StaticString,
) raises -> Uuid:
    var rt = _rt()
    ref reactor = rt.reactor()
    return s.register[Rt](
        reactor,
        org,
        ws,
        String(name),
        PROVIDER_GCP_SECRET_MANAGER,
        String(ref_),
        REACHABILITY_CENTRAL_REACHABLE,
        NOW,
    )


def _row(mut s: Store, id: Uuid) raises -> SecretManager:
    var rt = _rt()
    ref reactor = rt.reactor()
    var got = s.get[Rt](reactor, id)
    return got.take()


def test_migration_chain() raises:
    var chain = secret_migrations[SqliteDatabase]()
    assert_equal(len(chain), 2)
    assert_equal(chain[0].version, SECRET_SCHEMA_V1)
    assert_equal(chain[0].name, String("secret_manager table"))
    assert_equal(chain[1].version, SECRET_SCHEMA_V2)
    assert_equal(chain[1].name, String("secret_manager org_id index"))
    assert_equal(SECRET_SCHEMA_V1, 1)
    assert_equal(SECRET_SCHEMA_V2, 2)

    var rt = _rt()
    ref reactor = rt.reactor()
    var runner = MigrationRunner[SqliteDatabase](
        SqliteDatabase(String(":memory:"))
    )
    assert_equal(runner.run[Rt](reactor, secret_migrations[SqliteDatabase]()), 2)
    assert_equal(
        runner.run[Rt](reactor, secret_migrations[SqliteDatabase]()),
        0,
        "a migrated database applies nothing",
    )
    var db = runner^.into_db()
    # DROP INDEX raises unless the second step made the index.
    _ = db_blocking_execute(
        db,
        String("DROP INDEX idx_secret_manager_org_id"),
        List[DbValue](),
    )


def test_register_and_get_round_trip() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var org = generate_uuidv7()
    var id = s.register[Rt](
        reactor,
        org,
        Optional[Uuid](),
        String("prod-pg"),
        PROVIDER_GCP_SECRET_MANAGER,
        String("projects/p/secrets/prod-pg/versions/latest"),
        REACHABILITY_CENTRAL_REACHABLE,
        NOW,
    )
    var got = s.get[Rt](reactor, id)
    assert_true(Bool(got), "the registered row reads back")
    var row = got.take()
    assert_true(row.id == id)
    assert_true(row.org_id == org)
    assert_equal(row.name_handle, String("prod-pg"))
    assert_equal(
        row.secret_ref, String("projects/p/secrets/prod-pg/versions/latest")
    )
    assert_equal(row.provider_kind, PROVIDER_GCP_SECRET_MANAGER)
    assert_equal(row.reachability, REACHABILITY_CENTRAL_REACHABLE)
    assert_equal(row.status, SECRET_STATUS_PENDING)
    assert_false(row.is_ready())
    assert_equal(row.version, Int64(1))
    assert_equal(row.created_at.micros, NOW)
    assert_equal(row.updated_at.micros, NOW)
    assert_true(row.is_org_shared())
    assert_false(Bool(row.workspace_id), "org-shared reads back no workspace")

    var other = s.register[Rt](
        reactor,
        org,
        Optional[Uuid](),
        String("byo"),
        PROVIDER_VAULT_KV,
        String("kv/data/byo"),
        REACHABILITY_CUSTOMER_BOUNDARY_ONLY,
        NOW,
    )
    assert_false(other == id, "each register mints a fresh id")
    var row2 = _row(s, other)
    assert_equal(row2.provider_kind, PROVIDER_VAULT_KV)
    assert_equal(row2.reachability, REACHABILITY_CUSTOMER_BOUNDARY_ONLY)

    assert_false(Bool(s.get[Rt](reactor, generate_uuidv7())), "unknown id")


def test_workspace_scope_round_trips() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var ws = generate_uuidv7()
    var id = _register(s, generate_uuidv7(), Optional[Uuid](ws), "w", "ref-w")
    var row = _row(s, id)
    assert_false(row.is_org_shared())
    assert_true(Bool(row.workspace_id))
    assert_true(row.workspace_id.value() == ws)


def test_set_status() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var id = _register(s, generate_uuidv7(), Optional[Uuid](), "n", "r")
    assert_true(s.set_status[Rt](reactor, id, SECRET_STATUS_READY, NOW + 5))
    var row = _row(s, id)
    assert_equal(row.status, SECRET_STATUS_READY)
    assert_true(row.is_ready())
    assert_equal(row.version, Int64(2))
    assert_equal(row.updated_at.micros, NOW + 5)
    assert_equal(row.created_at.micros, NOW, "created_at is not touched")
    assert_equal(row.secret_ref, String("r"), "other columns are not touched")

    assert_true(s.set_status[Rt](reactor, id, SECRET_STATUS_FAILED, NOW + 6))
    var failed = _row(s, id)
    assert_equal(failed.status, SECRET_STATUS_FAILED)
    assert_false(failed.is_ready())
    assert_equal(failed.version, Int64(3))

    assert_false(
        s.set_status[Rt](reactor, generate_uuidv7(), SECRET_STATUS_READY, NOW),
        "an unknown id changes nothing",
    )


def test_update_secret_ref_is_a_version_cas() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var id = _register(s, generate_uuidv7(), Optional[Uuid](), "n", "ref-v1")

    assert_true(
        s.update_secret_ref[Rt](reactor, id, String("ref-v2"), Int64(1), NOW + 1),
        "the current version wins",
    )
    var won = _row(s, id)
    assert_equal(won.secret_ref, String("ref-v2"))
    assert_equal(won.version, Int64(2))
    assert_equal(won.updated_at.micros, NOW + 1)

    assert_false(
        s.update_secret_ref[Rt](reactor, id, String("stale"), Int64(1), NOW + 2),
        "a stale version loses",
    )
    var kept = _row(s, id)
    assert_equal(kept.secret_ref, String("ref-v2"), "the loser wrote nothing")
    assert_equal(kept.version, Int64(2))
    assert_equal(kept.updated_at.micros, NOW + 1)

    assert_false(
        s.update_secret_ref[Rt](
            reactor, generate_uuidv7(), String("x"), Int64(1), NOW
        ),
        "an unknown id loses",
    )


def test_list_for_org_is_scoped() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var org_a = generate_uuidv7()
    var org_b = generate_uuidv7()
    var ws = generate_uuidv7()
    var first = _register(s, org_a, Optional[Uuid](), "a-shared", "ref-1")
    var second = _register(s, org_a, Optional[Uuid](ws), "a-ws", "ref-2")
    var only_b = _register(s, org_b, Optional[Uuid](), "b-shared", "ref-4")

    var a = s.list_for_org[Rt](reactor, org_a)
    assert_equal(len(a), 2)
    var saw_shared = False
    var saw_ws = False
    for i in range(len(a)):
        if a[i].id == first:
            saw_shared = True
            assert_equal(a[i].name_handle, String("a-shared"))
            assert_true(a[i].is_org_shared())
        elif a[i].id == second:
            saw_ws = True
            assert_equal(a[i].name_handle, String("a-ws"))
            assert_true(a[i].workspace_id.value() == ws)
    assert_true(saw_shared and saw_ws, "both of the org's rows are listed")

    var b = s.list_for_org[Rt](reactor, org_b)
    assert_equal(len(b), 1)
    assert_true(b[0].id == only_b)

    assert_equal(len(s.list_for_org[Rt](reactor, generate_uuidv7())), 0)


def test_list_for_org_is_in_id_order() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var org = generate_uuidv7()
    for _ in range(12):
        _ = _register(s, org, Optional[Uuid](), "n", "r")
    var rows = s.list_for_org[Rt](reactor, org)
    assert_equal(len(rows), 12)
    for i in range(1, len(rows)):
        assert_true(
            rows[i - 1].id.to_hyphenated() < rows[i].id.to_hyphenated(),
            "rows come back in ascending id order",
        )


def main() raises:
    test_migration_chain()
    test_register_and_get_round_trip()
    test_workspace_scope_round_trips()
    test_set_status()
    test_update_secret_ref_is_a_version_cas()
    test_list_for_org_is_scoped()
    test_list_for_org_is_in_id_order()
    print("PASS test_secret_manager_store")
