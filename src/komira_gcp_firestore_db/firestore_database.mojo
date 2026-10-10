# =============================================================================
# komira_gcp_firestore_db/firestore_database.mojo — FirestoreDatabase[C, S]:
#   the neutral `Database` trait's ops implemented NATIVELY on Firestore.
# =============================================================================
#
# WHAT THIS IS. A GENUINE conformer of the backend-NEUTRAL `komira_db.Database`
# trait (the tx verbs + the 9 STRUCTURED ops — get_by_key / put / delete_by_key /
# query_rows / conditional_update / delete_where / create_if_absent / claim_rows)
# realized on Firestore DOCUMENT primitives, NOT SQL. It owns a moved-in
# `FirestoreClient[C, S]` (single owner). Parametric over the client's
# connector `C` (TLS in production, a `MockFirestoreConnector` in a test) and
# its token source `S`.
#
# THE PAYOFF. A store written as `Store[DB: Database]` touches ONLY the neutral
# ops + begin/commit/rollback, so `Store[FirestoreDatabase[T]]` runs the EXACT
# SAME store source that runs on `Store[SqliteDatabase]` / `Store[PgDatabase]` —
# the SQL is rendered inside the SQL drivers' op impls; here the SAME ops are
# Firestore document ops.
#
# ---------------------------------------------------------------------------------
# THE 9-OP MAPPING (each neutral op -> a Firestore document primitive), GENERIC
# over `(table=collection, cols, DbValue)` so it works for ANY DbStorable:
#
#   begin / commit / rollback -> NO-OP on the wire. Each op this driver sends is
#     ONE document write (a Commit carrying one write) and it opens no Firestore
#     transaction, so a multi-statement tx is not expressed. The contract: each op is individually
#     atomic (a single-doc create / CAS / delete), and a store that writes two
#     documents for one logical change (a row plus its dedup key, say) orders
#     the writes so the load-bearing state lands first. `begin` / `rollback`
#     journal and compensate creates (see the write journal below).
#
#   get_by_key(table, cols, key_col, key)   -> get_document(collection=table,
#     doc-id = key.as_text()); typed not-found -> None; decode the doc -> a
#     projected DbRow.
#
#   put(table, cols, vals)                   -> create_document(collection=table,
#     doc-id = the PK value from (cols, vals), fields = encode(cols, vals)).
#     Returns 1 (rows_affected).
#
#   delete_by_key(table, key_col, key)       -> delete_document (typed not-found
#     swallowed -> 0).
#
#   query_rows(table, cols, Filter, order, limit) -> run_query(structuredQuery
#     built from the Filter/Order/limit: EQ/LT/IS_NULL/IS_NOT_NULL, single AND-group;
#     the OR-union case is handled by the STORE issuing two query_rows). Decode each
#     result doc -> a projected DbRow.
#
#   conditional_update(table, guard, updates, coalesce, bump_version_col, now_cols)
#     -> an `UPDATE <table> SET ... WHERE <guard>`, in TWO arms.
#     (a) THE PK ARM — the guard names the table's PK: read the doc by its id,
#     evaluate the guard (id/phase/version) CLIENT-SIDE, then
#     update_if_unchanged(expectedUpdateTime = the read-back updateTime) applying
#     the updates (+ bump version, + stamp now_cols with a client-side wall-clock
#     micros). A guard mismatch OR a FAILED_PRECONDITION (a racer moved the doc
#     between our read + write) -> rows_affected 0 (the store then reports a
#     concurrent modification). A read + pre-check + `_cas_write`, and it issues
#     NO query.
#     (b) THE MULTI-ROW ARM — no PK pred: push the guard's EQ preds to a
#     structuredQuery, evaluate the FULL guard client-side per candidate, and CAS
#     EACH matching doc on its OWN updateTime, CHUNKED at <= FS_DB_BATCH_MAX.
#     Returns the number of docs actually committed. (An earlier version of this
#     arm resolved AT MOST ONE doc, `WHERE <first EQ col> == $ LIMIT 1`, so a
#     revoke-all-sessions update revoked one arbitrary session of N.)
#
#   delete_where(table, Filter)              -> run_query + per-doc delete, CHUNKED
#     at <= FS_DB_BATCH_MAX (Firestore has no server-side range delete).
#
#   create_if_absent(table, unique_col, unique_val, cols, vals) -> the atomic
#     conditional-create on the unique-key doc-id (currentDocument.exists=false);
#     ALREADY_EXISTS -> False (we lost the key); else True (we won): an
#     idempotency-key create, generic over the table.
#
#   claim_rows(table, n, filter, order, phase_col, from_phase, to_phase, extra,
#     per_row_mint, bump_version_col, now_cols) -> THE b1 CLAIM LOOP, VERBATIM:
#     run_query WHERE phase_col == from_phase ORDER BY created_at ASC LIMIT n, then
#     per-doc update_if_unchanged(from_phase->to_phase + extra + version bump +
#     now_cols + pod_name via per_row_mint) guarded on the doc's updateTime; skip
#     on FAILED_PRECONDITION (the SKIP-LOCKED skip); collect the winners into a
#     DbRows. AT-MOST-ONCE per doc (the claiming loop is assumed to be a single
#     writer; even a doubled loop needs only at-most-once per row).
#
# ---------------------------------------------------------------------------------
# THE DbValue<->DOCUMENT ENCODER. A `DbValue` carries a LOGICAL type tag + a NULL flag +
# ONE canonical `_text` String (db_value.mojo). The encoder maps each DbValue to a
# Firestore field:
#   * is_null                          -> {"nullValue":null}
#   * LOGICAL_INT4 / INT8 / TIMESTAMPTZ -> {"integerValue":"<decimal>"} (so the
#     mock's LESS_THAN inequality evaluates on timestamps + `DbRow.get_int8` /
#     `get_timestamptz` parse the decimal back)
#   * everything else (TEXT / UUID / JSONB / BOOL / TEXT_ARRAY / FLOAT)
#                                      -> {"stringValue":"<canonical text>"} (the
#     as_text() form; `DbRow.get_text` / `get_uuid` / `get_jsonb` /
#     `get_text_array` parse it back verbatim)
# The DECODER inverts it: read each projected column's typed field into the column's
# canonical text (+ null flag), then `DbRow.from_values` re-surfaces the flat DbRow
# a `DbStorable.from_row` decodes. The DbRow getters (get_text / get_int8 /
# get_uuid / ...) parse the canonical text regardless of the stored logical tag, so
# the round-trip is exact for every column type.
#
# DOC-ID = the PK value's canonical text (a UUID renders hyphenated-lowercase;
# a Firestore-legal doc-id — no `/`, not reserved). The idempotency-key doc-id is the
# (percent-encoded) client key. So get_by_key / conditional_update address the doc
# directly by its PK, and create_if_absent keys the doc on the unique value.
#
# ENCAPSULATION. The surface is the `Database` trait's String /
# List[DbValue] / structured value types in, DbRow / DbRows / typed scalar out —
# ZERO UnsafePointer crosses any boundary; no wildcard origin; no
# unsafe_from_address. The interior is a moved-in `FirestoreClient[T]` (single
# owner) + owned String collection config. No byte-slab, no wildcard, no
# heap-owning-inner-in-a-slab field. `def`-based, Mojo 1.0.0b2.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_clock import now_unix_ms

from komira_db import (
    Database,
    DbValue,
    DbRow,
    DbRows,
    Pred,
    Filter,
    Order,
    DbColVal,
    PodNameMinter,
    derive_pod_name,
    PRED_EQ,
    PRED_LT,
    PRED_LE,
    PRED_GTE,
    PRED_IS_NULL,
    PRED_IS_NOT_NULL,
    PRED_JSON_KEY_EQ,
    PRED_IN,
    PRED_ARRAY_CONTAINS,
    PRED_NE,
    COMBINE_AND,
    COMBINE_OR,
    COLVAL_BIND,
    COLVAL_RAW_EXPR,
    classify_raw_expr,
    raw_expr_refusal,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_BYTES,
    LOGICAL_TIMESTAMPTZ,
    LOGICAL_TEXT_ARRAY,
    generate_uuidv7,
)

from komira_encoding.base64 import base64_encode, base64_decode

# THE UNDECLARED-COMPOSITE-INDEX GUARD (sibling module, same package). Sits at
# `_build_structured_query` — see that function's docstring for why that is the
# only site that sees the true wire shape.
from komira_gcp_firestore_db.firestore_index_guard import (
    DeclaredIndexSet,
    require_declared_index,
)

# COLVAL_COALESCE is not re-exported from the `komira_db` facade (only
# COLVAL_BIND / COLVAL_RAW_EXPR are); import it directly from the module.
from komira_db.neutral_ops import COLVAL_COALESCE

from komira_gcp_firestore.firestore_value import (
    fs_json_quote as _fs_json_quote,
    FsValue,
    FS_T_INTEGER,
    FS_T_NULL,
    FS_T_BYTES,
    FS_T_ARRAY,
)
from komira_http_core.transport.io_stream import Connector
from komira_gcp_core import GcpTokenSource

from komira_gcp_firestore.firestore_client import (
    FirestoreClient,
    FixedBearer,
    FirestoreDocument,
    is_not_found_error,
    is_already_exists_error,
    is_precondition_failed_error,
)


# =============================================================================
# §0 — the Firestore BatchWrite server cap: a `:commit` / batchWrite carries AT
# MOST 500 writes. delete_where deletes one doc per call but CHUNKS at this
# cap so a single call never attempts a >500-doc unit of work.
# =============================================================================
comptime FS_DB_BATCH_MAX: Int = 500


# =============================================================================
# §1 — FirestoreDatabase[T] — the neutral `Database` conformer over Firestore.
# =============================================================================
struct FirestoreDatabase[
    C: Connector, S: GcpTokenSource = FixedBearer
](
    Database, Movable, Deinitable
):
    """A GENUINE `komira_db.Database` conformer implemented on Firestore document
    ops (get / create / patch / delete / conditional-create + updateTime-CAS
    / runQuery). Owns a moved-in `FirestoreClient[T]` (single owner). The 9 neutral
    ops map onto Firestore primitives (see the module header); begin/commit/rollback
    journal and compensate creates (single-write backend). This is what lets a
    `Store[FirestoreDatabase[T]]` run the SAME store source as
    `Store[SqliteDatabase]`.

    ENCAPSULATION: the `Database` trait surface (String / List[DbValue] / structured
    types in; DbRow / DbRows / typed scalar out). Owns the client by value; NO raw
    pointer field."""

    var _client: FirestoreClient[Self.C, Self.S]
    # A monotone client-minted suffix for the claim pod_name mint (unique per claim).
    var _next_suffix: Int
    # THE COMPENSATING-ROLLBACK WRITE JOURNAL. Each write is its own one-write
    # Commit — a multi-statement `begin ... commit/rollback` transaction is not
    # expressed.
    # A dedup create is `begin -> put(row) -> create_if_absent(key)
    # -> (won ? commit : rollback)`; on a real tx the `rollback` un-does the row
    # INSERT, but Firestore has no rollback. So `begin` starts JOURNALING every
    # doc-create this DB does, `commit` DISCARDS the journal (the writes stand), and
    # `rollback` COMPENSATES by DELETING each journaled doc — reproducing the SQL
    # rollback's effect (delete the orphan row doc on a dedup loss), driven by
    # the store's own begin/commit/rollback calls. Two flat `List[String]`
    # journals + a Bool flag.
    var _in_tx: Bool
    var _journal_collections: List[String]
    var _journal_doc_ids: List[String]
    # THE COMPOSITE INDEXES THIS DRIVER HAS BEEN TOLD EXIST. Every structuredQuery
    # this DB builds is checked against it: a shape Firestore cannot serve off its
    # automatic single-field indexes, and that no entry here covers, is REFUSED at
    # build time instead of being sent to the cloud to come back 500
    # FAILED_PRECONDITION. An EMPTY set is not a disabled guard — it means nothing
    # is declared, so every composite-requiring shape is refused. See
    # `firestore_index_guard.mojo` for the rule and what it does not claim.
    var _declared_indexes: DeclaredIndexSet
    # THE KEY COLUMN OF EACH TABLE (`TableKeys`): which column's value names a
    # table's documents. Undeclared tables are keyed on `id`.
    var _table_keys: TableKeys

    def __init__(out self, var client: FirestoreClient[Self.C, Self.S]):
        """Construct over a moved-in `FirestoreClient[T]` with NO declared
        composite indexes: every query shape Firestore cannot serve off its
        automatic single-field indexes is refused, naming the collection, the
        shape and the index that would serve it, instead of reaching Firestore
        and coming back FAILED_PRECONDITION.

        Pass a `DeclaredIndexSet` (the two-argument form) for a database whose
        composite indexes are declared; that is the form a service should use.

        Declares NO table keys either: every table is keyed on `id` until a
        `TableKeys` is passed (the three-argument form)."""
        self._client = client^
        self._next_suffix = 1
        self._in_tx = False
        self._journal_collections = List[String]()
        self._journal_doc_ids = List[String]()
        self._declared_indexes = DeclaredIndexSet()
        self._table_keys = TableKeys()

    def __init__(
        out self,
        var client: FirestoreClient[Self.C, Self.S],
        var declared_indexes: DeclaredIndexSet,
    ):
        """Construct over a moved-in client AND the composite indexes that have
        been declared for this database. This is the form a service should use:
        the declaration is what makes an ordered / range query legal, and stating
        it at the point the handle is built is what makes the omission visible.

        Declares NO table keys: every table is keyed on `id`. A database whose
        tables are keyed on another column (`owner_id`, `email`, ...) must use the
        three-argument form; under this one such a table's documents are named
        by its `id` column, or by a minted id when the projection has none."""
        self._client = client^
        self._next_suffix = 1
        self._in_tx = False
        self._journal_collections = List[String]()
        self._journal_doc_ids = List[String]()
        self._declared_indexes = declared_indexes^
        self._table_keys = TableKeys()

    def __init__(
        out self,
        var client: FirestoreClient[Self.C, Self.S],
        var declared_indexes: DeclaredIndexSet,
        var table_keys: TableKeys,
    ):
        """Construct over a moved-in client, the composite indexes declared for
        this database, and the key column of every table whose documents are
        not keyed on `id` (see `TableKeys`)."""
        self._client = client^
        self._next_suffix = 1
        self._in_tx = False
        self._journal_collections = List[String]()
        self._journal_doc_ids = List[String]()
        self._declared_indexes = declared_indexes^
        self._table_keys = table_keys^

    def _journal_write(mut self, collection: String, doc_id: String):
        """Record a doc-create so a later `rollback` can compensate it (delete it).
        A no-op outside a tx (a create with no surrounding begin stands on its own)."""
        if self._in_tx:
            self._journal_collections.append(String(collection))
            self._journal_doc_ids.append(String(doc_id))

    def client_ref(ref self) -> ref [self._client] FirestoreClient[Self.C, Self.S]:
        """Borrow the underlying client. A reference rooted at `self._client`,
        never a raw pointer."""
        return self._client

    # =========================================================================
    # tx verbs — COMPENSATING (each write is its own one-write Commit; no
    # multi-statement tx). `begin` starts JOURNALING doc-creates; `commit` DISCARDS the journal (the
    # writes stand); `rollback` DELETES each journaled doc (the compensating undo).
    # A dedup create calls begin/put/create_if_absent/rollback — the rollback
    # deletes the orphan row doc, reproducing the SQL rollback's effect. Each
    # Firestore write is individually atomic; the compensating rollback closes the
    # 2-doc dedup window.
    # =========================================================================
    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        _ = reactor
        self._in_tx = True
        self._journal_collections = List[String]()
        self._journal_doc_ids = List[String]()

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        _ = reactor
        # The writes committed atomically one-by-one already; just close the tx +
        # discard the journal (the writes STAND).
        self._in_tx = False
        self._journal_collections = List[String]()
        self._journal_doc_ids = List[String]()

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        _ = reactor
        # Compensate: DELETE each doc created since `begin` (undo the uncommitted
        # writes — the SQL rollback's effect). Best-effort per doc (a 404 is fine —
        # the doc may already be gone). Snapshot the journal first (the delete does
        # not itself re-journal — _in_tx is cleared up front).
        self._in_tx = False
        var cols = self._journal_collections.copy()
        var ids = self._journal_doc_ids.copy()
        self._journal_collections = List[String]()
        self._journal_doc_ids = List[String]()
        for i in range(len(ids)):
            _ = self._best_effort_delete(String(cols[i]), String(ids[i]))

    # =========================================================================
    # 1. get_by_key -> get_document (doc-id = key.as_text()) when key_col IS the
    #    table's PK; else a single-field-equality query (WHERE key_col == key LIMIT
    #    1). The doc is ONLY addressable by its doc-id (= the PK value), so a lookup
    #    by a NON-PK column (a `users` row by `email`, an `api_keys` row by
    #    `key_hash`, an `invites` row by `token_hash`, ...) must query the
    #    field, NOT GET a doc named after the lookup value. Firestore auto-indexes
    #    every single field, so a one-field equality query needs no composite index.
    # =========================================================================
    def get_by_key[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        key_col: String,
        key_val: DbValue,
    ) raises -> Optional[DbRow]:
        _ = reactor
        if _key_is_pk(self._table_keys, table, key_col):
            # The doc IS keyed by the PK value -> a direct GET (the fast path).
            var doc_opt = self._get_doc_opt(table, _doc_id_for(key_val))
            if not doc_opt:
                return Optional[DbRow]()
            return Optional[DbRow](_doc_to_row(doc_opt.take(), cols))
        # A non-PK lookup key -> a single-field-equality query. The doc-id is the PK
        # value (not the lookup value), so we cannot GET it by name; find it by field.
        var doc_opt = self._query_one_doc(table, key_col, key_val)
        if not doc_opt:
            return Optional[DbRow]()
        return Optional[DbRow](_doc_to_row(doc_opt.take(), cols))

    # =========================================================================
    # 2. put -> create_document (doc-id = the PK value in (cols, vals)).
    # =========================================================================
    def put[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> UInt64:
        _ = reactor
        var pk = _pk_index(self._table_keys, table, cols)
        if pk < 0:
            _refuse_minted_doc_id_for_declared_table(
                self._table_keys, table, cols
            )
        # PK-less projection (an append-only ledger whose SERIAL id is
        # server-assigned + NOT in the projected cols): mint a fresh UUIDv7 doc-id (append-only forensic ledger,
        # one doc per row). Else the doc-id is the PK value's canonical text.
        var doc_id = (
            generate_uuidv7().to_hyphenated()
            if pk < 0
            else _doc_id_for(vals[pk])
        )
        var fields = _encode_fields(cols, vals)
        var _doc = self._client.create_document(table, doc=doc_id, fields=fields^)
        self._journal_write(table, doc_id)  # for a compensating rollback (dedup loss)
        return UInt64(1)

    # =========================================================================
    # 3. delete_by_key -> delete_document (404 swallowed -> 0) when key_col IS the
    #    PK; else find the doc by a single-field-equality query, then delete it by
    #    its real doc-id (the PK value). Mirrors get_by_key's key_col-aware routing:
    #    a delete keyed on a NON-PK column (mail_account by `address`) must locate
    #    the doc by field, NOT delete a doc named after the lookup value.
    # =========================================================================
    def delete_by_key[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        key_col: String,
        key_val: DbValue,
    ) raises -> UInt64:
        _ = reactor
        if _key_is_pk(self._table_keys, table, key_col):
            return self._best_effort_delete(table, _doc_id_for(key_val))
        # A non-PK lookup key -> find the doc by field, delete it by its real doc-id.
        var doc_opt = self._query_one_doc(table, key_col, key_val)
        if not doc_opt:
            return UInt64(0)  # no matching row
        return self._best_effort_delete(
            table, _last_name_segment(doc_opt.take().name)
        )

    # =========================================================================
    # 4. query_rows -> run_query(structuredQuery from Filter/Order/limit).
    # =========================================================================
    def query_rows[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
        limit: Optional[UInt32],
    ) raises -> DbRows:
        _ = reactor
        # An IN predicate rides on `filter` (e.g. a `status IN
        # (PROVISIONING, ACTIVE)` dedup read). Firestore's native `in` operator
        # caps at <=10 values; for a bigger set (or to stay backend-uniform under
        # the mock's EQ/NOT_EQ/LT evaluator) we LOAD the candidate rows (the non-IN
        # preds pushed to the structured query) + FILTER the IN preds in Mojo —
        # the "load candidates, filter in Mojo" pattern. Split
        # the filter into a pushed part (no IN preds) + the IN preds evaluated
        # here. When there are no IN preds this is byte-identical to before (the
        # pushed filter == the full filter, `in_preds` empty).
        var pushed = _filter_without_in(filter)
        var in_preds = _in_preds_of(filter)
        var q = _build_structured_query(
            table, pushed, order, limit, self._declared_indexes
        )
        var docs = self._client.run_query(q^)
        var rows = List[DbRow]()
        var lim = Int(limit.value()) if limit else -1
        for i in range(len(docs)):
            if lim >= 0 and len(rows) >= lim:
                break  # belt-and-suspenders LIMIT (a mock that ignores it still caps)
            if not _doc_matches_in_preds(docs[i], in_preds):
                continue  # the load-and-filter IN evaluation, in Mojo
            rows.append(_doc_to_row(docs[i], cols))
        return DbRows(rows^, cols.copy())

    def query_rows_locked[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
    ) raises -> DbRows:
        """The concurrent-SCAN read on Firestore: IGNORE the row-lock hint (there
        is no Firestore `FOR UPDATE SKIP LOCKED` — the SAME single-writer property
        sqlite/pgstore rely on to omit it covers a single-writer scan loop) and
        delegate to `query_rows` with NO limit."""
        return self.query_rows[RT](
            reactor, table, cols, filter, order, Optional[UInt32]()
        )

    # =========================================================================
    # 5. conditional_update -> read + evaluate guard + update_if_unchanged.
    # =========================================================================
    def conditional_update[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        guard: Filter,
        updates: List[DbColVal],
        coalesce: Bool,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> UInt64:
        _ = reactor
        # ---------------------------------------------------------------------
        # (a) THE PK FAST PATH — the guard has an EQ pred on the table's PK
        #     column, so the doc-id IS that value: a direct GET + one CAS
        #     (`id=$`, or a declared key such as `owner_id=$`). NO query is
        #     issued; a point update must not become a collection query.
        # ---------------------------------------------------------------------
        var pk_val_opt = _pk_pred_value(self._table_keys, guard, table)
        if pk_val_opt:
            var pk_doc_id = _doc_id_for(pk_val_opt.value())
            var pk_doc_opt = self._get_doc_opt(table, pk_doc_id)
            if not pk_doc_opt:
                return UInt64(0)  # the doc does not exist -> nothing updated
            var pk_doc = pk_doc_opt.take()
            if not _guard_matches(pk_doc, guard):
                return UInt64(0)  # a phase/version mismatch — the pre-check fails
            var pk_fields = _apply_updates(
                pk_doc, updates, coalesce, bump_version_col, now_cols, _now_micros()
            )
            var pk_committed = self._cas_write(
                table, pk_doc_id, pk_fields^, String(pk_doc.update_time)
            )
            return UInt64(1) if pk_committed else UInt64(0)
        # ---------------------------------------------------------------------
        # (b) THE MULTI-ROW PATH — an `UPDATE <table> SET ... WHERE <guard>`.
        #
        # ⛔ EVERY DOCUMENT THE GUARD MATCHES IS UPDATED, as on every SQL
        # backend. Resolving only one (a `LIMIT 1` on the first equality, the
        # rest of the guard checked against whichever document Firestore's
        # implicit `__name__ ASC` returned first) would stamp an arbitrary
        # subset: a per-row flag lands on zero rows, a revoke-all revokes one
        # session of N, and two lease acquirers can CAS different documents
        # and both believe they hold the lease.
        #
        # THE SHAPE IS `delete_where`'s (58 lines below), for the same reasons:
        # push the filter, `run_query`, iterate, chunk at FS_DB_BATCH_MAX.
        #
        # ⚠ ONLY THE **EQ** PREDS ARE PUSHED, and the choice is load-bearing:
        #   * MULTIPLE EQUALITIES with no ordering and no range are served off
        #     Firestore's AUTOMATIC single-field indexes (the zigzag merge join),
        #     so pushing them all needs NO declared composite index and cannot
        #     turn a working CAS into a live FAILED_PRECONDITION. Pushing a range
        #     or a NOT_EQUAL ALONGSIDE an equality would require one — see
        #     `firestore_index_guard.mojo`.
        #   * A Firestore `NOT_EQUAL` fieldFilter EXCLUDES documents that do not
        #     carry the field, which is exactly the population a PRED_NE guard
        #     exists to reach (see `_guard_matches`).
        # Acceptance is UNCHANGED by pushing more of them: a doc lacking a guard
        # EQ column was rejected client-side before (an absent field fails
        # PRED_EQ) and is filtered server-side now — same verdict, less wire.
        #
        # EVERY predicate is still evaluated CLIENT-SIDE against each candidate,
        # so the pushed filter is an optimisation and never the authority.
        # ---------------------------------------------------------------------
        var pushed = _pushable_eq_filter(guard)
        if len(pushed.preds) == 0:
            # No EQ pred at all. REFUSE rather than scan the collection: a guard
            # made only of ranges would otherwise read every document in the
            # table.
            return UInt64(0)
        var q = _build_structured_query(
            table,
            pushed,
            List[Order](),
            Optional[UInt32](),
            self._declared_indexes,
        )
        var docs = self._client.run_query(q^)
        # ONE clock reading for the whole statement, not one per document — SQL's
        # `now()` is stable within a statement, and rows written by a single
        # `UPDATE ... WHERE` must not carry timestamps that disagree.
        var stmt_now = _now_micros()
        var updated = UInt64(0)
        var attempted = 0
        for i in range(len(docs)):
            if attempted >= FS_DB_BATCH_MAX:
                break  # CHUNK cap — never attempt a >500-doc unit of work
            if not _guard_matches(docs[i], guard):
                continue  # the CAS pre-check, per candidate document
            attempted += 1
            # PER-DOCUMENT CAS on THAT document's own observed updateTime. A
            # blind multi-doc write would not be safe under concurrency: a racer
            # that moved one row must lose that row and only that row.
            var fields = _apply_updates(
                docs[i], updates, coalesce, bump_version_col, now_cols, stmt_now
            )
            if self._cas_write(
                table,
                _last_name_segment(docs[i].name),
                fields^,
                String(docs[i].update_time),
            ):
                updated += 1
        return updated

    # =========================================================================
    # 6. delete_where -> run_query + per-doc delete, CHUNKED at <= FS_DB_BATCH_MAX.
    # =========================================================================
    def delete_where[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        filter: Filter,
    ) raises -> UInt64:
        _ = reactor
        # SPLIT the filter EXACTLY as query_rows does: an IN predicate (PRED_IN, op
        # 6) has NO single-field Firestore fieldFilter analog here — pushing it to
        # `_build_structured_query` raises "unsupported predicate op 6" (a live
        # cascade-delete failure: a parent delete removes child rows scoped by
        # `parent_id IN (<the parent's ids>)`). So push the NON-IN preds to the structured
        # query + evaluate the IN preds CLIENT-SIDE against each returned candidate
        # doc before deleting it — the "load candidates, filter in Mojo"
        # pattern, identical to query_rows. When there are no IN preds this is
        # byte-identical to before (pushed == filter, in_preds empty).
        var pushed = _filter_without_in(filter)
        var in_preds = _in_preds_of(filter)
        var q = _build_structured_query(
            table,
            pushed,
            List[Order](),
            Optional[UInt32](),
            self._declared_indexes,
        )
        var docs = self._client.run_query(q^)
        var deleted = UInt64(0)
        for i in range(len(docs)):
            if Int(deleted) >= FS_DB_BATCH_MAX:
                break  # CHUNK cap — never attempt a >500-doc unit of work
            if not _doc_matches_in_preds(docs[i], in_preds):
                continue  # the load-and-filter IN evaluation, in Mojo
            var doc_id = _last_name_segment(docs[i].name)
            _ = self._best_effort_delete(String(table), doc_id)
            deleted += 1
        return deleted

    # =========================================================================
    # 7. create_if_absent -> atomic conditional-create on the unique-key doc-id.
    # =========================================================================
    def create_if_absent[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        unique_col: String,
        unique_val: DbValue,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        _ = reactor
        # THE DOC-ID = the table's PK value (so get_by_key / conditional_update /
        # delete_by_key — which all address the doc by its PK — find the row this
        # created). The dedup key (`unique_col`) may be a DIFFERENT column than the
        # PK (e.g. `notifications` / `push_devices`: PK=`id`, dedup=`dedupe_key`);
        # keying the doc on the dedup value would strand it from the PK-addressed
        # ops. Two arms:
        #   (a) unique_col IS the PK (an `idempotency_keys.key`, or a table
        #       whose PK == the dedup column): the doc-id IS the unique value, and
        #       `create_if_absent` (currentDocument.exists=false) rejects a second
        #       live create ATOMICALLY (409 ALREADY_EXISTS -> False, we lost).
        #   (b) unique_col is a NON-PK column (notifications / push_devices): the
        #       doc-id is the PK value; dedup is enforced by a snapshot-read query
        #       on `unique_col == unique_val` before the plain create. This is the
        #       SAME non-atomic snapshot-read + insert the pgstore arm uses
        #       (_create_if_absent_pgstore); safe under a single-writer
        #       contract.
        var pk = _pk_index(self._table_keys, table, cols)
        var pk_is_unique = pk >= 0 and cols[pk] == unique_col
        var fields = _encode_fields(cols, vals)
        if pk < 0 or pk_is_unique:
            # ARM (a): the atomic doc-id=unique_val exists-check.
            var doc_id = _encode_doc_id_part(_doc_id_for(unique_val))
            try:
                var _res = self._client.create_if_absent(table, doc_id, fields^)
                self._journal_write(table, doc_id)  # won -> a later rollback compensates
                return True  # we won the key
            except e:
                if is_already_exists_error(String(e)):
                    return False  # a prior create already claimed the key
                raise e^
        # ARM (b): PK-keyed doc + a snapshot-read dedup query on unique_col.
        var probe = _build_structured_query(
            table,
            Filter.just(Pred.eq(String(unique_col), unique_val.copy())),
            List[Order](),
            Optional[UInt32](UInt32(1)),
            self._declared_indexes,
        )
        var existing = self._client.run_query(probe^)
        if len(existing) > 0:
            return False  # a row with this unique value is already present (we lost)
        var pk_doc_id = _encode_doc_id_part(_doc_id_for(vals[pk]))
        var _doc = self._client.create_document(table, doc=pk_doc_id, fields=fields^)
        self._journal_write(table, pk_doc_id)  # won -> a later rollback compensates
        return True  # we won the key

    # =========================================================================
    # 7b. create_if_absent_composite -> conditional-create on a doc-id DERIVED
    #     from the COMPOSITE key tuple (the multi-column dedup key).
    # =========================================================================
    def create_if_absent_composite[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        conflict_cols: List[String],
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        _ = reactor
        if len(conflict_cols) == 0:
            raise Error(
                "FirestoreDatabase.create_if_absent_composite: empty conflict_cols"
            )
        # The doc-id is a DETERMINISTIC, injective encoding of the composite key
        # tuple: each conflict column's value percent-encoded (slash-free) and
        # joined by a `~` separator that cannot appear in the encoded parts (so two
        # distinct tuples never collide). create_if_absent (currentDocument.exists=
        # false) REJECTS a second live create of the SAME tuple ATOMICALLY.
        var doc_id = _composite_doc_id(conflict_cols, cols, vals)
        var fields = _encode_fields(cols, vals)
        try:
            var _res = self._client.create_if_absent(table, doc_id, fields^)
            self._journal_write(table, doc_id)  # won -> a later rollback compensates it
            return True  # we won the composite key
        except e:
            if is_already_exists_error(String(e)):
                return False  # a prior create already claimed the composite key
            raise e^

    # =========================================================================
    # 8. claim_rows -> THE b1 CLAIM LOOP (run_query PENDING FIFO + per-doc CAS).
    # =========================================================================
    def claim_rows[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        n: Int,
        filter: Filter,
        order: List[Order],
        phase_col: String,
        from_phase: String,
        to_phase: String,
        extra: List[DbColVal],
        per_row_mint: PodNameMinter,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> DbRows:
        _ = reactor
        _ = filter  # the claim's pending predicate is owned here (phase==from_phase)
        _ = order  # the claim's FIFO order is owned here (ORDER BY created_at ASC)
        # 1. run_query WHERE phase_col == from_phase ORDER BY created_at ASC LIMIT n.
        var q = _build_claim_query(table, phase_col, from_phase, n)
        var pending = self._client.run_query(q^)
        var claimed_rows = List[DbRow]()
        var cols = List[String]()  # the claim result carries the full doc field set
        var now_us = _now_micros()
        for i in range(len(pending)):
            if len(claimed_rows) >= n:
                break
            ref doc = pending[i]
            # Fast-path skip: only claim docs still at from_phase (a stale query
            # result could carry a doc a prior claim moved — the CAS below is the
            # real guard, this is the cheap check).
            if _doc_field_text(doc, phase_col) != from_phase:
                continue
            var observed_version = _doc_field_int(doc, _version_col_name(bump_version_col))
            # 2. Build the per-doc claim update: phase from_phase->to_phase, +extra,
            #    +version bump, +now_cols stamp, +pod_name via per_row_mint.
            var updates = _build_claim_updates(
                phase_col, to_phase, extra, per_row_mint, doc
            )
            # 3. The per-doc version-CAS — the linearization point. On
            #    FAILED_PRECONDITION (a racer/heartbeat moved the doc since the
            #    query read) the CAS is rejected -> SKIP (the SKIP-LOCKED skip).
            var fields = _apply_updates(
                doc, updates, False, bump_version_col, now_cols, now_us
            )
            var won = self._cas_write(
                table, _last_name_segment(doc.name), fields^, String(doc.update_time)
            )
            _ = observed_version
            if won:
                # 4. Re-read the just-claimed doc so the returned row carries the
                #    to_phase + the durable pod_name + the fresh updateTime.
                var after = self._get_doc_opt(table, _last_name_segment(doc.name))
                if after:
                    var after_doc = after.take()
                    if len(cols) == 0:
                        cols = _all_field_names(after_doc)
                    claimed_rows.append(_doc_to_row(after_doc, cols))
            # else: FAILED_PRECONDITION -> SKIP (continue).
        return DbRows(claimed_rows^, cols^)

    # =========================================================================
    # internals.
    # =========================================================================
    def _get_doc_opt(
        mut self, collection: String, doc_id: String
    ) raises -> Optional[FirestoreDocument]:
        """GET one doc; None on 404 (the query_opt shape), the doc otherwise. Any
        OTHER error propagates (a real backend failure)."""
        try:
            var doc = self._client.get_document(collection, doc_id)
            return Optional[FirestoreDocument](doc^)
        except e:
            if is_not_found_error(String(e)):
                return Optional[FirestoreDocument]()
            raise e^

    def _query_one_doc(
        mut self, collection: String, key_col: String, key_val: DbValue
    ) raises -> Optional[FirestoreDocument]:
        """Find AT MOST ONE doc by a single-field equality: run a structuredQuery
        `WHERE key_col == key_val LIMIT 1` and return its first result (None if the
        set is empty). This is the NON-PK-lookup resolver used by get_by_key /
        delete_by_key / conditional_update when the lookup key is NOT the table's
        doc-id column (e.g. a `users` row by `email`, an `api_keys` row by
        `key_hash`). Firestore
        auto-indexes every single field, so this needs no declared composite index.
        Reuses the SAME `_build_structured_query` + `run_query` path query_rows uses
        — no new client method."""
        var q = _build_structured_query(
            collection,
            Filter.just(Pred.eq(String(key_col), key_val.copy())),
            List[Order](),
            Optional[UInt32](UInt32(1)),
            self._declared_indexes,
        )
        var docs = self._client.run_query(q^)
        if len(docs) == 0:
            return Optional[FirestoreDocument]()
        return Optional[FirestoreDocument](docs[0].copy())

    def _cas_write(
        mut self,
        collection: String,
        doc_id: String,
        var fields: FsValue,
        expected_update_time: String,
    ) raises -> Bool:
        """The single-doc version-CAS write: `update_if_unchanged` guarded on
        `expected_update_time`. True iff committed; a typed FAILED_PRECONDITION (the
        version moved — a racing writer won) -> False (the caller re-reads / skips).
        Any OTHER error propagates."""
        try:
            var _res = self._client.update_if_unchanged(
                collection, doc_id, fields^, expected_update_time
            )
            return True
        except e:
            if is_precondition_failed_error(String(e)):
                return False  # the version moved — the SKIP-LOCKED skip
            raise e^

    def _best_effort_delete(
        mut self, collection: String, doc_id: String
    ) raises -> UInt64:
        """Delete a doc, swallowing a 404 (already gone) -> 0. A non-404 error
        propagates. Returns 1 iff a doc was actually deleted."""
        try:
            self._client.delete_document(collection, doc_id)
            return UInt64(1)
        except e:
            if is_not_found_error(String(e)):
                return UInt64(0)  # already gone
            raise e^


# =============================================================================
# §2 — the DbValue<->document field ENCODER / DECODER (the ONE new piece).
# =============================================================================


def _encode_fields(cols: List[String], vals: List[DbValue]) raises -> FsValue:
    """Encode a positional row of DbValues onto a Firestore `fields` map keyed by
    `cols`. The inverse of `_doc_to_row`. Each DbValue -> a typed FsValue arm:
      * is_null                          -> nullValue
      * INT4 / INT8 / TIMESTAMPTZ        -> integerValue (decimal text) — so the
        mock's LESS_THAN inequality works on timestamps + `DbRow.get_int8` /
        `get_timestamptz` parse the decimal back
      * everything else                  -> stringValue (the canonical as_text())
    """
    if len(cols) != len(vals):
        raise Error(
            String("FirestoreDatabase._encode_fields: cols/vals arity mismatch (")
            + String(len(cols))
            + String(" vs ")
            + String(len(vals))
            + String(")")
        )
    var keys = List[String]()
    var fvs = List[FsValue]()
    for i in range(len(cols)):
        keys.append(String(cols[i]))
        fvs.append(_encode_value(vals[i]))
    return FsValue.map_of(keys^, fvs^)


def _encode_value(v: DbValue) -> FsValue:
    """Encode ONE DbValue to its Firestore field value (see `_encode_fields`)."""
    if v.is_null:
        return FsValue.null()
    var lt = v.logical_type
    if lt == LOGICAL_INT4 or lt == LOGICAL_INT8 or lt == LOGICAL_TIMESTAMPTZ:
        # integerValue (decimal text on the wire) — the inequality-comparable arm.
        return FsValue.integer(v.as_text())
    if lt == LOGICAL_BYTES:
        # bytesValue — the RAW blob bytes base64-encoded into the REST JSON (the
        # Firestore wire form for binary). `_decode_field` base64-decodes it back
        # into the exact write-side bytes. A genuine binary field, not a TEXT hack.
        return FsValue.bytes(base64_encode(v.as_bytes_owned()))
    if lt == LOGICAL_TEXT_ARRAY:
        # arrayValue — a NATIVE Firestore array of stringValues (NOT the pg `{a,b,c}`
        # text literal). This is what makes the server-side `ARRAY_CONTAINS`
        # fieldFilter work (e.g. a tag filter on `tags`). `_decode_field` reconstructs the `{a,b,c}` literal so the
        # SQL round-trip (`DbRow.get_text_array` parses `{a,b,c}`) is UNCHANGED.
        var elems = v.text_array_elements()
        var items = List[FsValue]()
        for i in range(len(elems)):
            items.append(FsValue.string(String(elems[i])))
        return FsValue.array_of(items^)
    # TEXT / UUID / JSONB / BOOL / FLOAT -> the canonical text form.
    return FsValue.string(v.as_text())


def _doc_to_row(doc: FirestoreDocument, cols: List[String]) raises -> DbRow:
    """Decode a Firestore doc into a projected `DbRow` over `cols` (in order). Each
    column's typed field is read into its canonical text (+ null flag); an ABSENT
    column -> null (the schema-evolution add-column null-fill). `DbRow.from_values`
    re-surfaces the flat DbRow a `DbStorable.from_row` decodes — the DbRow
    getters (get_text / get_int8 / get_uuid / ...) parse the canonical text
    regardless of the stored logical tag, so the round-trip is exact.

    NOTE: the DbValue we build back carries a best-effort logical type (integer arm
    -> INT8, else TEXT) — it is used ONLY for `is_null` in the DbRow; the getters
    never branch on it (they parse the text)."""
    var vals = List[DbValue]()
    for i in range(len(cols)):
        vals.append(_decode_field(doc, cols[i]))
    return DbRow.from_values(vals, cols.copy())


def _decode_field(doc: FirestoreDocument, col: String) raises -> DbValue:
    """Read ONE column's typed field back into a DbValue carrying its canonical
    text. Absent / nullValue -> a typed NULL. An integerValue -> an INT8-tagged
    DbValue (the getters parse the decimal); anything else -> a TEXT-tagged
    DbValue carrying the scalar text verbatim."""
    if not doc.has_field(col):
        return DbValue.null(LOGICAL_INT8)  # absent -> null (the add-column null-fill)
    var fv = doc.get_field(col)
    if fv.is_null():
        return DbValue.null(LOGICAL_INT8)
    if fv.type_tag == FS_T_INTEGER:
        # integerValue -> keep the decimal text; the DbRow getters (get_int8 /
        # get_int4 / get_timestamptz) parse it. Build an INT8-tagged DbValue over
        # the raw decimal text (the 3-arg ctor: logical_type, is_null, text) — the
        # getters parse the text, the tag only feeds the DbRow's is_null flag.
        return DbValue(LOGICAL_INT8, False, fv.as_string())
    if fv.type_tag == FS_T_BYTES:
        # bytesValue -> base64-DECODE the wire string into the RAW blob bytes, and
        # carry them VERBATIM as a LOGICAL_BYTES DbValue (`DbValue.bytes` copies the
        # bytes into the byte-backed `_text`). `DbRow.get_bytes` reads them back
        # exactly — the inverse of `_encode_value`'s bytesValue arm.
        return DbValue.bytes_list(base64_decode(fv.as_string()))
    if fv.type_tag == FS_T_ARRAY:
        # arrayValue -> RECONSTRUCT the pg `{a,b,c}` text literal from the native
        # array's stringValue items, so `DbRow.get_text_array` (which parses
        # `{a,b,c}`) round-trips EXACTLY. The inverse of `_encode_value`'s
        # LOGICAL_TEXT_ARRAY arm. A non-string item is read via `as_string()`
        # (the closed-set contract: simple labels / hyphenated UUIDs).
        var elems = List[String]()
        for i in range(len(fv.list_items)):
            elems.append(fv.list_items[i].as_string())
        return DbValue.text_array(elems^)
    # stringValue (or any other scalar arm) -> the canonical text verbatim; the
    # DbRow getters (get_text / get_uuid / get_jsonb / get_text_array) parse it.
    return DbValue.text(fv.as_string())


# =============================================================================
# §3 — doc-id + PK helpers.
# =============================================================================


def _doc_id_for(v: DbValue) -> String:
    """The Firestore doc-id for a PK / unique value = its canonical text. A Job.id
    UUID renders hyphenated-lowercase (Firestore-doc-id-legal: no `/`, not reserved);
    a text idempotency key renders verbatim (percent-encoded by the caller)."""
    return v.as_text()


def _composite_doc_id(
    conflict_cols: List[String], cols: List[String], vals: List[DbValue]
) raises -> String:
    """A DETERMINISTIC, injective doc-id for a COMPOSITE key tuple: the value of
    each `conflict_cols[i]` (matched positionally against `cols`) percent-encoded
    (slash-free) and joined by `~`. Percent-encoding escapes `%`/`/`/`~` so no two
    distinct tuples produce the same id (`(a, bc)` vs `(ab, c)` cannot collide).
    The single-column path stays keyed on `_encode_doc_id_part(_doc_id_for(val))`;
    this is its composite generalization for keys like `(mailbox_id, content_hash)`.
    """
    var out = String("")
    for i in range(len(conflict_cols)):
        var found = False
        for j in range(len(cols)):
            if cols[j] == conflict_cols[i]:
                if i > 0:
                    out += String("~")
                out += _encode_composite_part(_doc_id_for(vals[j]))
                found = True
                break
        if not found:
            raise Error(
                String(
                    "FirestoreDatabase.create_if_absent_composite: conflict column"
                    " \""
                )
                + conflict_cols[i]
                + String("\" is not in the inserted cols")
            )
    return out^


def _encode_composite_part(part: String) -> String:
    """Percent-encode a composite-key part so it is slash-free AND separator-free
    (`~`): encode `%` first (reversible), then `/`, then `~`. Injective — the
    joined tuple id round-trips uniquely."""
    var sb = part.as_bytes()
    var out = String("")
    for i in range(len(sb)):
        var c = sb[i]
        if c == UInt8(ord("%")):
            out += "%25"
        elif c == UInt8(ord("/")):
            out += "%2F"
        elif c == UInt8(ord("~")):
            out += "%7E"
        else:
            out += chr(Int(c))
    return out^


struct TableKeys(Copyable, Movable, Deinitable):
    """The doc-id (primary key) column of each table a `FirestoreDatabase`
    stores, as the caller declares it.

    Each doc-addressed op (put / get_by_key / conditional_update /
    delete_by_key) names the Firestore document after the value of this column,
    so all of them find the SAME document. A table not declared here is keyed
    on `id`. A table declared with an EMPTY column has no key column in its
    projection (a server-assigned serial id, say), and `put` mints a document id
    for each row.

    A table whose key is NOT `id` must be declared: otherwise `put` cannot find
    the key column in its projection and mints a random document id, which no
    later read by key can find. A declared key that the projection then lacks is
    refused by `put` rather than minted (see
    `_refuse_minted_doc_id_for_declared_table`)."""

    var _tables: List[String]
    var _cols: List[String]

    def __init__(out self):
        self._tables = List[String]()
        self._cols = List[String]()

    def declare(mut self, var table: String, var pk_col: String):
        """Key `table`'s documents on `pk_col` (empty: no key column; mint)."""
        for i in range(len(self._tables)):
            if self._tables[i] == table:
                self._cols[i] = pk_col^
                return
        self._tables.append(table^)
        self._cols.append(pk_col^)

    def pk_col(self, table: String) -> String:
        """The key column of `table`: its declared one, else `id`."""
        for i in range(len(self._tables)):
            if self._tables[i] == table:
                return self._cols[i].copy()
        return String("id")

    def is_declared(self, table: String) -> Bool:
        for i in range(len(self._tables)):
            if self._tables[i] == table:
                return True
        return False


def _key_is_pk(keys: TableKeys, table: String, key_col: String) -> Bool:
    """True iff `key_col` is the table's doc-id (PK) column — the direct-GET fast
    path for get_by_key / delete_by_key. A False verdict routes the lookup through
    a single-field-equality query (`_query_one_doc`), because the doc is named after
    the PK value, NOT after `key_col`'s value."""
    return key_col == keys.pk_col(table)


def _pushable_eq_filter(guard: Filter) raises -> Filter:
    """The part of a CAS guard that may be PUSHED to a structuredQuery: every
    EQ predicate carrying a NON-NULL value, preserving the guard's combine mode.

    ⚠ THIS IS A SELECTIVITY FILTER, NOT THE AUTHORITY. `conditional_update`
    re-evaluates the FULL guard client-side (`_guard_matches`) against every
    document this query returns, so anything left out here can only cost extra
    candidates — never a wrong write.

    WHAT IS DELIBERATELY LEFT OUT, and why each one would be a defect:
      * a RANGE pred (LT / LE / GTE) — pushed ALONGSIDE an equality it requires a
        declared COMPOSITE index, so pushing it could turn a CAS that works today
        into a live FAILED_PRECONDITION (`firestore_index_guard.mojo`).
      * PRED_NE — a Firestore `NOT_EQUAL` fieldFilter EXCLUDES every document
        that does not carry the field, which is the exact population a PRED_NE
        guard exists to reach (see `_guard_matches`); and it is an inequality, so
        it drags in the composite-index requirement too.
      * a NULL-valued EQ (`col = NULL`) — renders as a unaryFilter IS_NULL, a
        DIFFERENT question from the client-side evaluator's, so it is left to the
        client-side arm.
      * PRED_IN / PRED_JSON_KEY_EQ / PRED_ARRAY_CONTAINS — no fieldFilter analog
        here (query_rows splits IN out; `_guard_matches` fails closed on them).

    MULTIPLE EQUALITIES with no ordering and no range are served off Firestore's
    AUTOMATIC single-field indexes, so what this DOES push is index-free."""
    var kept = List[Pred]()
    for i in range(len(guard.preds)):
        ref p = guard.preds[i]
        if p.op == PRED_EQ and not p.val.is_null:
            kept.append(p.copy())
    return Filter(kept^, guard.combine)


def _refuse_minted_doc_id_for_declared_table(
    keys: TableKeys, table: String, cols: List[String]
) raises:
    """RAISE iff `put` is about to mint a RANDOM doc-id for a table whose primary
    key is DECLARED in `keys` as something other than the conventional `id` —
    i.e. the declaration and the projection disagree.

    ⛔ WHY A RANDOM DOC-ID IS NOT MERELY ODD. `put` names the document after the
    PK value; when it cannot find that column it mints a fresh UUIDv7 instead. The
    row then has a doc-id naming no column, so a SECOND write of the SAME logical
    key creates a SECOND document, and every PK-addressed read / CAS / delete
    afterwards resolves an arbitrary one of them. A version-CAS lock built on
    such a table stops being a mutual exclusion: two acquirers CAS two DIFFERENT
    documents and each passes its own guard.

    ⚠ THE UNDECLARED (`id`) CASE IS NOT REFUSED. A table nobody declared answers
    `id`; if its projection lacks `id`, `put` still mints. Refusing that would
    turn every caller that never declared its keys into a hard failure at once;
    a caller with a non-`id` key declares it in `TableKeys`, and from then on
    this arm holds the projection to the declaration."""
    var pk_col = keys.pk_col(table)
    if pk_col.byte_length() == 0:
        return  # a DECLARED key-less projection: minting is right
    if pk_col == String("id"):
        return  # the conventional key (declared or not): see above
    var present = String("")
    for i in range(len(cols)):
        if i > 0:
            present += String(", ")
        present += cols[i]
    raise Error(
        String(
            "FirestoreDatabase.put REFUSED a random document id: table \""
        )
        + table
        + String("\" is declared in its TableKeys with primary key \"")
        + String(pk_col)
        + String(
            "\", but that column is not in the projection this write names ["
        )
        + present
        + String(
            "]. Minting a UUIDv7 here would give the row a doc-id naming no"
            " column, so a second write of the SAME logical key would create a"
            " SECOND document and every PK-addressed read / CAS / delete would"
            " then resolve an arbitrary one of them. Project the primary-key"
            " column, or — if this table genuinely has no single-column key —"
            " write it through `create_if_absent_composite`, which derives a"
            " deterministic composite doc-id."
        )
    )


def _pk_index(keys: TableKeys, table: String, cols: List[String]) -> Int:
    """The index of the doc-id column in `cols` for `table` (the doc is keyed on
    THIS column's value). Resolves the PK column name via `keys.pk_col(table)`
    and locates it in the projection. Falls back to -1 (a minted doc-id) for a
    declared key-less projection or a PK column absent from the projection."""
    var pk_col = keys.pk_col(table)
    if pk_col.byte_length() == 0:
        return -1  # declared key-less projection — the caller mints a doc-id
    for i in range(len(cols)):
        if cols[i] == pk_col:
            return i
    return -1  # the PK column is not in this projection — mint a doc-id


def _pk_pred_value(
    keys: TableKeys, guard: Filter, table: String
) -> Optional[DbValue]:
    """Extract the PK predicate's value from a CAS guard Filter (the doc the
    conditional_update addresses). The PK column is resolved per-table via
    `keys.pk_col(table)` (a guard is typically `id = $ [AND phase/version]`, or
    `<declared key> = $`). The PK EQ pred names the doc; every other guard pred (phase/version) is a
    client-side pre-check on the read-back doc."""
    var pk_col = keys.pk_col(table)
    for i in range(len(guard.preds)):
        ref p = guard.preds[i]
        if p.op == PRED_EQ and pk_col.byte_length() > 0 and p.col == pk_col:
            return Optional[DbValue](p.val.copy())
    # Defensive fallback: if the table's PK column is not among the guard preds,
    # accept the conventional `id` / `key` EQ pred.
    for i in range(len(guard.preds)):
        ref p = guard.preds[i]
        if p.op == PRED_EQ and (p.col == String("id") or p.col == String("key")):
            return Optional[DbValue](p.val.copy())
    return Optional[DbValue]()


# =============================================================================
# §4 — the CLIENT-SIDE guard evaluator (the CAS pre-check) + update application.
# =============================================================================


def _guard_matches(doc: FirestoreDocument, guard: Filter) raises -> Bool:
    """Evaluate every guard predicate CLIENT-SIDE against the read-back doc — the
    `... WHERE id=,phase=,version=` CAS pre-check. A mismatch -> False (the CAS
    loses without a write). Supports EQ / NE / LT / GTE / IS_NULL / IS_NOT_NULL
    over the doc's string/integer/null fields.

    ⚠ AN ABSENT FIELD IS NOT A NULL — BUT IT STILL FAILS `PRED_EQ`, DELIBERATELY.
    A document written before a column existed simply has no such field, and this
    evaluator cannot know what DDL default the SQL backends materialized for it.
    Answering "yes, it equals what you asked" would turn every identity predicate
    (`owner_id`, `scope_id`, `item_id`) into a wildcard on exactly the oldest rows, so
    EQ stays fail-closed. The predicate that CAN answer honestly is `PRED_NE`:
    "is the stored value distinct from `val`" is TRUE when there is no stored
    value, and that is how the restamp guard reaches a legacy row."""
    for i in range(len(guard.preds)):
        ref p = guard.preds[i]
        var present = doc.has_field(p.col)
        var is_null = (not present) or doc.get_field(p.col).is_null()
        if p.op == PRED_EQ:
            if is_null:
                return False
            # Compare the doc field's canonical text to the pred value's text.
            var dv = doc.get_field(p.col).as_string()
            if dv != p.val.as_text():
                return False
        elif p.op == PRED_NE:
            # `IS DISTINCT FROM` — see PRED_NE in `neutral_ops.mojo`. An ABSENT or
            # NULL field IS distinct from any bound value: the row has no stored
            # value, so it cannot be the one being written. A NULL bound value
            # makes this `IS DISTINCT FROM NULL`, i.e. plain IS NOT NULL.
            if p.val.is_null:
                if is_null:
                    return False
                continue
            if is_null:
                continue  # no stored value -> it differs
            if doc.get_field(p.col).as_string() == p.val.as_text():
                return False
        elif p.op == PRED_LT:
            if is_null:
                return False
            var di = _text_to_int(doc.get_field(p.col).as_string())
            if not (di < _text_to_int(p.val.as_text())):
                return False
        elif p.op == PRED_GTE:
            if is_null:
                return False
            var dg = _text_to_int(doc.get_field(p.col).as_string())
            if not (dg >= _text_to_int(p.val.as_text())):
                return False
        elif p.op == PRED_IS_NULL:
            if not is_null:
                return False
        elif p.op == PRED_IS_NOT_NULL:
            if is_null:
                return False
        else:
            return False  # an unsupported guard op fails closed
    return True


def _apply_updates(
    doc: FirestoreDocument,
    updates: List[DbColVal],
    coalesce: Bool,
    bump_version_col: Optional[String],
    now_cols: List[String],
    now_us: Int64,
) raises -> FsValue:
    """Build the FULL updated `fields` map for a conditional_update / claim CAS:
    START from the doc's current fields (so un-touched columns are preserved — the
    Firestore full-doc-write model), then apply each `updates` term, bump
    `bump_version_col` by 1, and stamp each `now_cols` column with `now_us`.

    The DbColVal kinds map to the Firestore full-doc-write:
      * COLVAL_BIND     -> overwrite the column with the bound value.
      * COLVAL_COALESCE -> overwrite ONLY if the bound value is non-NULL (a NULL
        leaves the read-back value — the partial-heartbeat COALESCE semantic).
        With `coalesce` True a COLVAL_BIND term is read the same way, as the
        `Database.conditional_update` contract and the SQL renderer have it.
      * COLVAL_RAW_EXPR -> classified by the NEUTRAL `classify_raw_expr` (the one
        vocabulary this backend and DynamoDB share):
          - `<col> + 1`  -> the INCREMENT: read the column back and add one (the
            `version = version + 1` bump transition_job passes as a RAW_EXPR
            term, NOT via bump_version_col — both routes are honored).
          - a scalar LITERAL (`true` / `false` / `null` / a signed decimal int)
            -> written through the SAME `_encode_value` a BIND uses, so a
            literal-set and a bound-set store identical bytes.
          - anything else -> ⛔ REFUSED BY NAME. See below.
      * any OTHER kind  -> ⛔ REFUSED BY NAME.

    ⛔ WHY AN UNRECOGNISED TERM RAISES INSTEAD OF BEING SKIPPED. A revoke
    sets its flag with `DbColVal.raw_expr("revoked", "true")`, the SQL bool
    LITERAL. Skipping a term this function cannot read would commit a document
    whose `revoked` field never changed, bump `version`, and return a NON-ZERO
    rows_affected: every caller would see a successful revoke that did
    nothing. A store that drops what it cannot read is indistinguishable from
    one that applied it; one that refuses by name says so.
    """
    # Materialize the doc's current fields into a mutable (keys, values) pair.
    var keys = List[String]()
    var fvs = List[FsValue]()
    for i in range(len(doc.fields.map_keys)):
        keys.append(String(doc.fields.map_keys[i]))
        fvs.append(doc.fields.map_values[i].copy())

    # Apply each update term.
    for i in range(len(updates)):
        ref u = updates[i]
        if u.kind == COLVAL_RAW_EXPR:
            var term = classify_raw_expr(String(u.col), u.val.as_text())
            if term.is_increment():
                var cur = _keys_get_int(keys, fvs, String(u.col))
                _set_field(
                    keys, fvs, String(u.col), FsValue.integer(String(cur + Int64(1)))
                )
                continue
            if term.is_literal():
                # The SAME encoder a BIND goes through — a bool literal and a
                # `DbColVal.bind(col, DbValue.bool_val(True))` store identical
                # bytes, so there is no second representation to decode.
                _set_field(
                    keys, fvs, String(u.col), _encode_value(term.literal)
                )
                continue
            raise Error(
                raw_expr_refusal(
                    String("FirestoreDatabase"),
                    String(u.col),
                    u.val.as_text(),
                )
            )
        if u.val.is_null and (
            u.kind == COLVAL_COALESCE or (coalesce and u.kind == COLVAL_BIND)
        ):
            continue  # COALESCE(NULL, col) -> leave the read-back value untouched
        if u.kind != COLVAL_BIND and u.kind != COLVAL_COALESCE:
            # A kind this backend has no arm for. Same reason as above: a silent
            # skip is a lost write that reports success.
            raise Error(
                String("FirestoreDatabase: unsupported DbColVal kind ")
                + String(Int(u.kind))
                + String(" for column '")
                + u.col
                + String(
                    "'. Every neutral update kind needs an explicit arm here;"
                    " dropping one silently loses the write."
                )
            )
        _set_field(keys, fvs, String(u.col), _encode_value(u.val))

    # Bump the version column (+1) if requested.
    if bump_version_col:
        var vc = bump_version_col.value()
        var cur_v = _keys_get_int(keys, fvs, vc)
        _set_field(keys, fvs, vc, FsValue.integer(String(cur_v + Int64(1))))

    # Stamp each now_cols column with the client-side wall-clock micros.
    for i in range(len(now_cols)):
        _set_field(
            keys, fvs, String(now_cols[i]), FsValue.integer(String(now_us))
        )

    return FsValue.map_of(keys^, fvs^)


# ⛔ RAW_EXPR terms are read ONLY by `komira_db.neutral_ops.classify_raw_expr`,
# the one vocabulary every backend shares. Do not add a local matcher here: a
# second recogniser can only ever disagree with the neutral contract (and a
# term it misses is a write silently dropped).


def _build_claim_updates(
    phase_col: String,
    to_phase: String,
    extra: List[DbColVal],
    per_row_mint: PodNameMinter,
    doc: FirestoreDocument,
) raises -> List[DbColVal]:
    """Build the per-doc claim update terms: phase_col := to_phase (BIND), each
    `extra` SET term, and the pod_name mint as a BIND term. The version bump +
    now_cols stamp ride `_apply_updates`'s first-class args (NOT here).

    ⭐ THE MINT IS `derive_pod_name(prefix, <this doc's id>)` — the SAME
    function the SQL arms render server-side, called here because a document
    backend has no SQL evaluator. It is a pure function of the id so the
    placement name can be recomputed: a job manager that crashed between the
    `pod_name` write and the `create` can still address the unit that create
    may have left behind. ⛔ Do not add ANY per-row entropy here — per-row
    distinctness comes from the id, which is per-row unique by construction,
    and the neutral ORACLE asserts it across a claim."""
    var out = List[DbColVal]()
    out.append(DbColVal.bind(String(phase_col), DbValue.text(String(to_phase))))
    for i in range(len(extra)):
        out.append(extra[i].copy())
    if per_row_mint.is_active():
        var pod_name = derive_pod_name(
            per_row_mint.prefix, _doc_field_text(doc, String("id"))
        )
        out.append(DbColVal.bind(String("pod_name"), DbValue.text(pod_name^)))
    return out^


# =============================================================================
# §5 — mutable (keys, values) field-map helpers (the full-doc-write substrate).
# =============================================================================


def _set_field(
    mut keys: List[String], mut fvs: List[FsValue], col: String, var v: FsValue
):
    """Overwrite (or append) the field `col` in the parallel (keys, values) arrays."""
    for i in range(len(keys)):
        if keys[i] == col:
            fvs[i] = v^
            return
    keys.append(String(col))
    fvs.append(v^)


def _keys_get_int(keys: List[String], fvs: List[FsValue], col: String) -> Int64:
    """Read the integer value of `col` from the (keys, values) arrays (0 if absent
    / null / non-integer). Used for the version bump read-modify-write."""
    for i in range(len(keys)):
        if keys[i] == col:
            if fvs[i].is_null():
                return Int64(0)
            return _text_to_int(fvs[i].as_string())
    return Int64(0)


# =============================================================================
# §6 — structured-query builders (the JSON form of a v1 StructuredQuery, which
#      FirestoreClient.run_query reads strictly into the generated message).
# =============================================================================


def _build_structured_query(
    collection: String,
    filter: Filter,
    order: List[Order],
    limit: Optional[UInt32],
    declared: DeclaredIndexSet,
) raises -> String:
    """Assemble the structuredQuery JSON body from a neutral Filter / Order / limit.
    The Filter is a single AND (or OR) group of Preds — the mock + live Firestore
    evaluate a compositeFilter AND of fieldFilters (EQUAL / LESS_THAN) plus
    unaryFilters (IS_NULL / IS_NOT_NULL for the null-comparison preds). The OR-union
    case is handled by the STORE issuing TWO query_rows, so
    an OR Filter here is treated as a single group.

    ★ THE INDEX GUARD LIVES HERE, AND HERE IS THE ONLY RIGHT PLACE FOR IT. This is
    the single site where a neutral (Filter, Order) becomes a Firestore query, and
    it receives the PUSHED filter — the IN preds the store evaluates client-side
    have already been split out — so the shape judged here is the TRUE WIRE SHAPE,
    not what the caller believed it was asking for. A shape Firestore cannot serve
    off automatic single-field indexes, and that `declared` does not cover, RAISES
    rather than being sent to the cloud to come back 500 FAILED_PRECONDITION (a
    live list outage). See
    `firestore_index_guard.mojo` for the rule and for what it does NOT claim.

    NOT wrapped in {"structuredQuery":..} — the client wraps it."""
    require_declared_index(declared, collection, filter, order)
    var out = String('{"from":[{"collectionId":')
    out += _json_quote(collection)
    out += String("}]")
    # WHERE.
    var where = _render_where(filter)
    if where.byte_length() > 0:
        out += String(',"where":') + where
    # ORDER BY (first order term; ASCENDING/DESCENDING per its `desc`).
    if len(order) > 0:
        out += String(',"orderBy":[')
        for i in range(len(order)):
            if i > 0:
                out += String(",")
            out += String('{"field":{"fieldPath":')
            out += _json_quote(String(order[i].col))
            out += String('},"direction":')
            out += _json_quote(
                String("DESCENDING") if order[i].desc else String("ASCENDING")
            )
            out += String("}")
        out += String("]")
    # LIMIT.
    if limit:
        out += String(',"limit":') + String(Int(limit.value()))
    out += String("}")
    return out^


def _build_claim_query(
    collection: String, phase_col: String, from_phase: String, limit: Int
) -> String:
    """The claim loop's FIFO sweep: FROM collection WHERE phase_col == from_phase
    ORDER BY created_at ASC LIMIT `limit`. Needs a composite index on (phase_col,
    created_at) on a live database (a provisioning concern)."""
    var out = String('{"from":[{"collectionId":')
    out += _json_quote(collection)
    out += String('}],"where":')
    out += _field_filter_op(
        phase_col,
        String("EQUAL"),
        String('{"stringValue":') + _json_quote(from_phase) + String("}"),
    )
    out += String(',"orderBy":[{"field":{"fieldPath":')
    out += _json_quote(String("created_at"))
    out += String('},"direction":"ASCENDING"}]')
    out += String(',"limit":') + String(limit)
    out += String("}")
    return out^


def _render_where(filter: Filter) raises -> String:
    """Render a neutral Filter to a Firestore `where` clause. An empty filter -> ""
    (no WHERE). A single pred -> a bare fieldFilter; multiple preds -> a
    compositeFilter AND (or OR) of fieldFilters."""
    if len(filter.preds) == 0:
        return String("")
    if len(filter.preds) == 1:
        return _render_pred(filter.preds[0])
    var op = String("OR") if filter.combine == COMBINE_OR else String("AND")
    var out = String('{"compositeFilter":{"op":') + _json_quote(op)
    out += String(',"filters":[')
    for i in range(len(filter.preds)):
        if i > 0:
            out += String(",")
        out += _render_pred(filter.preds[i])
    out += String("]}}")
    return out^


def _render_pred(p: Pred) raises -> String:
    """Render ONE neutral Pred to a Firestore filter. EQ -> EQUAL; LT ->
    LESS_THAN; LE -> LESS_THAN_OR_EQUAL; GTE -> GREATER_THAN_OR_EQUAL;
    IS_NULL -> unaryFilter IS_NULL; IS_NOT_NULL -> unaryFilter IS_NOT_NULL. The
    value's Firestore type follows the pred's logical type (INT/TIMESTAMP ->
    integerValue so the inequality compares numerically; else stringValue). PRED_IN
    preds are NEVER passed here — the store's query_rows SPLITS them out and
    evaluates them in Mojo (the load-and-filter path).

    NULL-COMPARISON RULE (the load-bearing correctness invariant): a Firestore
    `fieldFilter` with `op:EQUAL`/`op:NOT_EQUAL` against `{"nullValue":null}`
    matches NOTHING on a live Firestore — equality/inequality-to-null is defined to
    match no document. IS NULL / IS NOT NULL MUST be expressed as a `unaryFilter`
    with `op:IS_NULL` / `op:IS_NOT_NULL`. So both PRED_IS_NULL / PRED_IS_NOT_NULL
    AND a PRED_EQ whose bound value is NULL (a `= NULL` shape) render as unary
    ops — never as a fieldFilter against a nullValue."""
    # A `= NULL` equality (a null-valued bind on PRED_EQ) is IS NULL on Firestore —
    # a fieldFilter EQUAL {"nullValue":null} silently matches nothing, so redirect
    # it to the unaryFilter IS_NULL operator.
    if p.op == PRED_EQ and p.val.is_null:
        return _unary_filter_op(String(p.col), String("IS_NULL"))
    if p.op == PRED_EQ:
        return _field_filter_op(
            String(p.col), String("EQUAL"), _pred_value_json(p.val)
        )
    elif p.op == PRED_LT:
        return _field_filter_op(
            String(p.col), String("LESS_THAN"), _pred_value_json(p.val)
        )
    elif p.op == PRED_LE:
        return _field_filter_op(
            String(p.col),
            String("LESS_THAN_OR_EQUAL"),
            _pred_value_json(p.val),
        )
    elif p.op == PRED_GTE:
        return _field_filter_op(
            String(p.col),
            String("GREATER_THAN_OR_EQUAL"),
            _pred_value_json(p.val),
        )
    elif p.op == PRED_IS_NULL:
        # IS NULL is a unaryFilter (a fieldFilter EQUAL {"nullValue":null} matches
        # NOTHING on live Firestore — an `archived_at IS NULL` default filter
        # silently returned empty until this fix).
        return _unary_filter_op(String(p.col), String("IS_NULL"))
    elif p.op == PRED_IS_NOT_NULL:
        # IS NOT NULL is a unaryFilter (NOT_EQUAL {"nullValue":null} is likewise
        # invalid on live Firestore).
        return _unary_filter_op(String(p.col), String("IS_NOT_NULL"))
    elif p.op == PRED_ARRAY_CONTAINS:
        # `ARRAY_CONTAINS` — the NATIVE server-side array-membership fieldFilter:
        # the field is the array COLUMN (`p.col`, stored as a native arrayValue by
        # `_encode_value`), the value is the scalar ELEMENT to test. This is the
        # Firestore analog of the pg `<val> = ANY(<col>)` push-down — a real
        # server-side index scan, NOT a client-side load-and-filter. The element is
        # a stringValue (the tag label / hyphenated dep uuid closed-set contract).
        return _field_filter_op(
            String(p.col),
            String("ARRAY_CONTAINS"),
            String('{"stringValue":') + _json_quote(p.val.as_text()) + String("}"),
        )
    else:
        # PRED_JSON_KEY_EQ (config ->> key = val) has no single-field Firestore
        # analog (config is stored as a JSONB stringValue). A caller narrowed to
        # SQL backends uses it, so this path is unreached; fail closed if it
        # ever is.
        # PRED_IN is likewise unreached here (split out by query_rows).
        raise Error(
            String("FirestoreDatabase: unsupported predicate op ")
            + String(Int(p.op))
        )


# =============================================================================
# The IN-predicate load-and-filter helpers (the NoSQL "load candidates,
# filter in Mojo" pattern). query_rows SPLITS the filter: the non-IN preds are
# pushed to the structured query; the IN preds are evaluated CLIENT-SIDE against
# each returned candidate doc.
# =============================================================================


def _filter_without_in(filter: Filter) raises -> Filter:
    """A copy of `filter` with every PRED_IN predicate REMOVED — the pushed-down
    part of the query (the structured-query builder handles it). Preserves the
    combine mode + the order of the remaining preds. When there are no IN preds
    this is a value-equal copy of `filter`."""
    var kept = List[Pred]()
    for i in range(len(filter.preds)):
        if filter.preds[i].op != PRED_IN:
            kept.append(filter.preds[i].copy())
    return Filter(kept^, filter.combine)


def _in_preds_of(filter: Filter) raises -> List[Pred]:
    """The PRED_IN predicates of `filter` (evaluated CLIENT-SIDE by
    `_doc_matches_in_preds`). Empty when the filter has no IN pred."""
    var out = List[Pred]()
    for i in range(len(filter.preds)):
        if filter.preds[i].op == PRED_IN:
            out.append(filter.preds[i].copy())
    return out^


def _doc_matches_in_preds(doc: FirestoreDocument, in_preds: List[Pred]) raises -> Bool:
    """True iff the doc satisfies EVERY IN predicate: `doc[col]` (as canonical
    text) equals one of the pred's `in_vals` (compared by `as_text()`). A NULL /
    absent field never matches an IN. Empty `in_preds` -> True (no IN to check)."""
    for i in range(len(in_preds)):
        ref p = in_preds[i]
        var present = doc.has_field(p.col)
        if not present or doc.get_field(p.col).is_null():
            return False  # NULL / absent never matches an IN membership
        var dv = doc.get_field(p.col).as_string()
        var found = False
        for j in range(len(p.in_vals)):
            if dv == p.in_vals[j].as_text():
                found = True
                break
        if not found:
            return False
    return True


def _pred_value_json(v: DbValue) -> String:
    """A Firestore value JSON for a pred's comparison value: integerValue for
    INT/TIMESTAMP (so LESS_THAN compares numerically), stringValue otherwise."""
    if v.is_null:
        return String('{"nullValue":null}')
    var lt = v.logical_type
    if lt == LOGICAL_INT4 or lt == LOGICAL_INT8 or lt == LOGICAL_TIMESTAMPTZ:
        return String('{"integerValue":') + _json_quote(v.as_text()) + String("}")
    return String('{"stringValue":') + _json_quote(v.as_text()) + String("}")


def _field_filter_op(field: String, op: String, value_json: String) -> String:
    """A Firestore fieldFilter `{"fieldFilter":{"field":{"fieldPath":..},"op":..,
    "value":..}}`."""
    var out = String('{"fieldFilter":{"field":{"fieldPath":')
    out += _json_quote(field)
    out += String('},"op":') + _json_quote(op) + String(',"value":')
    out += value_json
    out += String("}}")
    return out^


def _unary_filter_op(field: String, op: String) -> String:
    """A Firestore unaryFilter `{"unaryFilter":{"field":{"fieldPath":..},"op":..}}`
    — the operator form for the value-less null comparisons IS_NULL / IS_NOT_NULL.
    Firestore REQUIRES these to be a unaryFilter: a fieldFilter EQUAL / NOT_EQUAL
    against `{"nullValue":null}` matches NOTHING (equality-to-null is defined to
    match no document), so an `archived_at IS NULL` rendered as EQUAL nullValue
    silently returned an empty result set. `op` is `IS_NULL` or `IS_NOT_NULL`."""
    var out = String('{"unaryFilter":{"field":{"fieldPath":')
    out += _json_quote(field)
    out += String('},"op":') + _json_quote(op)
    out += String("}}")
    return out^


# =============================================================================
# §7 — small doc-field readers + string / int / hex helpers.
# =============================================================================


def _doc_field_text(doc: FirestoreDocument, col: String) raises -> String:
    """The canonical text of a doc field ("" if absent / null)."""
    if doc.has_field(col):
        var v = doc.get_field(col)
        if not v.is_null():
            return v.as_string()
    return String("")


def _doc_field_int(doc: FirestoreDocument, col: String) raises -> Int64:
    """The integer value of a doc field (0 if absent / null / non-integer)."""
    if doc.has_field(col):
        var v = doc.get_field(col)
        if not v.is_null():
            return _text_to_int(v.as_string())
    return Int64(0)


def _all_field_names(doc: FirestoreDocument) -> List[String]:
    """Every field name in a doc, in stored order (the claim result's full-doc
    projection — the returned DbRow carries every column so a `from_row`
    finds each by name)."""
    var out = List[String]()
    for i in range(len(doc.fields.map_keys)):
        out.append(String(doc.fields.map_keys[i]))
    return out^


def _version_col_name(bump_version_col: Optional[String]) -> String:
    """The version column name (default `version`) for the claim's observed-version
    read."""
    if bump_version_col:
        return bump_version_col.value()
    return String("version")


def _text_to_int(s: String) -> Int64:
    """Parse a decimal string into Int64 (0 on malformed — the fields we read this
    way are always well-formed decimals we wrote)."""
    var sb = s.as_bytes()
    if len(sb) == 0:
        return Int64(0)
    var neg = False
    var i = 0
    if sb[0] == UInt8(ord("-")):
        neg = True
        i = 1
    var acc = Int64(0)
    while i < len(sb):
        var c = sb[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return Int64(0)
        acc = acc * Int64(10) + Int64(Int(c) - ord("0"))
        i += 1
    return -acc if neg else acc


def _last_name_segment(name: String) -> String:
    """The last `/`-delimited segment of a Firestore resource name
    `projects/.../documents/c/<id>` -> `<id>` (the doc-id a runQuery result carries
    in its `name`)."""
    var sb = name.as_bytes()
    var last_slash = -1
    for i in range(len(sb)):
        if sb[i] == UInt8(ord("/")):
            last_slash = i
    var start = last_slash + 1 if last_slash >= 0 else 0
    var out = String("")
    for i in range(start, len(sb)):
        out += chr(Int(sb[i]))
    return out^


def _encode_doc_id_part(part: String) -> String:
    """Percent-encode a doc-id part so it is slash-free + never a reserved `__.*__`
    id (an idempotency key could contain `/`). Encodes `%` first (reversible), then
    `/`."""
    var sb = part.as_bytes()
    var out = String("")
    for i in range(len(sb)):
        var c = sb[i]
        if c == UInt8(ord("%")):
            out += "%25"
        elif c == UInt8(ord("/")):
            out += "%2F"
        else:
            out += chr(Int(c))
    return out^


def _hex2(b: Int) -> String:
    """Two lowercase-hex digits for a byte value."""
    return _hex1(b >> 4) + _hex1(b & 0x0F)


def _hex1(nibble: Int) -> String:
    if nibble < 10:
        return chr(0x30 + nibble)
    return chr(0x61 + nibble - 10)


def _json_quote(s: String) -> String:
    """`s` as a JSON string literal, escaped by komira_json (every control
    byte, and UTF-8 kept whole), for the structured-query JSON this driver
    composes; `FirestoreClient.run_query` then reads that JSON strictly into
    the generated `StructuredQuery`."""
    return _fs_json_quote(s)


def _now_micros() -> Int64:
    """The client-side wall-clock in MICROSECONDS (the now_cols stamp + the claim's
    updated_at). Sourced from the core clock (ms) scaled to µs — matches the SQL
    now_expr()'s microsecond resolution for the `updated_at` column."""
    return now_unix_ms() * Int64(1000)
