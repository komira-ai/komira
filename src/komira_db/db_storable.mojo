# =============================================================================
# komira_db/db_storable.mojo — the DbStorable trait + the Store[DB] surface.
# =============================================================================
#
# `DbStorable` is the contract the protoc-gen-mojo `db_storable`
# emit target generates conformance for. The generated struct
# supplies every body — the schema half (`column_names` / `column_types` /
# `create_table_ddl` / `insert_sql`) AND the value cascades (`to_row` /
# `from_row`); komira_db declares the contract + the substrate those bodies
# call (DbValue / DbColumn / DbRow / proto_json). The member set the
# generator emits:
#
#   comptime TABLE / PK
#   @staticmethod column_names()  -> List[String]
#   @staticmethod column_types()  -> List[DbColumn]
#   @staticmethod create_table_ddl() -> String
#   @staticmethod insert_sql[D: Database]() -> String
#   fn to_row(self) -> List[DbValue]
#   @staticmethod from_row(row: DbRow, col_index: List[Int]) raises -> Self
#
# `Store[DB: Database]` is the typed convenience surface:
# `insert(row)` runs the generated INSERT through the backend, `query[T]` /
# `query_opt[T]` decode rows via `T.from_row`. The methods that touch a live
# DB are thin wrappers over the driver; the pure-mapping helpers (insert SQL
# build, identity col_index) need no backend.

#
# Encapsulation: ZERO UnsafePointer crosses any boundary; the typed
# surface is values / List / Optional only.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import Database, SqlDatabase
from komira_db.db_value import DbValue, DbColumn
from komira_db.db_row import DbRow, DbRows


# =============================================================================
# DbStorable — the generated row-type contract.
# =============================================================================
trait DbStorable(Copyable, Movable, Deinitable):
    """A database-storable row type. The protoc-gen-mojo db_storable target
    generates a conforming struct from a `.proto` message; komira_db owns the
    contract + the value/column/row substrate the generated bodies call."""

    comptime TABLE: StaticString
    comptime PK: StaticString

    @staticmethod
    def column_names() -> List[String]:
        """Column names in field-number (declaration) order."""
        ...

    @staticmethod
    def column_types() -> List[DbColumn]:
        """Column descriptors (name + field_number + logical_type + nullable)
        in field-number order — the schema half."""
        ...

    @staticmethod
    def create_table_ddl() -> String:
        """`CREATE TABLE IF NOT EXISTS ...` (the drift-guard DDL).
        """
        ...

    @staticmethod
    def insert_sql[D: SqlDatabase]() -> String:
        """`INSERT INTO <TABLE> (cols...) VALUES (<placeholders>)` rendered with
        the backend `D`'s placeholder dialect (`D.placeholder(i)`). Bound on
        `SqlDatabase` because it reaches the SQL-dialect `D.placeholder(i)`."""
        ...

    def to_row(self) -> List[DbValue]:
        """The value cascade — one DbValue per field."""
        ...

    @staticmethod
    def from_row(row: DbRow, col_index: List[Int]) raises -> Self:
        """The inverse value cascade — decode each field by logical getter."""
        ...


# =============================================================================
# Identity column-index helper — the default SELECT-* decode mapping.
# =============================================================================
def identity_col_index(n: Int) -> List[Int]:
    """The trivial `col_index` mapping `[0, 1, ..., n-1]` — used when a row's
    columns arrive in the same order as the type's `column_names()` (the
    `SELECT <all cols>` case). When the query projects a different column order,
    the caller builds `col_index` by matching `column_names()` against the
    result's column-name map (DbRow.column_index)."""
    var out = List[Int]()
    for i in range(n):
        out.append(i)
    return out^


def col_index_for[T: DbStorable](row: DbRow) -> List[Int]:
    """Build the `col_index` mapping for decoding `row` into `T`: for each of
    `T`'s columns (in field-number order) find its position in `row` by name,
    falling back to identity position when the name is absent (e.g. a row built
    positionally from a `SELECT *`)."""
    var names = T.column_names()
    var out = List[Int]()
    for i in range(len(names)):
        var idx = row.column_index(names[i])
        out.append(idx if idx >= 0 else i)
    return out^


# =============================================================================
# Store[DB] — the typed convenience surface over a backend.
# =============================================================================
struct Store[DB: SqlDatabase](Movable):
    """The typed store: wraps a backend `DB` and runs generated CRUD through it.
    Bound on `SqlDatabase` (not the neutral `Database`) because `insert` /
    `insert_sql_for` / `delete_sql_for` render SQL via `DB.placeholder(i)` (and
    `T.insert_sql[DB]`, itself `SqlDatabase`-bound).
    It provides the pure-mapping helpers (insert SQL build, row decode)
    + thin DB-touching wrappers over the driver. Typed data-access services
    (e.g. `komira_job_store`) are written against this surface."""

    var _db: Self.DB

    def __init__(out self, var db: Self.DB):
        self._db = db^

    def db(ref self) -> ref [self._db] Self.DB:
        """Borrow the underlying backend (for hand-written SQL / tx control)."""
        return self._db

    def into_db(deinit self) -> Self.DB:
        """Recover the owned backend out of the store (single-owner move-out).
        Mirrors `JobStore.into_store()`: a transient `Store` built over a pooled
        connection (`PgPool.take`) hands the connection BACK to the pool via
        `store.into_db()` -> `pool.give_back(lease, db^)`. Encapsulation-clean:
        the connection moves by value (`^`), no pointer crosses the boundary."""
        return self._db^

    # ---- pure-mapping helpers (usable now, no live DB) ----

    @staticmethod
    def insert_sql_for[T: DbStorable]() -> String:
        """The generated INSERT for `T`, rendered with this backend's
        placeholder dialect."""
        return T.insert_sql[Self.DB]()

    @staticmethod
    def delete_sql_for[T: DbStorable]() -> String:
        """`DELETE FROM <T.TABLE> WHERE <T.PK> = <placeholder(0)>`, rendered with
        this backend's placeholder dialect. The single-row delete-by-primary-key
        statement — the inverse of `insert_sql_for`. Built from the `T.TABLE` /
        `T.PK` comptime members so it tracks the generated schema (no hand-typed
        table/column names that can drift from the `.proto`)."""
        return (
            String("DELETE FROM ")
            + T.TABLE
            + String(" WHERE ")
            + T.PK
            + String(" = ")
            + Self.DB.placeholder(0)
        )

    def decode_row[T: DbStorable](self, row: DbRow) raises -> T:
        """Decode one untyped `DbRow` into the typed `T` (matching columns by
        name; identity fallback for positional rows)."""
        return T.from_row(row, col_index_for[T](row))

    def decode_rows[T: DbStorable](self, rows: DbRows) raises -> List[T]:
        """Decode an entire result set into `List[T]`."""
        var out = List[T]()
        for i in range(rows.__len__()):
            ref r = rows.row(i)
            out.append(T.from_row(r, col_index_for[T](r)))
        return out^

    # ---- live-DB wrappers (thin; complete once a driver conforms) ----
    #
    # Every live-DB wrapper is METHOD-`[RT]`-parametric + threads the

    # caller's `mut reactor` into the underlying `Database` method. The runtime
    # choice lives at the top (a `BlockingRuntime` for single-shot / tests; a
    # `PerCoreAsyncRuntime` for concurrent production reads). The two type
    # parameters compose as `insert[RT, T]` (RT first, then the row type).

    def insert[RT: Runtime, T: DbStorable](
        mut self, mut reactor: Reactor[RT.Sink], row: T
    ) raises -> UInt64:
        """Run the generated INSERT for `row` through the backend."""
        return self._db.execute[RT](
            reactor, T.insert_sql[Self.DB](), row.to_row()
        )

    def delete[RT: Runtime, T: DbStorable](
        mut self, mut reactor: Reactor[RT.Sink], var pk: DbValue
    ) raises -> UInt64:
        """Delete the single `T` row whose primary key equals `pk`, via
        `DELETE FROM <T.TABLE> WHERE <T.PK> = <placeholder(0)>`; return
        rows_affected (0 if no such row, 1 on a successful delete). The PK value
        is supplied by the caller (which knows `T` and its key encoding — e.g.
        `DbValue.uuid(job.id.bytes())`), mirroring `insert`'s value-cascade shape
        while keeping the typed surface pointer-free."""
        var params = List[DbValue]()
        params.append(pk^)
        return self._db.execute[RT](
            reactor, Self.delete_sql_for[T](), params^
        )

    def query[RT: Runtime, T: DbStorable](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> List[T]:
        var rows = self._db.query[RT](reactor, sql, params)
        return self.decode_rows[T](rows)

    def query_opt[RT: Runtime, T: DbStorable](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> Optional[T]:
        var maybe = self._db.query_opt[RT](reactor, sql, params)
        if maybe:
            return Optional[T](self.decode_row[T](maybe.value()))
        return Optional[T]()

    def query_one[RT: Runtime, T: DbStorable](
        mut self,
        mut reactor: Reactor[RT.Sink],
        sql: String,
        params: List[DbValue],
    ) raises -> T:
        var row = self._db.query_one[RT](reactor, sql, params)
        return self.decode_row[T](row)

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self._db.begin[RT](reactor)

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self._db.commit[RT](reactor)

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self._db.rollback[RT](reactor)
