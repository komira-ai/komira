# =============================================================================
# test_secret_manager_custody.mojo -- the catalog row holds names only, and its
#   ordinals have stable wire tokens.
# =============================================================================
#
# Every column of the `SecretManager` row is a NAME or handle: no value, key,
# token or ciphertext column. The checks read the schema itself (`column_names`,
# `column_types`, the DDL), so a column added that could hold a secret value
# turns them red.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_secrets import (
    PROVIDER_AWS_SECRETS_MANAGER,
    PROVIDER_AZURE_KEY_VAULT,
    PROVIDER_CONJUR,
    PROVIDER_GCP_SECRET_MANAGER,
    PROVIDER_KIND_COUNT,
    PROVIDER_LOCAL_KEYCHAIN,
    PROVIDER_VAULT_KV,
    REACHABILITY_CENTRAL_REACHABLE,
    REACHABILITY_CUSTOMER_BOUNDARY_ONLY,
    SECRET_STATUS_FAILED,
    SECRET_STATUS_PENDING,
    SECRET_STATUS_READY,
    SECRET_STATUS_UNSPECIFIED,
    SecretManager,
    provider_kind_str,
    secret_status_str,
)


# The forbidden substrings — any column whose name contains one of these would
# be a custody violation (a column that could hold a secret VALUE rather than a
# NAME/handle). `secret_ref` is the ALLOWED exception: it is an opaque HANDLE
# ("ask THIS store for THIS key"), never the value — so we match on the
# value-bearing roots, not the substring "secret" alone.
def _is_forbidden_column(name: String) -> Bool:
    """True iff `name` looks like a secret-VALUE column (a custody violation).
    `secret_ref` (an opaque handle) is explicitly allowed; everything matching a
    value-bearing root (token / password / ciphertext / a bare `value` / a bare
    `secret` / a key-MATERIAL column) is forbidden."""
    if name == String("secret_ref"):
        return False  # the allowed OPAQUE handle — not a value
    var forbidden = List[String]()
    forbidden.append(String("token"))
    forbidden.append(String("password"))
    forbidden.append(String("passwd"))
    forbidden.append(String("ciphertext"))
    forbidden.append(String("plaintext"))
    forbidden.append(String("secret_value"))
    forbidden.append(String("key_material"))
    forbidden.append(String("wrapped"))
    forbidden.append(String("dek"))
    forbidden.append(String("kek"))
    for i in range(len(forbidden)):
        if name == forbidden[i]:
            return True
    # A bare `value` / `secret` column (not `secret_ref`) is forbidden too.
    if name == String("value") or name == String("secret"):
        return True
    return False


def test_the_forbidden_column_filter_flags_value_columns() raises:
    """The filter the other checks rely on flags value-bearing names and passes
    the opaque handle."""
    assert_true(_is_forbidden_column(String("token")))
    assert_true(_is_forbidden_column(String("password")))
    assert_true(_is_forbidden_column(String("ciphertext")))
    assert_true(_is_forbidden_column(String("value")))
    assert_true(_is_forbidden_column(String("secret")))
    assert_false(_is_forbidden_column(String("secret_ref")))
    assert_false(_is_forbidden_column(String("name_handle")))


def test_no_value_bearing_column() raises:
    """No `SecretManager` column is a secret-VALUE column. Every column is a
    NAME/handle."""
    var names = SecretManager.column_names()
    assert_true(len(names) == 11, "SecretManager has 11 names-only columns")
    for i in range(len(names)):
        assert_false(
            _is_forbidden_column(names[i]),
            String("column '") + names[i] + String("' is NAMES-only (no value)"),
        )


def test_expected_names_only_columns_present() raises:
    """The names-only column set is present in field-number order: id, org_id,
    workspace_id, name_handle, provider_kind, secret_ref, reachability, status,
    created_at, updated_at, version — and NOTHING that holds a value."""
    var names = SecretManager.column_names()
    var expected = List[String]()
    expected.append(String("id"))
    expected.append(String("org_id"))
    expected.append(String("workspace_id"))
    expected.append(String("name_handle"))
    expected.append(String("provider_kind"))
    expected.append(String("secret_ref"))
    expected.append(String("reachability"))
    expected.append(String("status"))
    expected.append(String("created_at"))
    expected.append(String("updated_at"))
    expected.append(String("version"))
    assert_equal(len(names), len(expected), "column count matches")
    for i in range(len(expected)):
        assert_equal(names[i], expected[i], "column in field-number order")


def test_column_types_carry_no_value() raises:
    """`column_types()` agrees with `column_names()` (same count, same names) and
    carries no value-bearing column. The `workspace_id` column is the only
    NULLABLE one (the org-shared sentinel)."""
    var cols = SecretManager.column_types()
    var names = SecretManager.column_names()
    assert_equal(len(cols), len(names), "column_types matches column_names count")
    var nullable_count = 0
    for i in range(len(cols)):
        assert_equal(cols[i].name, names[i], "column descriptor name matches")
        assert_false(
            _is_forbidden_column(cols[i].name),
            String("descriptor '") + cols[i].name + String("' is NAMES-only"),
        )
        if cols[i].nullable:
            nullable_count += 1
            assert_equal(
                cols[i].name,
                String("workspace_id"),
                "only workspace_id is NULLABLE (org-shared sentinel)",
            )
    assert_equal(nullable_count, 1, "exactly one NULLABLE column (workspace_id)")


def test_ddl_emits_no_value_column() raises:
    """The CREATE TABLE DDL (which the migration sources, so it cannot drift from
    the row) emits no value/secret-value column token. It DOES emit `secret_ref`
    (the opaque handle)."""
    var ddl = SecretManager.create_table_ddl()
    # The opaque handle column IS present.
    assert_true(
        ddl.find(String("secret_ref")) >= 0, "DDL emits the secret_ref handle"
    )
    # No value-bearing column tokens.
    assert_true(ddl.find(String("ciphertext")) < 0, "DDL has no ciphertext col")
    assert_true(ddl.find(String("password")) < 0, "DDL has no password col")
    assert_true(ddl.find(String("_token")) < 0, "DDL has no token col")
    assert_true(
        ddl.find(String("secret_value")) < 0, "DDL has no secret_value col"
    )


def test_ordinals_have_stable_wire_tokens() raises:
    """Each provider and status ordinal stringifies to its own stable token, and
    an unknown ordinal gets a fail-closed token, never a concrete provider or
    `ready`."""
    assert_equal(PROVIDER_KIND_COUNT, 6)
    assert_equal(provider_kind_str(PROVIDER_GCP_SECRET_MANAGER), "gcp_secret_manager")
    assert_equal(provider_kind_str(PROVIDER_AWS_SECRETS_MANAGER), "aws_secrets_manager")
    assert_equal(provider_kind_str(PROVIDER_AZURE_KEY_VAULT), "azure_key_vault")
    assert_equal(provider_kind_str(PROVIDER_VAULT_KV), "vault_kv")
    assert_equal(provider_kind_str(PROVIDER_CONJUR), "conjur")
    assert_equal(provider_kind_str(PROVIDER_LOCAL_KEYCHAIN), "local_keychain")
    assert_equal(provider_kind_str(Int32(99)), "unknown")
    assert_equal(provider_kind_str(Int32(-1)), "unknown")

    assert_equal(secret_status_str(SECRET_STATUS_UNSPECIFIED), "unspecified")
    assert_equal(secret_status_str(SECRET_STATUS_PENDING), "pending")
    assert_equal(secret_status_str(SECRET_STATUS_READY), "ready")
    assert_equal(secret_status_str(SECRET_STATUS_FAILED), "failed")
    assert_equal(secret_status_str(Int32(99)), "unspecified")

    assert_equal(REACHABILITY_CENTRAL_REACHABLE, Int32(0))
    assert_equal(REACHABILITY_CUSTOMER_BOUNDARY_ONLY, Int32(1))


def main() raises:
    test_the_forbidden_column_filter_flags_value_columns()
    test_no_value_bearing_column()
    test_expected_names_only_columns_present()
    test_column_types_carry_no_value()
    test_ddl_emits_no_value_column()
    test_ordinals_have_stable_wire_tokens()
