# =============================================================================
# komira_crm/schema.mojo -- the store's tables, as every backend sees them.
# =============================================================================
#
# The store writes only through the backend-neutral `komira_db.Database`
# operations, so the same tables live on a SQL backend (created by the DDL
# below) and on a document backend (nothing to create; one collection per
# table). One deployment holds one dataset: no table has a column scoping a
# row to a customer.
#
# Row tables (primary key `id`; `body` is the message's proto3 JSON, and the
# scalar columns beside it override the body when a row is read):
#
#   crm_accounts           org_card_id, owner_iss, owner_sub, status,
#                          external_id, version, modseq, body
#   crm_pipelines          version, modseq, body
#   crm_deals              pipeline_id, stage_key, account_id, owner_iss,
#                          owner_sub, status, close_date, external_id,
#                          last_activity_at (Unix microseconds, 0 for none),
#                          version, modseq, body
#   crm_activities         subject_kind, subject_id, actor_iss, actor_sub,
#                          occurred_at (Unix microseconds), system, version,
#                          modseq, body
#   crm_custom_field_defs  entity_kind, field_key, version, modseq, body
#
# An owner or an actor is held only in its two columns, never in `body`, so
# an erasure that rewrites the columns leaves no copy behind.
#
# Key tables (the primary key is the unique tuple; a key row names the row
# that holds it):
#
#   crm_external_ids       (entity_kind, external_id) -> entity_id
#   crm_custom_field_keys  (entity_kind, field_key) -> def_id
#   crm_account_contacts   (account_id, card_id) -> role
#
# The change feed's counter:
#
#   crm_feed               one row, id "crm", modseq: the last number taken
#
# Every query the store runs is equalities only, or a range and an order on
# `modseq` alone, so a document backend needs no composite index.
# =============================================================================

comptime FEED: StaticString = "crm_feed"
comptime ACCOUNTS: StaticString = "crm_accounts"
comptime ACCOUNT_CONTACTS: StaticString = "crm_account_contacts"
comptime PIPELINES: StaticString = "crm_pipelines"
comptime DEALS: StaticString = "crm_deals"
comptime ACTIVITIES: StaticString = "crm_activities"
comptime EXTERNAL_IDS: StaticString = "crm_external_ids"
comptime FIELD_DEFS: StaticString = "crm_custom_field_defs"
comptime FIELD_KEYS: StaticString = "crm_custom_field_keys"

comptime FEED_ROW_ID: StaticString = "crm"


def strs(*items: StaticString) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(String(s))
    return out^


def feed_cols() -> List[String]:
    return strs("id", "modseq")


def account_cols() -> List[String]:
    return strs("id", "org_card_id", "owner_iss", "owner_sub", "status", "external_id", "version", "modseq", "body")


def account_contact_cols() -> List[String]:
    return strs("account_id", "card_id", "role")


def pipeline_cols() -> List[String]:
    return strs("id", "version", "modseq", "body")


def deal_cols() -> List[String]:
    return strs(
        "id",
        "pipeline_id",
        "stage_key",
        "account_id",
        "owner_iss",
        "owner_sub",
        "status",
        "close_date",
        "external_id",
        "last_activity_at",
        "version",
        "modseq",
        "body",
    )


def activity_cols() -> List[String]:
    return strs(
        "id",
        "subject_kind",
        "subject_id",
        "actor_iss",
        "actor_sub",
        "occurred_at",
        "system",
        "version",
        "modseq",
        "body",
    )


def external_id_cols() -> List[String]:
    return strs("entity_kind", "external_id", "entity_id")


def field_def_cols() -> List[String]:
    return strs("id", "entity_kind", "field_key", "version", "modseq", "body")


def field_key_cols() -> List[String]:
    return strs("entity_kind", "field_key", "def_id")


def sqlite_schema() -> List[String]:
    """The SQLite `CREATE TABLE` and `CREATE INDEX` statements."""
    var out = List[String]()
    out.append(String("CREATE TABLE IF NOT EXISTS crm_feed (id TEXT PRIMARY KEY, modseq INTEGER NOT NULL)"))
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_accounts (id TEXT PRIMARY KEY,"
            " org_card_id TEXT NOT NULL, owner_iss TEXT NOT NULL, owner_sub TEXT NOT NULL,"
            " status TEXT NOT NULL, external_id TEXT NOT NULL, version INTEGER NOT NULL,"
            " modseq INTEGER NOT NULL, body TEXT NOT NULL)"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_account_contacts (account_id TEXT NOT NULL,"
            " card_id TEXT NOT NULL, role TEXT NOT NULL, PRIMARY KEY (account_id, card_id))"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_pipelines (id TEXT PRIMARY KEY, version INTEGER NOT NULL,"
            " modseq INTEGER NOT NULL, body TEXT NOT NULL)"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_deals (id TEXT PRIMARY KEY, pipeline_id TEXT NOT NULL,"
            " stage_key TEXT NOT NULL, account_id TEXT NOT NULL, owner_iss TEXT NOT NULL,"
            " owner_sub TEXT NOT NULL, status TEXT NOT NULL, close_date TEXT NOT NULL,"
            " external_id TEXT NOT NULL, last_activity_at INTEGER NOT NULL,"
            " version INTEGER NOT NULL, modseq INTEGER NOT NULL, body TEXT NOT NULL)"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_activities (id TEXT PRIMARY KEY,"
            " subject_kind TEXT NOT NULL, subject_id TEXT NOT NULL, actor_iss TEXT NOT NULL,"
            " actor_sub TEXT NOT NULL, occurred_at INTEGER NOT NULL, system INTEGER NOT NULL,"
            " version INTEGER NOT NULL, modseq INTEGER NOT NULL, body TEXT NOT NULL)"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_external_ids (entity_kind TEXT NOT NULL,"
            " external_id TEXT NOT NULL, entity_id TEXT NOT NULL,"
            " PRIMARY KEY (entity_kind, external_id))"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_custom_field_defs (id TEXT PRIMARY KEY,"
            " entity_kind TEXT NOT NULL, field_key TEXT NOT NULL, version INTEGER NOT NULL,"
            " modseq INTEGER NOT NULL, body TEXT NOT NULL)"
        )
    )
    out.append(
        String(
            "CREATE TABLE IF NOT EXISTS crm_custom_field_keys (entity_kind TEXT NOT NULL,"
            " field_key TEXT NOT NULL, def_id TEXT NOT NULL, PRIMARY KEY (entity_kind, field_key))"
        )
    )
    var feed_tables = strs("crm_accounts", "crm_pipelines", "crm_deals", "crm_activities", "crm_custom_field_defs")
    for i in range(len(feed_tables)):
        out.append(
            String("CREATE INDEX IF NOT EXISTS ")
            + feed_tables[i]
            + String("_modseq ON ")
            + feed_tables[i]
            + String(" (modseq)")
        )
    out.append(String("CREATE INDEX IF NOT EXISTS crm_deals_pipeline ON crm_deals (pipeline_id, status)"))
    out.append(
        String("CREATE INDEX IF NOT EXISTS crm_activities_subject ON crm_activities (subject_kind, subject_id)")
    )
    return out^
