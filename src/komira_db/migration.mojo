# =============================================================================
# komira_db/migration.mojo — the ordered, transactional MigrationRunner.
# =============================================================================
#
# The migration-chain machinery. Schema evolution is first-class: a `.proto` change
# becomes one numbered DDL step appended to an ORDERED migration chain, and a
# `MigrationRunner[DB: Database]` applies the pending steps in a transaction,
# idempotently, recording each in a ledger table (default `_komira_migrations`,
# caller-overridable — see `MigrationRunner.__init__`).
#
# The two halves:
#   * `Migration` — version int + up-SQL. The up-SQL is BACKEND-RENDERED by the
#     caller (it may use `DB.placeholder` / `DB.now_expr` and per-backend type
#     names) — the runner does not interpret the SQL, only orders + records it.
#     A migration that is genuinely portable (no dialect tokens) is the common
#     case; a migration that needs a per-backend form is built per backend at
#     chain-construction time (the same shape `create_table_ddl()` already takes,
#     where sqlite + pg DDL differ).
#   * `MigrationRunner[DB]` — owns a borrowed `Database` for the run, ensures the
#     ledger table exists, reads the set of step NAMES the ledger already holds,
#     applies every step whose name is absent from it (in version order) inside
#     ONE `begin`/`commit` (rollback on any error), and exposes
#     `current_version()`. Re-running an applied chain applies nothing. The
#     ledger keys on the step's NAME and not on its version ordinal: chain
#     assembly RENUMBERS fused sub-chains, so an ordinal is not an identity —
#     see the `run` docstring for the full argument.
#
# The `create_table_ddl()` drift-guard: `check_drift` compares the live
# table's column set against a DbStorable's `column_names()` — catching a
# proto↔deployed-DB skew (a missing column the migration chain forgot, or a
# stale column the proto dropped).
#
# Encapsulation: the surface is `Migration` / String / List / typed
# scalars only — ZERO UnsafePointer crosses any boundary. `Migration` carries a
# single heap field per String, relocation-safe in a growing `List[Migration]`.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.db_value import DbValue
from komira_db.db_row import DbRow, DbRows
from komira_db.db_storable import DbStorable


# =============================================================================
# Migration — one numbered DDL step in the chain.
# =============================================================================
struct Migration(Movable, Copyable):
    """One ordered migration step: a monotone `version` + the `up_sql` DDL that
    advances the schema to that version. The up-SQL is already rendered for the
    target backend (the caller builds the chain per backend when a step's DDL is
    dialect-specific — e.g. `TIMESTAMPTZ` vs `INTEGER` µs). Single heap field
    (`up_sql: String`) — relocation-safe in a growing `List[Migration]`.

    ★ `name` IS THE LEDGER IDENTITY. It is what `MigrationRunner` records and
    what it matches against on the next run to decide whether this step has
    already been applied. `version` orders the chain; it does NOT identify the
    step (see the `run` docstring for why). Two
    consequences, both load-bearing:

      * every step MUST carry a name, and two steps of one chain may share one
        only if their `up_sql` is IDENTICAL (the same step contributed twice by
        an assembly that folds overlapping sub-chains — applied once). One name
        over two DIFFERENT statements is refused outright: one of them could
        never reach an already-migrated database. A step with no name at all
        falls back to an identity derived from its `up_sql`, which is stable
        under a renumber but changes if the SQL is edited — name your steps.
      * a step's name is PERMANENT. Renaming one presents it to every already-
        migrated database as a step that was never applied, and it is re-run.
        For the idempotent `CREATE ... IF NOT EXISTS` majority that is a no-op;
        for a bare sqlite `ALTER TABLE ... ADD COLUMN` it is a hard error that
        rolls back the whole migrate. Rename a step only when you mean "run this
        again, everywhere"."""

    var version: Int
    var up_sql: String
    var name: String

    def __init__(out self, version: Int, var up_sql: String):
        self.version = version
        self.up_sql = up_sql^
        self.name = String("")

    def __init__(out self, version: Int, var up_sql: String, var name: String):
        self.version = version
        self.up_sql = up_sql^
        self.name = name^


# =============================================================================
# MigrationRunner[DB] — apply a chain idempotently inside a transaction.
# =============================================================================
struct MigrationRunner[DB: SqlDatabase](Movable):
    """The ordered, transactional, idempotent migration runner.
    Bound on `SqlDatabase`: `run()` renders the ledger INSERT via
    `DB.placeholder(i)` + `DB.now_expr()`.

    Construction adopts a moved-in `DB` backend (single owner for the migration
    run); `into_db()` hands it back when the chain has been applied so a caller
    can keep using the same connection. Methods:

      * `run(migrations)` — ensure the ledger exists, order by version, apply
        every step whose NAME is absent from the ledger inside ONE transaction,
        recording each. Returns how many steps were applied (0 on a
        fully-migrated DB — the idempotence property).
      * `applied_identities()` — the set of step names the ledger records.
      * `current_version()` — `MAX(version)` from the ledger (0 if empty). Under
        the name-keyed ledger this is the APPLY-SEQUENCE high-water mark (how
        many steps this database has ever applied), not a chain ordinal. On a
        fresh database run through one chain the two coincide, which is why
        every existing caller keeps its meaning.
      * `check_drift[T]()` — the drift-guard: assert the live table for `T` has
        exactly `T.column_names()` (the proto↔DB skew check)."""

    var _db: Self.DB
    var _ledger: String

    # The DEFAULT ledger table name: a library-namespaced form rather than the
    # common `schema_migrations`, so it never collides with an app table.
    comptime LEDGER: StaticString = "_komira_migrations"

    def __init__(out self, var db: Self.DB):
        """Adopt `db`, recording applied steps in the default `LEDGER` table."""
        self._db = db^
        self._ledger = String(Self.LEDGER)

    def __init__(out self, var db: Self.DB, var ledger: String):
        """Adopt `db`, recording applied steps in the table named `ledger`.

        ★ THE LEDGER NAME IS PERSISTENT SCHEMA, NOT A LABEL. The runner decides
        what is pending by reading this table. A database whose applied steps
        are recorded under a different table name must pass THAT name: pointed
        at a fresh name, the runner sees an empty ledger, creates it, and
        re-applies every step — non-idempotent DDL then fails and rolls back,
        and idempotent DDL leaves a duplicate history. The name is spliced into
        SQL as an identifier, so it must be a trusted constant, never input."""
        self._db = db^
        self._ledger = ledger^

    def ledger(self) -> String:
        """The ledger table name this runner reads and writes."""
        return self._ledger

    def db(ref self) -> ref [self._db] Self.DB:
        """Borrow the underlying backend (for hand-written SQL between runs)."""
        return self._db

    def into_db(deinit self) -> Self.DB:
        """Reclaim the backend after the chain has been applied."""
        return self._db^

    # ---- the ledger ----

    def ensure_ledger[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        """Create the ledger table (`ledger()`) if it does not exist. The
        shape is backend-portable (id / version / name / applied_at). The
        `applied_at` column is typed `TIMESTAMPTZ` so the BACKEND's `now_expr()`
        renders correctly on BOTH backends WITHOUT a per-backend ledger DDL:
          * pg — `applied_at TIMESTAMPTZ` accepts `NOW()` (timestamptz) directly.
          * sqlite — `TIMESTAMPTZ` carries NUMERIC affinity, so it stores the
            `now_expr()` µs INTEGER (the sqlite TIMESTAMPTZ convention) fine.
        This is the one place the ledger touches the per-backend `now_expr()`
        divergence (see `now_expr` in database.mojo); a single `TIMESTAMPTZ` column
        absorbs both renderings (a genuine logical/physical split, not hidden).
        """
        var ddl = (
            String("CREATE TABLE IF NOT EXISTS ")
            + self._ledger
            + String(
                " (\n"
                "    id INTEGER PRIMARY KEY,\n"
                "    version INTEGER NOT NULL UNIQUE,\n"
                "    name TEXT NOT NULL,\n"
                "    applied_at TIMESTAMPTZ NOT NULL\n"
                ")"
            )
        )
        _ = self._db.execute[RT](reactor, ddl, List[DbValue]())

    def current_version[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises -> Int:
        """The highest applied migration version, or 0 if none applied yet.
        Ensures the ledger exists first (so a never-run DB reports 0, not an
        error)."""
        self.ensure_ledger[RT](reactor)
        # COALESCE so an empty ledger yields 0 rather than a NULL row.
        var rows = self._db.query[RT](
            reactor,
            String("SELECT COALESCE(MAX(version), 0) AS v FROM ")
            + self._ledger,
            List[DbValue](),
        )
        if rows.__len__() == 0:
            return 0
        return Int(rows.row(0).get_int8(0))

    def applied_identities[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises -> List[String]:
        """The set of migration IDENTITIES this database has already applied, read
        from the ledger's `name` column. This is the pending-set oracle: a chain
        step whose identity appears here has run, whatever ordinal it now carries.

        Reads via `SELECT *` + a column-name lookup rather than `SELECT name`
        because `SELECT *` is the projection shape `live_columns` already proves
        on every backend this runner is driven over (sqlite, pg, and the pgstore
        SQL subset); a bare column projection would be a new shape to qualify.
        Rows with a NULL/empty name are skipped — they carry no identity, so they
        can neither mark a step applied nor be trusted to."""
        self.ensure_ledger[RT](reactor)
        var rows = self._db.query[RT](
            reactor,
            String("SELECT * FROM ") + self._ledger,
            List[DbValue](),
        )
        var name_col = -1
        for i in range(rows.column_count()):
            if rows.column_name(i) == String("name"):
                name_col = i
        var out = List[String]()
        if name_col < 0:
            return out^
        for i in range(rows.__len__()):
            if rows.row(i).is_null(name_col):
                continue
            var nm = rows.row(i).get_text(name_col)
            if nm.byte_length() > 0:
                out.append(nm^)
        return out^

    # ---- apply the chain ----

    def run[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], migrations: List[Migration]
    ) raises -> Int:
        """Apply every migration whose IDENTITY (its `name`) is absent from the
        ledger, in ascending version order, inside ONE transaction. Records each
        applied step in the ledger. Idempotent: re-running a fully-applied chain
        applies nothing and returns 0. Returns the number of steps applied.

        Raises on a duplicate version in the chain, or on one name carrying two
        DIFFERENT statements (both are chain-authoring bugs, caught before the
        transaction opens); and raises after rollback on any DDL failure — the
        run is atomic, so a partial chain never lands.

        =====================================================================
        ★ WHY THE PENDING SET IS KEYED ON THE NAME AND NOT ON THE VERSION.
        =====================================================================
        A runner that selects `version > MAX(version)` — a monotone watermark
        over the step's ORDINAL — is only correct if a step's ordinal never
        moves, and ordinals do move: an application that FUSES several
        independently-authored chains RENUMBERS them onto ONE global contiguous
        1..N sequence, and binaries that share one ledger hand-offset their
        chains. So inserting a slice into, or REMOVING one from, the middle
        of a chain shifts every later slice's ordinal, and any step that lands at
        or below an already-migrated database's watermark is SILENTLY SKIPPED —
        present in the code, absent from the data, with every other test green
        because a FRESH database (watermark 0) applies everything regardless.

        The alternatives considered, and why this one:

          * A GOLDEN (version, name) LEDGER committed to the repo. This turns a
            renumber into a diff instead of silence — but it is a DETECTOR, not a
            fix: the live database still mis-converges, and the person who has to
            regenerate the golden file is the same person who just renumbered, so
            it degrades into a rubber stamp. It also makes a SAFE mid-chain
            insert (safe, under this fix) produce a mandatory file edit.
          * KEEPING the ordinal and forbidding mid-chain edits by convention.
            That leaves slices guarded by prose comments saying "this must stay
            last", and it cannot survive an edit whose whole operation is
            REMOVING fused slices.
          * NAME-KEYING (this). It deletes the ordinal from the identity, so no
            edit anywhere in a chain can strand any other step. The runner
            becomes correct rather than carefully-driven, which is the only form
            that scales past one guarded slice.

        =====================================================================
        ★ HOW AN EXISTING, ALREADY-MIGRATED LEDGER IS INTERPRETED. (No data
          migration is required, and none is performed.)
        =====================================================================
        The ledger records `name` for every row, so a live ledger contains
        exactly the set of identities that database has applied. Reading that
        column is therefore a complete account of the work done, and a ledger
        written by an ordinal-keyed runner reads the same way:

          * a step whose name is in the ledger is NOT re-applied (identical to
            an ordinal-keyed runner for a chain that has not been edited);
          * a step whose name is absent IS applied, wherever it now sits. This is
            the only behavioural difference from an ordinal-keyed runner, which
            would skip such a step whenever its ordinal fell under the
            watermark.

        The `version` COLUMN of a written row is an APPLY-SEQUENCE number
        (`MAX(version)` + 1, 2, ...) rather than the chain ordinal. Three
        reasons this is right:

          * the ledger's `id INTEGER PRIMARY KEY` / `version INTEGER UNIQUE`
            constraints make the chain ordinal UNUSABLE after an edit — an
            inserted mid-chain step carries an ordinal a previous row already
            holds, so writing it would abort the whole boot on a UNIQUE
            violation. An apply-sequence is collision-free by construction.
          * on an ordinal-keyed ledger the two coincide: chains are contiguous 1..N and
            were applied in order, so `MAX(version)` == the number of applied
            steps, and the sequence simply continues from there.
          * on a fresh database run through one chain they still coincide, which
            is why `current_version()` keeps its meaning for every caller.

        The one hazard this creates is stated on `Migration.name`: a step's name
        is its identity FOREVER, so renaming one re-runs it everywhere. That
        failure is loud (the run is transactional and rolls back), unlike a
        silent skip."""
        self.ensure_ledger[RT](reactor)
        var current = self.current_version[RT](reactor)
        var applied_names = self.applied_identities[RT](reactor)

        # Sort the chain by version (selection sort over the small chain — the
        # chain is bounded by the number of `.proto` revisions). Reject dup
        # versions while we're here (a dup is a chain-authoring bug).
        var ordered = migrations.copy()
        var nm = len(ordered)
        for i in range(nm):
            var min_j = i
            for j in range(i + 1, nm):
                if ordered[j].version < ordered[min_j].version:
                    min_j = j
            if min_j != i:
                var tmp = ordered[i].copy()
                ordered[i] = ordered[min_j].copy()
                ordered[min_j] = tmp^
        for i in range(1, nm):
            if ordered[i].version == ordered[i - 1].version:
                raise Error(
                    String("MigrationRunner: duplicate version ")
                    + String(ordered[i].version)
                    + String(" in chain")
                )

        # The IDENTITY of each step, in apply order.
        var ids = List[String]()
        for i in range(nm):
            ids.append(_migration_identity(ordered[i]))

        # ── Chain-internal duplicate identities. ────────────────────────────
        # Two cases, and they are NOT the same thing:
        #
        #   * SAME identity, SAME `up_sql` — one step CONTRIBUTED TWICE by an
        #     assembly that folds overlapping sub-chains. This is real and
        #     routine: one module returns a fused chain that already carries
        #     another module's slice while that module also returns its own
        #     chain, so a registry collecting both hands us both copies. The
        #     step is applied ONCE and recorded ONCE. Nothing is lost — the
        #     copies are byte-identical DDL.
        #
        #   * SAME identity, DIFFERENT `up_sql` — genuinely AMBIGUOUS, and fatal.
        #     The ledger cannot record two different statements under one key, so
        #     whichever copy lost would be marked applied by the other and would
        #     never run on any already-migrated database. That is exactly the
        #     silent-skip failure this runner exists to prevent, so it is raised
        #     rather than resolved by position. (A real condition: composing a
        #     chain whose copy of a slice degrades composite indexes to
        #     single-column form (for a narrower backend) with a second,
        #     undegraded copy of the same slice produces precisely it.)
        var dup_of = List[Int]()  # -1 = first occurrence; else index of the first
        for i in range(nm):
            var first = -1
            for j in range(i):
                if ids[j] == ids[i]:
                    first = j
                    break
            if first >= 0 and ordered[first].up_sql != ordered[i].up_sql:
                raise Error(
                    String("MigrationRunner: CONFLICTING migration identity '")
                    + ids[i]
                    + String("' in chain — two steps (versions ")
                    + String(ordered[first].version)
                    + String(" and ")
                    + String(ordered[i].version)
                    + String(
                        ") share one name but carry DIFFERENT up_sql. The ledger"
                        " keys on the name, so one of them would be considered"
                        " applied by the other and would never reach an"
                        " already-migrated database. Give them distinct names, or"
                        " stop folding both copies into one chain."
                    )
                )
            dup_of.append(first)

        # Collect the pending steps: first occurrences whose IDENTITY the ledger
        # has never recorded. Position is irrelevant — that is the whole point.
        var pending = List[Int]()
        for i in range(nm):
            if dup_of[i] < 0 and not _contains(applied_names, ids[i]):
                pending.append(i)
        if len(pending) == 0:
            return 0  # everything already applied — the idempotence fast path

        # Apply atomically: BEGIN, each up-SQL + a ledger insert, COMMIT. The
        # ledger row's id/version is a fresh APPLY-SEQUENCE number continuing
        # from the ledger's high-water mark, NOT the step's chain ordinal — an
        # edited chain re-presents ordinals the ledger already holds, and the
        # `UNIQUE`/`PRIMARY KEY` columns would abort the boot on the collision.
        self._db.begin[RT](reactor)
        var applied = 0
        var seq = current
        try:
            for k in range(len(pending)):
                ref m = ordered[pending[k]]
                _ = self._db.execute[RT](reactor, m.up_sql, List[DbValue]())
                # Record the step. applied_at = backend NOW() in the µs
                # convention; id = version = the next APPLY-SEQUENCE number.
                seq += 1
                var ins = (
                    String("INSERT INTO ")
                    + self._ledger
                    + String(" (id, version, name, applied_at) VALUES (")
                    + Self.DB.placeholder(0)
                    + String(", ")
                    + Self.DB.placeholder(1)
                    + String(", ")
                    + Self.DB.placeholder(2)
                    + String(", ")
                    + Self.DB.now_expr()
                    + String(")")
                )
                # id + version bind as INT4 to match the ledger's `INTEGER`
                # columns: pg's BINARY bind is width-strict (an int4 column
                # rejects an 8-byte bigint binary). Sequence numbers are small
                # monotone ints, so INT4 is always sufficient. sqlite is
                # dynamically typed and accepts either width.
                #
                # `name` is bound from the step's IDENTITY, not from `m.name`
                # directly: the two are the same for every named step (all of
                # them, in every production chain), and for an unnamed one the
                # identity is derived from the SQL so that the row is still a
                # key the next run can match on. Writing `m.name` here would
                # record an empty string and the step would re-run forever.
                var p = List[DbValue]()
                p.append(DbValue.int4(Int32(seq)))
                p.append(DbValue.int4(Int32(seq)))
                p.append(DbValue.text(ids[pending[k]]))
                _ = self._db.execute[RT](reactor, ins, p)
                applied += 1
            self._db.commit[RT](reactor)
        except e:
            self._db.rollback[RT](reactor)
            raise Error(String("MigrationRunner.run failed: ") + String(e))
        return applied

    # ---- the drift-guard ----

    def live_columns[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String
    ) raises -> List[String]:
        """The live column-name set for `table`, ordered. Uses a `SELECT * LIMIT
        0` and reads the result column names — a backend-portable way to read
        the deployed table shape without an information_schema/pragma dialect
        split (both backends return the column list on a describe of an empty
        result)."""
        var rows = self._db.query[RT](
            reactor,
            String("SELECT * FROM ") + table + String(" LIMIT 0"),
            List[DbValue](),
        )
        var out = List[String]()
        for i in range(rows.column_count()):
            out.append(rows.column_name(i))
        return out^

    def check_drift[RT: Runtime, T: DbStorable](
        mut self, mut reactor: Reactor[RT.Sink]
    ) raises:
        """Assert the live table for `T` has EXACTLY `T.column_names()` (same
        set, ignoring order — the column identity is the field number, not the
        physical position). Raises with the first divergence found. This is the
        proto↔deployed-DB skew guard: a column the chain forgot to add,
        or a stale column the proto removed but a tombstone retained
        unexpectedly."""
        var want = T.column_names()
        var have = self.live_columns[RT](reactor, String(T.TABLE))
        # Every wanted column must be present.
        for i in range(len(want)):
            if not _contains(have, want[i]):
                raise Error(
                    String("schema drift: column '")
                    + want[i]
                    + String("' in DbStorable but MISSING from live table '")
                    + String(T.TABLE)
                    + String("'")
                )
        # No EXTRA live column beyond the wanted set (a removed-but-not-
        # tombstoned column, or a manual ALTER the proto does not know about).
        for i in range(len(have)):
            if not _contains(want, have[i]):
                raise Error(
                    String("schema drift: live table '")
                    + String(T.TABLE)
                    + String("' has column '")
                    + have[i]
                    + String("' not present in the DbStorable schema")
                )


# =============================================================================
# Local helpers.
# =============================================================================
def _migration_identity(m: Migration) -> String:
    """The LEDGER IDENTITY of a step — the key `MigrationRunner` records and
    matches on. It is the step's `name`, which is stable across the renumbering
    that chain assembly performs, unlike the `version` ordinal.

    A step constructed WITHOUT a name (the two-argument `Migration` ctor) has no
    author-supplied identity, so one is derived from its `up_sql`. That is still
    renumber-stable — which is the property that matters — but it is NOT edit-
    stable: touching the SQL of an unnamed step presents it as a new step. Name
    your steps."""

    if m.name.byte_length() > 0:
        return m.name.copy()
    return String("sql:") + m.up_sql


def _contains(haystack: List[String], needle: String) -> Bool:
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False
