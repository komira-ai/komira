# =============================================================================
# iceberg_catalog/iceberg_commit.mojo — the append committer: one statement's
#   append to an Iceberg table, committed through the REST catalog.
# =============================================================================
#
# WHAT THIS IS. `commit_append` makes one commit of one statement's new data
# files to one table, following docs/design/iceberg_tables.md, "Commit
# semantics":
#
#   * Before the first attempt: the base is loaded at execution; the snapshot
#     id `S` (drawn again while the base already has it) and the commit id
#     `C` (summary `komira.commit-id`) are fixed for the statement and kept
#     across retries.
#   * One attempt: check the base (table uuid, format version 2, every
#     written column still present with a compatible type); have the writer
#     write the manifest list for parent `P` = `main` and sequence number
#     `n` = last-sequence-number + 1; POST requirements `assert-table-uuid`,
#     `assert-ref-snapshot-id(main, P)`, `assert-current-schema-id` and
#     updates `add-snapshot` (operation `append`), `set-snapshot-ref(main,
#     S)`. The snapshot's timestamp is the clock's time, or one more than the
#     parent's when that is later.
#   * Each answer:
#       - 200: success when `S` is `main` or an ancestor of it in the returned
#         metadata, or a snapshot in `main`'s ancestry carries
#         `komira.commit-id = C`; else `ICEBERG_COMMIT_STATE_UNKNOWN`.
#       - 409: reload; a tainted statement first looks for its commit. A
#         statement that read its target fails with `ICEBERG_COMMIT_CONFLICT`
#         (never rebases); otherwise it retries on the new base within the
#         budget, and fails with `ICEBERG_COMMIT_CONFLICT` once the budget is
#         spent.
#       - 5xx or a transport error: the outcome is unknown and the statement
#         is tainted. With an idempotency key, the byte-identical request is
#         resent once under the same key. Then the committer reloads and looks
#         up its commit: found is success; absent with `main` still at `P` is
#         a retry; absent with `main` moved is `ICEBERG_COMMIT_STATE_UNKNOWN`
#         (a rebase might append the rows twice).
#       - any other status: fails with its token. A tainted statement looks
#         up its commit first.
#   * A tainted statement whose 409 ends it fails with
#     `ICEBERG_COMMIT_STATE_UNKNOWN`, not `ICEBERG_COMMIT_CONFLICT`.
#
# Cleanup is the caller's, from the outcome: `delete_statement_files` says
# whether this statement's data files and manifest may be deleted (only after
# a definite failure: never after an unknown outcome unless a lookup proved
# the commit absent with `main` still at `P`), and `manifest_lists_to_delete`
# lists the manifest lists to delete: every one written after such a
# failure, and every one but the landed snapshot's after success.
#
# THE RETRY BUDGET comes from the table's properties, with Iceberg Java's
# defaults: `commit.retry.num-retries` 4, `commit.retry.min-wait-ms` 100,
# `commit.retry.max-wait-ms` 60000, `commit.retry.total-timeout-ms` 1800000.
# Every wait (before a retried commit, a resend, or a reloaded load) doubles
# from the minimum, capped at the maximum, and is taken on the injected
# `CommitClock`, so tests drive time without sleeping.
#
# THE SEAMS. `CommitClock` (time and waiting), `CommitIds` (snapshot ids and
# UUIDv7 text) and `AppendSnapshotWriter` (the per-attempt manifest list).
# `CommitClock` and `CommitIds` have production conformers here, with test
# ones (`ManualCommitClock`, `SequenceCommitIds`); the writer is the caller's.
#
# Not here yet: the staged-create and replace commits, `Retry-After`, and the
# write sink's `AppendSnapshotWriter` (docs/design/iceberg_tables.md, "Order of
# work").
# =============================================================================

from std.time import sleep

from clock import now_unix_ms
from uuid import generate_uuidv7

from .iceberg_rest_catalog_client import (
    CatalogCredentialProvider,
    COMMIT_APPLIED,
    COMMIT_CONFLICT,
    COMMIT_REFUSED,
    COMMIT_UNKNOWN,
    CommitResponse,
    IcebergRestCatalog,
    LoadedTable,
)
from .iceberg_rest_errors import (
    ICEBERG_CATALOG_RESPONSE_INVALID,
    ICEBERG_CATALOG_UNAVAILABLE,
    ICEBERG_COMMIT_CONFLICT,
    ICEBERG_COMMIT_STATE_UNKNOWN,
    ICEBERG_SCHEMA_INCOMPATIBLE,
    ICEBERG_TABLE_REPLACED,
    ICEBERG_WRITE_FORMAT_UNSUPPORTED,
    error_has_token,
)
from .iceberg_rest_transport import IcebergRestTransport
from .iceberg_table_changes import (
    NewSnapshot,
    TableRequirement,
    TableUpdate,
    commit_table_body,
)
from .iceberg_table_metadata import SchemaField, TableMetadata


comptime COMMIT_ID_SUMMARY_KEY: String = "komira.commit-id"
"""The snapshot summary member that carries the statement's commit id."""

comptime _MAX_ID_DRAWS: Int = 64


# =============================================================================
# §0 — the seams.
# =============================================================================


trait CommitClock(Movable):
    """The committer's time: the wall clock in milliseconds since the Unix
    epoch, and a wait."""

    def now_ms(mut self) -> Int64:
        ...

    def sleep_ms(mut self, ms: Int64):
        ...


struct SystemCommitClock(CommitClock, Movable):
    """The production clock: the system's wall clock, and a real sleep."""

    def __init__(out self):
        pass

    def now_ms(mut self) -> Int64:
        return now_unix_ms()

    def sleep_ms(mut self, ms: Int64):
        sleep(Float64(ms) / 1000.0)


struct ManualCommitClock(CommitClock, Movable):
    """A test clock: time moves only when the committer waits, by exactly the
    wait, and every wait is recorded."""

    var _now: Int64
    var waits: List[Int64]

    def __init__(out self, start_ms: Int64):
        self._now = start_ms
        self.waits = List[Int64]()

    def now_ms(mut self) -> Int64:
        return self._now

    def sleep_ms(mut self, ms: Int64):
        self.waits.append(ms)
        self._now += ms


trait CommitIds(Movable):
    """Where the committer's ids come from: positive 63-bit snapshot ids, and
    UUIDv7 text for the commit id and idempotency keys."""

    def snapshot_id(mut self) raises -> Int64:
        ...

    def uuid(mut self) raises -> String:
        ...


struct RandomCommitIds(CommitIds, Movable):
    """The production ids: a snapshot id is 62 random bits of a fresh UUIDv7
    (never 0); a uuid is a fresh UUIDv7. Raise when the system entropy source
    fails."""

    def __init__(out self):
        pass

    def snapshot_id(mut self) raises -> Int64:
        var bytes = generate_uuidv7().as_bytes()
        var v = UInt64(0)
        for i in range(8, 16):
            v = (v << UInt64(8)) | UInt64(bytes[i])
        v = v & UInt64(0x7FFFFFFFFFFFFFFF)
        if v == UInt64(0):
            v = UInt64(1)
        return Int64(v)

    def uuid(mut self) raises -> String:
        return generate_uuidv7().to_hyphenated()


struct SequenceCommitIds(CommitIds, Movable):
    """Test ids: the snapshot ids given, in order, then 1, 2, 3, ...; uuids
    `00000000-0000-7000-8000-00000000000<k>` for k = 1, 2, 3, ..."""

    var _snapshot_ids: List[Int64]
    var _next_snapshot: Int
    var _next_uuid: Int

    def __init__(out self, var snapshot_ids: List[Int64]):
        self._snapshot_ids = snapshot_ids^
        self._next_snapshot = 0
        self._next_uuid = 0

    def snapshot_id(mut self) raises -> Int64:
        var i = self._next_snapshot
        self._next_snapshot += 1
        if i < len(self._snapshot_ids):
            return self._snapshot_ids[i]
        return Int64(i - len(self._snapshot_ids) + 1)

    def uuid(mut self) raises -> String:
        self._next_uuid += 1
        var digits = String(self._next_uuid)
        var pad = String("")
        for _ in range(12 - digits.byte_length()):
            pad += "0"
        return String("00000000-0000-7000-8000-") + pad + digits


trait AppendSnapshotWriter(Movable):
    """Writes one attempt's manifest list: every manifest of `base`'s `main`
    snapshot, then the statement's new manifest with sequence number
    `sequence_number`, under the table's metadata path as
    `snap-<snapshot_id>-<attempt>-<uuid>.avro`. Returns its location."""

    def write_manifest_list(
        mut self,
        snapshot_id: Int64,
        attempt: Int,
        base: TableMetadata,
        sequence_number: Int64,
    ) raises -> String:
        ...


# =============================================================================
# §1 — what the committer is given and what it returns.
# =============================================================================


struct AppendCommit(Copyable, Movable):
    """One statement's append.

      * `namespace`, `table`: the target.
      * `table_uuid`: the target's uuid as the plan bound it; a base with
        another uuid is `ICEBERG_TABLE_REPLACED`.
      * `written_columns`: the columns the data files hold, by field id, name
        and type.
      * `pinned_snapshot_ids`: the snapshots of the target the statement read
        (its plan's pins on the same table uuid); non-empty means the
        statement read its target, so a 409 is a conflict, never a rebase.
      * `added_data_files`, `added_records`, `added_files_size`: the summary's
        added counts. Zero files sends no commit."""

    var namespace: String
    var table: String
    var table_uuid: String
    var written_columns: List[SchemaField]
    var pinned_snapshot_ids: List[Int64]
    var added_data_files: Int64
    var added_records: Int64
    var added_files_size: Int64

    def __init__(
        out self,
        var namespace: String,
        var table: String,
        var table_uuid: String,
        var written_columns: List[SchemaField],
        var pinned_snapshot_ids: List[Int64],
        added_data_files: Int64,
        added_records: Int64,
        added_files_size: Int64,
    ):
        self.namespace = namespace^
        self.table = table^
        self.table_uuid = table_uuid^
        self.written_columns = written_columns^
        self.pinned_snapshot_ids = pinned_snapshot_ids^
        self.added_data_files = added_data_files
        self.added_records = added_records
        self.added_files_size = added_files_size


struct AppendCommitOutcome(Copyable, Movable):
    """What `commit_append` did.

      * `committed`: the append is in the table (or had no files to add).
      * `message`: "" on success, else the error, starting with its token.
      * `snapshot_id`, `commit_id`: the statement's `S` and `C` (0 and "" when
        it failed before drawing them).
      * `landed_snapshot_id`: the snapshot that holds the commit (`S`, or the
        one carrying `C` after a catalog rewrote it); None unless committed
        with files.
      * `manifest_list`: the landed snapshot's manifest list ("" otherwise).
      * `delete_statement_files`: the statement's data files and manifest may
        be deleted (a definite failure).
      * `manifest_lists_to_delete`: the manifest lists the caller deletes.
      * `posts`: how many commit requests were sent."""

    var committed: Bool
    var message: String
    var snapshot_id: Int64
    var commit_id: String
    var landed_snapshot_id: Optional[Int64]
    var manifest_list: String
    var delete_statement_files: Bool
    var manifest_lists_to_delete: List[String]
    var posts: Int

    def __init__(out self):
        self.committed = False
        self.message = String("")
        self.snapshot_id = 0
        self.commit_id = String("")
        self.landed_snapshot_id = None
        self.manifest_list = String("")
        self.delete_statement_files = False
        self.manifest_lists_to_delete = List[String]()
        self.posts = 0


struct CommitRetryBudget(Copyable, Movable):
    """The retry budget (module header)."""

    var num_retries: Int
    var min_wait_ms: Int64
    var max_wait_ms: Int64
    var total_timeout_ms: Int64

    def __init__(
        out self,
        num_retries: Int,
        min_wait_ms: Int64,
        max_wait_ms: Int64,
        total_timeout_ms: Int64,
    ):
        self.num_retries = num_retries
        self.min_wait_ms = min_wait_ms
        self.max_wait_ms = max_wait_ms
        self.total_timeout_ms = total_timeout_ms

    @staticmethod
    def from_properties(md: TableMetadata) raises -> CommitRetryBudget:
        """The table's `commit.retry.*` properties, each defaulting to Iceberg
        Java's value. A value that is not a non-negative integer raises
        `ICEBERG_CATALOG_RESPONSE_INVALID` naming the property."""
        return CommitRetryBudget(
            Int(_int_property(md, String("commit.retry.num-retries"), 4)),
            _int_property(md, String("commit.retry.min-wait-ms"), 100),
            _int_property(md, String("commit.retry.max-wait-ms"), 60000),
            _int_property(md, String("commit.retry.total-timeout-ms"), 1800000),
        )


def _int_property(md: TableMetadata, name: String, default: Int64) raises -> Int64:
    var v = md.property(name)
    if not v:
        return default
    var text = v.value()
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 18:
        raise Error(_bad_property(name, text))
    var n = Int64(0)
    for i in range(len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            raise Error(_bad_property(name, text))
        n = n * 10 + Int64(b[i] - 0x30)
    return n


def _bad_property(name: String, text: String) -> String:
    return (
        ICEBERG_CATALOG_RESPONSE_INVALID
        + String(": table property '")
        + name
        + String("' is not a non-negative integer: '")
        + text
        + String("'")
    )


# =============================================================================
# §2 — the run state.
# =============================================================================


struct _Waits(Movable):
    """The budget being spent: how many waits were taken, and since when."""

    var budget: CommitRetryBudget
    var start_ms: Int64
    var used: Int

    def __init__(out self, var budget: CommitRetryBudget, start_ms: Int64):
        self.budget = budget^
        self.start_ms = start_ms
        self.used = 0

    def take[K: CommitClock](mut self, mut clock: K) -> Bool:
        """Wait the next backoff and return True, or return False (without
        waiting) when the retries or the total time are spent."""
        if self.used >= self.budget.num_retries:
            return False
        var wait = self.budget.min_wait_ms
        for _ in range(self.used):
            wait = wait * 2
            if wait >= self.budget.max_wait_ms:
                break
        if wait > self.budget.max_wait_ms:
            wait = self.budget.max_wait_ms
        var elapsed = clock.now_ms() - self.start_ms
        if elapsed + wait > self.budget.total_timeout_ms:
            return False
        clock.sleep_ms(wait)
        self.used += 1
        return True


def _load[
    T: IcebergRestTransport, P: CatalogCredentialProvider, K: CommitClock
](
    mut catalog: IcebergRestCatalog[T, P],
    mut clock: K,
    mut waits: _Waits,
    namespace: String,
    table: String,
) raises -> LoadedTable:
    """Load the table, retrying `ICEBERG_CATALOG_UNAVAILABLE` within the
    budget. Raises the last error when it is another error or the budget is
    spent."""
    while True:
        try:
            return catalog.load_table_metadata(namespace, table)
        except e:
            var msg = String(e)
            if not error_has_token(msg, ICEBERG_CATALOG_UNAVAILABLE):
                raise Error(msg)
            if not waits.take(clock):
                raise Error(msg)


def _find_commit(
    md: TableMetadata, snapshot_id: Int64, commit_id: String
) -> Optional[Int64]:
    """The snapshot that holds the commit: `snapshot_id` when it is `main`
    or an ancestor, else the snapshot in `main`'s ancestry whose summary
    carries `commit_id`; None when neither."""
    if md.in_main_ancestry(snapshot_id):
        return Optional[Int64](snapshot_id)
    return md.find_in_main_ancestry(String(COMMIT_ID_SUMMARY_KEY), commit_id)


def _main_text(id: Optional[Int64]) -> String:
    if id:
        return String(id.value())
    return String("none")


# =============================================================================
# §3 — the base check.
# =============================================================================


def check_append_base(commit: AppendCommit, md: TableMetadata) -> String:
    """"" when `md` can take the append, else the error: the uuid differs
    (`ICEBERG_TABLE_REPLACED`), the format version is not 2
    (`ICEBERG_WRITE_FORMAT_UNSUPPORTED`), or a written column was dropped
    from the current schema or changed to a type its data cannot be read as
    (`ICEBERG_SCHEMA_INCOMPATIBLE`). A new column, a rename and a promotion
    (int to long, float to double, a wider decimal of the same scale) do
    not stop the write."""
    var key = commit.namespace + String(".") + commit.table
    if md.table_uuid != commit.table_uuid:
        return (
            ICEBERG_TABLE_REPLACED
            + String(": table '")
            + key
            + String("' has uuid ")
            + md.table_uuid
            + String(", the statement was planned on ")
            + commit.table_uuid
        )
    if md.format_version != 2:
        return (
            ICEBERG_WRITE_FORMAT_UNSUPPORTED
            + String(": table '")
            + key
            + String("' is format version ")
            + String(md.format_version)
            + String("; komira writes version 2 only")
        )
    var si = md.schema_index(md.current_schema_id)
    if si < 0:
        return (
            ICEBERG_CATALOG_RESPONSE_INVALID
            + String(": table '")
            + key
            + String("' has no schema with its current-schema-id ")
            + String(md.current_schema_id)
        )
    ref schema = md.schemas[si]
    for i in range(len(commit.written_columns)):
        ref col = commit.written_columns[i]
        var j = schema.field_by_id(col.id)
        if j < 0:
            return (
                ICEBERG_SCHEMA_INCOMPATIBLE
                + String(": table '")
                + key
                + String("': column '")
                + col.name
                + String("' (field id ")
                + String(col.id)
                + String(") was dropped")
            )
        ref now = schema.fields[j]
        if not type_reads_as(col.type_name, now.type_name):
            return (
                ICEBERG_SCHEMA_INCOMPATIBLE
                + String(": table '")
                + key
                + String("': column '")
                + col.name
                + String("' (field id ")
                + String(col.id)
                + String(") is now ")
                + now.type_name
                + String(", the statement writes ")
                + col.type_name
            )
    return String("")


def type_reads_as(written: String, current: String) -> Bool:
    """True iff data written as `written` reads as `current`: the same type,
    or one of Iceberg's promotions (int to long, float to double,
    decimal(P,S) to decimal(P2,S) with P2 >= P)."""
    if written == current:
        return True
    if written == String("int") and current == String("long"):
        return True
    if written == String("float") and current == String("double"):
        return True
    var w = _decimal_parts(written)
    var c = _decimal_parts(current)
    if len(w) == 2 and len(c) == 2:
        return w[1] == c[1] and c[0] >= w[0]
    return False


def _decimal_parts(t: String) -> List[Int]:
    """[precision, scale] of `decimal(P,S)` (spaces allowed after the comma),
    or [] for any other type."""
    var out = List[Int]()
    if not t.startswith(String("decimal(")) or not t.endswith(String(")")):
        return out^
    var inner = String(t[byte=8 : t.byte_length() - 1])
    var comma = inner.find(String(","))
    if comma < 0:
        return out^
    try:
        var p = Int(String(inner[byte=0:comma]).strip())
        var s = Int(String(inner[byte=comma + 1 : inner.byte_length()]).strip())
        out.append(p)
        out.append(s)
    except:
        return List[Int]()
    return out^


# =============================================================================
# §4 — the attempt's request.
# =============================================================================


def append_snapshot(
    commit: AppendCommit,
    base: TableMetadata,
    snapshot_id: Int64,
    commit_id: String,
    manifest_list: String,
    now_ms: Int64,
) -> NewSnapshot:
    """The snapshot of one attempt on `base`: parent `main`, sequence number
    last + 1, the timestamp `now_ms` or one more than the parent's when that
    is later, the current schema, and an `append` summary. The totals are the
    parent's plus the added counts; a total the parent's summary lacks is
    omitted (a table with no parent starts them at the added counts and at 0
    deletes)."""
    var parent = base.main_snapshot_id
    var ts = now_ms
    var names = List[String]()
    var values = List[String]()
    names.append(String("added-data-files"))
    values.append(String(commit.added_data_files))
    names.append(String("added-records"))
    values.append(String(commit.added_records))
    names.append(String("added-files-size"))
    values.append(String(commit.added_files_size))
    var pi = -1
    if parent:
        pi = base.snapshot_index(parent.value())
        if pi >= 0 and base.snapshots[pi].timestamp_ms >= ts:
            ts = base.snapshots[pi].timestamp_ms + 1
    _total(base, pi, names, values, String("total-data-files"), commit.added_data_files)
    _total(base, pi, names, values, String("total-records"), commit.added_records)
    _total(base, pi, names, values, String("total-files-size"), commit.added_files_size)
    _total(base, pi, names, values, String("total-delete-files"), 0)
    _total(base, pi, names, values, String("total-position-deletes"), 0)
    _total(base, pi, names, values, String("total-equality-deletes"), 0)
    names.append(String(COMMIT_ID_SUMMARY_KEY))
    values.append(String(commit_id))
    return NewSnapshot(
        snapshot_id,
        parent,
        base.last_sequence_number + 1,
        ts,
        base.current_schema_id,
        String(manifest_list),
        String("append"),
        names^,
        values^,
    )


def _total(
    base: TableMetadata,
    parent_index: Int,
    mut names: List[String],
    mut values: List[String],
    name: String,
    added: Int64,
):
    """Append `name` = parent's `name` + `added`; with no parent snapshot,
    `added`; omitted when the parent's summary lacks it or it is not an
    integer."""
    if parent_index < 0:
        if base.main_snapshot_id:
            return  # main names a snapshot the table no longer lists
        names.append(name)
        values.append(String(added))
        return
    var prev = base.snapshots[parent_index].summary(name)
    if not prev:
        return
    try:
        var n = Int64(Int(prev.value()))
        names.append(name)
        values.append(String(n + added))
    except:
        return


def append_commit_body(
    base: TableMetadata, snapshot: NewSnapshot
) raises -> String:
    """The commit body of one append attempt on `base`."""
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_table_uuid(String(base.table_uuid)))
    reqs.append(
        TableRequirement.assert_ref_snapshot_id(
            String("main"), base.main_snapshot_id
        )
    )
    reqs.append(TableRequirement.assert_current_schema_id(base.current_schema_id))
    var ups = List[TableUpdate]()
    var sid = snapshot.snapshot_id
    ups.append(TableUpdate.add_snapshot(snapshot.copy()))
    ups.append(TableUpdate.set_branch(String("main"), sid))
    return commit_table_body(reqs, ups)


# =============================================================================
# §5 — commit_append.
# =============================================================================


def commit_append[
    T: IcebergRestTransport,
    P: CatalogCredentialProvider,
    W: AppendSnapshotWriter,
    K: CommitClock,
    I: CommitIds,
](
    mut catalog: IcebergRestCatalog[T, P],
    mut writer: W,
    mut clock: K,
    mut ids: I,
    commit: AppendCommit,
) -> AppendCommitOutcome:
    """Commit `commit` (module header). Never raises: every failure is an
    outcome whose `message` starts with its token."""
    var out = AppendCommitOutcome()
    var written = List[String]()
    var key = commit.namespace + String(".") + commit.table
    var waits = _Waits(CommitRetryBudget(4, 100, 60000, 1800000), clock.now_ms())

    # The base, loaded at execution.
    var base: LoadedTable
    try:
        base = _load(catalog, clock, waits, commit.namespace, commit.table)
        waits.budget = CommitRetryBudget.from_properties(base.metadata)
    except e:
        return _fail(out^, String(e), True, written^)

    var check = check_append_base(commit, base.metadata)
    if check.byte_length() > 0:
        return _fail(out^, check^, True, written^)
    if commit.added_data_files == 0:
        out.committed = True
        return out^

    var idempotent: Bool
    try:
        # S, drawn again while the base already holds it; then C.
        out.snapshot_id = ids.snapshot_id()
        var draws = 1
        while base.metadata.snapshot_index(out.snapshot_id) >= 0:
            if draws >= _MAX_ID_DRAWS:
                return _fail(
                    out^,
                    ICEBERG_COMMIT_CONFLICT
                    + String(": commit to '")
                    + key
                    + String("': no unused snapshot id after ")
                    + String(_MAX_ID_DRAWS)
                    + String(" draws"),
                    True,
                    written^,
                )
            out.snapshot_id = ids.snapshot_id()
            draws += 1
        out.commit_id = ids.uuid()
        idempotent = catalog.supports_idempotency()
    except e:
        return _fail(out^, String(e), True, written^)

    var tainted = False
    var attempt = 0
    while True:
        if attempt > 0:
            check = check_append_base(commit, base.metadata)
            if check.byte_length() > 0:
                return _fail(out^, check^, not tainted, written^)
        var parent = base.metadata.main_snapshot_id
        var body: String
        var idem_key = String("")
        try:
            var ml = writer.write_manifest_list(
                out.snapshot_id,
                attempt,
                base.metadata,
                base.metadata.last_sequence_number + 1,
            )
            written.append(ml)
            var snap = append_snapshot(
                commit, base.metadata, out.snapshot_id, out.commit_id, ml, clock.now_ms()
            )
            body = append_commit_body(base.metadata, snap)
            if idempotent:
                idem_key = ids.uuid()
        except e:
            if tainted:
                return _unknown(out^, key, written, String(e))
            return _fail(out^, String(e), True, written^)

        var resp: CommitResponse
        try:
            resp = catalog.commit_table(
                commit.namespace, commit.table, body, idem_key
            )
            out.posts += 1
            if resp.kind == COMMIT_UNKNOWN and idem_key.byte_length() > 0:
                # A byte-identical resend under the same key: the server
                # answers it from its stored result.
                tainted = True
                if not waits.take(clock):
                    return _unknown(out^, key, written, resp.message)
                resp = catalog.commit_table(
                    commit.namespace, commit.table, body, idem_key
                )
                out.posts += 1
        except e:
            # Raised before sending (an endpoint not listed, a credential
            # failure): nothing of this attempt reached the catalog.
            if tainted:
                return _unknown(out^, key, written, String(e))
            return _fail(out^, String(e), True, written^)

        if resp.kind == COMMIT_APPLIED:
            ref md = resp.table.value().metadata
            var found = _find_commit(md, out.snapshot_id, out.commit_id)
            if found:
                return _succeed(out^, md, found.value(), written^)
            return _unknown(
                out^,
                key,
                written,
                String("the catalog answered 200, and its metadata has neither"
                " the snapshot nor the commit id in main's history"),
            )

        if resp.kind == COMMIT_UNKNOWN:
            tainted = True
            if not waits.take(clock):
                return _unknown(out^, key, written, resp.message)
            var reloaded: LoadedTable
            try:
                reloaded = _load(
                    catalog, clock, waits, commit.namespace, commit.table
                )
            except e:
                return _unknown(out^, key, written, String(e))
            var found = _find_commit(
                reloaded.metadata, out.snapshot_id, out.commit_id
            )
            if found:
                return _succeed(out^, reloaded.metadata, found.value(), written^)
            if not _same_main(reloaded.metadata.main_snapshot_id, parent):
                return _unknown(
                    out^,
                    key,
                    written,
                    resp.message
                    + String("; main moved from ")
                    + _main_text(parent)
                    + String(" to ")
                    + _main_text(reloaded.metadata.main_snapshot_id),
                )
            # Absent, with main still at P: it did not land. Retry.
            base = reloaded^
            attempt += 1
            continue

        if resp.kind == COMMIT_REFUSED:
            if not tainted:
                return _fail(out^, resp.message, True, written^)
            var reloaded: LoadedTable
            try:
                reloaded = _load(
                    catalog, clock, waits, commit.namespace, commit.table
                )
            except e:
                return _unknown(out^, key, written, String(e))
            var found = _find_commit(
                reloaded.metadata, out.snapshot_id, out.commit_id
            )
            if found:
                return _succeed(out^, reloaded.metadata, found.value(), written^)
            return _fail(
                out^,
                resp.message,
                _same_main(reloaded.metadata.main_snapshot_id, parent),
                written^,
            )

        # COMMIT_CONFLICT: a requirement failed; reload first.
        var reloaded: LoadedTable
        try:
            reloaded = _load(catalog, clock, waits, commit.namespace, commit.table)
        except e:
            if tainted:
                return _unknown(out^, key, written, String(e))
            return _fail(out^, String(e), True, written^)
        if tainted:
            var found = _find_commit(
                reloaded.metadata, out.snapshot_id, out.commit_id
            )
            if found:
                return _succeed(out^, reloaded.metadata, found.value(), written^)
            if not _same_main(reloaded.metadata.main_snapshot_id, parent):
                # Absent with main moved: the earlier attempt may have
                # landed and been expired since, so a rebase could append
                # the rows twice.
                return _unknown(
                    out^,
                    key,
                    written,
                    String("the catalog answered 409; main moved from ")
                    + _main_text(parent)
                    + String(" to ")
                    + _main_text(reloaded.metadata.main_snapshot_id),
                )
        var now_main = _main_text(reloaded.metadata.main_snapshot_id)
        if len(commit.pinned_snapshot_ids) > 0:
            var pins = String("")
            for i in range(len(commit.pinned_snapshot_ids)):
                if i > 0:
                    pins += ", "
                pins += String(commit.pinned_snapshot_ids[i])
            var why = (
                String("the statement read the table at snapshot ")
                + pins
                + String(", and main is now ")
                + now_main
            )
            if tainted:
                return _unknown(out^, key, written, why)
            return _fail(
                out^,
                ICEBERG_COMMIT_CONFLICT
                + String(": commit to '")
                + key
                + String("': ")
                + why,
                True,
                written^,
            )
        if not waits.take(clock):
            var why = (
                String("the table changed under each of ")
                + String(attempt + 1)
                + String(" attempts and the retry budget is spent; main is now ")
                + now_main
            )
            if tainted:
                return _unknown(out^, key, written, why)
            return _fail(
                out^,
                ICEBERG_COMMIT_CONFLICT
                + String(": commit to '")
                + key
                + String("': ")
                + why,
                True,
                written^,
            )
        base = reloaded^
        attempt += 1


def _same_main(a: Optional[Int64], b: Optional[Int64]) -> Bool:
    if a and b:
        return a.value() == b.value()
    return not a and not b


def _succeed(
    var out: AppendCommitOutcome,
    md: TableMetadata,
    landed: Int64,
    var written: List[String],
) -> AppendCommitOutcome:
    """Success: keep the manifest list the landed snapshot names, and list
    every other one this statement wrote for deletion."""
    out.committed = True
    out.landed_snapshot_id = Optional[Int64](landed)
    var i = md.snapshot_index(landed)
    out.manifest_list = String(md.snapshots[i].manifest_list)
    for j in range(len(written)):
        if written[j] != out.manifest_list:
            out.manifest_lists_to_delete.append(written[j])
    return out^


def _fail(
    var out: AppendCommitOutcome,
    var message: String,
    delete: Bool,
    var written: List[String],
) -> AppendCommitOutcome:
    """A failure with `message`; with `delete`, the statement's files and
    every manifest list it wrote may be deleted."""
    out.message = message^
    out.delete_statement_files = delete
    if delete:
        out.manifest_lists_to_delete = written^
    return out^


def _unknown(
    var out: AppendCommitOutcome,
    key: String,
    written: List[String],
    cause: String,
) -> AppendCommitOutcome:
    """`ICEBERG_COMMIT_STATE_UNKNOWN`, naming the table, `S`, `C` and the last
    manifest list; nothing may be deleted."""
    var ml = String("none")
    if len(written) > 0:
        ml = String(written[len(written) - 1])
    out.message = (
        ICEBERG_COMMIT_STATE_UNKNOWN
        + String(": commit to '")
        + key
        + String("' may or may not have landed: snapshot ")
        + String(out.snapshot_id)
        + String(", commit id ")
        + out.commit_id
        + String(", manifest list ")
        + ml
        + String(": ")
        + cause
    )
    out.delete_statement_files = False
    return out^
