# =============================================================================
# cdc_apply.mojo — map a batch of ChangeRecords to ONE atomic Iceberg commit.
# =============================================================================
#
# `apply_batch` turns a batch of provider-agnostic `ChangeRecord`s (from a
# `ChangeStreamListener`) into ONE Iceberg commit of data files and delete files:
#
#   INSERT  -> append the new row (data file).
#   MODIFY  -> equality-delete the key + append the new row.
#   REMOVE  -> equality-delete the key.
#
# A whole `ChangeBatch` becomes ONE commit, not one commit per record: the
# batch's appends coalesce into a single Parquet data file and its deletes into
# a single equality-delete file. The commit also stamps the batch's ending
# per-shard stream position into the snapshot `summary` (via
# `commit_with_summary`), so the resume point rides the same atomic commit as the
# data (see cdc_position.mojo).
#
# Idempotence: apply skips any ChangeRecord whose `sequence_number` is not
# greater than the committed position for its shard. An equality delete by key is
# naturally idempotent (deleting an absent key is a no-op); the skip guards the
# append case against a re-applied batch (a crash between the data write and the
# pointer swap re-reads from the last committed position and re-applies). Sequence
# numbers are bare decimal strings that may exceed Int64 and are not zero-padded
# to a fixed width, so ordering is by numeric magnitude via `seq_gt`.
#
# No pointer type appears in any signature. The writer is taken by `mut ref` and
# the batch by value.
# =============================================================================

from komira_snapshotter.change_stream_trait import (
    ChangeRecord,
    ChangeBatch,
    CDC_OP_INSERT,
    CDC_OP_MODIFY,
    CDC_OP_REMOVE,
)

from komira_objectstore.store import ConditionalWriteStore

from komira_iceberg import (
    IcebergSchema,
    IcebergTableWriter,
    IcebergCommitResult,
    DataFileInfo,
    ColumnBound,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    RowCell,
    SummaryKV,
    build_parquet_data_file,
    build_equality_delete_file,
    col_types_of,
)

from .cdc_position import (
    ShardPositions,
    seq_gt,
)


# =============================================================================
# ApplyStats — what an apply produced (for the driver loop's logging + tests).
# =============================================================================


@fieldwise_init
struct ApplyStats(Copyable, Movable, Deinitable):
    """Counts for one applied batch (a plain POD struct — no heap field).

    Fields:
      var appended: Int   — rows appended (INSERT + MODIFY new images).
      var deleted: Int    — delete keys emitted (MODIFY old key + REMOVE key).
      var skipped: Int     — records skipped as <= the committed shard position
                             (the idempotence guard).
      var committed: Bool  — True iff a commit was issued (False iff the batch
                             produced no work after idempotence filtering).
      var version: Int     — the new metadata version (0 iff no commit).
    """

    var appended: Int
    var deleted: Int
    var skipped: Int
    var committed: Bool
    var version: Int


# =============================================================================
# CdcApplyConfig — the binding between the change stream and the Iceberg table.
# =============================================================================


struct CdcApplyConfig(Copyable, Movable, Deinitable):
    """The apply configuration: the target schema + the equality-delete key
    field-ids (the primary-key columns the delete-by-key matches on).

    `key_field_ids` are the SCHEMA field-ids of the primary-key columns (the
    columns a MODIFY/REMOVE delete matches on). The delete rows carry ONLY those
    columns; the reader masks any data row whose same columns equal a delete
    row's (for data files with a strictly lower sequence number). The columns
    MUST be `required` (Iceberg equality-delete on a nullable key is rejected at
    the write boundary).

    A plain owned-field struct (an IcebergSchema + a `List[Int]`), only
    ever held in a plain local; it has no pointer field."""

    var schema: IcebergSchema
    var key_field_ids: List[Int]

    def __init__(
        out self, var schema: IcebergSchema, var key_field_ids: List[Int]
    ):
        self.schema = schema^
        self.key_field_ids = key_field_ids^

    def copy(self) -> Self:
        var ids = List[Int]()
        for i in range(len(self.key_field_ids)):
            ids.append(self.key_field_ids[i])
        return Self(self.schema.copy(), ids^)

    def key_col_types(self) -> List[Int]:
        """The declared type tags of the key columns, in key-field-id order (the
        equality-delete file's column types)."""
        var out = List[Int]()
        for k in range(len(self.key_field_ids)):
            for i in range(len(self.schema.fields)):
                if self.schema.fields[i].field_id == self.key_field_ids[k]:
                    out.append(self.schema.fields[i].type_tag)
                    break
        return out^


# =============================================================================
# The apply — one ChangeBatch -> one atomic Iceberg commit.
# =============================================================================


def apply_batch[
    Store: ConditionalWriteStore
](
    mut writer: IcebergTableWriter[Store],
    config: CdcApplyConfig,
    shard_id: String,
    batch: ChangeBatch,
    mut positions: ShardPositions,
) raises -> ApplyStats:
    """Apply one `ChangeBatch` from shard `shard_id` to the Iceberg table as ONE
    atomic commit, stamping the batch's ending position into the snapshot
    summary.

    For each record (in stream order), SKIP it if its sequence_number is <= the
    committed position for `shard_id` (idempotence). The remaining records are
    COALESCED per primary key to their NET effect within the batch (so an
    INSERT-then-MODIFY of the same key in one batch becomes one final append, and
    an INSERT-then-REMOVE becomes a no-op) — see `_KeyState`. Then, from the
    coalesced state:
      * a key whose NET final op is INSERT/MODIFY (present) -> emit its final
        new_image for APPEND *and* an equality-delete of the key (to mask any
        PRIOR-generation data file — the delete's strictly-lower-seq rule keeps
        the SAME-commit append alive);
      * a key whose NET final op is REMOVE (absent) -> emit an equality-delete of
        the key only (no append).
    All deletes + appends land in ONE atomic commit that ALSO stamps the updated
    `positions` (the whole known per-shard map) into the snapshot summary.

    WHY the per-key delete on a present key: within one commit the data + delete
    files share the commit's sequence number, and an equality delete masks ONLY
    data files with a STRICTLY LOWER seq — so a delete emitted for an INSERT/
    MODIFY masks the key's PRIOR generations (earlier commits) while leaving this
    commit's fresh append alive. That is exactly upsert semantics.

    `positions` is updated IN PLACE to the batch's max applied sequence for
    `shard_id`; on commit, the FULL positions map is stamped so every shard's
    resume point is present in the latest snapshot. If nothing remains after the
    idempotence filter, NO commit is issued (an empty batch or a fully-replayed
    batch is a no-op) and `positions` is unchanged."""
    var committed_pos = positions.get(shard_id)

    var skipped = 0
    var max_applied = String(committed_pos)

    # ---- coalesce the batch per primary key to its NET effect ----
    # Two parallel lists: the projected key cells + its net state (final op +
    # final new_image). A linear scan keyed on RowCell value-equality — a batch
    # is small, so O(records * distinct-keys) is fine and avoids a Dict-of-row
    # dependency.
    var key_cells = List[List[RowCell]]()  # the projected key per distinct key
    var states = List[_KeyState]()

    for ri in range(len(batch.records)):
        ref rec = batch.records[ri]
        # Idempotence: skip any record at or below the committed position.
        # `seq_gt` orders by NUMERIC MAGNITUDE; its inputs (rec.sequence_number,
        # committed_pos) are provider-guaranteed BARE decimal strings (digits
        # only, may exceed Int64, not fixed-width) — the provider contract that
        # makes the significant-digit-count compare correct.
        if committed_pos.byte_length() > 0 and not seq_gt(
            rec.sequence_number, committed_pos
        ):
            skipped += 1
            continue
        rec.validate()
        var kproj = _project_key(rec, config.key_field_ids, config.schema)
        var slot = _find_key(key_cells, kproj)
        var img = List[RowCell]()
        if rec.op != CDC_OP_REMOVE:
            img = _copy_row(rec.new_image)
        if slot < 0:
            key_cells.append(_copy_key(kproj))
            states.append(_KeyState(rec.op, img^))
        else:
            # A later op for the same key WINS (records are in stream order).
            states[slot] = _KeyState(rec.op, img^)
        # Track the max applied sequence for this shard (records are in stream
        # order, so the last non-skipped record carries the max).
        if seq_gt(rec.sequence_number, max_applied):
            max_applied = String(rec.sequence_number)

    # ---- emit deletes + appends from the coalesced state ----
    var append_rows = List[List[RowCell]]()
    var delete_keys = List[List[RowCell]]()
    for i in range(len(states)):
        ref st = states[i]
        # EVERY touched key gets an equality-delete (masks PRIOR generations; a
        # no-op for a never-before-seen key). A present key ALSO appends its
        # final image; an absent (net-REMOVE) key does not.
        delete_keys.append(_copy_key(key_cells[i]))
        if st.op != CDC_OP_REMOVE:
            append_rows.append(_copy_row(st.image))

    var appended = len(append_rows)
    var deleted = len(delete_keys)

    # Nothing to do (empty batch or fully replayed) -> no commit, no position
    # advance.
    if appended == 0 and deleted == 0:
        return ApplyStats(0, 0, skipped, False, 0)

    # ---- build the data + delete files ----
    var data_files = List[DataFileInfo]()
    if appended > 0:
        var data_key = (
            writer.data_dir() + "/cdc-" + shard_id + "-" + max_applied
            + ".parquet"
        )
        var data_bytes = build_parquet_data_file(config.schema, append_rows)
        writer.put_object(data_key, data_bytes.copy())
        data_files.append(
            DataFileInfo(
                String(data_key), len(data_bytes), appended, List[ColumnBound]()
            )
        )

    var delete_files = List[DataFileInfo]()
    if deleted > 0:
        var key_types = config.key_col_types()
        var del_bytes = build_equality_delete_file(
            config.key_field_ids, key_types, delete_keys
        )
        var del_key = (
            writer.data_dir() + "/cdc-eqdel-" + shard_id + "-" + max_applied
            + ".avro"
        )
        writer.put_object(del_key, del_bytes.copy())
        var eids = List[Int]()
        for k in range(len(config.key_field_ids)):
            eids.append(config.key_field_ids[k])
        delete_files.append(
            DataFileInfo(
                String(del_key),
                len(del_bytes),
                deleted,
                List[ColumnBound](),
                ICE_DATA_CONTENT_EQUALITY_DELETES,
                eids^,
                Int64(0),  # stamped by the commit.
            )
        )

    # ---- advance the in-memory position + stamp the FULL map into the summary
    positions.set(shard_id, String(max_applied))
    var extra = positions.to_summary_kvs()

    var result = writer.commit_with_summary(
        data_files^, delete_files^, extra
    )
    return ApplyStats(appended, deleted, skipped, True, result.version)


# =============================================================================
# Per-key net-state (batch coalescing).
# =============================================================================


struct _KeyState(Movable, Deinitable):
    """The NET state of one primary key within a batch: its final op + (for a
    present key) its final new_image. A plain owned-field struct with no
    pointer field."""

    var op: Int
    var image: List[RowCell]

    def __init__(out self, op: Int, var image: List[RowCell]):
        self.op = op
        self.image = image^


def _find_key(keys: List[List[RowCell]], probe: List[RowCell]) -> Int:
    """Index of `probe` in `keys` by cell-wise VALUE equality, or -1 if absent
    (the per-key coalescing lookup)."""
    for i in range(len(keys)):
        if _key_eq(keys[i], probe):
            return i
    return -1


@always_inline
def _key_eq(a: List[RowCell], b: List[RowCell]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not a[i].equals(b[i]):
            return False
    return True


@always_inline
def _copy_key(k: List[RowCell]) -> List[RowCell]:
    var out = List[RowCell]()
    for i in range(len(k)):
        out.append(k[i].copy())
    return out^


# =============================================================================
# Row / key projection helpers.
# =============================================================================


@always_inline
def _copy_row(row: List[RowCell]) -> List[RowCell]:
    var out = List[RowCell]()
    for i in range(len(row)):
        out.append(row[i].copy())
    return out^


def _project_key(
    rec: ChangeRecord, key_field_ids: List[Int], schema: IcebergSchema
) raises -> List[RowCell]:
    """Project the primary-key cells for an equality-delete row, in
    `key_field_ids` order.

    The ChangeRecord's `key` is already the positional key cells the provider
    produced (the source keys projected onto the schema column order).
    But the equality-delete file carries ONLY the key columns in
    `key_field_ids` order, so project the record's KEY (a full-schema-ordered
    tuple from the provider) OR its old_image down to those columns. We use the
    old_image when present (MODIFY/REMOVE always carry it) since it is the full
    row; otherwise the key tuple."""
    # The provider projects Keys onto the FULL schema column order (positional),
    # so column index == field_id - 1 (field-ids are 1-based in column order).
    # Prefer the old_image (the full row, present on MODIFY/REMOVE); else the key
    # tuple (which the provider also projects onto the full schema width).
    var src = List[RowCell]()
    if len(rec.old_image) == len(schema.fields):
        src = _copy_row(rec.old_image)
    elif len(rec.key) == len(schema.fields):
        src = _copy_row(rec.key)
    else:
        # A key tuple that is NOT full-schema-width: for a correct equality-delete
        # we need the key columns positionally, so require a full-width image.
        raise Error(
            "_project_key: neither old_image nor key is full-schema-width"
            " (cannot project the equality-delete key columns)"
        )
    var out = List[RowCell]()
    for k in range(len(key_field_ids)):
        var ci = _col_index_of_field_id(schema, key_field_ids[k])
        out.append(src[ci].copy())
    return out^


def _col_index_of_field_id(schema: IcebergSchema, field_id: Int) raises -> Int:
    for i in range(len(schema.fields)):
        if schema.fields[i].field_id == field_id:
            return i
    raise Error(
        "_col_index_of_field_id: field-id " + String(field_id) + " not in schema"
    )
