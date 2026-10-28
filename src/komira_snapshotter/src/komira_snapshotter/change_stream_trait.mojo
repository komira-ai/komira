# =============================================================================
# komira_snapshotter/change_stream_trait.mojo — the ChangeStreamListener seam
#   + the provider-agnostic ChangeRecord model.
# =============================================================================
#
# WHAT THIS IS. The ONE change-stream seam every CDC provider conforms to. A
# `ChangeStreamListener` yields a stream of `ChangeRecord`s — the normalized,
# provider-agnostic form of "a row was inserted / modified / removed in the
# source table". DynamoDB Streams and Firestore Watch conform to the SAME seam.
# A snapshotter's apply+write+commit+checkpoint half is generic over
# `[L: ChangeStreamListener]` (one generic binary plus per-provider listeners),
# so it is written ONCE.
#
# THE RECORD SHAPE. A `ChangeRecord` carries:
#   * op            — INSERT | MODIFY | REMOVE (the CDC operation)
#   * key           — the primary-key cells (always present; the equality-delete
#                     key for the Iceberg merge-on-read path)
#   * new_image     — the full row AFTER the change (INSERT / MODIFY); empty for
#                     REMOVE
#   * old_image     — the full row BEFORE the change (MODIFY / REMOVE); empty for
#                     INSERT
#   * sequence_number — the source stream's monotonic cursor for THIS record. It
#                     feeds the Iceberg delete/append per-entry sequence number
#                     (merge ordering: an equality delete only masks data files
#                     with a LOWER sequence number) AND the checkpoint/commit
#                     atomicity boundary. Carried here, NOT interpreted — the
#                     snapshotter owns that semantics.
#
# WHY `RowCell` FOR THE CELLS. The Iceberg writer, delete-writer and
# merge-on-read reader share ONE typed cell model: `komira_rowcell.RowCell` — a
# plain tagged union over the primitive scalar subset (boolean / int / long /
# float / double / string) with VALUE EQUALITY (equality-delete matching) and NO
# pointer exposure (it lives only in `List[RowCell]`). The change-stream seam
# yields `List[RowCell]` DIRECTLY so a `ChangeRecord` feeds the Iceberg
# delete/append path with ZERO conversion. The per-provider client is
# responsible for mapping its native attribute types onto `RowCell` (DynamoDB's
# `M`/`L`/`B` — with no primitive scalar arm — map to a STRING cell carrying the
# canonical JSON serialization). This keeps the writer consuming ONLY primitive
# cells.
#
# ⚠ THE CELL COMES FROM `komira_rowcell`, NOT FROM `komira_iceberg`. This seam
# is PROVIDER-AGNOSTIC by design; taking the cell type from `komira_iceberg`
# would put `komira_parquet` and the whole query engine in the build closure of
# every CDC provider client, and of every binary that links one. The cell model
# is the zero-dep leaf `komira_rowcell`. This library must NOT gain a
# `komira_iceberg` dep: the seam names the CELL, and Iceberg is one CONSUMER of
# the seam, not its supplier.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard origins;
# ZERO unsafe_from_address. `ChangeRecord` is a plain owned-field struct (an Int
# op tag + a String sequence cursor + three `List[RowCell]` images). RowCell has
# no pointer field and lives only in a plain List, never a byte-slab, so no
# stale-pointer reuse hazard applies to it.
# =============================================================================

from komira_rowcell.row_cell import RowCell


# =============================================================================
# §0 — the change-operation tags.
# =============================================================================
# The CDC operation kind. Provider-agnostic — DynamoDB's `INSERT`/`MODIFY`/
# `REMOVE` eventName, Firestore's document add/update/delete, and any future
# source all normalize onto these three.
comptime CDC_OP_INSERT: Int = 0
comptime CDC_OP_MODIFY: Int = 1
comptime CDC_OP_REMOVE: Int = 2


def cdc_op_name(op: Int) -> StaticString:
    """A short human name for a CDC op tag (for log lines / error messages)."""
    if op == CDC_OP_INSERT:
        return "INSERT"
    elif op == CDC_OP_MODIFY:
        return "MODIFY"
    elif op == CDC_OP_REMOVE:
        return "REMOVE"
    else:
        return "UNKNOWN"


# =============================================================================
# §1 — ChangeRecord — the normalized, provider-agnostic change row.
# =============================================================================


struct ChangeRecord(Copyable, Movable, Deinitable):
    """One normalized change from a CDC source.

    Field layout:
      var op: Int                     — CDC_OP_INSERT / _MODIFY / _REMOVE
      var key: List[RowCell]          — the primary-key cells (always present)
      var new_image: List[RowCell]    — the row AFTER (INSERT / MODIFY); empty
                                        for REMOVE
      var old_image: List[RowCell]    — the row BEFORE (MODIFY / REMOVE); empty
                                        for INSERT
      var sequence_number: String     — the source stream's cursor for THIS
                                        record (opaque; DynamoDB's decimal-string
                                        SequenceNumber). Carried, not interpreted;
                                        feeds the Iceberg per-entry seq + the
                                        checkpoint.

    Invariants (enforced at construction by the typed constructors below, and
    asserted by `validate()`):
      * INSERT  -> new_image non-empty, old_image empty
      * MODIFY  -> new_image AND old_image non-empty
      * REMOVE  -> old_image non-empty, new_image empty
      * key     -> always non-empty (a keyless change cannot be equality-deleted)

    A plain owned-field struct. RowCell has NO pointer field and lives only in
    a plain `List`, never a byte-slab. No wildcard origin, no UnsafePointer
    field."""

    var op: Int
    var key: List[RowCell]
    var new_image: List[RowCell]
    var old_image: List[RowCell]
    var sequence_number: String

    def __init__(
        out self,
        op: Int,
        var key: List[RowCell],
        var new_image: List[RowCell],
        var old_image: List[RowCell],
        var sequence_number: String,
    ):
        self.op = op
        self.key = key^
        self.new_image = new_image^
        self.old_image = old_image^
        self.sequence_number = sequence_number^

    def copy(self) -> Self:
        return Self(
            self.op,
            _copy_cells(self.key),
            _copy_cells(self.new_image),
            _copy_cells(self.old_image),
            String(self.sequence_number),
        )

    @always_inline
    def op_name(self) -> String:
        return cdc_op_name(self.op)

    @always_inline
    def is_insert(self) -> Bool:
        return self.op == CDC_OP_INSERT

    @always_inline
    def is_modify(self) -> Bool:
        return self.op == CDC_OP_MODIFY

    @always_inline
    def is_remove(self) -> Bool:
        return self.op == CDC_OP_REMOVE

    def validate(self) raises:
        """Assert the op<->image invariants (fail fast + loud). The per-provider
        client builds a ChangeRecord via the typed constructors below which
        already enforce these; `validate()` is the belt-and-suspenders check the
        snapshotter can run on any record it receives."""
        if len(self.key) == 0:
            raise Error(
                "ChangeRecord.validate: key is empty (a keyless change cannot"
                " be equality-deleted)"
            )
        if self.op == CDC_OP_INSERT:
            if len(self.new_image) == 0:
                raise Error(
                    "ChangeRecord.validate: INSERT with empty new_image"
                )
            if len(self.old_image) != 0:
                raise Error(
                    "ChangeRecord.validate: INSERT with non-empty old_image"
                )
        elif self.op == CDC_OP_MODIFY:
            if len(self.new_image) == 0:
                raise Error(
                    "ChangeRecord.validate: MODIFY with empty new_image"
                )
            if len(self.old_image) == 0:
                raise Error(
                    "ChangeRecord.validate: MODIFY with empty old_image"
                )
        elif self.op == CDC_OP_REMOVE:
            if len(self.old_image) == 0:
                raise Error(
                    "ChangeRecord.validate: REMOVE with empty old_image"
                )
            if len(self.new_image) != 0:
                raise Error(
                    "ChangeRecord.validate: REMOVE with non-empty new_image"
                )
        else:
            raise Error(
                String("ChangeRecord.validate: unknown op tag ")
                + String(self.op)
            )


# -----------------------------------------------------------------------------
# Typed constructors — enforce the op<->image invariant at construction.
# -----------------------------------------------------------------------------


def make_insert_record(
    var key: List[RowCell],
    var new_image: List[RowCell],
    var sequence_number: String,
) -> ChangeRecord:
    """An INSERT: the row appeared. `new_image` is the full new row; `old_image`
    is empty (there was no prior row)."""
    return ChangeRecord(
        CDC_OP_INSERT,
        key^,
        new_image^,
        List[RowCell](),
        sequence_number^,
    )


def make_modify_record(
    var key: List[RowCell],
    var old_image: List[RowCell],
    var new_image: List[RowCell],
    var sequence_number: String,
) -> ChangeRecord:
    """A MODIFY: the row changed. Both images present — `old_image` is the row
    BEFORE (the equality-delete target), `new_image` is the row AFTER (the
    append)."""
    return ChangeRecord(
        CDC_OP_MODIFY,
        key^,
        new_image^,
        old_image^,
        sequence_number^,
    )


def make_remove_record(
    var key: List[RowCell],
    var old_image: List[RowCell],
    var sequence_number: String,
) -> ChangeRecord:
    """A REMOVE: the row was deleted. `old_image` is the row BEFORE (the
    equality-delete target); `new_image` is empty (there is no after)."""
    return ChangeRecord(
        CDC_OP_REMOVE,
        key^,
        List[RowCell](),
        old_image^,
        sequence_number^,
    )


@always_inline
def _copy_cells(cells: List[RowCell]) -> List[RowCell]:
    """Deep-copy a cell list (RowCell.copy per element — the String arm needs a
    fresh String)."""
    var out = List[RowCell]()
    for i in range(len(cells)):
        out.append(cells[i].copy())
    return out^


# =============================================================================
# §2 — ChangeBatch — a bounded run of ChangeRecords the listener yields per poll.
# =============================================================================


struct ChangeBatch(Copyable, Movable, Deinitable):
    """A bounded run of `ChangeRecord`s from ONE listener poll, plus the resume
    cursor for the NEXT poll.

    Field layout:
      var records: List[ChangeRecord]  — the change records in stream order
      var next_cursor: String          — the opaque resume token for the next
                                         poll (DynamoDB's NextShardIterator).
                                         Empty String means "this shard/stream
                                         segment is exhausted" (end-of-shard).
      var exhausted: Bool              — True iff the source segment has ended
                                         (DynamoDB: a null NextShardIterator).
                                         When True, `next_cursor` is empty and no
                                         further poll on THIS segment is possible.

    The `exhausted`/`next_cursor` distinction is load-bearing for the DynamoDB
    Streams shard-iteration contract: an EMPTY `records` with a
    LIVE `next_cursor` (exhausted=False) means "no new records yet, keep polling"
    — NOT end-of-stream; a null NextShardIterator (exhausted=True) means the shard
    is closed."""

    var records: List[ChangeRecord]
    var next_cursor: String
    var exhausted: Bool

    def __init__(
        out self,
        var records: List[ChangeRecord],
        var next_cursor: String,
        exhausted: Bool,
    ):
        self.records = records^
        self.next_cursor = next_cursor^
        self.exhausted = exhausted

    def copy(self) -> Self:
        """Deep-copy the batch (each ChangeRecord deep-copies its cell lists).
        Used by a driver/test that replays a batch across passes."""
        var recs = List[ChangeRecord]()
        for i in range(len(self.records)):
            recs.append(self.records[i].copy())
        return Self(recs^, String(self.next_cursor), self.exhausted)

    @staticmethod
    def empty_live(var next_cursor: String) -> ChangeBatch:
        """No records this poll, but the segment is still live — keep polling
        with `next_cursor`."""
        return ChangeBatch(List[ChangeRecord](), next_cursor^, False)

    @staticmethod
    def end_of_segment() -> ChangeBatch:
        """The source segment has ended (a null resume token). No further poll."""
        return ChangeBatch(List[ChangeRecord](), String(""), True)

    @always_inline
    def __len__(self) -> Int:
        return len(self.records)

    @always_inline
    def is_exhausted(self) -> Bool:
        return self.exhausted


# =============================================================================
# §3 — ChangeStreamListener — the provider-agnostic seam trait.
# =============================================================================


trait ChangeStreamListener(Movable, Deinitable):
    """The ONE seam every CDC provider conforms to. A listener is
    opened against a source table, `open()` returns the FIRST resume cursor, and
    `poll(cursor)` yields a `ChangeBatch` + the NEXT resume cursor — threading the
    cursor across polls is the caller's job (the snapshotter loop). DynamoDB
    Streams and Firestore Watch conform to the SAME surface.

    The seam is POLLING-shaped (a `poll(cursor) -> batch` pull). DynamoDB Streams
    is natively polling; Firestore Watch is push (a bidi stream) but adapts to
    this pull by buffering server pushes and draining them per `poll` — so the
    ONE snapshotter loop drives both. No UnsafePointer crosses the boundary; the
    cursor is an opaque `String` the provider interprets.

    NOTE (deliberately NOT here). The snapshotter main loop, the checkpoint, and
    the apply-to-Iceberg wiring live with the consumer (they own the
    exactly-once decision). This seam stops at "the listener yields correct
    ChangeRecords from the source"."""

    def open(mut self) raises -> String:
        """Open the listener against the source table and return the FIRST resume
        cursor (DynamoDB: DescribeStream -> GetShardIterator). RAISES on a source
        error (fail fast + loud). The returned cursor is opaque; pass it to the
        first `poll`."""
        ...

    def poll(mut self, cursor: String) raises -> ChangeBatch:
        """Fetch the next `ChangeBatch` from `cursor` (DynamoDB: GetRecords). The
        returned batch's `next_cursor` is the cursor for the NEXT poll; an
        exhausted batch (`is_exhausted()`) means the source segment has ended.
        RAISES on a source error. An empty batch with a live cursor is NORMAL
        (no new records yet) — the caller keeps polling."""
        ...


# =============================================================================
# §4 — MultiShardChangeStreamListener — the multi-segment fan-out seam.
# =============================================================================


trait MultiShardChangeStreamListener(Movable, Deinitable):
    """The multi-SEGMENT extension of the change-stream seam (CDC ingest).

    A single-shard tail SILENTLY MISSES changes on other shards of the same
    stream, so the CDC ingest binary tails ALL currently-open shards, tracking a
    per-shard position. This trait adds the two operations the single-shard
    `ChangeStreamListener` cannot express:

      * `list_shard_ids()`     — enumerate the stream's OPEN shard/segment ids
                                 (DynamoDB: DescribeStream -> the Shards list).
      * `open_shard(id, after)` — a shard iterator that RESUMES strictly after
                                 `after` (the last-applied SequenceNumber derived
                                 from the committed Iceberg snapshot summary), or
                                 from the oldest record when `after` is empty
                                 (cold start). DynamoDB: GetShardIterator with
                                 AFTER_SEQUENCE_NUMBER (or TRIM_HORIZON).

    `poll(cursor)` is INHERITED in shape from `ChangeStreamListener` (a listener
    conforms to BOTH): the driver threads each shard's cursor across polls
    independently. The DynamoDB Streams client conforms; a Firestore listener
    can conform to the SAME surface. Child-shard discovery on split
    (re-enumerate after a shard closes) is not part of this seam — it tails the
    shards present NOW."""

    def list_shard_ids(mut self) raises -> List[String]:
        """Enumerate the stream's currently-open shard/segment ids. RAISES on a
        source error."""
        ...

    def open_shard(
        mut self, shard_id: String, after_sequence_number: String
    ) raises -> String:
        """Open `shard_id` and return its FIRST resume cursor, positioned
        STRICTLY AFTER `after_sequence_number` (or at the oldest record when it
        is empty — a cold start for this shard). RAISES on a source error."""
        ...

    def poll(mut self, cursor: String) raises -> ChangeBatch:
        """Fetch the next `ChangeBatch` from `cursor` (same shape as the
        single-shard seam). The driver threads each shard's cursor independently.
        """
        ...
