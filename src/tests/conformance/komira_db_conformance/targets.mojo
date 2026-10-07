# =============================================================================
# komira_db_conformance/targets.mojo -- what an implementation supplies to be
#   checked: a factory of fresh databases, and the schema the checks assume.
# =============================================================================
#
# The suites are written once, generic over these two traits. An implementation
# under test supplies a small struct conforming to one or both:
#
#   NeutralTarget  `fresh()` hands back a `Database` holding the three tables
#                  below, empty. A SQL backend creates them with its own DDL;
#                  a document backend has nothing to create.
#   SqlTarget      `fresh()` hands back a `SqlDatabase` with no conformance
#                  tables (the SQL checks issue their own DDL, by dialect),
#                  and `error_text(kind)` names the text the backend's own
#                  documentation gives for each error kind. The trait says
#                  only that these calls raise; the message is the backend's.
#
# Every check calls `fresh()` itself, so no check sees another's rows.
#
# THE NEUTRAL SCHEMA (column, logical type, NULL allowed):
#
#   conf_items  id TEXT primary key, owner TEXT, phase TEXT, version INT8,
#               note TEXT NULL, created_at INT8,
#               updated_at TIMESTAMPTZ NULL (the now column: `now_expr()` writes
#               it, and komira_db/migration.mojo types such a column
#               TIMESTAMPTZ so pg's NOW() and sqlite's µs INTEGER both fit)
#   conf_types  id TEXT primary key, then one NULL-able column per logical
#               type: t_text TEXT, t_int4 INT4, t_int8 INT8, t_float8 FLOAT8,
#               t_float4 FLOAT4, t_bool BOOL, t_bytes BYTES, t_uuid UUID,
#               t_ts TIMESTAMPTZ, t_jsonb JSONB, t_text_array TEXT[]
#   conf_pairs  a TEXT, b TEXT, v INT8, with (a, b) unique
#
# A SQL backend declares them with the column types protoc-gen-mojo-db gives
# each logical type for its dialect (tools/build/proto-codegen,
# emit_dbstorable.rs). The only query shape the Firestore index guard checks
# that needs a declared composite index is `owner == ? ORDER BY created_at` on
# conf_items (ascending). The claim query (phase == ? ORDER BY created_at)
# bypasses the guard; on real Firestore it needs an index too.
# =============================================================================

from komira_db import Database, SqlDatabase

comptime ITEMS: StaticString = "conf_items"
comptime TYPES: StaticString = "conf_types"
comptime PAIRS: StaticString = "conf_pairs"

# The tables the SQL checks create (a target on a shared server drops them in
# `fresh()`; an in-memory target starts without them).
comptime SQL_TABLE: StaticString = "conf_sql_t"
comptime SQL_TABLE_NN: StaticString = "conf_sql_nn"

# `SqlTarget.error_text` kinds.
comptime ERR_SYNTAX: Int = 0
comptime ERR_UNIQUE: Int = 1
comptime ERR_NOT_NULL: Int = 2
comptime ERR_NO_TABLE: Int = 3


trait NeutralTarget(Movable):
    """A source of fresh `Database`s holding the neutral schema, empty."""

    comptime DB: Database

    def name(self) -> String:
        ...

    def fresh(mut self) raises -> Self.DB:
        ...


trait SqlTarget(Movable):
    """A source of fresh `SqlDatabase`s, and the backend's own error texts."""

    comptime DB: SqlDatabase

    def name(self) -> String:
        ...

    def fresh(mut self) raises -> Self.DB:
        ...

    def error_text(self, kind: Int) -> String:
        """A fragment the backend's error message carries for `kind` (one of
        the ERR_* kinds), as its own documentation spells it."""
        ...
