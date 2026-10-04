# =============================================================================
# komira_db/db_schema.mojo — the DbSchema (DDL-only) trait.
# =============================================================================
#
# `DbSchema` is the LIGHTER sibling of `DbStorable` (db_storable.mojo): the
# contract the protoc-gen-mojo-db `schema_only` emit mode generates conformance
# for. It is the "DDL-only" half — a message marked `(komira.db.schema_only)`
# in the `.proto` (e.g. the auxiliary control-plane tables `job_failures` /
# `idempotency_keys`) gets ONLY the per-backend `CREATE TABLE` DDL, never the
# value cascades (`to_row` / `from_row` / `insert_sql`).
#
# These tables do NOT fit the DbStorable identity-column model:
#   * job_failures   — a server-assigned SERIAL surrogate PK that the consumer
#                      never reads back; an append-only forensic ledger.
#   * idempotency_keys — the PK is the CLIENT key, not a proto identity column.
# So they are schema-only: the emitter generates the DDL so the bootstrap does
# not hand-write it, but it generates no row marshalling.
#
# The member set the generator emits (e.g. for `JobFailure` /
# `IdempotencyKey` `struct ...(DbSchema)` blocks):

#
#   comptime TABLE: StaticString
#   @staticmethod column_names()          -> List[String]
#   @staticmethod create_table_ddl_pg()   -> String
#   @staticmethod create_table_ddl_sqlite() -> String
#
# (No `PK` member, no `column_types`, no value cascade — that is exactly what
# distinguishes DbSchema from DbStorable.)
#
# Encapsulation: String / List[String] only; no UnsafePointer crosses
# any boundary, no wildcard origin, no unsafe_from_address.
# =============================================================================


# =============================================================================
# DbSchema — the generated DDL-only schema contract.
# =============================================================================
trait DbSchema(Copyable, Movable):
    """A DDL-only database table type. The protoc-gen-mojo-db `schema_only` emit
    mode generates a conforming struct from a `.proto` message marked
    `(komira.db.schema_only)`; it supplies the table name, the column-name set,
    and the two per-backend `CREATE TABLE IF NOT EXISTS` DDL bodies — but NO
    row marshalling (no `to_row` / `from_row` / `insert_sql`). The lighter
    sibling of `DbStorable` for auxiliary control-plane tables that do not fit
    the identity-column round-trip model."""

    comptime TABLE: StaticString

    @staticmethod
    def column_names() -> List[String]:
        """Column names in field-number (declaration) order — the canonical set
        the schema drift-guard asserts against the live table."""
        ...

    @staticmethod
    def create_table_ddl_pg() -> String:
        """The postgres-dialect `CREATE TABLE IF NOT EXISTS ...` (native UUID /
        TIMESTAMPTZ / TEXT[] / SERIAL types, NOW() defaults)."""
        ...

    @staticmethod
    def create_table_ddl_sqlite() -> String:
        """The sqlite-dialect `CREATE TABLE IF NOT EXISTS ...` (BLOB / INTEGER /
        TEXT carriers, INTEGER PRIMARY KEY AUTOINCREMENT surrogate)."""
        ...
