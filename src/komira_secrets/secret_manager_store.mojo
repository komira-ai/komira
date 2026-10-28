# =============================================================================
# komira_secrets/secret_manager_store.mojo -- SecretManagerStore[DB], the
#   persistence of the names-only secret catalog.
# =============================================================================
#
# A service parametric over the backend-neutral `DB: Database`, owning a moved-in
# `db` directly, with a small typed surface: register / get / list_for_org / CAS
# updates. It runs on any `Database` (SQLite, Postgres, a document backend).
#
#   * register(...)          -- INSERT a `secret_manager` row holding ONLY names,
#                               at status=pending / version=1; returns the new id.
#   * get(id)                -- read a row by id; None on an unknown id.
#   * list_for_org(org_id)   -- every row of the org, ordered by id.
#   * set_status(id, status) -- set the onboarding-grant readiness, bumping
#                               version (pending -> ready | failed).
#   * update_secret_ref(id, ref, expected_version) -- replace the OPAQUE handle
#                               only if the row is still at `expected_version`.
#
# CUSTODY: no method takes a value, so a secret VALUE cannot reach this store by
# construction. The value is written to the customer's store by other means.
#
# No pointer crosses the API: `Uuid` / `String` / scalars / `Optional` / `List`
# in and out. The `DB` is a plain owned field.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import (
    Database,
    DbValue,
    DbRow,
    DbRows,
    DbColVal,
    Filter,
    Pred,
    Order,
    Uuid,
    Timestamptz,
    generate_uuidv7,
    col_index_for,
)

from komira_secrets.secret_manager import (
    SecretManager,
    SECRET_STATUS_PENDING,
)


struct SecretManagerStore[DB: Database](Movable):
    """Names-only secret-catalog persistence over the backend-NEUTRAL `Database`.
    Owns the moved-in `db` directly (NOT a `Store[DB]`, which is
    SqlDatabase-bound) for the service's lifetime. Every op is neutral (put /
    get_by_key / query_rows / conditional_update), so the same store runs on
    SQLite, Postgres or a document backend. Persists ONLY names (no value
    parameter on any method)."""

    var _db: Self.DB

    def __init__(out self, var db: Self.DB):
        self._db = db^

    def into_db(deinit self) -> Self.DB:
        """Recover the underlying `db` (e.g. to share the connection)."""
        return self._db^

    def db(ref self) -> ref [self._db] Self.DB:
        """Borrow the underlying backend (raw SQL / tx control escape hatch —
        valid when `DB` is concretely a `SqlDatabase`)."""
        return self._db

    # =========================================================================
    # register — INSERT a secret_manager row (NAMES only), return its id.
    # =========================================================================
    def register[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        org_id: Uuid,
        workspace_id: Optional[Uuid],
        var name_handle: String,
        provider_kind: Int32,
        var secret_ref: String,
        reachability: Int32,
        now_us: Int64,
    ) raises -> Uuid:
        """Register a secret catalog entry scoped to `org_id` (and optionally a
        `workspace_id`; `None` => org-shared):
        INSERT a `secret_manager` row holding ONLY the handle NAMES (no
        value/key/token/ciphertext) at status=pending / version=1, and
        return the new row's id. The row id is a fresh UUIDv7 (time-sortable).
        The onboarding read grant later flips status pending -> ready.

        There is NO value parameter — by construction a secret VALUE cannot reach
        this store; the value is written to the CUSTOMER store separately."""
        var manager_id = generate_uuidv7()
        var ts = Timestamptz(now_us)
        var row = SecretManager(
            manager_id,
            org_id,
            workspace_id,
            name_handle^,
            provider_kind,
            secret_ref^,
            reachability,
            SECRET_STATUS_PENDING,
            ts,  # created_at
            ts,  # updated_at
            Int64(1),  # version
        )
        _ = self._db.put[RT](
            reactor,
            String(SecretManager.TABLE),
            SecretManager.column_names(),
            row.to_row(),
        )
        return manager_id

    # =========================================================================
    # get — read the secret_manager row by its id.
    # =========================================================================
    def get[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], manager_id: Uuid
    ) raises -> Optional[SecretManager]:
        """Read the `secret_manager` row by its id. Returns `None` (not a raise)
        on an unknown id."""
        var row = self._db.get_by_key[RT](
            reactor,
            String(SecretManager.TABLE),
            SecretManager.column_names(),
            String("id"),
            DbValue.uuid(manager_id.bytes()),
        )
        if row:
            return Optional[SecretManager](
                SecretManager.from_row(
                    row.value(), col_index_for[SecretManager](row.value())
                )
            )
        return Optional[SecretManager]()

    # =========================================================================
    # list_for_org — the org-scoped catalog.
    # =========================================================================
    def list_for_org[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], org_id: Uuid
    ) raises -> List[SecretManager]:
        """Every `secret_manager` row scoped to `org_id` (org-shared rows +
        workspace-scoped rows under that org), ordered by id (time-sortable
        UUIDv7). NAMES only; no value ever leaves
        this surface."""
        var order = List[Order]()
        order.append(Order.asc(String("id")))
        var rows = self._db.query_rows[RT](
            reactor,
            String(SecretManager.TABLE),
            SecretManager.column_names(),
            Filter.just(Pred.eq(String("org_id"), DbValue.uuid(org_id.bytes()))),
            order^,
            Optional[UInt32](),
        )
        return _secret_manager_decode_rows(rows)

    # =========================================================================
    # set_status — CAS the onboarding-grant readiness (pending -> ready|failed).
    # =========================================================================
    def set_status[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        manager_id: Uuid,
        status: Int32,
        now_us: Int64,
    ) raises -> Bool:
        """Set the `status` on the row identified by `manager_id`, bumping
        `version` + `updated_at`. Returns True iff exactly one row was updated.
        Unconditional on the prior status (a re-grant may flip failed -> ready
        after the customer fixes the store binding) — the version bump keeps it
        CAS-clean for concurrent polls. Idempotent at the value level."""
        # SET status = $1, updated_at = $2, version = version + 1 WHERE id = $3 —
        # updated_at binds the caller's deterministic now_us (a bound term, not NOW()); version bumps
        # via a raw_expr term kept in SET order.
        var updates = List[DbColVal]()
        updates.append(DbColVal.bind(String("status"), DbValue.int4(status)))
        updates.append(
            DbColVal.bind(
                String("updated_at"), DbValue.timestamptz(Timestamptz(now_us))
            )
        )
        updates.append(
            DbColVal.raw_expr(String("version"), String("version + 1"))
        )
        var affected = self._db.conditional_update[RT](
            reactor,
            String(SecretManager.TABLE),
            Filter.just(Pred.eq(String("id"), DbValue.uuid(manager_id.bytes()))),
            updates^,
            False,
            Optional[String](),
            List[String](),
        )
        return affected > 0

    # =========================================================================
    # update_secret_ref — CAS the OPAQUE handle (keyed on id+version).
    # =========================================================================
    def update_secret_ref[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        manager_id: Uuid,
        var secret_ref: String,
        expected_version: Int64,
        now_us: Int64,
    ) raises -> Bool:
        """Update the OPAQUE `secret_ref` handle (e.g. the customer re-keys the
        store entry) under optimistic-concurrency: the UPDATE applies ONLY if the
        row's current `version` equals `expected_version`, bumping `version` +
        `updated_at`. Returns True iff exactly one row matched (the CAS won);
        False on a version mismatch (a concurrent writer won — the caller re-reads
        and retries). NEVER a value — `secret_ref` is the handle, not the secret.
        This is a names-only version-CAS."""
        # SET secret_ref = $1, updated_at = $2, version = version + 1
        # WHERE id = $3 AND version = $4.
        var updates = List[DbColVal]()
        updates.append(
            DbColVal.bind(String("secret_ref"), DbValue.text(secret_ref^))
        )
        updates.append(
            DbColVal.bind(
                String("updated_at"), DbValue.timestamptz(Timestamptz(now_us))
            )
        )
        updates.append(
            DbColVal.raw_expr(String("version"), String("version + 1"))
        )
        var guard = List[Pred]()
        guard.append(Pred.eq(String("id"), DbValue.uuid(manager_id.bytes())))
        guard.append(Pred.eq(String("version"), DbValue.int8(expected_version)))
        var affected = self._db.conditional_update[RT](
            reactor,
            String(SecretManager.TABLE),
            Filter.all_of(guard^),
            updates^,
            False,
            Optional[String](),
            List[String](),
        )
        return affected > 0


# =============================================================================
# Module helper — the SQL projection builder (no pointer flow).
# =============================================================================
def _secret_manager_decode_rows(rows: DbRows) raises -> List[SecretManager]:
    """Decode an entire `DbRows` result set into `List[SecretManager]` — the
    `Store.decode_rows` cascade lifted to a free helper so a `[DB: Database]`
    store can decode without a `Store`."""
    var out = List[SecretManager]()
    for i in range(rows.__len__()):
        ref r = rows.row(i)
        out.append(SecretManager.from_row(r, col_index_for[SecretManager](r)))
    return out^
