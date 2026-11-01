# =============================================================================
# komira_secrets/secret_migration.mojo -- the `secret_manager` schema chain.
# =============================================================================
#
# The catalog schema as a `komira_db.MigrationRunner` chain: the `secret_manager`
# table plus its `org_id` lookup index, ONE DDL statement per step. The table DDL
# comes from `SecretManager.create_table_ddl()`, so the migration and the row
# layout cannot drift.
#
# The chain is numbered from 1. A caller that folds it into a larger chain
# re-stamps the versions.
#
# One statement per migration: the runner executes each step's `up_sql` as a
# single `Database.execute`, and the SQLite driver compiles only the first
# statement of a multi-statement string.
#
# Idempotent and backend-portable: `CREATE ... IF NOT EXISTS` over portable SQL
# types (UUID / TIMESTAMPTZ / INTEGER / BIGINT / TEXT), so the same chain drives
# SQLite and Postgres. Re-running a migrated database applies nothing.
# =============================================================================

from komira_db import Migration, SqlDatabase

from komira_secrets.secret_manager import SecretManager


comptime SECRET_SCHEMA_V1: Int = 1  # secret_manager table
comptime SECRET_SCHEMA_V2: Int = 2  # secret_manager org_id lookup index


def secret_migrations[DB: SqlDatabase]() -> List[Migration]:
    """The `secret_manager` schema chain. Step 1
    creates the table (sourced from `SecretManager.create_table_ddl()` so it
    cannot drift from the row layout); step 2 adds the `org_id` lookup index
    backing `list_for_org`."""
    var out = List[Migration]()
    out.append(
        Migration(
            SECRET_SCHEMA_V1,
            SecretManager.create_table_ddl(),
            String("secret_manager table"),
        )
    )
    out.append(
        Migration(
            SECRET_SCHEMA_V2,
            String(
                "CREATE INDEX IF NOT EXISTS idx_secret_manager_org_id"
                " ON secret_manager (org_id)"
            ),
            String("secret_manager org_id index"),
        )
    )
    return out^
