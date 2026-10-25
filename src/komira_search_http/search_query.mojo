# =============================================================================
# search_query.mojo — the `_search` request JSON -> QueryIR translator
# =============================================================================
#
# The OpenSearch/Elasticsearch `_search` request translator. It parses the
# `match` query, the fast-field filter clauses (term / range / bool-AND), `sort`,
# `from`/`size` and the `aggs` block into the QueryIR that the engine's
# `SearchCore.search` consumes.
#
# Wire:
#   {"query":{"match":{"<field>":"<text>"}},"size":N}
#   {"query":{"term":{"<field>":<value>}}}                  (filter-only -> 400)
#   {"query":{"bool":{"must":[{"match":...},{"term":...},{"range":...}]}}}
#   {"query":{"bool":{"must":[...],"filter":[...]}}}  (filter == unscored must)
#   {"range":{"<field>":{"gte":x,"gt":x,"lte":y,"lt":y}}}   (-> BIN_GE/GT/LE/LT)
#
# THE TWO-STEP LOWERING:
#   (a) search_json_to_queryir(body, generation): the PARSE step. Parses the
#       match spec and collects the candidate fast-field conjuncts into a
#       BIN_AND chain attached to QueryIR.filter. It runs a structural gate
#       (reject should / bool-OR / must_not / filter-only) before any split
#       lookup, so empty-index and populated-index handling agree. It does not
#       run the field-existence or dtype gate: that needs the split's meta.
#   (b) the gates in search_gates.mojo take the resolved split's fast-field
#       meta and raise (an HTTP 400) when a pushed conjunct, sort target or
#       aggregation names a non-fast-field or has a literal/field dtype
#       mismatch. The direct path has no downstream Filter to fall back to.
#
# A filter-only / match_all / constant-score query (filter, term or range
# clauses but no `match`) raises a clear 400. The filter applies inside the
# posting accumulate loop, where only documents that matched a query term
# iterate, so a filter-only request would silently return zero hits. The one
# exception is a request with `aggs`, which takes the whole-split aggregation
# path.
#
# A JSON number keeps its raw text, so the translator inspects the text for
# '.' / 'e' / 'E' to choose an int64 or a float64 literal.
#
# Untrusted input: this module parses HTTP request bodies. The JSON parser
# (komira_json) refuses nesting deeper than its depth limit; this module bounds
# the filter clause count (MAX_BOOL_CLAUSES), refuses a `from` or `size` above
# the result window before adding them (no integer overflow), and rejects the
# nested forms (nested bool, nested aggregations) rather than recursing.
#
# Pure value functions over Span[UInt8] / JsonValue -> QueryIR (+ Expr). No
# pointers.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    BIN_AND,
    BIN_EQ,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_search.analyzer import AnalyzerConfig
from komira_search.source import (
    QueryIR,
    SORT_DESC,
    SORT_ASC,
    MISSING_LAST,
    MISSING_FIRST,
    SORT_FIELD_SCORE,
    AggSpec,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    AGG_KIND_SUM,
    AGG_KIND_VALUE_COUNT,
    AGG_KIND_STATS,
    AGG_ORDER_COUNT_DESC,
    AGG_ORDER_COUNT_ASC,
    AGG_ORDER_KEY_ASC,
    AGG_ORDER_KEY_DESC,
    DEFAULT_TERMS_SIZE,
)

from komira_json import JsonValue, parse_json_bytes

from .envelopes import (
    TRACK_TOTAL_DEFAULT,
    TRACK_TOTAL_TRUE,
    TRACK_TOTAL_FALSE,
)


# The OpenSearch default `size` when the request omits it.
comptime DEFAULT_SIZE: Int = 10

# The OpenSearch `index.max_result_window` default: the cap on from + size.
comptime MAX_RESULT_WINDOW: Int = 10000

# The cap on the term / range clauses of one bool query (OpenSearch's
# `indices.query.bool.max_clause_count` default). The clauses fold into a
# left-leaning BIN_AND chain whose depth is the clause count, and the gates,
# the keyword rewrite and the destructor all walk that chain recursively, so an
# unbounded count would let a request body drive the stack depth.
comptime MAX_BOOL_CLAUSES: Int = 1024


def _parse_body(body: Span[UInt8, _]) raises -> JsonValue:
    """Parse the request body bytes as JSON. The bytes are handed to the parser
    directly, so a body that is not valid UTF-8 is refused by the parser and is
    never turned into a String first."""
    var buf = List[UInt8](capacity=len(body))
    for i in range(len(body)):
        buf.append(body[i])
    return parse_json_bytes(buf)


# =============================================================================
# §1 — literal inference (PR3 — a JSON NUMBER keeps raw text, no is_integral).
# =============================================================================


def _number_is_integral(text: String) -> Bool:
    """A JSON number is INTEGRAL iff its raw text carries no '.'/'e'/'E' (PR3 —
    JsonValue has no kind distinction between 100 and 100.5; inspect the text)."""
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(46) or c == UInt8(101) or c == UInt8(69):  # '.' 'e' 'E'
            return False
    return True


def _json_value_to_scalar(v: JsonValue) raises -> ScalarValue:
    """Infer the ScalarValue for a `term`/`range` literal from the JSON value.
    JSON_STRING -> keyword string literal; JSON_NUMBER integral -> int64;
    JSON_NUMBER fractional -> float64. JSON_BOOL -> 400 (no bool fast-field class
    in P1.2)."""
    if v.kind == 3:  # JSON_STRING
        return ScalarValue.from_string(v.as_string())
    if v.kind == 2:  # JSON_NUMBER
        if _number_is_integral(v.text):
            return ScalarValue.from_int64(v.as_int64())
        return ScalarValue.from_float(v.as_float64())
    raise Error(
        "search parse: unsupported literal kind for a term/range clause"
        " (P1.2 supports string + number; bool/null are out)"
    )


# =============================================================================
# §2 — clause -> Expr lowering (term / range; bool decomposed by the caller).
# =============================================================================


def _lower_term(term_obj: JsonValue) raises -> Expr:
    """`{"term":{"<field>":<value>}}` -> `col(field) == literal` (BIN_EQ)."""
    if not term_obj.is_object() or len(term_obj.obj_keys) == 0:
        raise Error("search parse: `term` clause has no field")
    var field = term_obj.obj_keys[0]
    var val = term_obj.get(field)
    var lit = _json_value_to_scalar(val)
    return Expr.binary(BIN_EQ, Expr.col_ref(field), Expr.literal(lit^))


def _lower_range(range_obj: JsonValue) raises -> Expr:
    """`{"range":{"<field>":{"gte":x,"gt":x,"lte":y,"lt":y}}}` -> a right-leaning
    BIN_AND of the per-bound comparisons (gte->BIN_GE, gt->BIN_GT, lte->BIN_LE,
    lt->BIN_LT) in canonical order (gte outermost-left, lt innermost-right). The
    right-leaning shape is the canonical optimizer-emitted shape so two
    structurally-equal predicate sets hash equal (§5).

    Built WITHOUT a `List[Expr]` (Expr is Movable-only — `List[T]` requires
    Copyable): a recursive fold over the fixed canonical bound order."""
    if not range_obj.is_object() or len(range_obj.obj_keys) == 0:
        raise Error("search parse: `range` clause has no field")
    var field = range_obj.obj_keys[0]
    var bounds = range_obj.get(field)
    if not bounds.is_object():
        raise Error("search parse: `range.<field>` is not an object of bounds")
    var folded = _fold_range_bounds(field, bounds, 0)
    if not folded:
        raise Error(
            "search parse: `range.<field>` has no recognized bound"
            " (expected one of gte/gt/lte/lt)"
        )
    return folded.take()


def _fold_range_bounds(
    field: String, bounds: JsonValue, idx: Int
) raises -> Optional[Expr]:
    """Recursively fold the present bounds at canonical index `idx` (0=gte, 1=gt,
    2=lte, 3=lt) into a right-leaning BIN_AND. Returns None if no bound at `idx`
    or beyond. Each present bound becomes `cmp AND <fold(idx+1)>` (or `cmp` alone
    if nothing follows) — first present bound outermost-left."""
    if idx > 3:
        return None
    var key: String
    var op: UInt8
    if idx == 0:
        key = String("gte")
        op = BIN_GE
    elif idx == 1:
        key = String("gt")
        op = BIN_GT
    elif idx == 2:
        key = String("lte")
        op = BIN_LE
    else:
        key = String("lt")
        op = BIN_LT
    var rest = _fold_range_bounds(field, bounds, idx + 1)
    if not bounds.has(key):
        return rest^
    var lit = _json_value_to_scalar(bounds.get(key))
    var cmp = Expr.binary(op, Expr.col_ref(field), Expr.literal(lit^))
    if rest:
        return Optional[Expr](Expr.binary(BIN_AND, cmp^, rest.take()))
    return Optional[Expr](cmp^)


# =============================================================================
# §3 — the PARSE step: search_json_to_queryir (match + structural filter gate).
# =============================================================================


def search_json_to_queryir(
    body: Span[UInt8, _],
    generation: Int64,
    text_field: String = String(""),
) raises -> QueryIR:
    """Parse the `_search` query into a QueryIR (P0.8 match + P1.2 fast-field
    filter). THE PARSE STEP (IM1 (a)):

      * `{"match":{...}}` (top-level OR a `bool.must` arm) -> the match-spec
        QueryIR (field + raw query text + size + analyzer config).
      * `{"term":...}` / `{"range":...}` (a `bool.must`/`bool.filter` arm) ->
        a candidate fast-field conjunct, folded right-leaning into QueryIR.filter.

    STRUCTURAL gate (CB4 / IM1), run BEFORE any split lookup so empty-index and
    populated-index handling are consistent:
      * `should` / `bool`-OR -> 400 (P1.2 OUT).
      * `must_not` -> 400 (P1.2 OUT).
      * a filter/term/range query with NO `match` clause (filter-only /
        constant-score) -> 400 (CB4 — the apply lives in the posting accumulate
        loop; filter-only would silently return zero hits; it is P1.3).

    `text_field` names the text field the index searches. A `match` query names
    its own field, so it is not used there. A request with aggregations and no
    `match` (no query, or `match_all`) names no field at all, yet `SearchCore`
    answers a query only from a split of the field it targets, so such a request
    targets `text_field`; pass the index's text field when the QueryIR will be
    run. The default "" is for a caller that only inspects the parse.

    The field-existence / literal-dtype gate is NOT run here (it needs the split's
    fast-field meta) — see gate_filter_against_fastfields (the GATE-AND-ATTACH
    step), wired into _handle_search after split resolution (§3.3 / IM1 (b))."""
    var root = _parse_body(body)
    if not root.is_object():
        raise Error("search parse: request body is not a JSON object")

    # P1.4: parse `aggs` (or its synonym `aggregations`) off the request root
    # FIRST — B1 relaxes the mandatory-query/mandatory-match raises when aggs are
    # present (the headline `{"size":0,"aggs":{...}}` aggs-only / no-query /
    # match_all dashboard query).
    var aggs = List[AggSpec]()
    if root.has(String("aggs")):
        aggs = _parse_aggs(root.get(String("aggs")))
    elif root.has(String("aggregations")):
        aggs = _parse_aggs(root.get(String("aggregations")))
    var have_aggs = len(aggs) > 0

    # B1: a `query` clause is required UNLESS aggs are present (an aggs-only
    # request has no query). A `match_all` query is accepted only in the aggs
    # case (it lowers to a no-term whole-split aggregation, §B1).
    var have_query = root.has(String("query"))
    if not have_query and not have_aggs:
        raise Error("search parse: request is missing the `query` clause")

    var query = JsonValue.empty_object()
    if have_query:
        query = root.get(String("query"))
        if not query.is_object():
            raise Error("search parse: `query` is not a JSON object")

    # `size` (top_k), default 10.
    var top_k = DEFAULT_SIZE
    if root.has(String("size")):
        var size_val = root.get(String("size"))
        top_k = Int(size_val.as_int64())
        if top_k < 0:
            raise Error("search parse: `size` must be non-negative")

    # P1.3 §4.1: `from` (page offset), default 0; from<0 -> 400.
    var from_offset = 0
    if root.has(String("from")):
        from_offset = Int(root.get(String("from")).as_int64())
        if from_offset < 0:
            raise Error("search parse: `from` must be non-negative")

    # P1.3 §4.1: the max_result_window cap (from + size <= 10000) -> 400 above.
    # Each operand is compared on its own first: `from` and `size` are
    # client-supplied Int64 values, and their sum wraps for operands near the
    # Int64 maximum, which would let a huge window pass the check below.
    if from_offset > MAX_RESULT_WINDOW or top_k > MAX_RESULT_WINDOW \
        or from_offset + top_k > MAX_RESULT_WINDOW:
        raise Error(
            "search parse: Result window is too large, from + size must be less"
            " than or equal to " + String(MAX_RESULT_WINDOW)
            + " (max_result_window)"
        )

    # P1.3 §4.5: search_after -> explicit 400 (DEFER, not ignore).
    if root.has(String("search_after")):
        raise Error(
            "search parse: search_after is not yet supported (P1.3 ships"
            " from/size pagination; search_after is a follow-on)"
        )

    # P1.3 §4.2: parse `sort` (single-key; multi-level / non-fast-field handled
    # structurally here + against the split meta in gate_sort_against_fastfields).
    var sort_field = String("")
    var sort_order = SORT_DESC
    var missing_order = MISSING_LAST
    if root.has(String("sort")):
        var parsed = _parse_sort(root.get(String("sort")))
        sort_field = parsed[0]
        sort_order = parsed[1]
        missing_order = parsed[2]

    # The match spec + the collected candidate filter conjuncts. The conjuncts
    # accumulate into a single Optional[Expr] (left-leaning BIN_AND) — Expr is
    # Movable-only, so a `List[Expr]` is not available (List[T] requires
    # Copyable). Determinism (same input -> same shape) is what the fingerprint
    # needs; the per-clause range sub-fold stays right-leaning (case 12 pins it).
    var match_field = String("")
    var match_text = String("")
    var have_match = False
    var conjuncts: Optional[Expr] = None

    # B1: the aggs-only / no-query / match_all path. When aggs are present AND
    # there is no query clause (or the query is `match_all`), build a NO-TERM
    # QueryIR carrying the aggs — the engine's match-all-for-aggs path (§B1)
    # populates `touched` with the whole split. This bypasses the
    # mandatory-match raise (which would 400 the canonical dashboard query).
    var is_match_all = have_query and query.has(String("match_all"))
    if have_aggs and (not have_query or is_match_all):
        # H6: the SAME v1 TEXT analyzer (symmetry). The empty query_text yields
        # zero tokens, so the engine takes the B1 whole-split aggregation path.
        var analyzer = AnalyzerConfig.text(text_field)
        return QueryIR(
            text_field.copy(), String(""), top_k, analyzer^, generation, None,
            sort_field^, sort_order, missing_order, from_offset, aggs^,
        )

    if query.has(String("match")):
        # Top-level match (P0.8 shape; no filter).
        var ms = _parse_match(query.get(String("match")))
        match_field = ms[0]
        match_text = ms[1]
        have_match = True
    elif query.has(String("bool")):
        # bool with must / filter arms. should / must_not -> 400.
        var bq = query.get(String("bool"))
        if bq.has(String("should")):
            raise Error(
                "search parse: `bool.should` (OR) is unsupported in P1.2"
                " (kept un-pushed; revisit per benchmark)"
            )
        if bq.has(String("must_not")):
            raise Error(
                "search parse: `bool.must_not` (negation) is unsupported in P1.2"
            )
        # Bound the clause count before building the BIN_AND chain (see
        # MAX_BOOL_CLAUSES): the chain's depth is the number of clauses.
        var n_clauses = 0
        if bq.has(String("must")):
            n_clauses += bq.get(String("must")).array_len()
        if bq.has(String("filter")):
            n_clauses += bq.get(String("filter")).array_len()
        if n_clauses > MAX_BOOL_CLAUSES:
            raise Error(
                "search parse: too many bool clauses (" + String(n_clauses)
                + "); the limit is " + String(MAX_BOOL_CLAUSES)
                + " (max_clause_count)"
            )
        # Walk `must` THEN `filter` (both are conjuncts; the only difference is
        # scoring, which the UNSCORED-filter apply preserves regardless).
        _walk_bool_arm(bq, String("must"), match_field, match_text, have_match, conjuncts)
        _walk_bool_arm(bq, String("filter"), match_field, match_text, have_match, conjuncts)
    elif query.has(String("term")) or query.has(String("range")):
        # filter-only / constant-score (CB4) -> 400.
        raise Error(
            "search parse: filter-only / constant-score query unsupported in"
            " P1.2 — a `match` clause is required; filter-only is P1.3"
        )
    else:
        var clause = String("<empty>")
        if len(query.obj_keys) > 0:
            clause = query.obj_keys[0]
        raise Error(
            "search parse: unsupported query clause '" + clause + "'"
            " (P1.2 supports match + bool[must/filter] term/range)"
        )

    if not have_match:
        # CB4: a bool with only filter/term/range arms (no match) -> 400.
        raise Error(
            "search parse: filter-only / constant-score query unsupported in"
            " P1.2 — a `match` clause is required; filter-only is P1.3"
        )

    # H6: the SAME v1 TEXT analyzer the SearchSink hardcodes (the symmetry
    # guarantee). is_tokenized() == True (E7) — analyze_text raises otherwise.
    # P1.4: a match query MAY carry aggs (aggregated over the matched set).
    var analyzer = AnalyzerConfig.text(match_field)
    return QueryIR(
        match_field^, match_text^, top_k, analyzer^, generation, conjuncts^,
        sort_field^, sort_order, missing_order, from_offset, aggs^,
    )


def _parse_match(match_obj: JsonValue) raises -> Tuple[String, String]:
    """Parse a `match` clause -> (field, raw query text). The match value is a
    BARE STRING or an OBJECT with an inner `query` string (P0.8)."""
    if not match_obj.is_object():
        raise Error("search parse: `match` is not a JSON object")
    if len(match_obj.obj_keys) == 0:
        raise Error("search parse: `match` clause has no field")
    var field = match_obj.obj_keys[0]
    var mv = match_obj.get(field)
    var qtext: String
    if mv.is_object():
        if not mv.has(String("query")):
            raise Error(
                "search parse: `match.<field>` object is missing the inner"
                " `query` string"
            )
        qtext = mv.get(String("query")).as_string()
    else:
        qtext = mv.as_string()
    return (field, qtext^)


def _order_of(s: String) raises -> UInt8:
    """Map an `order` string to SORT_ASC / SORT_DESC. Anything else -> 400."""
    if s == String("asc"):
        return SORT_ASC
    if s == String("desc"):
        return SORT_DESC
    raise Error(
        "search parse: invalid sort order '" + s + "' (expected asc / desc)"
    )


def _missing_of(s: String) raises -> UInt8:
    """Map a `missing` string to MISSING_LAST / MISSING_FIRST. Else -> 400."""
    if s == String("_last"):
        return MISSING_LAST
    if s == String("_first"):
        return MISSING_FIRST
    raise Error(
        "search parse: invalid sort missing '" + s + "' (expected _last /"
        " _first)"
    )


def _default_order_for(field: String) -> UInt8:
    """OpenSearch default order: `desc` for `_score`, `asc` for everything else
    (including `_doc` and any named field)."""
    if field == SORT_FIELD_SCORE:
        return SORT_DESC
    return SORT_ASC


def _parse_sort(sort_val: JsonValue) raises -> Tuple[String, UInt8, UInt8]:
    """Parse the `sort` JSON array (P1.3 §4.2) -> (sort_field, sort_order,
    missing_order). Single-key only: a multi-element array -> 400 (NOT silently
    truncated, C8). Element forms:
      * bare string: "price" -> (price, asc); "_score" -> (_score, desc);
        "_doc" -> (_doc, asc).
      * object with order: {"price":{"order":"asc","missing":"_first"}}.
      * object shorthand: {"price":"desc"}.
    The field-existence / TEXT-field gate runs later against the split meta
    (gate_sort_against_fastfields); `_score`/`_doc` are always allowed."""
    if not sort_val.is_array():
        raise Error("search parse: `sort` must be a JSON array")
    if len(sort_val.children) == 0:
        # An empty sort array -> default (sort by _score, unchanged).
        return (String(""), SORT_DESC, MISSING_LAST)
    if len(sort_val.children) > 1:
        raise Error(
            "search parse: multi-level sort is not yet supported (P1.3.0 ships"
            " single-key sort; multi-level is P1.3.x)"
        )
    ref el = sort_val.children[0]
    return _parse_sort_element(el)


def _parse_sort_element(el: JsonValue) raises -> Tuple[String, UInt8, UInt8]:
    """Parse ONE sort element (the three forms)."""
    # Bare string: "price" / "_score" / "_doc".  (kind 3 == JSON_STRING.)
    if el.kind == 3:
        var field = el.as_string()
        return (field, _default_order_for(field), MISSING_LAST)
    # Object: {"<field>":<order-string>} OR {"<field>":{"order":..,"missing":..}}.
    if not el.is_object() or len(el.obj_keys) == 0:
        raise Error(
            "search parse: a `sort` element must be a field name string or a"
            " {field: order|{order,missing}} object"
        )
    var field = el.obj_keys[0]
    var spec = el.get(field)
    var order = _default_order_for(field)
    var missing = MISSING_LAST
    if spec.is_object():
        # {"<field>":{"order":..,"missing":..}}.
        if spec.has(String("order")):
            order = _order_of(spec.get(String("order")).as_string())
        if spec.has(String("missing")):
            missing = _missing_of(spec.get(String("missing")).as_string())
    else:
        # Shorthand {"<field>":"asc|desc"}.
        order = _order_of(spec.as_string())
    return (field, order, missing)


def _append_conjunct(mut acc: Optional[Expr], var c: Expr):
    """Fold a new conjunct into the running accumulator (left-leaning BIN_AND).
    Deterministic; the per-clause range sub-fold keeps its own right-leaning
    shape internally."""
    if acc:
        acc = Optional[Expr](Expr.binary(BIN_AND, acc.take(), c^))
    else:
        acc = Optional[Expr](c^)


def _walk_bool_arm(
    bq: JsonValue,
    arm_key: String,
    mut match_field: String,
    mut match_text: String,
    mut have_match: Bool,
    mut conjuncts: Optional[Expr],
) raises:
    """Walk a `bool.<arm>` array (must / filter). A `match` element sets the
    match spec; a `term`/`range` element folds a candidate conjunct. A nested
    bool / unsupported element -> 400."""
    if not bq.has(arm_key):
        return
    var arm = bq.get(arm_key)
    if not arm.is_array():
        raise Error("search parse: `bool." + arm_key + "` is not an array")
    for i in range(len(arm.children)):
        ref el = arm.children[i]
        if el.has(String("match")):
            if have_match:
                raise Error(
                    "search parse: multiple `match` clauses unsupported in P1.2"
                    " (multi-scored-match bool is out of scope)"
                )
            var ms = _parse_match(el.get(String("match")))
            match_field = ms[0]
            match_text = ms[1]
            have_match = True
        elif el.has(String("term")):
            _append_conjunct(conjuncts, _lower_term(el.get(String("term"))))
        elif el.has(String("range")):
            _append_conjunct(conjuncts, _lower_range(el.get(String("range"))))
        elif el.has(String("should")) or el.has(String("must_not")) \
            or el.has(String("bool")):
            raise Error(
                "search parse: nested bool / should / must_not in a bool arm"
                " is unsupported in P1.2"
            )
        else:
            var clause = String("<empty>")
            if len(el.obj_keys) > 0:
                clause = el.obj_keys[0]
            raise Error(
                "search parse: unsupported bool-arm clause '" + clause + "'"
            )


# =============================================================================
# §3b — P1.4: the `aggs` request-block lowering (search_query §7.1).
# =============================================================================


def _metric_kind_of(agg_type: String) -> UInt8:
    """Map a metric agg type string to AGG_KIND_*. Returns 255 (an invalid
    sentinel) for a non-metric / unrecognized type (the caller raises)."""
    if agg_type == String("avg"):
        return AGG_KIND_AVG
    if agg_type == String("min"):
        return AGG_KIND_MIN
    if agg_type == String("max"):
        return AGG_KIND_MAX
    if agg_type == String("sum"):
        return AGG_KIND_SUM
    if agg_type == String("value_count"):
        return AGG_KIND_VALUE_COUNT
    if agg_type == String("stats"):
        return AGG_KIND_STATS
    return UInt8(255)


def _parse_terms_order(order_val: JsonValue) raises -> UInt8:
    """Parse a `terms` `order` object -> an AGG_ORDER_* code. OpenSearch shape:
    {"_count":"desc"} / {"_count":"asc"} / {"_key":"asc"} / {"_key":"desc"}. A
    multi-key order array, or an unknown order key/direction -> 400."""
    if not order_val.is_object() or len(order_val.obj_keys) == 0:
        raise Error(
            "search parse: `terms.order` must be a {_count|_key: asc|desc}"
            " object"
        )
    if len(order_val.obj_keys) > 1:
        raise Error(
            "search parse: multi-key `terms.order` is unsupported (single key:"
            " _count or _key)"
        )
    var key = order_val.obj_keys[0]
    var dir = order_val.get(key).as_string()
    if key == String("_count"):
        if dir == String("desc"):
            return AGG_ORDER_COUNT_DESC
        if dir == String("asc"):
            return AGG_ORDER_COUNT_ASC
        raise Error("search parse: invalid `_count` order '" + dir + "'")
    if key == String("_key"):
        if dir == String("asc"):
            return AGG_ORDER_KEY_ASC
        if dir == String("desc"):
            return AGG_ORDER_KEY_DESC
        raise Error("search parse: invalid `_key` order '" + dir + "'")
    raise Error(
        "search parse: unsupported `terms.order` key '" + key + "' (use _count"
        " or _key)"
    )


def _parse_terms_agg(name: String, terms_obj: JsonValue) raises -> AggSpec:
    """Parse a `terms` agg body -> an AggSpec (§7.1). Shape:
    {"field":"<f>"[,"size":N][,"order":{...}][,"min_doc_count":N][,"missing":"<s>"]}.
    Multi-field terms / scripted terms -> 400."""
    if not terms_obj.is_object():
        raise Error("search parse: `terms` body is not an object")
    if terms_obj.has(String("script")):
        raise Error("search parse: scripted `terms` is unsupported (P1.4)")
    if not terms_obj.has(String("field")):
        # A `terms` with no `field` (e.g. multi-field via `fields`/`sources`) is
        # OOS — composite/multi-field terms is P1.5.
        raise Error(
            "search parse: `terms` requires a single `field` (multi-field /"
            " composite terms is unsupported in P1.4)"
        )
    var field = terms_obj.get(String("field")).as_string()
    var size = DEFAULT_TERMS_SIZE
    if terms_obj.has(String("size")):
        size = Int(terms_obj.get(String("size")).as_int64())
        if size < 0:
            raise Error("search parse: `terms.size` must be non-negative")
    var order_code = AGG_ORDER_COUNT_DESC
    if terms_obj.has(String("order")):
        order_code = _parse_terms_order(terms_obj.get(String("order")))
    var min_doc_count = 1
    if terms_obj.has(String("min_doc_count")):
        min_doc_count = Int(terms_obj.get(String("min_doc_count")).as_int64())
        if min_doc_count < 0:
            raise Error("search parse: `terms.min_doc_count` must be >= 0")
    var missing = String("")
    if terms_obj.has(String("missing")):
        missing = terms_obj.get(String("missing")).as_string()
    return AggSpec(
        name, AGG_KIND_TERMS, field^, size, order_code, min_doc_count, missing^
    )


def _parse_one_agg(name: String, body: JsonValue) raises -> AggSpec:
    """Parse ONE named agg body -> an AggSpec. The body is a single-keyed object
    {<agg_type>:{...}} (the obj_keys[0] agg-type idiom). Nested sub-aggs
    (a sibling `aggs`/`aggregations` inside the body) -> 400. Unrecognized /
    OOS agg types (cardinality, date_histogram, ...) -> 400 with a specific
    reason."""
    if not body.is_object() or len(body.obj_keys) == 0:
        raise Error(
            "search parse: agg '" + name + "' body must be a {<type>:{...}}"
            " object"
        )
    # Nested sub-aggregations are OUT (§6) — a sibling aggs/aggregations key
    # alongside the agg type.
    if body.has(String("aggs")) or body.has(String("aggregations")):
        raise Error(
            "search parse: nested sub-aggregations (aggs inside '" + name
            + "') are unsupported in P1.4"
        )
    if len(body.obj_keys) > 1:
        raise Error(
            "search parse: agg '" + name + "' has multiple type keys (expected"
            " exactly one of avg/min/max/sum/value_count/stats/terms)"
        )
    var agg_type = body.obj_keys[0]
    var inner = body.get(agg_type)

    if agg_type == String("terms"):
        return _parse_terms_agg(name, inner)

    var mk = _metric_kind_of(agg_type)
    if mk != UInt8(255):
        if not inner.is_object() or not inner.has(String("field")):
            raise Error(
                "search parse: metric agg '" + name + "' requires a `field`"
            )
        var field = inner.get(String("field")).as_string()
        return AggSpec(name, mk, field^)

    # Explicit OOS agg types (§6) — each with a specific reason.
    if agg_type == String("cardinality"):
        raise Error(
            "search parse: `cardinality` is unsupported in P1.4 (exact distinct"
            " is a follow-on)"
        )
    if agg_type == String("date_histogram"):
        raise Error(
            "search parse: `date_histogram` is unsupported in P1.4"
        )
    if agg_type == String("histogram") or agg_type == String("range") \
        or agg_type == String("filters") or agg_type == String("nested"):
        raise Error(
            "search parse: bucket agg '" + agg_type + "' is unsupported in P1.4"
        )
    raise Error(
        "search parse: unrecognized agg type '" + agg_type + "' in agg '" + name
        + "' (P1.4 supports avg/min/max/sum/value_count/stats/terms)"
    )


def _parse_aggs(aggs_obj: JsonValue) raises -> List[AggSpec]:
    """Parse the `aggs` (or `aggregations`) request block -> List[AggSpec]. The
    block is an object keyed by the user's agg NAME, each value a single-keyed
    {<agg_type>:{...}} body. v1 is single-level (no nesting — caught per-agg in
    _parse_one_agg). An empty `aggs:{}` -> an empty list (has_aggs() False,
    backward-compatible)."""
    if not aggs_obj.is_object():
        raise Error("search parse: `aggs` must be a JSON object")
    var out = List[AggSpec]()
    for i in range(len(aggs_obj.obj_keys)):
        var name = aggs_obj.obj_keys[i]
        var body = aggs_obj.get(name)
        out.append(_parse_one_agg(name, body))
    return out^


# =============================================================================
# §6 — track_total_hits: the envelope render mode (P1.3 §4.4 / A5).
# =============================================================================


def parse_track_total_hits(body: Span[UInt8, _]) raises -> UInt8:
    """Parse the `track_total_hits` flag off the request root (a pure RENDER
    knob — NOT a QueryIR field; the leaf always computes the exact total):
      * true   -> TRACK_TOTAL_TRUE  (exact value, relation always eq).
      * false  -> TRACK_TOTAL_FALSE (omit the total object entirely).
      * absent -> TRACK_TOTAL_DEFAULT (exact up to 10000, relation gte above).
    The integer-valued custom-threshold form is a defer-able follow-on (P1.3.0
    honors true/false/default only)."""
    var root = _parse_body(body)
    if not root.is_object():
        return TRACK_TOTAL_DEFAULT
    if not root.has(String("track_total_hits")):
        return TRACK_TOTAL_DEFAULT
    var v = root.get(String("track_total_hits"))
    if v.kind == 1:  # JSON_BOOL
        if v.as_bool():
            return TRACK_TOTAL_TRUE
        return TRACK_TOTAL_FALSE
    # An integer threshold (custom) is a follow-on; treat as default for P1.3.0.
    return TRACK_TOTAL_DEFAULT


def sort_is_by_score(query: QueryIR) -> Bool:
    """True iff the result is sorted by relevance (`_score` / the default ""),
    NOT a field. Drives max_score rendering (null under field sort, §5 / A7)."""
    var sf = query.sort_field
    return sf.byte_length() == 0 or sf == SORT_FIELD_SCORE
