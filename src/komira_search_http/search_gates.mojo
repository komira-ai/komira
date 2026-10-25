# =============================================================================
# search_gates.mojo — the direct-path gates that check a parsed `_search`
# request against one split's fast-field meta
# =============================================================================
#
# `search_json_to_queryir` (search_query.mojo) parses a request without a split
# in hand. These gates run after the split is resolved: each takes the parsed
# QueryIR and the split's `FastFieldReader`, raises (an HTTP 400 for the caller)
# when the filter, sort or aggregation names a field the direct path cannot
# serve, and returns the QueryIR with any `<field>.keyword` alias rewritten to
# the bare keyword fast-field name.
#
# Pure value functions over QueryIR / Expr / FastFieldReader; no pointers.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_IN_LIST,
    BIN_AND,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_search.analyzer import (
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
    FIELD_CLASS_TEXT,
)
from komira_search.fast_fields import FastFieldReader, FF_ENC_FLOAT_FULL
from komira_search.source import (
    QueryIR,
    SORT_FIELD_SCORE,
    SORT_FIELD_DOC,
)

# P1.6-kw: the OpenSearch `<field>.keyword` sub-field suffix. Real OpenSearch
# maps a string field to `text` (analyzed) + a `<field>.keyword` keyword
# sub-field; Kibana / opensearch-py target `<field>.keyword` for exact term
# filters, sort, and terms aggs. Non-`body` strings are keyword-only
# fast-fields stored under the BARE name (P1.6), so `status.keyword` resolves to
# the `status` keyword fast-field. See `_resolve_keyword_field` for the rule.
comptime KEYWORD_SUFFIX: String = String(".keyword")


def _resolve_keyword_field(name: String, reader: FastFieldReader) raises -> String:
    """P1.6-kw — resolve an OpenSearch `<field>.keyword` sub-field alias to the
    bare keyword fast-field name. The fidelity gap (13_..._design / fix note):
    real OS clients/Kibana use `<field>.keyword` for exact term/sort/terms-agg,
    but P1.6 builds keyword fast-fields under the BARE name (`status`), so a
    `status.keyword` reference would fail `has_field` and 400.

    The rule (simplest-correct — suffix-strip in resolution):
      * a name ending in exactly ONE trailing `.keyword` is stripped to its bare
        form, and the bare form is ACCEPTED only if it is a KEYWORD fast-field
        (mirroring OS, which only adds the `.keyword` sub-field to STRINGS).
      * a `.keyword` suffix on a NON-keyword fast-field (numeric / date) -> 400.
      * a `.keyword` suffix on a non-existent bare field (incl. `body`, the TEXT
        field, which has no fast-field) -> 400 (same as today).
      * a name WITHOUT the suffix is returned unchanged (bare-name resolution
        keeps working — more permissive than OS, compatible).

    Scope (documented decision): strip only a SINGLE trailing `.keyword`, not
    arbitrary dotted paths — nested / object fields are out of scope per P1.6.
    `status.keyword.keyword` strips one level to `status.keyword`, which is then
    not a fast-field -> 400. A bare field that legitimately contains a dot but
    does NOT end in `.keyword` is returned unchanged."""
    if not name.endswith(KEYWORD_SUFFIX):
        return name
    var nb = name.as_bytes()
    var bare = String(
        StringSlice(unsafe_from_utf8=nb[: len(nb) - len(KEYWORD_SUFFIX.as_bytes())])
    )
    # An empty bare name (the literal field ".keyword") -> not a fast-field.
    if not reader.has_field(bare):
        raise Error(
            "search parse: `.keyword` sub-field '" + name + "' does not resolve"
            " (no '" + bare + "' fast-field — OpenSearch only adds `.keyword` to"
            " string fields; `body` is analyzed text with no fast-field)"
        )
    var fc = reader.field_class_of(bare)
    if fc != FIELD_CLASS_KEYWORD:
        raise Error(
            "search parse: `.keyword` sub-field '" + name + "' is invalid — '"
            + bare + "' is a non-keyword (numeric/date) field (OpenSearch only"
            " adds the `.keyword` sub-field to string fields)"
        )
    return bare^




# =============================================================================
# §4 — the GATE-AND-ATTACH step: field-existence + literal-dtype gate (§3.3).
# =============================================================================


def gate_filter_against_fastfields(
    var query: QueryIR, reader: FastFieldReader
) raises -> QueryIR:
    """The DIRECT-PATH gate (IM1 (b) / §3.3): given the resolved split's
    fast-field reader, RAISE a clear 400 if any pushed conjunct names a
    non-fast-field or has a literal/field dtype mismatch — the direct path has no
    downstream Filter to fall back to, so silently dropping a filter would be
    silently-wrong (C8). Returns `query` unchanged if every conjunct passes (or
    if there is no filter).

    Mirrors Searcher._pushdown_supported / CB3 EXACTLY (the accept-set here ==
    the engine apply's eval-set).

    P1.6-kw: BEFORE validating, REWRITE any `<field>.keyword` col-ref to its bare
    keyword fast-field name (`_resolve_keyword_field`). The rewrite produces a
    fresh predicate tree the engine reads via the BARE name (the col-ref name is
    what SearchCore.search resolves the fast-field column by), so a
    `{"term":{"status.keyword":...}}` filter reads the same `status` column as
    the bare form. The rewrite RAISES 400 for a `.keyword` on a non-keyword /
    non-existent / `body` field (mirroring OS)."""
    if not query.has_filter():
        return query^
    var rewritten = _rewrite_predicate_keyword_aliases(query.filter_ref(), reader)
    _gate_predicate(rewritten, reader)
    query.replace_filter(rewritten^)
    return query^


def _rewrite_predicate_keyword_aliases(
    pred: Expr, reader: FastFieldReader
) raises -> Expr:
    """P1.6-kw — rebuild the pushed predicate with every `<field>.keyword`
    col-ref resolved to its bare keyword fast-field name (`_resolve_keyword_field`).
    The Expr tree is held immutably behind an `Optional[ArcPointer[Expr]]`
    (shared, no in-place mutation), so the gate rebuilds a FRESH tree:
      * BIN_AND -> recurse both sides, rebuild the AND.
      * a comparison -> rebuild with the (possibly resolved) col-ref name on
        whichever side carries it, the literal copied unchanged.
      * EXPR_IN_LIST -> resolve the child col-ref, copy the value list.
    A non-`.keyword` name is returned unchanged by `_resolve_keyword_field`, so
    a filter with no `.keyword` references rebuilds to a structurally-identical
    tree (the fingerprint is preserved for the bare-name case)."""
    if pred.tag == EXPR_BINARY_OP:
        var op = pred.binary_op()
        if op == BIN_AND:
            var l = _rewrite_predicate_keyword_aliases(
                pred.binary_left_ref(), reader
            )
            var r = _rewrite_predicate_keyword_aliases(
                pred.binary_right_ref(), reader
            )
            return Expr.binary(BIN_AND, l^, r^)
        return _rewrite_comparison_keyword_aliases(pred, reader)
    elif pred.tag == EXPR_IN_LIST:
        ref child = pred.in_list_child_ref()
        if child.tag != EXPR_COL_REF:
            # Not a col-ref child — leave it to the validating gate to reject.
            return pred.copy()
        var resolved = _resolve_keyword_field(child.col_ref_name(), reader)
        ref vals = pred.in_list_values_ref()
        var vals_copy = List[ScalarValue](capacity=len(vals))
        for i in range(len(vals)):
            vals_copy.append(vals[i].copy())
        return Expr.in_list_node(Expr.col_ref(resolved^), vals_copy^)
    # Any other shape is left untouched — the validating gate raises on it.
    return pred.copy()


def _rewrite_comparison_keyword_aliases(
    pred: Expr, reader: FastFieldReader
) raises -> Expr:
    """Rebuild one comparison conjunct with a resolved col-ref name (the literal
    arm is copied verbatim). Handles both col-op-literal orders; a shape that is
    NOT col-op-literal is copied unchanged (the validating gate rejects it)."""
    ref l = pred.binary_left_ref()
    ref r = pred.binary_right_ref()
    var op = pred.binary_op()
    if l.tag == EXPR_COL_REF and r.tag == EXPR_LITERAL:
        var resolved = _resolve_keyword_field(l.col_ref_name(), reader)
        return Expr.binary(
            op, Expr.col_ref(resolved^), Expr.literal(r.literal_value())
        )
    if r.tag == EXPR_COL_REF and l.tag == EXPR_LITERAL:
        var resolved = _resolve_keyword_field(r.col_ref_name(), reader)
        return Expr.binary(
            op, Expr.literal(l.literal_value()), Expr.col_ref(resolved^)
        )
    return pred.copy()


def _gate_predicate(pred: Expr, reader: FastFieldReader) raises:
    """Recursively validate a pushed predicate against the split's fast-fields.
    BIN_AND -> recurse both sides. A comparison -> validate the col-ref is a
    fast-field of the right class for the op AND the literal dtype matches the
    class. EXPR_IN_LIST -> the child + every value. Raises (-> 400) on any
    violation."""
    if pred.tag == EXPR_BINARY_OP:
        var op = pred.binary_op()
        if op == BIN_AND:
            _gate_predicate(pred.binary_left_ref(), reader)
            _gate_predicate(pred.binary_right_ref(), reader)
            return
        _gate_comparison(pred, reader)
        return
    elif pred.tag == EXPR_IN_LIST:
        ref child = pred.in_list_child_ref()
        if child.tag != EXPR_COL_REF:
            raise Error("search parse: IN child is not a column reference")
        var name = child.col_ref_name()
        _require_ff_class(name, reader, False)  # IN is term-class (eq)
        ref vals = pred.in_list_values_ref()
        for i in range(len(vals)):
            _require_literal_matches(name, vals[i], reader)
        return
    raise Error("search parse: unsupported pushed predicate shape")


def _gate_comparison(pred: Expr, reader: FastFieldReader) raises:
    """Validate one comparison conjunct: one bare col-ref + one literal (either
    order), the col-ref a fast-field of the right class for the op, the literal
    dtype matching the class."""
    ref l = pred.binary_left_ref()
    ref r = pred.binary_right_ref()
    var op = pred.binary_op()
    var is_range = (op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE)
    if l.tag == EXPR_COL_REF and r.tag == EXPR_LITERAL:
        var name = l.col_ref_name()
        _require_ff_class(name, reader, is_range)
        _require_literal_matches(name, r.literal_value(), reader)
        return
    if r.tag == EXPR_COL_REF and l.tag == EXPR_LITERAL:
        var name = r.col_ref_name()
        _require_ff_class(name, reader, is_range)
        _require_literal_matches(name, l.literal_value(), reader)
        return
    raise Error("search parse: comparison is not column-op-literal")


def _require_ff_class(name: String, reader: FastFieldReader, is_range: Bool) raises:
    """Raise (-> 400) if `name` is not a fast-field, or is a KEYWORD field used
    with a range op (KEYWORD gets term only in P1.2)."""
    if not reader.has_field(name):
        raise Error(
            "search parse: filter on non-fast-field '" + name + "' is not"
            " supported on the direct path (P1.2)"
        )
    var fc = reader.field_class_of(name)
    if fc == FIELD_CLASS_KEYWORD and is_range:
        raise Error(
            "search parse: range filter on keyword field '" + name + "' is"
            " unsupported in P1.2 (keyword gets term only)"
        )


def _require_literal_matches(
    name: String, lit: ScalarValue, reader: FastFieldReader
) raises:
    """CB3: raise (-> 400) if the literal dtype does not match the resolved
    fast-field class. KEYWORD <- string; NUMERIC-int / DATE <- int/date/ts;
    NUMERIC-float <- float."""
    var fc = reader.field_class_of(name)
    if fc == FIELD_CLASS_KEYWORD:
        if not lit.is_string():
            raise Error(
                "search parse: type mismatch — non-string literal on keyword"
                " field '" + name + "'"
            )
        return
    # NUMERIC / DATE: distinguish float vs int by the field's encoding.
    var enc = _encoding_of(name, reader)
    if enc == FF_ENC_FLOAT_FULL:
        if not lit.is_float():
            raise Error(
                "search parse: type mismatch — non-float literal on float field"
                " '" + name + "'"
            )
        return
    # int numeric / date.
    if not (lit.is_int() or lit.is_date32() or lit.is_timestamp()):
        raise Error(
            "search parse: type mismatch — non-integer literal on numeric/date"
            " field '" + name + "'"
        )


def _encoding_of(name: String, reader: FastFieldReader) raises -> UInt8:
    """The encoding byte for `name` (FF_ENC_FLOAT_FULL marks a float field).
    Walks the public entry_meta_at accessor (IM2)."""
    for i in range(reader.num_fields()):
        var m = reader.entry_meta_at(i)
        if m[0] == name:
            return m[2]
    raise Error("search parse: no fast-field named '" + name + "'")


# =============================================================================
# §5 — the SORT gate: field-existence + TEXT-field rejection (P1.3 §4.3).
# =============================================================================


def gate_sort_against_fastfields(
    var query: QueryIR, reader: FastFieldReader
) raises -> QueryIR:
    """The DIRECT-PATH sort gate (P1.3 §4.3): given the resolved split's
    fast-field reader, RAISE a clear 400 if the sort target is not sortable on
    the direct path. `_score`/`_doc`/"" are ALWAYS allowed (no fast-field
    needed). A named field must be a fast-field of a non-TEXT class:
      * a sort field that is not a fast-field -> 400 (only in the inverted index
        or absent);
      * a sort field that is a TEXT field -> 400 (the OpenSearch
        "Fielddata is disabled on text fields by default" analogue).
    The direct path has no downstream Sort to fall back to, so an unsupported
    sort target cannot be silently kept-downstream (C8 fail-loud).

    P1.6-kw: a `<field>.keyword` sort target is resolved to its bare keyword
    fast-field name FIRST (`_resolve_keyword_field`), and the resolved bare name
    is written back onto `query.sort_field` so the engine sorts by the right
    column (`sort:["status.keyword"]` sorts the `status` keyword fast-field). A
    `.keyword` on a non-keyword / non-existent / `body` field -> 400. Returns the
    (possibly rewritten) query."""
    var sf = query.sort_field
    if sf.byte_length() == 0 or sf == SORT_FIELD_SCORE or sf == SORT_FIELD_DOC:
        return query^  # _score / _doc / default — no fast-field needed.
    var resolved = _resolve_keyword_field(sf, reader)
    if not reader.has_field(resolved):
        # A field present only in the inverted index (a TEXT field) is NOT a
        # fast-field — the "fielddata disabled on text fields" analogue. We
        # cannot tell "absent" from "text-only" via has_field alone, so report
        # the field-class diagnostic the user needs.
        raise Error(
            "search parse: sort on field '" + sf + "' not supported (not a"
            " fast-field — keyword/numeric/date fast-fields only)"
        )
    var fc = reader.field_class_of(resolved)
    if fc == FIELD_CLASS_TEXT:
        raise Error(
            "search parse: sort on text field '" + sf + "' is disabled (use a"
            " keyword/numeric/date field)"
        )
    query.sort_field = resolved^
    return query^


# =============================================================================
# §5b — P1.4: the AGG gate: field-existence + class gate (m1 / §6).
# =============================================================================


def gate_aggs_against_fastfields(
    var query: QueryIR, reader: FastFieldReader
) raises -> QueryIR:
    """The DIRECT-PATH agg gate (m1 / §6): given the resolved split's fast-field
    reader, RAISE a clear 400 if any agg field is not a fast-field of the right
    class. The direct path has no downstream operator to fall back to, so a bad
    agg field cannot be silently kept (C8 fail-loud) — and without this gate the
    field would reach SearchCore and raise a 500-shaped error instead of a 400.
      * metric agg field must be NUMERIC or DATE (a keyword/text field -> 400).
      * `terms` field must be KEYWORD / NUMERIC / DATE (a TEXT field -> 400, the
        fielddata-disabled analogue, mirroring the sort gate).
      * a field absent from the fast-field set -> 400 (only in the inverted
        index, or absent).

    P1.6-kw: a `<field>.keyword` agg field (typically a `terms` agg over
    `status.keyword`) is resolved to its bare keyword fast-field name FIRST
    (`_resolve_keyword_field`) and written back onto the AggSpec so the engine
    buckets/aggregates the right column. A `.keyword` only resolves against a
    KEYWORD field, so a `.keyword` metric agg (e.g. `avg` over `price.keyword`)
    -> 400 (the bare field is numeric, not keyword) BEFORE the metric/numeric
    gate; a `.keyword` on a non-existent / `body` field -> 400. Returns the
    (possibly rewritten) query."""
    var n = len(query.aggs_ref())
    for i in range(n):
        # Resolve `.keyword` against the reader; rewrite the AggSpec field BEFORE
        # the class gate so the resolved bare name is what is validated + read.
        # Copy the field name + is_metric flag OUT (no ref held across the
        # rewrite_agg_field mutation below).
        var raw_field = query.aggs_ref()[i].field.copy()
        var is_metric = query.aggs_ref()[i].is_metric()
        var resolved = _resolve_keyword_field(raw_field, reader)
        if not reader.has_field(resolved):
            raise Error(
                "search parse: aggregation on field '" + resolved + "' not"
                " supported (not a fast-field — keyword/numeric/date fast-fields"
                " only)"
            )
        var fc = reader.field_class_of(resolved)
        if is_metric:
            if fc != FIELD_CLASS_NUMERIC and fc != FIELD_CLASS_DATE:
                raise Error(
                    "search parse: metric aggregation on non-numeric field '"
                    + resolved + "' is unsupported (metric aggs require a"
                    " numeric/date fast-field)"
                )
        else:  # terms
            if fc == FIELD_CLASS_TEXT:
                raise Error(
                    "search parse: `terms` on text field '" + resolved + "' is"
                    " disabled (use a keyword/numeric/date field)"
                )
        query.rewrite_agg_field(i, resolved^)
    return query^

