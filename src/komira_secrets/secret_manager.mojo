# =============================================================================
# komira_secrets/secret_manager.mojo -- the persisted `secret_manager` row, the
#   names-only catalog of the secrets an organisation holds handles for.
# =============================================================================
#
# A `SecretManager` is the catalog row for one secret: the handle callers use,
# the org/workspace scope, WHICH customer store the value lives in, and the
# OPAQUE `secret_ref` the store adapter resolves at point of use. The VALUE
# lives in the customer's own secret store; this row holds ONLY names.
#
# It is a hand-written `komira_db.DbStorable` (not generated), so a schema tweak
# needs no code generation. The column set, field-number order and DDL here are
# the authoritative schema; the migration sources `create_table_ddl()` so the
# two cannot drift.
#
# Columns (field-number order):
#   1  id             UUID         PK, the manager id (UUIDv7)
#   2  org_id         UUID         REQ -- owning org (the tenant anchor)
#   3  workspace_id   UUID         NULLABLE -- NULL => org-shared; set => ws-scoped
#   4  name_handle    TEXT         the OPAQUE catalog handle callers use
#   5  provider_kind  INT4         WHICH customer store (an ordinal)
#   6  secret_ref     TEXT         the OPAQUE handle the adapter resolves --
#                                  NEVER the value
#   7  reachability   INT4         central_reachable vs customer_boundary_only
#   8  status         INT4         unspecified/pending/ready/failed
#   9  created_at     TIMESTAMPTZ  microseconds since epoch
#   10 updated_at     TIMESTAMPTZ  microseconds since epoch
#   11 version        INT8         optimistic-concurrency version
#
# CUSTODY INVARIANT (tested): EVERY column is a NAME or handle. There is no
# value, key, token or ciphertext column, so a row is as safe to hold in a
# shared database as any other catalog row.
#
# The row is flat: only `Uuid` / `String` / scalar fields. The nullable
# `workspace_id` is an `Optional[Uuid]` (an inline 16-byte value, no heap).
# No pointer type appears in any signature.
# =============================================================================

from komira_db import (
    DbStorable,
    SqlDatabase,
    DbValue,
    DbRow,
    DbColumn,
    Uuid,
    Timestamptz,
    LOGICAL_UUID,
    LOGICAL_TEXT,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_TIMESTAMPTZ,
)


# =============================================================================
# §1 — provider_kind ordinals (field #5) — WHICH customer store the value lives
# in. Persisted as a compact INT4 (rename-safe on-disk identity).
# =============================================================================
comptime PROVIDER_GCP_SECRET_MANAGER: Int32 = 0
"""GCP Secret Manager (the generatable gRPC client — the easy first conformer)."""
comptime PROVIDER_AWS_SECRETS_MANAGER: Int32 = 1
"""AWS Secrets Manager (JSON-over-HTTP + SigV4)."""
comptime PROVIDER_AZURE_KEY_VAULT: Int32 = 2
"""Azure Key Vault (REST/JSON + AAD bearer)."""
comptime PROVIDER_VAULT_KV: Int32 = 3
"""HashiCorp Vault (REST/JSON + K8s-auth login)."""
comptime PROVIDER_CONJUR: Int32 = 4
"""CyberArk Conjur (REST/JSON)."""
comptime PROVIDER_LOCAL_KEYCHAIN: Int32 = 5
"""The laptop-first OS keychain (Keychain / DPAPI / libsecret) — local-dev path."""

comptime PROVIDER_KIND_COUNT: Int = 6
"""The number of defined provider kinds (for completeness asserts / iteration)."""


def provider_kind_str(provider_kind: Int32) -> StaticString:
    """The stable wire token for a provider-kind ordinal. An unknown ordinal ->
    `unknown` (never a misleading concrete provider name)."""
    if provider_kind == PROVIDER_GCP_SECRET_MANAGER:
        return "gcp_secret_manager"
    if provider_kind == PROVIDER_AWS_SECRETS_MANAGER:
        return "aws_secrets_manager"
    if provider_kind == PROVIDER_AZURE_KEY_VAULT:
        return "azure_key_vault"
    if provider_kind == PROVIDER_VAULT_KV:
        return "vault_kv"
    if provider_kind == PROVIDER_CONJUR:
        return "conjur"
    if provider_kind == PROVIDER_LOCAL_KEYCHAIN:
        return "local_keychain"
    return "unknown"


# =============================================================================
# §2 — reachability ordinals (field #7) — whether the value's store is reachable
# from central at all. Drives the trust classification surfaced
# to callers as `SecretMeta.reachability`.
# =============================================================================
comptime REACHABILITY_CENTRAL_REACHABLE: Int32 = 0
"""The store is reachable from central (cloud SM — the `do-not-read` case)."""
comptime REACHABILITY_CUSTOMER_BOUNDARY_ONLY: Int32 = 1
"""The store is reachable ONLY inside the customer boundary (on-prem / air-gapped
Vault — the `can-not-read` case)."""


# =============================================================================
# §3 — status ordinals (field #8) — onboarding-grant readiness.
# =============================================================================
comptime SECRET_STATUS_UNSPECIFIED: Int32 = 0
comptime SECRET_STATUS_PENDING: Int32 = 1
"""The one-time IAM/policy read grant is not yet in place."""
comptime SECRET_STATUS_READY: Int32 = 2
"""The grant is in place; `secret_ref` is resolvable at point-of-use."""
comptime SECRET_STATUS_FAILED: Int32 = 3
"""The store entry is unresolvable (deleted/unreachable) — fail fast and loud,
never a silent stale value."""


def secret_status_str(status: Int32) -> StaticString:
    """The stable wire token for a status ordinal. An unknown ordinal ->
    `unspecified` (fail-closed — never a misleading `ready`)."""
    if status == SECRET_STATUS_PENDING:
        return "pending"
    if status == SECRET_STATUS_READY:
        return "ready"
    if status == SECRET_STATUS_FAILED:
        return "failed"
    return "unspecified"


# =============================================================================
# §4 — SecretManager — the names-only DbStorable row.
# =============================================================================
struct SecretManager(DbStorable):
    """The persisted `secret_manager` row (hand-authored DbStorable). Org-scoped
    with a NULLABLE workspace_id (NULL =>
    org-shared). Holds ONLY the handle NAMES (no value, no key, no
    token, no ciphertext). The VALUE lives behind `secret_ref` in the customer's
    REQUIRED secret store, which Komira does not operate."""

    comptime TABLE: StaticString = "secret_manager"
    comptime PK: StaticString = "id"

    # field #1 `id` -> column `id` (UUID) — the manager id.
    var id: Uuid
    # field #2 `org_id` -> column `org_id` (UUID) — REQUIRED, the tenant anchor.
    var org_id: Uuid
    # field #3 `workspace_id` -> column `workspace_id` (UUID, NULLABLE) — NULL =>
    # org-shared, set => workspace-scoped.
    var workspace_id: Optional[Uuid]
    # field #4 `name_handle` -> column `name_handle` (TEXT) — the OPAQUE catalog
    # handle callers use. A NAME, not a value.
    var name_handle: String
    # field #5 `provider_kind` -> column `provider_kind` (INT4) — WHICH store.
    var provider_kind: Int32
    # field #6 `secret_ref` -> column `secret_ref` (TEXT) — the OPAQUE handle the
    # adapter resolves at point-of-use. NEVER the value.
    var secret_ref: String
    # field #7 `reachability` -> column `reachability` (INT4).
    var reachability: Int32
    # field #8 `status` -> column `status` (INT4) — onboarding-grant readiness.
    var status: Int32
    # field #9 `created_at` -> column `created_at` (TIMESTAMPTZ).
    var created_at: Timestamptz
    # field #10 `updated_at` -> column `updated_at` (TIMESTAMPTZ).
    var updated_at: Timestamptz
    # field #11 `version` -> column `version` (INT8) — optimistic-CAS version.
    var version: Int64

    def __init__(
        out self,
        id: Uuid,
        org_id: Uuid,
        workspace_id: Optional[Uuid],
        var name_handle: String,
        provider_kind: Int32,
        var secret_ref: String,
        reachability: Int32,
        status: Int32,
        created_at: Timestamptz,
        updated_at: Timestamptz,
        version: Int64,
    ):
        self.id = id
        self.org_id = org_id
        self.workspace_id = workspace_id
        self.name_handle = name_handle^
        self.provider_kind = provider_kind
        self.secret_ref = secret_ref^
        self.reachability = reachability
        self.status = status
        self.created_at = created_at
        self.updated_at = updated_at
        self.version = version

    @always_inline
    def is_org_shared(self) -> Bool:
        """True iff this manager is org-scoped (workspace_id NULL) rather than
        scoped to a single workspace."""
        return not self.workspace_id.__bool__()

    @always_inline
    def is_ready(self) -> Bool:
        """True iff the onboarding read grant is in place and `secret_ref` is
        resolvable at point-of-use."""
        return self.status == SECRET_STATUS_READY

    @staticmethod
    def column_names() -> List[String]:
        var out = List[String]()
        out.append(String("id"))
        out.append(String("org_id"))
        out.append(String("workspace_id"))
        out.append(String("name_handle"))
        out.append(String("provider_kind"))
        out.append(String("secret_ref"))
        out.append(String("reachability"))
        out.append(String("status"))
        out.append(String("created_at"))
        out.append(String("updated_at"))
        out.append(String("version"))
        return out^

    @staticmethod
    def column_types() -> List[DbColumn]:
        # CUSTODY (tested): every column is a NAME/handle — no value,
        # key, token, or ciphertext column. The NAMES-ONLY CUSTODY test asserts
        # this list contains no secret-bearing column.
        var out = List[DbColumn]()
        out.append(DbColumn("id", 1, LOGICAL_UUID, False))
        out.append(DbColumn("org_id", 2, LOGICAL_UUID, False))
        # workspace_id is NULLABLE.
        out.append(DbColumn("workspace_id", 3, LOGICAL_UUID, True))
        out.append(DbColumn("name_handle", 4, LOGICAL_TEXT, False))
        out.append(DbColumn("provider_kind", 5, LOGICAL_INT4, False))
        out.append(DbColumn("secret_ref", 6, LOGICAL_TEXT, False))
        out.append(DbColumn("reachability", 7, LOGICAL_INT4, False))
        out.append(DbColumn("status", 8, LOGICAL_INT4, False))
        out.append(DbColumn("created_at", 9, LOGICAL_TIMESTAMPTZ, False))
        out.append(DbColumn("updated_at", 10, LOGICAL_TIMESTAMPTZ, False))
        out.append(DbColumn("version", 11, LOGICAL_INT8, False))
        return out^

    @staticmethod
    def create_table_ddl() -> String:
        # PORTABLE DDL (sqlite + pg), matching the `cloud_account` /
        # `comms_invite` discipline: UUID / TEXT / INT4 / TIMESTAMPTZ / BIGINT —
        # no per-backend dialect token, so ONE DDL string drives both backends.
        # workspace_id is the only NULLABLE column (the org-shared sentinel).
        return String(
            "CREATE TABLE IF NOT EXISTS secret_manager (\n"
            "    id UUID PRIMARY KEY,\n"
            "    org_id UUID NOT NULL,\n"
            "    workspace_id UUID,\n"
            "    name_handle TEXT NOT NULL,\n"
            "    provider_kind INTEGER NOT NULL DEFAULT 0,\n"
            "    secret_ref TEXT NOT NULL,\n"
            "    reachability INTEGER NOT NULL DEFAULT 0,\n"
            "    status INTEGER NOT NULL DEFAULT 0,\n"
            "    created_at TIMESTAMPTZ NOT NULL,\n"
            "    updated_at TIMESTAMPTZ NOT NULL,\n"
            "    version BIGINT NOT NULL DEFAULT 1\n"
            ")"
        )

    @staticmethod
    def insert_sql[D: SqlDatabase]() -> String:
        var sql = (
            String("INSERT INTO ")
            + Self.TABLE
            + String(
                " (id, org_id, workspace_id, name_handle, provider_kind,"
                " secret_ref, reachability, status, created_at, updated_at,"
                " version) VALUES ("
            )
        )
        for i in range(11):
            if i > 0:
                sql += String(", ")
            sql += D.placeholder(i)
        sql += String(")")
        return sql^

    def to_row(self) -> List[DbValue]:
        """The value cascade — one DbValue per field (field-number order). The
        NULLABLE `workspace_id` encodes as `DbValue.null()` when unset (the
        org-shared row), never a sentinel UUID."""
        var out = List[DbValue]()
        out.append(DbValue.uuid(self.id.bytes()))  # field 1
        out.append(DbValue.uuid(self.org_id.bytes()))  # field 2
        if self.workspace_id:  # field 3 (NULLABLE)
            out.append(DbValue.uuid(self.workspace_id.value().bytes()))
        else:
            out.append(DbValue.null(LOGICAL_UUID))
        out.append(DbValue.text(self.name_handle))  # field 4
        out.append(DbValue.int4(self.provider_kind))  # field 5
        out.append(DbValue.text(self.secret_ref))  # field 6
        out.append(DbValue.int4(self.reachability))  # field 7
        out.append(DbValue.int4(self.status))  # field 8
        out.append(DbValue.timestamptz(self.created_at))  # field 9
        out.append(DbValue.timestamptz(self.updated_at))  # field 10
        out.append(DbValue.int8(self.version))  # field 11
        return out^

    @staticmethod
    def from_row(row: DbRow, col_index: List[Int]) raises -> Self:
        """The inverse value cascade — decode each field by logical getter. The
        NULLABLE `workspace_id` decodes to `None` when the column is NULL (the
        org-shared row)."""
        var _f0 = Uuid(row.get_uuid(col_index[0]))
        var _f1 = Uuid(row.get_uuid(col_index[1]))
        var _f2: Optional[Uuid]
        if row.is_null(col_index[2]):
            _f2 = Optional[Uuid]()
        else:
            _f2 = Optional[Uuid](Uuid(row.get_uuid(col_index[2])))
        var _f3 = row.get_text(col_index[3])
        var _f4 = row.get_int4(col_index[4])
        var _f5 = row.get_text(col_index[5])
        var _f6 = row.get_int4(col_index[6])
        var _f7 = row.get_int4(col_index[7])
        var _f8 = row.get_timestamptz(col_index[8])
        var _f9 = row.get_timestamptz(col_index[9])
        var _f10 = row.get_int8(col_index[10])
        return SecretManager(
            _f0,
            _f1,
            _f2,
            _f3^,
            _f4,
            _f5^,
            _f6,
            _f7,
            _f8,
            _f9,
            _f10,
        )
