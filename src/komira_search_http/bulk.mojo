# =============================================================================
# bulk.mojo — the `_bulk` NDJSON -> DocBatch translator
# =============================================================================
#
# The OpenSearch/Elasticsearch `_bulk` request translator. It parses the
# ALTERNATING action-line + source-line NDJSON wire (the `index` action only)
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
# one item: an odd number of non-blank NDJSON lines (a dangling action line
# with no source document). The handler maps it to a 400 envelope.
#
# Dynamic field mapping, applied to the good documents:
#   Pass 1 (stage): per-pair parse and validation -> a _PendingDoc (text value,
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

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_jsonl.line_splitter import split_lines_in_buffer

from .bulk_columns import str_col_nullable, i64_col_nullable, f64_col_nullable

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


# -----------------------------------------------------------------------------
# Inferred-field type codes (the v1 dynamic-mapping set, doc 18 §1.1).
# -----------------------------------------------------------------------------
#
# The translator infers ONLY these three Arrow types (the set the SearchSink
# classifier reliably keeps as fast-fields): STRING (keyword), INT64 (long),
# FLOAT64 (double). bool/null/object/array do NOT produce a fast-field column.
comptime INFER_STRING: Int = 0
comptime INFER_INT64: Int = 1
comptime INFER_FLOAT64: Int = 2

# The cap on the fields one index may map dynamically (OpenSearch's
# `index.mapping.total_fields.limit` default). Each distinct field name costs an
# accumulator that every committed document pads, so an unbounded count would
# let a request body drive the work and memory of a `_bulk`. A document that
# carries more fields than the cap, or that would take the union schema past it,
# fails as an item.
comptime MAX_DYNAMIC_FIELDS: Int = 1000

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
    Bool) so the outcome can live in a `List[BulkItem]` (Mojo 1.0.0b1: `List[T]`
    requires `T: Copyable`). gap6 N/A — a stack value, never a byte-slab element.

    A SUCCESS item: status=201, ok=True, result="created", error_* empty. A
    FAILED item: status=400, ok=False, result empty, error_type/error_reason
    carry the OpenSearch-shaped error. `client_id` always echoes the action
    line's `_id` (or the minted dense ordinal) so the response item carries the
    right `_id` even for a failed doc.

    Fields:
      client_id:    the action `_id` (or the minted dense ordinal).
      status:       201 (created) or 400 (bad request).
      ok:           True iff the doc indexed (status 201).
      result:       "created" for a success; empty for a failure.
      error_type:   the OpenSearch error `type` (failure only; empty otherwise).
      error_reason: the OpenSearch error `reason` (failure only; empty)."""

    var client_id: String
    var status: Int
    var ok: Bool
    var result: String
    var error_type: String
    var error_reason: String

    @staticmethod
    def created(var client_id: String) -> BulkItem:
        """A success item (status 201, result "created")."""
        return BulkItem(
            client_id=client_id^,
            status=ITEM_STATUS_CREATED,
            ok=True,
            result=String("created"),
            error_type=String(""),
            error_reason=String(""),
        )

    @staticmethod
    def failed(
        var client_id: String, var error_type: String, var error_reason: String
    ) -> BulkItem:
        """A failed item (status 400, OpenSearch-shaped error)."""
        return BulkItem(
            client_id=client_id^,
            status=ITEM_STATUS_BAD_REQUEST,
            ok=False,
            result=String(""),
            error_type=error_type^,
            error_reason=error_reason^,
        )


struct _FieldAccum(Copyable, Movable, Deinitable):
    """A per-inferred-field accumulator (P1.6 pass-2 state). One per UNION-schema
    field name; the values List is positionally aligned to the COMMITTED-doc
    index (a committed doc that omits the field contributes a null cell).

    Copyable (synthesized): every field is ImplicitlyCopyable (String + List of
    String/Int64/Float64/Bool) so the accumulator can live in a `List[_FieldAccum]`
    (Mojo 1.0.0b1: `List[T]` requires `T: Copyable`). gap6 N/A — a stack value,
    never a byte-slab element.

    The inferred Arrow type is fixed by the FIRST committed non-null occurrence
    (doc 18 §3). A later value either fits (stored), coerces (int->FLOAT64), or
    rejects the candidate doc (P1.7: the candidate is excluded, NOT raised).

    Storage: a string field keeps its values in `str_vals` + `valid`; a numeric
    field keeps its values in `f64_vals` (FLOAT64) or `i64_vals` (INT64) + `valid`.
    Only the List matching `inferred` is populated. All are plain stack Lists —
    gap6 N/A (never a byte-slab element).

    Fields:
      name:      the field name (the Arrow column name).
      inferred:  INFER_STRING / INFER_INT64 / INFER_FLOAT64.
      str_vals:  per-committed-doc string values (INFER_STRING).
      i64_vals:  per-committed-doc int values (INFER_INT64).
      f64_vals:  per-committed-doc float values (INFER_FLOAT64).
      valid:     per-committed-doc validity (True = present non-null; False = null)."""

    var name: String
    var inferred: Int
    var str_vals: List[String]
    var i64_vals: List[Int64]
    var f64_vals: List[Float64]
    var valid: List[Bool]

    def __init__(out self, var name: String, inferred: Int):
        self.name = name^
        self.inferred = inferred
        self.str_vals = List[String]()
        self.i64_vals = List[Int64]()
        self.f64_vals = List[Float64]()
        self.valid = List[Bool]()

    def _pad_to(mut self, doc_index: Int):
        """Back-fill null cells for committed docs [len(valid), doc_index) that
        did not carry this field (it was first seen at a later committed doc, or
        skipped earlier). Keeps the value Lists positionally aligned to the
        committed-doc index."""
        while len(self.valid) < doc_index:
            self.valid.append(False)
            if self.inferred == INFER_STRING:
                self.str_vals.append(String(""))
            elif self.inferred == INFER_INT64:
                self.i64_vals.append(Int64(0))
            else:
                self.f64_vals.append(Float64(0.0))


struct _StagedField(Copyable, Movable, Deinitable):
    """A per-candidate-doc staged field (P1.7 pass-1 output). The (name, inferred
    kind, EAGERLY-EXTRACTED value) for a single fast-fieldable scalar field of a
    candidate doc — staged in phase 1 so phase 2 can resolve the union schema
    with per-doc conflict EXCLUSION (a conflict drops the whole candidate, so the
    per-doc fields must be applied atomically, after the no-conflict check).

    Copyable (synthesized): String + Int + Int64 + Float64 — all
    ImplicitlyCopyable. NOTE: a `JsonValue` field would BREAK Copyable synthesis
    (Mojo 1.0.0b1: JsonValue is explicitly-copyable, NOT ImplicitlyCopyable), so
    the scalar is extracted EAGERLY during phase 1 into the typed slot matching
    `kind`. gap6 N/A — a stack value, never a byte-slab element.

    Only the slot matching `kind` is populated (str_val for INFER_STRING,
    i64_val for INFER_INT64, f64_val for INFER_FLOAT64). The int->FLOAT64 widen
    at commit reads `i64_val` as a float.

    Fields:
      name:    the field name.
      kind:    the per-value inferred kind (INFER_STRING/INT64/FLOAT64).
      str_val: the string value (INFER_STRING; empty otherwise).
      i64_val: the int value (INFER_INT64; 0 otherwise).
      f64_val: the float value (INFER_FLOAT64; 0.0 otherwise)."""

    var name: String
    var kind: Int
    var str_val: String
    var i64_val: Int64
    var f64_val: Float64

    def __init__(
        out self,
        var name: String,
        kind: Int,
        var str_val: String,
        i64_val: Int64,
        f64_val: Float64,
    ):
        self.name = name^
        self.kind = kind
        self.str_val = str_val^
        self.i64_val = i64_val
        self.f64_val = f64_val


struct _PendingDoc(Copyable, Movable, Deinitable):
    """A candidate good doc staged by phase 1 (P1.7). It cleared per-pair
    validation (an `index` action + a present non-string-checked text field + no
    nested/array/reserved-key field). It still must clear phase-2 type-conflict
    resolution to be COMMITTED.

    Copyable (synthesized): String + List[_StagedField]. gap6 N/A.

    Fields:
      item_index: the index into the NDJSON-order BulkItem list this doc owns
                  (so phase 2 can flip that item to a failure on a conflict).
      client_id:  the action `_id` / minted ordinal (the item echo).
      text_value: the (already-unescaped) text-field value -> the body column.
      source_line: the VERBATIM source line -> the _source blob.
      staged:     this doc's fast-fieldable fields (name, kind, value)."""

    var item_index: Int
    var client_id: String
    var text_value: String
    var source_line: String
    var staged: List[_StagedField]

    def __init__(
        out self,
        item_index: Int,
        var client_id: String,
        var text_value: String,
        var source_line: String,
        var staged: List[_StagedField],
    ):
        self.item_index = item_index
        self.client_id = client_id^
        self.text_value = text_value^
        self.source_line = source_line^
        self.staged = staged^


def _arrow_type_for_infer(inferred: Int) -> ArrowType:
    if inferred == INFER_STRING:
        return ArrowType.STRING
    elif inferred == INFER_INT64:
        return ArrowType.INT64
    else:
        return ArrowType.FLOAT64


struct BulkParse(Movable, Deinitable):
    """The parsed `_bulk` body (P1.7 per-item). The MULTI-column DocBatch built
    from the GOOD docs only + the per-item outcome list (NDJSON order) + the
    good-doc count + the any-error flag.

    H3 init idiom: a SINGLE explicit defaulted __init__ (NO @fieldwise_init with
    a same-arity custom init). Movable-only — owns a RecordBatch (Movable-only,
    not Copyable) + heap-owning Lists.

    gap6: a stack value the handler consumes immediately (init_sink / accept_
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
    split_lines_in_buffer (validated, bounds-safe)."""
    var buf = List[UInt8](capacity=end - start)
    for i in range(start, end):
        buf.append(body[i])
    return buf^


def _bytes_to_string(buf: List[UInt8]) -> String:
    """The String of bytes that already parsed as JSON, so they are well-formed
    UTF-8 (the parser refuses anything else)."""
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _is_blank_line(body: Span[UInt8, _], start: Int, end: Int) -> Bool:
    """True if `[start, end)` is empty or all ASCII whitespace (a blank
    separator line — NDJSON tolerates a trailing newline / blank lines)."""
    for i in range(start, end):
        var c = body[i]
        if c != 0x20 and c != 0x09 and c != 0x0A and c != 0x0D:
            return False
    return True


def _infer_kind_for_value(value_kind: Int, value: JsonValue) -> Int:
    """Map a (non-null, fast-fieldable) JSON value's kind to an INFER_* code.
    Returns -1 for a value that is NOT fast-fieldable (a nested object/array) —
    the caller fails the ITEM (P1.7) rather than raising.

    string -> INFER_STRING; integer number -> INFER_INT64; fractional/exponent
    number -> INFER_FLOAT64. A bool/null is handled BEFORE this (no column). A
    nested object/array -> -1 (the item is rejected)."""
    if value_kind == JSON_STRING:
        return INFER_STRING
    if value_kind == JSON_NUMBER:
        if value.is_integral_number():
            return INFER_INT64
        return INFER_FLOAT64
    # JSON_OBJECT / JSON_ARRAY reach here (bool/null filtered by the caller).
    return -1


def _find_field(fields: List[_FieldAccum], name: String) -> Int:
    """The index of the accumulator named `name`, or -1 if absent. Preserves
    first-seen field order."""
    for i in range(len(fields)):
        if fields[i].name == name:
            return i
    return -1


def _infer_name(inferred: Int) -> StaticString:
    if inferred == INFER_STRING:
        return "keyword(string)"
    elif inferred == INFER_INT64:
        return "long(int64)"
    else:
        return "double(float64)"


def ndjson_bulk_to_docbatch(
    body: Span[UInt8, _], text_field: String
) raises -> BulkParse:
    """Parse the `_bulk` NDJSON body into an N-column DocBatch (over the GOOD
    docs) + the per-item outcome list in NDJSON order (08 §2.1; 18 the
    dynamic-mapping bridge; 18-A6 the per-item partial-success follow-on).

    Wire (VERIFIED vs OS/ES): ALTERNATING action-line + source-line; P0 supports
    the `index` action ONLY. The action's `_id` (string client identity) is
    echoed in the response; if absent a dense ordinal ("0", "1", ...) is minted.
    The source doc's `text_field` value is extracted into the body column; the
    VERBATIM source line is carried as the `_source` blob; EVERY OTHER scalar
    field is dynamically mapped into a typed fast-field column (P1.6, doc 18).

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
    attributed to one item: an ODD number of non-blank NDJSON lines (a dangling
    action with no source doc). The handler maps it to a 400 envelope.

    Bounds-safe: every line range comes from split_lines_in_buffer; the JSON
    reads go through the unescaping JsonValue API (no UnsafePointer, no
    substring byte-arith)."""
    var split = split_lines_in_buffer(body)

    # Collect the NON-BLANK line ranges (the trailing newline / blank lines a
    # client may include are skipped — they are not docs).
    var starts = List[Int]()
    var ends = List[Int]()
    for i in range(len(split.starts)):
        var s = split.starts[i]
        var e = split.ends[i]
        if not _is_blank_line(body, s, e):
            starts.append(s)
            ends.append(e)
    # A trailing PARTIAL line (no terminating \n) is also a line payload.
    var tail_start = split.trailing_partial_start
    if tail_start < len(body) and not _is_blank_line(body, tail_start, len(body)):
        starts.append(tail_start)
        ends.append(len(body))

    var n_lines = len(starts)
    if n_lines == 0:
        # Empty body -> an empty DocBatch (count 0). The handler short-circuits
        # to the empty `_bulk` response and does NOT feed the sink.
        return _empty_bulk_parse(text_field)

    if n_lines % 2 != 0:
        # A dangling action line cannot be attributed to one item (the source
        # doc is structurally missing) -> the ONE whole-request raise.
        raise Error(
            "bulk parse: odd number of non-blank NDJSON lines ("
            + String(n_lines)
            + ") — a dangling action line with no source doc (P0 _bulk is"
            " alternating action+source)"
        )

    # -------------------------------------------------------------------------
    # Phase 1 — per-pair parse + validation. Each pair -> a SUCCESS-eligible
    # _PendingDoc (staged) OR a failed BulkItem. The `items` list is built in
    # NDJSON order with one entry per pair (a pending doc's item starts as a
    # placeholder SUCCESS, flipped to a failure in phase 2 only on a conflict).
    # -------------------------------------------------------------------------
    var items = List[BulkItem]()
    var pending = List[_PendingDoc]()

    var li = 0
    var ordinal = 0
    while li < n_lines:
        var item_index = len(items)
        # The client id is resolved BEFORE the source validation so a failed
        # item still echoes the right `_id`. The ordinal is minted per PAIR
        # (whether or not the doc is good) so the dense ordinal matches the
        # OpenSearch auto-id-per-action sequence.
        var client_id = String(ordinal)
        ordinal += 1

        # ---- action line (odd index 0, 2, 4, ...) ----
        var action_opt = _try_parse(_line_bytes(body, starts[li], ends[li]))
        if not action_opt:
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
            items.append(
                BulkItem.failed(
                    client_id^,
                    String("parse_exception"),
                    String("bulk parse: action line is not a JSON object"),
                )
            )
            li += 2
            continue
        # P0 supports the `index` action ONLY (08 §3.3).
        if not action.has(String("index")):
            # Echo a client `_id` from the (unsupported) action if it carries
            # one (create/update/delete also carry `_id`); else the ordinal.
            var bad_id = _extract_action_id(action, client_id)
            items.append(
                BulkItem.failed(
                    bad_id^,
                    String("action_not_supported"),
                    String(
                        "bulk parse: action not supported (P0 supports the"
                        " `index` action only — create/update/delete are P1)"
                    ),
                )
            )
            li += 2
            continue
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
        var staged = List[_StagedField]()
        var item_failed = False
        var fail_type = String("")
        var fail_reason = String("")
        var n_members = source_doc.num_members()
        for m in range(n_members):
            var key = source_doc.key_at(m)
            # Skip the text field (already the body column, doc 18 §A2).
            if key == text_field:
                continue
            # Per-item-reject reserved-name collisions (doc 18 §6.4).
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
            # contribution; bool -> dropped-to-_source, doc 18 §1.2/§6.7).
            if vkind == JSON_NULL or vkind == JSON_BOOL:
                continue
            var value = source_doc.value_at(m)
            var this_kind = _infer_kind_for_value(vkind, value)
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
            # (a JsonValue field would break _StagedField's Copyable synthesis).
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
                _StagedField(key.copy(), this_kind, str_val^, i64_val, f64_val)
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
            _PendingDoc(
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
    var fields = List[_FieldAccum]()  # the union accumulators (first-seen order).
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
            var fi = _find_field(fields, sf.name)
            if fi < 0:
                net_new += 1
                continue  # a net-new field — no established type to conflict.
            var established = fields[fi].inferred
            if not _kind_fits(established, sf.kind):
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

        if conflict:
            # Flip this candidate's item to a failure; do NOT commit.
            items[doc.item_index] = BulkItem.failed(
                items[doc.item_index].client_id.copy(),
                String("mapper_parsing_exception"),
                String("bulk parse: mapper_parsing_exception — field '")
                + conflict_field
                + "' was first mapped as "
                + _infer_name(conflict_established)
                + " but this doc carries an incompatible "
                + _infer_name(conflict_this)
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
            var fi = _find_field(fields, sf.name)
            if fi < 0:
                var acc = _FieldAccum(sf.name.copy(), sf.kind)
                acc._pad_to(committed)
                _append_staged(acc, sf)
                fields.append(acc^)
            else:
                _append_staged(fields[fi], sf)
        # Pad every field NOT present in this committed doc with a null cell.
        for fi in range(len(fields)):
            if len(fields[fi].valid) <= committed:
                fields[fi]._pad_to(committed + 1)
        committed += 1

    # -------------------------------------------------------------------------
    # Phase 3 — build the N-column DocBatch from the COMMITTED docs.
    # -------------------------------------------------------------------------
    var docbatch = _build_doc_batch(
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


def _kind_fits(established: Int, this_kind: Int) -> Bool:
    """True iff a value of `this_kind` fits a field already established as
    `established` under the first-wins + int->FLOAT64-widen policy (doc 18 §4):
      * exact type match -> fits.
      * int arriving at a FLOAT64 field -> fits (widened, lossless).
      * anything else -> a conflict."""
    if this_kind == established:
        return True
    if established == INFER_FLOAT64 and this_kind == INFER_INT64:
        return True
    return False


def _append_staged(mut acc: _FieldAccum, sf: _StagedField):
    """Append a staged (non-null) value to an accumulator. The caller has proved
    the staged kind fits `acc.inferred` (a net-new accumulator is created with
    the staged field's own kind; an established accumulator passed the
    `_kind_fits` dry check). The ONE coercion: a staged INT64 at a FLOAT64
    accumulator widens to float (lossless)."""
    acc.valid.append(True)
    if acc.inferred == INFER_STRING:
        acc.str_vals.append(sf.str_val)
    elif acc.inferred == INFER_INT64:
        acc.i64_vals.append(sf.i64_val)
    else:
        # FLOAT64 accumulator: a staged FLOAT64 stores f64_val; a staged INT64
        # (the widen case) reads i64_val as a float.
        if sf.kind == INFER_INT64:
            acc.f64_vals.append(Float64(sf.i64_val))
        else:
            acc.f64_vals.append(sf.f64_val)


def _build_doc_batch(
    text_field: String,
    text_values: List[String],
    source_values: List[String],
    fields: List[_FieldAccum],
) raises -> RecordBatch:
    """Build the N-column DocBatch (P1.6, doc 18 §7.2):
        {<text_field>: STRING non-null,
         _source: STRING non-null,
         <field_1>: <inferred type> nullable, ...}
    The text + _source columns are non-nullable (the OQ-2 contract — SearchSink
    .init_sink raises if the _source col is absent). Each inferred field is a
    NULLABLE typed column with per-doc null cells. Column order matches schema
    order (init_sink resolves text/_source by NAME, so the inferred columns may
    follow in any order — doc 18 §5)."""
    var ta = StringArray.from_strings(text_values)
    var sa = StringArray.from_strings(source_values)
    var sb = SchemaBuilder()
    sb.add_field(Field(text_field, ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    for fi in range(len(fields)):
        sb.add_field(
            Field(
                fields[fi].name,
                _arrow_type_for_infer(fields[fi].inferred),
                True,
            )
        )
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2 + len(fields))
    rb.add_column(Column.from_string(ta^))
    rb.add_column(Column.from_string(sa^))
    for fi in range(len(fields)):
        ref f = fields[fi]
        if f.inferred == INFER_STRING:
            rb.add_column(str_col_nullable(f.str_vals, f.valid))
        elif f.inferred == INFER_INT64:
            rb.add_column(i64_col_nullable(f.i64_vals, f.valid))
        else:
            rb.add_column(f64_col_nullable(f.f64_vals, f.valid))
    return rb.build(schema^)


def _empty_bulk_parse(text_field: String) raises -> BulkParse:
    """A BulkParse for an empty body: a 0-row 2-col DocBatch + no items +
    count 0 + no error. (The handler short-circuits to the empty response; this
    exists so the function's return shape is uniform.) No docs -> no inferred
    fields -> the schema is just {body, _source} (doc 18 §7.3)."""
    var empty_text = List[String]()
    var empty_source = List[String]()
    var empty_fields = List[_FieldAccum]()
    var docbatch = _build_doc_batch(
        text_field, empty_text, empty_source, empty_fields
    )
    return BulkParse(docbatch^, List[BulkItem](), 0, False)
