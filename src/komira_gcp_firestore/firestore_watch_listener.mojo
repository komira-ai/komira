# =============================================================================
# firestore_watch_listener.mojo — the Firestore Watch CDC ChangeStreamListener
#   conformer (maps a Listen source's ListenEvents -> ChangeRecords).
# =============================================================================
#
# CDC-Firestore ChangeSource. It conforms to BOTH of komira_snapshotter's
# `ChangeStreamListener` + `MultiShardChangeStreamListener`, so any consumer of
# that seam drives it unchanged. It wraps a Firestore Listen SOURCE (the push
# side) and, per `poll`, turns the drained `ListenEvent`s into normalized
# `ChangeRecord`s.
#
# THE SOURCE SEAM (`FirestoreListenSource`). The listener is generic over the
# source so a SCRIPTED source drives it OFFLINE. The source exposes two
# operations:
#   * `open_watch(after)` — open / RESUME the watch. `after` is the composite
#     cursor String (decode via firestore_cdc_cursor); an empty `after` cold-starts.
#     The production source re-opens the FirestoreListenClient with the decoded
#     resume_token; the scripted source records `after` + replays canned events.
#   * `drain()` — pull the buffered ListenEvents accumulated since the last drain
#     (the production source drives the h2 recv + framer via poll; the scripted
#     source returns its canned list once, then empties).
#
# THE MAPPING (design decisions #3, #4, #5, #6).
#   * DocumentChange -> a MODIFY ChangeRecord. Firestore does NOT distinguish
#     create vs update on the wire; equality-delete+append IS upsert-safe &
#     idempotent, so we ALWAYS emit MODIFY (decision #3). The key cell(s) are
#     extracted from the document id (the last resource-name segment); the
#     new_image is the fields projected onto the schema columns (with the key
#     column injected from the doc id). Both key + new_image are FULL-SCHEMA-WIDTH
#     positional rows (so a consumer that applies the change by position,
#     which needs a full-width old_image OR key, can find the equality-delete
#     key columns).
#   * DocumentDelete / DocumentRemove -> a REMOVE ChangeRecord (key only; no
#     new_image). The key is again the full-schema-width tuple built from the doc
#     id, since a delete/remove carries only the resource name (no fields).
#   * A resumable TargetChange (NO_CHANGE / CURRENT carrying a resume_token +
#     read_time) is the CDC checkpoint boundary: the batch's `next_cursor` encodes
#     its (read_time, resume_token) (decision #2), and EVERY record in the batch
#     is stamped with that read_time's normalized sequence (decision #1) — so on
#     resume, `open_shard(after)` re-opens the watch AFTER that snapshot and the
#     apply's idempotence skip drops any re-delivered record at that read_time.
#   * SINGLE SYNTHETIC SEGMENT (decision #5): `list_shard_ids` returns one id;
#     `open_shard` opens/resumes the one watch. Multi-collection fan-out is a
#     documented follow-on.
#   * RE-OPEN-PER-PASS (decision #6): stateless — each pass opens the watch after
#     the derived cursor, drains one batch, and returns.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. The source `Src` is moved in; owned String /
# List config. `def`-based, Mojo 1.0.0b2.
# =============================================================================

from komira_snapshotter.change_stream_trait import (
    ChangeStreamListener,
    MultiShardChangeStreamListener,
    ChangeRecord,
    ChangeBatch,
    make_modify_record,
    make_remove_record,
)

# THE CELL MODEL COMES FROM `komira_rowcell`, A ZERO-DEP LEAF: the listener
# emits cells, and the table schema they land in is the ingest side's business.
from komira_rowcell.row_cell import (
    RowCell,
    make_string_cell,
    make_null_cell,
    CELL_T_STRING,
)

from komira_gcp_firestore.firestore_listen_proto import (
    ListenEvent,
    LE_TARGET_CHANGE,
    LE_DOCUMENT_CHANGE,
    LE_DOCUMENT_DELETE,
    LE_DOCUMENT_REMOVE,
)
from komira_gcp_firestore.firestore_value import (
    FsValue,
    fs_value_to_row_cell,
)
from komira_gcp_firestore.firestore_cdc_cursor import (
    read_time_to_sequence,
    encode_firestore_cursor,
    decode_firestore_cursor,
)


# The one synthetic segment id the single-collection watch presents to the
# multi-shard driver (decision #5). Multi-collection fan-out (multiple segments)
# is a documented follow-on.
comptime FIRESTORE_SEGMENT_ID: String = "firestore-watch-0"


# =============================================================================
# §1 — the FirestoreListenSource seam (testable push side).
# =============================================================================


trait FirestoreListenSource(Movable, Deinitable):
    """The Firestore Listen push side the watch listener drains. A production
    source wraps a `FirestoreListenClient` + reactor (open the bidi stream, drive
    the recv, decode ListenResponses); a SCRIPTED source replays canned events
    offline. Generic-over-source keeps the listener testable with ZERO network."""

    def open_watch(mut self, after: String) raises:
        """Open / RESUME the watch. `after` is the composite cursor String (an
        empty String cold-starts). The production source decodes the resume_token
        and re-opens the FirestoreListenClient; the scripted source records
        `after`."""
        ...

    def drain(mut self) raises -> List[ListenEvent]:
        """Pull the ListenEvents buffered since the last drain (the production
        source drives one h2 recv + framer pop; the scripted source returns its
        canned list once)."""
        ...


# =============================================================================
# §2 — ScriptedListenSource — the offline test source.
# =============================================================================


struct ScriptedListenSource(FirestoreListenSource, Movable, Deinitable):
    """A FirestoreListenSource that replays a canned `List[ListenEvent]` once,
    recording the `after` cursor it was opened with (so a test asserts the resume
    cursor was threaded).

    Layout: plain owned-field struct (List[ListenEvent] + String + Bool) in a plain
    local — no pointer field, no byte-slab."""

    var _events: List[ListenEvent]
    var _opened_after: String
    var _drained: Bool

    def __init__(out self, var events: List[ListenEvent]):
        self._events = events^
        self._opened_after = String("")
        self._drained = False

    def open_watch(mut self, after: String) raises:
        self._opened_after = String(after)
        self._drained = False

    def drain(mut self) raises -> List[ListenEvent]:
        if self._drained:
            return List[ListenEvent]()
        self._drained = True
        var out = List[ListenEvent]()
        for i in range(len(self._events)):
            out.append(self._events[i].copy())
        return out^

    def opened_after(self) -> String:
        """The `after` cursor the source was last opened with (test seam)."""
        return String(self._opened_after)


# =============================================================================
# §3 — FirestoreWatchConfig — the schema <-> Firestore-document binding.
# =============================================================================


struct FirestoreWatchConfig(Copyable, Movable, Deinitable):
    """The binding between a Firestore document and the target table row.

    Fields:
      column_names  — the target column order, the order fs_fields_to_row_cells
                      projects a document's fields onto.
      key_column    — the name of the KEY column that holds the DOCUMENT ID (the
                      last resource-name segment). This is the primary-key column
                      the equality-delete matches on; it is NOT a document FIELD
                      (Firestore's document id is separate from its fields), so the
                      listener injects the doc id into this column.

    The table schema the records land in (key field ids, column types) is
    the ingest side's configuration, not the listener's: the listener only
    projects `column_names` and injects the document id into `key_column`.

    Layout: a plain owned-field struct (List[String] + String) in a plain local —
    no pointer field, no byte-slab."""

    var column_names: List[String]
    var key_column: String

    def __init__(
        out self,
        var column_names: List[String],
        var key_column: String,
    ):
        self.column_names = column_names^
        self.key_column = key_column^

    def copy(self) -> Self:
        var cols = List[String]()
        for i in range(len(self.column_names)):
            cols.append(String(self.column_names[i]))
        return Self(cols^, String(self.key_column))


# =============================================================================
# §4 — FirestoreWatchListener[Src] — the ChangeStreamListener conformer.
# =============================================================================


struct FirestoreWatchListener[Src: FirestoreListenSource](
    ChangeStreamListener,
    MultiShardChangeStreamListener,
    Movable,
    Deinitable,
):
    """The Firestore Watch change-stream client. Conforms to
    `ChangeStreamListener` + `MultiShardChangeStreamListener`. Parametric over the
    Listen source `Src` (a production FirestoreListenClient wrapper in prod, a
    ScriptedListenSource in test).

    open()/open_shard(after) -> open/resume the ONE watch after the composite
                                cursor `after`.
    poll(cursor)             -> drain the source's ListenEvents, map each to a
                                ChangeRecord, thread the (read_time, resume_token)
                                cursor from the batch's resumable TargetChange.

    Layout: the source `Src` (moved in) + owned FirestoreWatchConfig. No wildcard-
    origin field, no UnsafePointer field, no byte-slab."""

    var _source: Self.Src
    var _config: FirestoreWatchConfig

    def __init__(out self, var source: Self.Src, var config: FirestoreWatchConfig):
        self._source = source^
        self._config = config^

    # ----- source inspection (test seam) ------------------------------------
    def source_ref(ref self) -> ref [self._source] Self.Src:
        """Borrow the owned source for inspection (a test reads the scripted
        source's recorded `opened_after` AFTER driving the flow). Returns a
        reference rooted at `self._source` (never a raw pointer)."""
        return self._source

    # ----- ChangeStreamListener trait ---------------------------------------
    def open(mut self) raises -> String:
        """Cold-open the watch (no prior position) and return the initial cursor
        (empty — the first poll's TargetChange establishes the first real
        cursor)."""
        self._source.open_watch(String(""))
        return String("")

    # ----- multi-shard seam (single synthetic segment) ----------------------
    def list_shard_ids(mut self) raises -> List[String]:
        """The single synthetic segment (decision #5). Multi-collection fan-out
        is a documented follow-on."""
        var out = List[String]()
        out.append(String(FIRESTORE_SEGMENT_ID))
        return out^

    def open_shard(
        mut self, shard_id: String, after_sequence_number: String
    ) raises -> String:
        """Open / RESUME the one watch. `after_sequence_number` is the composite
        cursor (an empty String cold-starts). Returns it back as the poll cursor
        (the source holds the actual watch state)."""
        self._source.open_watch(after_sequence_number)
        return String(after_sequence_number)

    def poll(mut self, cursor: String) raises -> ChangeBatch:
        """Drain the source's ListenEvents, map each to a ChangeRecord, and thread
        the (read_time, resume_token) cursor from the batch's resumable
        TargetChange.

        Firestore delivers a run of DocumentChange/Delete/Remove events terminated
        by a resumable TargetChange (NO_CHANGE / CURRENT) that carries the
        consistent read_time + resume_token. EVERY record in the batch is stamped
        with that read_time's normalized sequence, and next_cursor encodes the
        pair — so on resume the watch re-opens AFTER that snapshot and the apply's
        idempotence skip drops any re-delivered record at that read_time.

        THE WATERMARK INVARIANT (why the batch-collapse + bare-read_time checkpoint
        is exactly-once safe). Firestore's Listen `read_time` is a CONSISTENT-
        SNAPSHOT WATERMARK, guaranteed by the public google.firestore.v1 contract:
          * "The stream is guaranteed to send a `read_time` ... whenever the entire
            stream reaches a new consistent snapshot." A TargetChange read_time=T
            means the target reflects ALL changes committed at or before T.
          * "For a given stream, `read_time` is guaranteed to be monotonically
            increasing." So read_time never repeats across DISTINCT consistent
            snapshots — it only advances.
          * Target.resume_token / Target.read_time RESUME semantics: "Start
            listening AFTER a specific `read_time`." A resume at T re-delivers only
            changes with read_time > T (and possibly re-delivers changes AT the
            snapshot boundary as duplicates, never a NEW change stamped <= T).
        Consequence: a WHOLE Listen batch legitimately collapses to ONE
        read_time_to_sequence(T) with NO intra-batch tiebreak, and the durable
        checkpoint is the bare read_time sequence. A DISTINCT NEW change can NEVER
        carry read_time <= a committed watermark T (that would violate the
        consistent-snapshot completeness of T). So any record arriving on resume
        stamped sequence == committed T can ONLY be a re-delivered duplicate of a
        change already captured in the T-snapshot — safe to drop via the strict-`>`
        idempotence guard a consumer applies. This is why the resume_token is a
        same-session convenience, not crash-critical: the read_time watermark alone
        is a sound, gap-free resume position. (Verified against the
        public firestore.proto TargetChange.read_time / Target.read_time comments.)

        If the drained batch carries NO resumable TargetChange (an idle poll, or a
        partial snapshot not yet CURRENT), the records are held with the INCOMING
        `cursor` re-threaded (no position advance) — a live-but-idle poll — so the
        driver keeps polling from the same point and never commits an un-checkpointed
        partial snapshot as a new position. An empty drain -> empty_live(cursor)."""
        var events = self._source.drain()

        # Find the batch's resumable TargetChange (the checkpoint boundary): the
        # LAST resumable TargetChange in the drained run (the most-advanced
        # snapshot). Its read_time is the batch sequence; its (read_time,
        # resume_token) is the next cursor.
        var have_boundary = False
        var boundary_seconds = Int64(0)
        var boundary_nanos = Int64(0)
        var boundary_token = List[UInt8]()
        for i in range(len(events)):
            ref ev = events[i]
            if (
                ev.kind == LE_TARGET_CHANGE
                and ev.has_resume_token
                and ev.has_read_time
            ):
                have_boundary = True
                boundary_seconds = ev.read_time_seconds
                boundary_nanos = ev.read_time_nanos
                boundary_token = List[UInt8]()
                for k in range(len(ev.resume_token)):
                    boundary_token.append(ev.resume_token[k])

        # No checkpoint boundary this drain: hold position, keep polling. (An
        # empty drain is also this case.)
        if not have_boundary:
            return ChangeBatch.empty_live(String(cursor))

        var batch_seq = read_time_to_sequence(boundary_seconds, boundary_nanos)
        var next_cursor = encode_firestore_cursor(
            boundary_seconds, boundary_nanos, boundary_token
        )

        # Map each document event to a ChangeRecord stamped with the batch seq.
        var records = List[ChangeRecord]()
        for i in range(len(events)):
            ref ev = events[i]
            if ev.kind == LE_DOCUMENT_CHANGE:
                records.append(
                    self._document_change_to_modify(ev, String(batch_seq))
                )
            elif ev.kind == LE_DOCUMENT_DELETE or ev.kind == LE_DOCUMENT_REMOVE:
                records.append(
                    self._document_delete_to_remove(ev, String(batch_seq))
                )
            # TARGET_CHANGE / UNKNOWN -> not a data change, skip.
        return ChangeBatch(records^, next_cursor^, False)

    # ----- per-event mapping -------------------------------------------------
    def _document_change_to_modify(
        self, ev: ListenEvent, var sequence: String
    ) raises -> ChangeRecord:
        """A DocumentChange -> a MODIFY ChangeRecord (decision #3). The key,
        old_image, and new_image are FULL-SCHEMA-WIDTH positional rows; the key
        column is injected from the document id (the last resource-name segment).

        Firestore does NOT send the before-state, so the `old_image` is the
        full-width KEY row (the doc id in the key column, NULLs elsewhere) — the
        equality-delete only needs the KEY columns, which a consumer reads
        positionally from this full-width old_image, and the MODIFY invariant
        (non-empty old_image) is satisfied. The equality-delete masks any PRIOR
        generation of this key; this commit's fresh new_image append survives (the
        upsert semantics)."""
        var doc_id = _extract_document_id(ev.document.name)
        var key = self._build_key_row(doc_id)
        var old_image = self._build_key_row(doc_id)
        var new_image = self._build_full_image(doc_id, ev.document.fields)
        return make_modify_record(key^, old_image^, new_image^, sequence^)

    def _document_delete_to_remove(
        self, ev: ListenEvent, var sequence: String
    ) raises -> ChangeRecord:
        """A DocumentDelete / DocumentRemove -> a REMOVE ChangeRecord. Both the
        `key` and the `old_image` are the SAME full-schema-width tuple built from
        the doc id — a Firestore delete carries only the resource name (no
        before-state), so the full-width key row IS the old_image the apply's
        equality-delete needs (make_remove_record requires a non-empty old_image,
        and a consumer positions the key columns from this full-width row)."""
        var doc_id = _extract_document_id(ev.document.name)
        var key = self._build_key_row(doc_id)
        var old_image = self._build_key_row(doc_id)
        return make_remove_record(key^, old_image^, sequence^)

    def _build_key_row(self, doc_id: String) raises -> List[RowCell]:
        """A FULL-SCHEMA-WIDTH positional row where the key column holds `doc_id`
        (a STRING cell) and every other column is NULL. A consumer positions the
        equality-delete key columns from this full-width row.
        """
        var out = List[RowCell]()
        for i in range(len(self._config.column_names)):
            if self._config.column_names[i] == self._config.key_column:
                out.append(make_string_cell(String(doc_id)))
            else:
                out.append(make_null_cell(CELL_T_STRING))
        return out^

    def _build_full_image(
        self, doc_id: String, fields: FsValue
    ) raises -> List[RowCell]:
        """A FULL-SCHEMA-WIDTH positional row: the key column holds `doc_id`; each
        other column is projected from the document `fields` (NULL-filled if
        absent). The document id is NOT a field (it's the resource-name segment),
        so it is injected into the key column; a value column that happens to
        share the key column's name still gets the doc id (the key IS the id)."""
        var out = List[RowCell]()
        for i in range(len(self._config.column_names)):
            var name = self._config.column_names[i]
            if name == self._config.key_column:
                out.append(make_string_cell(String(doc_id)))
            elif fields.map_has(name):
                out.append(fs_value_to_row_cell(fields.map_get(name)))
            else:
                out.append(make_null_cell(CELL_T_STRING))
        return out^


# =============================================================================
# §5 — document-id extraction.
# =============================================================================


def _extract_document_id(resource_name: String) raises -> String:
    """The document id = the LAST '/'-separated segment of a Firestore resource
    name `projects/{p}/databases/{d}/documents/{coll}/{id}` (or a deeper subcoll
    path — the id is always the trailing segment).

    A malformed name that yields an EMPTY id (an empty resource name, or one
    ending in '/') is REJECTED with a raise — NOT silently mapped to an empty-
    string id. An empty-string primary key would equality-COLLIDE with every OTHER
    malformed doc (they'd all share PK ""), so a same-batch equality-delete would
    mask the WRONG rows (a silent data-corruption class, same family as FF-1). Fail
    loud instead: a malformed push aborts the batch rather than corrupting the
    table with a colliding empty PK."""
    var rb = resource_name.as_bytes()
    var n = len(rb)
    var last_slash = -1
    for i in range(n):
        if rb[i] == UInt8(ord("/")):
            last_slash = i
    # `/` is ASCII, so the cut is a char boundary: the id's UTF-8 bytes as they are.
    var out = String(resource_name[byte=last_slash + 1 : n])
    if out.byte_length() == 0:
        raise Error(
            "firestore CDC: DocumentChange/Delete has an empty (id-less) resource"
            " name '"
            + resource_name
            + "' — cannot derive a primary key (an empty-string PK would"
            " equality-collide with other malformed docs and mask the wrong rows)"
        )
    return out^
