# =============================================================================
# bulk.mojo — the `_bulk` NDJSON -> DocBatch translator
# =============================================================================
#
# The OpenSearch/Elasticsearch `_bulk` request translator. It parses the
# action-line + source-line NDJSON wire (the `index` action only)
# into (a) a multi-column DocBatch RecordBatch that the engine's SearchSink
# consumes, built from the good documents only, and (b) the per-item outcome
# list (status 201/created or status 400/error) in NDJSON order for the
# `_bulk` response. The engine names DocBatch / QueryIR / HitBatch and never
# sees a wire byte.
#
# Per-item partial success. A `_bulk` answers HTTP 200 with
# `{"errors":bool, "items":[...]}` where each item succeeds or fails on its
# own, and the good documents still index (this is the contract
# `opensearch-py` `helpers.bulk` relies on). The translator records a per-item
# outcome and does not raise on a per-document failure:
#   * Validation failures (phase 1, per pair): a non-index action
#     (create/update/delete), a missing text field, malformed action or source
#     JSON, a non-object action or source, a source object that names a key
#     twice, a non-string text field, a nested or array field, an integer or
#     float out of range, a reserved-name key (`_source`, `__fieldnorm__`), or
#     more than MAX_DYNAMIC_FIELDS fields. That item gets a status-400
#     `{type,reason}` and is excluded; the rest proceed.
#   * Type conflicts (phase 2, across documents): a candidate whose field
#     conflicts with the type resolved from earlier documents (and cannot
#     widen int -> float), or that would take the union schema past
#     MAX_DYNAMIC_FIELDS fields, gets a status-400 `mapper_parsing_exception`
#     and is excluded.
# The only whole-request raise is a framing error that cannot be attributed to
# one item: a final action line that needs a source line and has none (a
# `delete` action takes no source line). The handler maps it to a 400 envelope.
# Records are split at every raw newline, so a malformed line cannot swallow
# the lines after it. The batch is bounded to MAX_BATCH_CELLS cells.
#
# Dynamic field mapping, applied to the good documents:
#   Pass 1 (stage): per-pair parse and validation -> a PendingDoc (text value,
#     verbatim _source line, the staged (key, inferred kind, value) tuples) or
#     a failed BulkItem.
#   Pass 2 (resolve): walk the candidates in order, building the union schema.
#     A candidate's staged fields are checked against the established types
#     first; a genuine conflict (first occurrence wins, int -> FLOAT64 widening
#     the one allowed coercion) excludes the candidate without touching the
#     accumulators; otherwise its values are committed.
#   Pass 3 (build): emit the typed RecordBatch from the committed documents:
#     a body STRING column and a _source STRING column (both non-null) plus
#     each inferred field as a nullable typed column (null where a document
#     omits the field). SearchSink reads it by name and type, not arity.
# The text field (`body`) is already the body column and is skipped; a source
# key `_source` (it collides with the synthesized blob) or `__fieldnorm__`
# (reserved) fails the item, and a nested object or array fails the item (it
# cannot be a fast field).
#
# Every JSON line is parsed with komira_json from its bytes. The unescaping
# JsonValue API reads the action `_id`, the text field and every field value,
# so `\n`, `\"` and `\uXXXX` round-trip through the analyzer and the _source
# blob. A line is turned into a String only after it parsed, so ill-formed
# UTF-8 is refused by the parser and never becomes a String.
#
# A pure value function over Span[UInt8] -> a value-typed BulkParse
# {RecordBatch + List[BulkItem] + Int + Bool}. No pointers. The per-field
# accumulators, the outcome list and the staged-field tuples are plain Lists
# of String / Float64 / Bool / Int64.
# =============================================================================

from std.builtin.swap import swap
from std.math import isfinite

from komira_arrow.record_batch import RecordBatch

from .bulk_fields import (
    INFER_STRING,
    INFER_INT64,
    INFER_FLOAT64,
    FieldAccum,
    StagedField,
    PendingDoc,
    kind_fits,
    append_staged,
    infer_name,
    infer_kind_for_value,
    build_doc_batch,
)

from komira_json import (
    JsonValue,
    parse_json_bytes,
    refuse_duplicate_keys,
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
)


# The cap on the fields one index may map dynamically (OpenSearch's
# `index.mapping.total_fields.limit` default). Each distinct field name costs an
# accumulator that every committed document pads, so an unbounded count would
# let a request body drive the work and memory of a `_bulk`. A document that
# carries more fields than the cap, or that would take the union schema past it,
# fails as an item.
comptime MAX_DYNAMIC_FIELDS: Int = 1000

# The cap on the cells of one `_bulk` batch: committed documents times mapped
# fields. Every committed document pads every mapped field with a cell (a null
# where it omits the field), so the fields cap alone does not bound memory: one
# document with MAX_DYNAMIC_FIELDS fields followed by many one-field documents
# costs MAX_DYNAMIC_FIELDS cells per document. A document that would take the
# batch past the cap fails as an item. The cap is about 26 MB of accumulator
# cells for string fields.
comptime MAX_BATCH_CELLS: Int = 1048576

# Reserved column names the translator owns / forbids on a source doc.
comptime SOURCE_COL: String = String("_source")
comptime FIELDNORM_COL: String = String("__fieldnorm__")


# -----------------------------------------------------------------------------
# Per-item outcome (P1.7 net-new) + per-item status constants.
# -----------------------------------------------------------------------------
comptime ITEM_STATUS_CREATED: Int = 201
comptime ITEM_STATUS_BAD_REQUEST: Int = 400


@fieldwise_init
struct BulkItem(Copyable, Movable, Deinitable):
    """One `_bulk` item outcome, in NDJSON order (P1.7 per-item partial-success).

    Copyable (synthesized): every field is ImplicitlyCopyable (String + Int +
    Bool) so the outcome can live in a `List[BulkItem]` (Mojo: `List[T]`
    requires `T: Copyable`).

    A SUCCESS item: status=201, ok=True, result="created", error_* empty. A
    FAILED item: status=400, ok=False, result empty, error_type/error_reason
    carry the OpenSearch-shaped error. `client_id` always echoes the action
    line's `_id` (or the minted dense ordinal) so the response item carries the
    right `_id` even for a failed doc. `verb` is the action verb (`index`,
    `create`, `update`, `delete`) the response item is keyed by.

    Fields:
      client_id:    the action `_id` (or the minted dense ordinal).
      status:       201 (created) or 400 (bad request).
      ok:           True iff the doc indexed (status 201).
      result:       "created" for a success; empty for a failure.
      error_type:   the OpenSearch error `type` (failure only; empty otherwise).
      error_reason: the OpenSearch error `reason` (failure only; empty).
      verb:         the action verb the item answers (`index` when the action
                    line could not be read)."""

    var client_id: String
    var status: Int
    var ok: Bool
    var result: String
    var error_type: String
    var error_reason: String
    var verb: String

    @staticmethod
    def created(
        var client_id: String, var verb: String = String("index")
    ) -> BulkItem:
        """A success item (status 201, result "created")."""
        return BulkItem(
            client_id=client_id^,
            status=ITEM_STATUS_CREATED,
            ok=True,
            result=String("created"),
            error_type=String(""),
            error_reason=String(""),
            verb=verb^,
        )

    @staticmethod
    def failed(
        var client_id: String,
        var error_type: String,
        var error_reason: String,
        var verb: String = String("index"),
    ) -> BulkItem:
        """A failed item (status 400, OpenSearch-shaped error)."""
        return BulkItem(
            client_id=client_id^,
            status=ITEM_STATUS_BAD_REQUEST,
            ok=False,
            result=String(""),
            error_type=error_type^,
            error_reason=error_reason^,
            verb=verb^,
        )


struct BulkParse(Movable, Deinitable):
    """The parsed `_bulk` body (P1.7 per-item). The MULTI-column DocBatch built
    from the GOOD docs only + the per-item outcome list (NDJSON order) + the
    good-doc count + the any-error flag.

    A SINGLE explicit defaulted __init__ (NO @fieldwise_init with
    a same-arity custom init). Movable-only — owns a RecordBatch (Movable-only,
    not Copyable) + heap-owning Lists.

    a stack value the handler consumes immediately (init_sink / accept_
    batch / response echo). Never a byte-slab element.

    P1.7: `items` carries one BulkItem per NDJSON action+source pair (both
    succeeded and failed), in wire order, for the `items[]` response. `count` is
    the number of COMMITTED (indexed) docs == docbatch.num_rows(); a failed item
    contributes NO row. `any_error` = (any item failed) -> the response
    `errors` flag.

    Fields:
      docbatch:   the N-col {<text_field>:STRING, _source:STRING, <inferred>...}
                  RecordBatch over the COMMITTED docs.
      items:      one BulkItem per NDJSON pair, in wire order (success + failure).
      count:      the number of COMMITTED docs (== docbatch.num_rows()).
      any_error:  True iff any item failed (the response `errors` flag).
    """

    var docbatch: RecordBatch
    var items: List[BulkItem]
    var count: Int
    var any_error: Bool

    def __init__(
        out self,
        var docbatch: RecordBatch,
        var items: List[BulkItem],
        count: Int,
        any_error: Bool,
    ):
        self.docbatch = docbatch^
        self.items = items^
        self.count = count
        self.any_error = any_error

    def take_docbatch(mut self) raises -> RecordBatch:
        """Move the DocBatch out of `self`, leaving an empty RecordBatch in its
        place (the swap-then-move idiom — hard-ban #11 replacement for a partial
        move out of the middle of a value). The caller may still read
        `self.items` / `self.count` / `self.any_error` afterward; `self` stays
        destructor-safe (its docbatch field is a valid empty value)."""
        var out = RecordBatch()
        swap(self.docbatch, out)
        return out^


def _line_bytes(body: Span[UInt8, _], start: Int, end: Int) -> List[UInt8]:
    """Copy the byte range `[start, end)`. The ranges come from
    _split_records (validated, bounds-safe)."""
    var buf = List[UInt8](capacity=end - start)
    for i in range(start, end):
        buf.append(body[i])
    return buf^


def _bytes_to_string(buf: List[UInt8]) -> String:
    """The String of bytes that already parsed as JSON, so they are well-formed
    UTF-8 (the parser refuses anything else)."""
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _split_records(
    body: Span[UInt8, _], mut starts: List[Int], mut ends: List[Int]
):
    """Append the byte range of every non-blank record of `body`. A record ends
    at every raw `\\n`, as in OpenSearch: valid JSON never holds a raw newline
    inside a string, so a line with an unbalanced quote must not swallow the
    records after it. Blank lines (a trailing newline, a client's separators)
    are skipped."""
    var start = 0
    var n = len(body)
    for i in range(n):
        if body[i] == 0x0A:
            if not _is_blank_line(body, start, i):
                starts.append(start)
                ends.append(i)
            start = i + 1
    if start < n and not _is_blank_line(body, start, n):
        starts.append(start)
        ends.append(n)


def _require_source_line(li: Int, n_lines: Int) raises:
    """The one whole-request raise: an action that takes a source line is the
    last record, so the source document is structurally missing and the failure
    cannot be attributed to one item."""
    if li + 1 >= n_lines:
        raise Error(
            "bulk parse: dangling action line with no source doc (the final"
            " action line has no source line)"
        )


def _is_blank_line(body: Span[UInt8, _], start: Int, end: Int) -> Bool:
    """True if `[start, end)` is empty or all ASCII whitespace (a blank
    separator line — NDJSON tolerates a trailing newline / blank lines)."""
    for i in range(start, end):
        var c = body[i]
        if c != 0x20 and c != 0x09 and c != 0x0A and c != 0x0D:
            return False
    return True


def ndjson_bulk_to_docbatch(
    body: Span[UInt8, _],
    text_field: String,
    max_cells: Int = MAX_BATCH_CELLS,
) raises -> BulkParse:
    """Parse the `_bulk` NDJSON body into an N-column DocBatch (over the GOOD
    docs) + the per-item outcome list in NDJSON order (per-item
    partial success).

    Wire: an action line, then a source line (none after a `delete` action);
    only the `index` action is supported. The action's `_id` (string client identity) is
    echoed in the response; if absent a dense ordinal ("0", "1", ...) is minted.
    The source doc's `text_field` value is extracted into the body column; the
    VERBATIM source line is carried as the `_source` blob; EVERY OTHER scalar
    field is dynamically mapped into a typed fast-field column.

    P1.7 per-item partial-success: a per-doc validation/conflict failure does
    NOT abort the request — the failing item gets a status-400 outcome and is
    EXCLUDED; the good docs still index. Per-item failures:
      * non-`index` action (create/update/delete) -> action_not_supported 400.
      * missing `body` (the text field) -> 400.
      * malformed action/doc JSON for that pair / a non-object action/source ->
        400.
      * a non-string text field -> 400.
      * a nested object/array field -> 400.
      * a reserved-name doc key (`_source`/`__fieldnorm__`) -> 400.
      * a dynamic-mapping type conflict with the resolved union type (no
        int->float widen) -> mapper_parsing_exception 400.

    The ONLY whole-request RAISE is a TRUE framing error that cannot be
    attributed to one item: a final action line that needs a source line and
    has none. A `delete` action has no source line and is answered with its own
    failed item. The handler maps the raise to a 400 envelope.

    `max_cells` bounds committed documents times mapped fields (see
    MAX_BATCH_CELLS); a document that would pass it fails as an item.

    Bounds-safe: every line range comes from _split_records; the JSON
    reads go through the unescaping JsonValue API (no UnsafePointer, no
    substring byte-arith)."""
    var starts = List[Int]()
    var ends = List[Int]()
    _split_records(body, starts, ends)

    var n_lines = len(starts)
    if n_lines == 0:
        # Empty body -> an empty DocBatch (count 0). The handler short-circuits
        # to the empty `_bulk` response and does NOT feed the sink.
        return _empty_bulk_parse(text_field)

    # -------------------------------------------------------------------------
    # Phase 1 — per-record parse + validation. Each action -> a SUCCESS-eligible
    # PendingDoc (staged) OR a failed BulkItem. The `items` list is built in
    # NDJSON order with one entry per action (a pending doc's item starts as a
    # placeholder SUCCESS, flipped to a failure in phase 2 only on a conflict).
    # An action is followed by a source line, except `delete`, which has none.
    # -------------------------------------------------------------------------
    var items = List[BulkItem]()
    var pending = List[PendingDoc]()

    var li = 0
    var ordinal = 0
    while li < n_lines:
        var item_index = len(items)
        # The client id is resolved BEFORE the source validation so a failed
        # item still echoes the right `_id`. The ordinal is minted per ACTION
        # (whether or not the doc is good) so the dense ordinal matches the
        # OpenSearch auto-id-per-action sequence.
        var client_id = String(ordinal)
        ordinal += 1

        # ---- action line ----
        var action_opt = _try_parse(_line_bytes(body, starts[li], ends[li]))
        if not action_opt:
            _require_source_line(li, n_lines)
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("parse_exception"),
                    String("bulk parse: action line is not valid JSON"),
                )
            )
            li += 2
            continue
        var action = action_opt.take()
        if not action.is_object():
            _require_source_line(li, n_lines)
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("parse_exception"),
                    String("bulk parse: action line is not a JSON object"),
                )
            )
            li += 2
            continue
        var action_dup = False
        try:
            refuse_duplicate_keys(action)
        except:
            action_dup = True
        if action_dup:
            _require_source_line(li, n_lines)
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("parse_exception"),
                    String("bulk parse: action line names a key more than once"),
                )
            )
            li += 2
            continue
        # Only the `index` action is supported.
        if not action.has(String("index")):
            # Echo a client `_id` from the (unsupported) action if it carries
            # one (create/update/delete also carry `_id`); else the ordinal.
            var bad_id = _extract_action_id(action, client_id)
            var verb = String("index")
            if len(action.obj_keys) > 0:
                verb = action.obj_keys[0]
            # A `delete` action has no source line; every other verb has one.
            var step = 1 if verb == String("delete") else 2
            if step == 2:
                _require_source_line(li, n_lines)
            items.append(
                BulkItem.failed(
                    bad_id^,
                    String("action_not_supported"),
                    String(
                        "bulk parse: action not supported (only the `index`"
                        " action is supported; create/update/delete are not)"
                    ),
                    verb^,
                )
            )
            li += step
            continue
        _require_source_line(li, n_lines)
        var action_meta = action.get(String("index"))
        # Extract the client `_id` if present; else keep the dense ordinal.
        if action_meta.is_object() and action_meta.has(String("_id")):
            try:
                client_id = action_meta.get(String("_id")).as_string()
            except:
                pass  # a non-string _id keeps the ordinal echo.

        # ---- source line (even index 1, 3, 5, ...) ----
        var src_start = starts[li + 1]
        var src_end = ends[li + 1]
        var source_bytes = _line_bytes(body, src_start, src_end)
        var source_opt = _try_parse(source_bytes)
        if not source_opt:
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("parse_exception"),
                    String("bulk parse: source line is not valid JSON"),
                )
            )
            li += 2
            continue
        var source_doc = source_opt.take()
        var source_line = _bytes_to_string(source_bytes)
        if not source_doc.is_object():
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("parse_exception"),
                    String("bulk parse: source line is not a JSON object"),
                )
            )
            li += 2
            continue
        var dup_failed = False
        try:
            # A key named twice would stage two cells for one document and
            # leave the column longer than the row count.
            refuse_duplicate_keys(source_doc)
        except:
            dup_failed = True
        if dup_failed:
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("parse_exception"),
                    String("bulk parse: source doc names a field more than once"),
                )
            )
            li += 2
            continue
        if not source_doc.has(text_field):
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("mapper_parsing_exception"),
                    String(
                        "bulk parse: source doc is missing the text field '"
                    )
                    + text_field
                    + "' (P0 single-text-field mapping)",
                )
            )
            li += 2
            continue
        var text_jv = source_doc.get(text_field)
        if text_jv.kind_tag() != JSON_STRING:
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("mapper_parsing_exception"),
                    String(
                        "bulk parse: the text field '"
                    )
                    + text_field
                    + "' must be a string",
                )
            )
            li += 2
            continue
        # The text field's value (already-unescaped via the JsonValue API).
        var text_value = source_doc.get(text_field).as_string()

        # ---- stage every OTHER scalar field; per-item-reject nested/reserved ----
        var staged = List[StagedField]()
        var item_failed = False
        var fail_type = String("")
        var fail_reason = String("")
        var n_members = source_doc.num_members()
        for m in range(n_members):
            var key = source_doc.key_at(m)
            # Skip the text field (already the body column).
            if key == text_field:
                continue
            # Per-item-reject reserved-name collisions.
            if key == SOURCE_COL:
                item_failed = True
                fail_type = String("mapper_parsing_exception")
                fail_reason = String(
                    "bulk parse: source doc key '_source' is reserved (it"
                    " collides with the synthesized _source blob)"
                )
                break
            if key == FIELDNORM_COL:
                item_failed = True
                fail_type = String("mapper_parsing_exception")
                fail_reason = String(
                    "bulk parse: source doc key '__fieldnorm__' is reserved"
                    " (the doc-length fieldnorm)"
                )
                break
            var vkind = source_doc.value_kind(m)
            # null/bool contribute NO fast-field column (null -> no field
            # contribution; bool -> dropped-to-_source).
            if vkind == JSON_NULL or vkind == JSON_BOOL:
                continue
            var value = source_doc.value_at(m)
            var this_kind = infer_kind_for_value(vkind, value)
            if this_kind < 0:
                # A nested object/array field -> reject the item.
                item_failed = True
                fail_type = String("mapper_parsing_exception")
                fail_reason = (
                    String(
                        "bulk parse: dynamic mapping of nested object / array"
                        " field '"
                    )
                    + key
                    + "' is not supported in v1 (flatten to scalar fields or"
                    " omit)"
                )
                break
            # Eagerly extract the scalar into the typed slot matching `this_kind`
            # (a JsonValue field would break StagedField's Copyable synthesis).
            var str_val = String("")
            var i64_val = Int64(0)
            var f64_val = Float64(0.0)
            var out_of_range = False
            if this_kind == INFER_STRING:
                str_val = value.as_string()
            elif this_kind == INFER_INT64:
                try:
                    i64_val = value.as_int64()
                except:
                    out_of_range = True
            else:
                try:
                    f64_val = value.as_float64()
                except:
                    out_of_range = True
                if not out_of_range and not isfinite(f64_val):
                    out_of_range = True
            if out_of_range:
                # A number outside the range of long / double fails the item;
                # it must not abort the whole request or store inf / nan.
                item_failed = True
                fail_type = String("mapper_parsing_exception")
                fail_reason = (
                    String("bulk parse: numeric value of field '")
                    + key
                    + "' is out of range"
                )
                break
            if len(staged) >= MAX_DYNAMIC_FIELDS:
                item_failed = True
                fail_type = String("mapper_parsing_exception")
                fail_reason = String(
                    "bulk parse: source doc exceeds the limit of "
                ) + String(MAX_DYNAMIC_FIELDS) + " fields"
                break
            staged.append(
                StagedField(key.copy(), this_kind, str_val^, i64_val, f64_val)
            )

        if item_failed:
            items.append(
                BulkItem.failed(client_id^, fail_type^, fail_reason^)
            )
            li += 2
            continue

        # The item starts as a SUCCESS placeholder; phase 2 may flip it to a
        # failure on a type conflict. (It owns the item at `item_index`.)
        items.append(BulkItem.created(client_id^))
        pending.append(
            PendingDoc(
                item_index,
                items[item_index].client_id.copy(),
                text_value^,
                source_line^,
                staged^,
            )
        )
        li += 2

    # -------------------------------------------------------------------------
    # Phase 2 — union-schema resolution over the candidates IN ORDER, with
    # per-candidate type-conflict EXCLUSION. A candidate that conflicts is
    # flipped to a failed item and dropped (its values are NOT committed). A
    # candidate that fits is COMMITTED (its values feed the accumulators).
    # -------------------------------------------------------------------------
    var text_values = List[String]()
    var source_values = List[String]()
    var fields = List[FieldAccum]()  # the union accumulators (first-seen order).
    # field name -> index into `fields`, so a lookup is O(1) instead of a scan
    # of up to MAX_DYNAMIC_FIELDS names per staged field.
    var field_index = Dict[String, Int]()
    var committed = 0

    for pi in range(len(pending)):
        ref doc = pending[pi]
        # First: a DRY conflict check against the CURRENT established types —
        # do NOT mutate any accumulator until we know the doc fits (so an
        # excluded candidate leaves the schema untouched).
        var conflict = False
        var conflict_field = String("")
        var conflict_established = INFER_STRING
        var conflict_this = INFER_STRING
        var net_new = 0
        for si in range(len(doc.staged)):
            ref sf = doc.staged[si]
            if sf.name not in field_index:
                net_new += 1
                continue  # a net-new field — no established type to conflict.
            var fi = field_index[sf.name]
            var established = fields[fi].inferred
            if not kind_fits(established, sf.kind):
                conflict = True
                conflict_field = sf.name.copy()
                conflict_established = established
                conflict_this = sf.kind
                break

        if not conflict and len(fields) + net_new > MAX_DYNAMIC_FIELDS:
            # Mapping this document's new fields would pass the field limit.
            items[doc.item_index] = BulkItem.failed(
                items[doc.item_index].client_id.copy(),
                String("mapper_parsing_exception"),
                String("bulk parse: mapper_parsing_exception — limit of ")
                + String(MAX_DYNAMIC_FIELDS)
                + " mapped fields exceeded",
            )
            continue

        if not conflict and (committed + 1) * (
            len(fields) + net_new
        ) > max_cells:
            # Committing this document would pad every mapped field with one
            # more cell; stop before the batch outgrows the cell budget.
            items[doc.item_index] = BulkItem.failed(
                items[doc.item_index].client_id.copy(),
                String("mapper_parsing_exception"),
                String("bulk parse: mapper_parsing_exception — the batch would")
                + " exceed "
                + String(max_cells)
                + " cells (documents times mapped fields)",
            )
            continue

        if conflict:
            # Flip this candidate's item to a failure; do NOT commit.
            items[doc.item_index] = BulkItem.failed(
                items[doc.item_index].client_id.copy(),
                String("mapper_parsing_exception"),
                String("bulk parse: mapper_parsing_exception — field '")
                + conflict_field
                + "' was first mapped as "
                + infer_name(conflict_established)
                + " but this doc carries an incompatible "
                + infer_name(conflict_this)
                + " value",
            )
            continue

        # No conflict -> COMMIT. Append the body + _source rows, then apply
        # every staged field (creating a net-new accumulator on first sight,
        # back-filling nulls for the committed docs before it).
        text_values.append(doc.text_value.copy())
        source_values.append(doc.source_line.copy())
        for si in range(len(doc.staged)):
            ref sf = doc.staged[si]
            if sf.name not in field_index:
                var acc = FieldAccum(sf.name.copy(), sf.kind)
                acc._pad_to(committed)
                append_staged(acc, sf)
                field_index[sf.name.copy()] = len(fields)
                fields.append(acc^)
            else:
                append_staged(fields[field_index[sf.name]], sf)
        # Pad every field NOT present in this committed doc with a null cell.
        for fi in range(len(fields)):
            # PERF-CRITICAL: bind a reference. Reading `fields[fi].valid`
            # through the list must not copy the accumulator (it holds one
            # cell per committed document), or the loop is quadratic.
            ref acc = fields[fi]
            if len(acc.valid) <= committed:
                acc._pad_to(committed + 1)
        committed += 1

    # -------------------------------------------------------------------------
    # Phase 3 — build the N-column DocBatch from the COMMITTED docs.
    # -------------------------------------------------------------------------
    var docbatch = build_doc_batch(
        text_field, text_values, source_values, fields
    )
    var any_error = False
    for ii in range(len(items)):
        if not items[ii].ok:
            any_error = True
            break
    return BulkParse(docbatch^, items^, committed, any_error)


def _try_parse(buf: List[UInt8]) -> Optional[JsonValue]:
    """Try to parse `buf` as a JsonValue. Returns the value on success; None on
    a parse error (P1.7 — a malformed line fails the ITEM, not the request).
    Catches the raise so the caller never aborts. The caller `.take()`s the
    value out (JsonValue is move-only / explicitly-copyable, not
    ImplicitlyCopyable, so a tuple-subscript copy would not compile)."""
    try:
        return Optional[JsonValue](parse_json_bytes(buf))
    except:
        return Optional[JsonValue]()


def _extract_action_id(action: JsonValue, var fallback: String) -> String:
    """Echo a client `_id` from an action's (any-verb) meta object if present;
    else the fallback (the dense ordinal). Used for a non-index action's failed
    item so it still carries the client's `_id`."""
    var n = action.num_members()
    for m in range(n):
        try:
            var meta = action.value_at(m)
            if meta.is_object() and meta.has(String("_id")):
                var id_jv = meta.get(String("_id"))
                if id_jv.kind_tag() == JSON_STRING:
                    return id_jv.as_string()
        except:
            pass
    return fallback^


def _empty_bulk_parse(text_field: String) raises -> BulkParse:
    """A BulkParse for an empty body: a 0-row 2-col DocBatch + no items +
    count 0 + no error. (The handler short-circuits to the empty response; this
    exists so the function's return shape is uniform.) No docs -> no inferred
    fields -> the schema is just {body, _source}."""
    var empty_text = List[String]()
    var empty_source = List[String]()
    var empty_fields = List[FieldAccum]()
    var docbatch = build_doc_batch(
        text_field, empty_text, empty_source, empty_fields
    )
    return BulkParse(docbatch^, List[BulkItem](), 0, False)
