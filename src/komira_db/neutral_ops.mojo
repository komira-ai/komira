# =============================================================================
# komira_db/neutral_ops.mojo — the backend-neutral structured-op value types.
# =============================================================================
#
# The STRUCTURED VALUE TYPES the 9
# `Database` neutral ops take instead of SQL strings — `Pred` / `Filter` /
# `Order` / `DbColVal` / `PodNameMinter`. All Movable & Copyable, relocation-safe
# (single-level heap fields only: each holds `String` / `List[<single-heap>]`,
# never a doubly-nested heap container). A document backend reads these
# structured values to build a native document GET / PATCH / conditional-create /
# query; a SQL backend renders them to byte-identical SQL (the `sql_*` renderers
# in `sql_neutral_ops.mojo`, which imports `SqlDatabase` for the dialect tokens).
#
# This module holds ONLY the value types — NO dependency on `Database` /
# `SqlDatabase` — so it sits BELOW `database.mojo` in the import graph (which
# imports these types for the 9 op signatures) with no cycle. The SQL rendering
# + the driver-facing op impls live in the sibling `sql_neutral_ops.mojo` (which
# CAN import `SqlDatabase` because it sits ABOVE `database.mojo`).
#
# Encapsulation: every field / accessor is String / typed scalar /
# single-heap DbValue / List — ZERO UnsafePointer crosses any boundary.
# =============================================================================

from komira_db.db_value import (
    DbValue,
    LOGICAL_BOOL,
    LOGICAL_INT8,
)


# =============================================================================
# The structured value types.
# =============================================================================

# ---- Pred.op — the comparison operator tags (a small closed set) ----
comptime PRED_EQ: UInt8 = 0  # <col> = $n
comptime PRED_LT: UInt8 = 1  # <col> < $n
comptime PRED_IS_NULL: UInt8 = 2  # <col> IS NULL   (val ignored)
comptime PRED_IS_NOT_NULL: UInt8 = 3  # <col> IS NOT NULL (val ignored)
comptime PRED_JSON_KEY_EQ: UInt8 = 4  # config->>$key = $n (JSON text-extract)
comptime PRED_LE: UInt8 = 5  # <col> <= $n
# PRED_IN — `<col> IN (v0, v1, ...)`. The value list rides on `in_vals` (NOT the
# single `val`). Two rendering modes, selected by `in_literals`:
#   * in_literals=True  — inline each `in_vals[i].as_text()` as a trusted SQL
#                         LITERAL: `<col> IN (0, 1)`. NO param bound. This is the
#                         `status IN (PROVISIONING, ACTIVE)` shape,
#                         where the ordinals are compile-time TRUSTED constants
#                         (byte-identical to the hand SQL — no injection surface).
#   * in_literals=False — bind each value positionally: `<col> IN ($n, $n+1, ...)`.
comptime PRED_IN: UInt8 = 6
comptime PRED_GTE: UInt8 = 7  # <col> >= $n (the watermark / since-cursor bound)
# PRED_ARRAY_CONTAINS — `<val> = ANY(<col>)`: the ARRAY-MEMBERSHIP predicate over a
# TEXT[] / array COLUMN (`<col>` is the array column; `<val>` is the scalar element
# to test for membership), e.g. a tag or depends-on reverse query (`tags`,
# `depends_on`). Rendering
# diverges by backend (the flat neutral Filter has no single portable form):
#   * pg      — `<ph> = ANY(<col>)` (GIN-accelerated); binds `val`. BYTE-IDENTICAL
#               to a hand-written `$1 = ANY(tags)`.
#   * sqlite / pgstore — NOT pushable (neither executor parses `= ANY(col)`;
#               pgstore's predicate grammar is `<col> <cmpop>
#               <lit>` with NO array operator); the SQL query-rows op DROPS this
#               pred from the WHERE and evaluates the membership CLIENT-SIDE in Mojo
#               over the decoded `{a,b,c}` literal (load-and-filter).
#   * Firestore — a NATIVE server-side `ARRAY_CONTAINS` fieldFilter (the array
#               column is stored as a native `arrayValue`).
# `val` binds ONLY on the pg push-down; the client-side arms carry it on `val` and
# read it via `as_text()`. Same relocation-safe layout as the other single-value preds
# (col: String + val: DbValue single-heap).
comptime PRED_ARRAY_CONTAINS: UInt8 = 8
# PRED_NE — `<col> IS DISTINCT FROM $n`: "the stored value is NOT `val`".
#
# ⚠ IT IS NOT THE NEGATION OF `PRED_EQ`, AND THAT IS THE WHOLE POINT. Three-valued
# SQL `<>` and Firestore's `NOT_EQUAL` both EXCLUDE a row whose column is NULL /
# whose document does not carry the field at all — so neither can express "this
# row is not already at the value I am about to write", which is the only thing
# this predicate is for. `IS DISTINCT FROM` is the SQL spelling of what every
# backend renders here:
#   * pg / sqlite — `(<col> IS NULL OR <col> <> $n)`; binds `val` ONCE.
#   * Firestore   — NEVER pushed to a structuredQuery (a `NOT_EQUAL` fieldFilter
#                   would drop exactly the absent-field documents this exists to
#                   reach, and an inequality alongside an equality needs a
#                   composite index). Evaluated CLIENT-SIDE by `_guard_matches`:
#                   an ABSENT or NULL field IS distinct from any bound value.
#   * DynamoDB    — `(attribute_not_exists(#n) OR #n <> :v)`.
#
# THE CASE IT EXISTS FOR. Spelling "rows whose value differs" as
# `flag == <the opposite>` is only equivalent for a TOTAL boolean column. On a
# document backend, documents written before the field existed carry no such
# field at all — so an update guarded that way never reaches them, and a new
# declaration can never take effect on data that predates it.
comptime PRED_NE: UInt8 = 9

# ---- Filter.combine — how the predicates join ----
comptime COMBINE_AND: UInt8 = 0
comptime COMBINE_OR: UInt8 = 1


struct Pred(Movable, Copyable):
    """One WHERE predicate: `<col> <op> <val>`. `op` is one of the PRED_* tags.
    For PRED_JSON_KEY_EQ, `key` names the JSON map key to extract (the
    `config->>key = val` shape); `col` is the JSON column. For PRED_IS_NULL /
    PRED_IS_NOT_NULL, `val` is ignored (bind nothing). For PRED_IN, the value
    LIST rides on `in_vals` and `in_inline` selects inline-literal vs bound
    rendering. relocation-safe: two String fields + one DbValue (single-heap) + one
    `List[DbValue]` (single-level heap: DbValue holds only a String) — no
    doubly-nested heap container."""

    var col: String
    var op: UInt8
    var val: DbValue
    var key: String  # only for PRED_JSON_KEY_EQ (the JSON map key)
    var in_vals: List[DbValue]  # only for PRED_IN (the value list)
    var in_inline: Bool  # PRED_IN: inline literals (True) vs bound params (False)

    def __init__(out self, var col: String, op: UInt8, var val: DbValue):
        self.col = col^
        self.op = op
        self.val = val^
        self.key = String("")
        self.in_vals = List[DbValue]()
        self.in_inline = False

    def __init__(
        out self, var col: String, op: UInt8, var val: DbValue, var key: String
    ):
        self.col = col^
        self.op = op
        self.val = val^
        self.key = key^
        self.in_vals = List[DbValue]()
        self.in_inline = False

    def __init__(
        out self,
        var col: String,
        op: UInt8,
        var in_vals: List[DbValue],
        in_inline: Bool,
    ):
        """The PRED_IN ctor: the value LIST + the literal/bound render mode. `val`
        is a null placeholder (unused for IN)."""
        self.col = col^
        self.op = op
        self.val = DbValue.null(0)
        self.key = String("")
        self.in_vals = in_vals^
        self.in_inline = in_inline

    @staticmethod
    def eq(var col: String, var val: DbValue) -> Pred:
        return Pred(col^, PRED_EQ, val^)

    @staticmethod
    def ne(var col: String, var val: DbValue) -> Pred:
        """`<col> IS DISTINCT FROM $n` — the stored value is NOT `val`, INCLUDING
        the row that has no stored value at all (SQL NULL / an absent Firestore
        field). See PRED_NE for why this is not `NOT (col = val)` on any backend
        and for the per-backend render."""
        return Pred(col^, PRED_NE, val^)

    @staticmethod
    def lt(var col: String, var val: DbValue) -> Pred:
        return Pred(col^, PRED_LT, val^)

    @staticmethod
    def le(var col: String, var val: DbValue) -> Pred:
        return Pred(col^, PRED_LE, val^)

    @staticmethod
    def gte(var col: String, var val: DbValue) -> Pred:
        """`<col> >= $n` — the watermark / since-cursor lower bound (e.g.
        `created_at >= since_us` for a per-user inbox read). Binds `val`."""
        return Pred(col^, PRED_GTE, val^)

    @staticmethod
    def array_contains(var col: String, var val: DbValue) -> Pred:
        """`<val> = ANY(<col>)` — array-membership over the TEXT[] / array COLUMN
        `col`, testing membership of the scalar `val`. See PRED_ARRAY_CONTAINS for
        the per-backend render divergence (pg push-down `= ANY`, sqlite/pgstore
        client-side Mojo filter, Firestore native `ARRAY_CONTAINS`). `val` is
        carried (read via `as_text()` on the client-side arms; bound on pg)."""
        return Pred(col^, PRED_ARRAY_CONTAINS, val^)

    @staticmethod
    def is_null(var col: String) -> Pred:
        return Pred(col^, PRED_IS_NULL, DbValue.null(0))

    @staticmethod
    def is_not_null(var col: String) -> Pred:
        return Pred(col^, PRED_IS_NOT_NULL, DbValue.null(0))

    @staticmethod
    def json_key_eq(var col: String, var key: String, var val: DbValue) -> Pred:
        return Pred(col^, PRED_JSON_KEY_EQ, val^, key^)

    @staticmethod
    def in_list(var col: String, var vals: List[DbValue]) -> Pred:
        """`<col> IN ($n, $n+1, ...)` — each value is BOUND positionally (the
        general untrusted-values IN shape)."""
        return Pred(col^, PRED_IN, vals^, False)

    @staticmethod
    def in_literals(var col: String, var vals: List[DbValue]) -> Pred:
        """`<col> IN (v0, v1, ...)` — each value is inlined as a TRUSTED SQL
        LITERAL (its `as_text()`), binding NOTHING. For compile-time trusted
        constants ONLY (e.g. a `status IN (PROVISIONING, ACTIVE)`
        ordinals) — byte-identical to the hand SQL, no injection surface."""
        return Pred(col^, PRED_IN, vals^, True)

    def binds_a_param(self) -> Bool:
        """True iff this predicate binds a positional param (EQ / LT / LE / GTE /
        JSON_KEY_EQ bind the value; JSON_KEY_EQ also binds the key; a bound-mode
        PRED_IN binds each `in_vals`). IS NULL / IS NOT NULL / literal-mode
        PRED_IN bind nothing. NOTE: for PRED_IN this is a per-predicate coarse
        flag; the bind COUNT is `len(in_vals)` (the renderer handles it)."""
        return (
            self.op == PRED_EQ
            or self.op == PRED_NE
            or self.op == PRED_LT
            or self.op == PRED_LE
            or self.op == PRED_GTE
            or self.op == PRED_JSON_KEY_EQ
            or (self.op == PRED_IN and not self.in_inline)
        )


struct Filter(Movable, Copyable):
    """A conjunction/disjunction of `Pred`s. `combine` is COMBINE_AND (default)
    or COMBINE_OR. An empty preds list renders no WHERE clause. relocation-safe:
    `List[Pred]` where Pred is single-level heap (String + DbValue)."""

    var preds: List[Pred]
    var combine: UInt8

    def __init__(out self):
        self.preds = List[Pred]()
        self.combine = COMBINE_AND

    def __init__(out self, var preds: List[Pred], combine: UInt8):
        self.preds = preds^
        self.combine = combine

    @staticmethod
    def all_of(var preds: List[Pred]) -> Filter:
        return Filter(preds^, COMBINE_AND)

    @staticmethod
    def any_of(var preds: List[Pred]) -> Filter:
        return Filter(preds^, COMBINE_OR)

    @staticmethod
    def none() -> Filter:
        return Filter()

    @staticmethod
    def just(var p: Pred) -> Filter:
        var l = List[Pred]()
        l.append(p^)
        return Filter(l^, COMBINE_AND)


struct Order(Movable, Copyable):
    """One ORDER BY term: `<col> [DESC]`. `explicit_asc` controls whether an
    ascending term renders a bare `col` (False — the JobStore.list_jobs shape,
    `ORDER BY created_at DESC`) or an explicit `col ASC` (True — the
    JobStore.list_jobs_by_config_key shape, `ORDER BY created_at ASC, id ASC`).
    relocation-safe (one String)."""

    var col: String
    var desc: Bool
    var explicit_asc: Bool

    def __init__(out self, var col: String, desc: Bool):
        self.col = col^
        self.desc = desc
        self.explicit_asc = False

    def __init__(out self, var col: String, desc: Bool, explicit_asc: Bool):
        self.col = col^
        self.desc = desc
        self.explicit_asc = explicit_asc

    @staticmethod
    def asc(var col: String) -> Order:
        """Ascending, rendered as a BARE `col` (no `ASC` keyword)."""
        return Order(col^, False, False)

    @staticmethod
    def asc_explicit(var col: String) -> Order:
        """Ascending, rendered as an EXPLICIT `col ASC` (the config-key query
        shape that writes the ASC keyword)."""
        return Order(col^, False, True)

    @staticmethod
    def descending(var col: String) -> Order:
        return Order(col^, True, False)


# ---- DbColVal.kind — the three SET-term shapes ----
comptime COLVAL_BIND: UInt8 = 0  # col = $n              (binds `val`, plain)
comptime COLVAL_COALESCE: UInt8 = 1  # col = COALESCE($n, col) (binds `val`, partial-update)
comptime COLVAL_RAW_EXPR: UInt8 = 2  # col = <val.as_text() literal SQL expr>  (NO bind)


struct DbColVal(Movable, Copyable):
    """One column := value assignment (an UPDATE SET term / a claim extra SET).
    `kind` selects the SET-term shape, matching JobStore's MIXED SET clauses
    (`phase = $1` plain + `progress = COALESCE($2, progress)` partial + `version
    = version + 1` expression — all in one UPDATE):
      * COLVAL_BIND     — `col = $n`              (binds `val`; a hard set)
      * COLVAL_COALESCE — `col = COALESCE($n, col)` (binds `val`; a None leaves
                          the column untouched — the partial-heartbeat shape)
      * COLVAL_RAW_EXPR — `col = <val.as_text()>`  (NO bind; a literal SQL
                          expression, e.g. `version = version + 1`, `updated_at
                          = NOW()`)
    relocation-safe (one String + one single-heap DbValue)."""

    var col: String
    var val: DbValue
    var kind: UInt8

    def __init__(out self, var col: String, var val: DbValue):
        self.col = col^
        self.val = val^
        self.kind = COLVAL_BIND

    def __init__(
        out self, var col: String, var val: DbValue, kind: UInt8
    ) raises:
        """A term of an explicit `kind`. Raises unless `kind` is one of
        COLVAL_BIND / COLVAL_COALESCE / COLVAL_RAW_EXPR: any other value is
        no SET-term shape. (`kind` is a public field, so the SQL renderers
        refuse an unknown kind too rather than number a placeholder the op
        binds no param for.)"""
        if kind > COLVAL_RAW_EXPR:
            raise Error(
                String("DbColVal: kind ")
                + String(Int(kind))
                + String(" is not COLVAL_BIND, COLVAL_COALESCE or COLVAL_RAW_EXPR")
            )
        self.col = col^
        self.val = val^
        self.kind = kind

    @staticmethod
    def bind(var col: String, var val: DbValue) -> DbColVal:
        """A plain `col = $n` hard set (binds `val`)."""
        return DbColVal(col^, val^)

    @staticmethod
    def coalesce(var col: String, var val: DbValue) -> DbColVal:
        """A `col = COALESCE($n, col)` partial-update set (binds `val`; a None
        leaves the column untouched)."""
        var t = DbColVal(col^, val^)
        t.kind = COLVAL_COALESCE
        return t^

    @staticmethod
    def raw_expr(var col: String, var expr: String) -> DbColVal:
        """A `col = <expr>` SET term where `<expr>` is literal SQL (NO bind) —
        e.g. `version = version + 1`, `updated_at = NOW()`."""
        var t = DbColVal(col^, DbValue.text(expr^))
        t.kind = COLVAL_RAW_EXPR
        return t^

    def is_bind(self) -> Bool:
        return self.kind == COLVAL_BIND

    def is_coalesce(self) -> Bool:
        return self.kind == COLVAL_COALESCE

    def is_raw_expr(self) -> Bool:
        return self.kind == COLVAL_RAW_EXPR

    def binds_a_param(self) -> Bool:
        """True iff this term binds a positional param (BIND / COALESCE bind
        `val`; RAW_EXPR binds nothing)."""
        return self.kind == COLVAL_BIND or self.kind == COLVAL_COALESCE


# =============================================================================
# RAW_EXPR classification — the ONE vocabulary every DOCUMENT backend reads.
# =============================================================================
#
# ⭐ WHY THIS LIVES IN THE NEUTRAL LAYER.
# `DbColVal.raw_expr(col, expr)` means "`col = <expr>` where `<expr>` is literal
# SQL". A SQL backend concatenates it and the server evaluates it. A DOCUMENT
# backend (Firestore / DynamoDB) has NO SQL evaluator, so it must recognise the
# expression itself. If each document backend carries its own private
# half-recogniser (say, one that matches `<col> + 1` and nothing else) and
# skips everything it does not match, terms are lost silently.
#
# THE CONSEQUENCE IT PREVENTS. A store that revokes a session sets the flag
# through `DbColVal.raw_expr("revoked", "true")` — the SQL bool LITERAL, chosen
# so the column is a real bool on pg and an integer 1 on sqlite. A document
# backend that drops that term still commits the CAS, bumps `version`, reports
# rows_affected NON-ZERO, and never changes `revoked`: sign-out becomes a no-op.
#
# ONE classifier, in the layer that DEFINES what a `DbColVal` may express, so a
# new literal shape cannot be understood by one document backend and dropped by
# the other. The SQL backends do not call it — they still concatenate the text,
# which is what makes the render byte-identical to the hand-written SQL.

# ---- the classification tags ----
comptime RAWEXPR_UNEVALUABLE: UInt8 = 0  # not a shape a document backend can apply
comptime RAWEXPR_INCREMENT: UInt8 = 1  # `<col> + 1` — read the column, add one
comptime RAWEXPR_LITERAL: UInt8 = 2  # a scalar constant, carried in `.literal`


struct RawExprTerm(Movable, Copyable):
    """What `classify_raw_expr` decided a `COLVAL_RAW_EXPR` term is.
    `literal` is meaningful ONLY when `kind == RAWEXPR_LITERAL` (it is the value
    to store, already typed — `DbValue.bool_val` / a typed NULL / an INT8); for
    the other two tags it is a placeholder NULL. relocation-safe (one UInt8 + one
    single-heap DbValue)."""

    var kind: UInt8
    var literal: DbValue

    def __init__(out self, kind: UInt8, var literal: DbValue):
        self.kind = kind
        self.literal = literal^

    def is_increment(self) -> Bool:
        return self.kind == RAWEXPR_INCREMENT

    def is_literal(self) -> Bool:
        return self.kind == RAWEXPR_LITERAL

    def is_unevaluable(self) -> Bool:
        return self.kind == RAWEXPR_UNEVALUABLE


def _rawexpr_strip_spaces(s: String) -> String:
    """`s` with every ASCII space removed (the expressions are whitespace-tolerant
    — `version+1` and `version + 1` are the same term)."""
    var sb = s.as_bytes()
    var out = String("")
    for i in range(len(sb)):
        if sb[i] != UInt8(ord(" ")):
            out += chr(Int(sb[i]))
    return out^


def _rawexpr_lower(s: String) -> String:
    """`s` ASCII-lowercased. The literal KEYWORDS are case-insensitive in SQL, so
    `TRUE` and `true` must classify identically; nothing else is folded."""
    var sb = s.as_bytes()
    var out = String("")
    for i in range(len(sb)):
        var b = sb[i]
        if b >= UInt8(ord("A")) and b <= UInt8(ord("Z")):
            b += UInt8(32)
        out += chr(Int(b))
    return out^


def _rawexpr_is_decimal_int(s: String) -> Bool:
    """True iff `s` is a bare decimal integer literal, optionally signed. NOT a
    general numeric parser: no exponent, no decimal point, no underscores, no
    leading `+0x`. A shape this does not accept is REFUSED, never guessed."""
    var sb = s.as_bytes()
    var n = len(sb)
    if n == 0:
        return False
    var i = 0
    if sb[0] == UInt8(ord("-")) or sb[0] == UInt8(ord("+")):
        i = 1
        if n == 1:
            return False
    while i < n:
        if sb[i] < UInt8(ord("0")) or sb[i] > UInt8(ord("9")):
            return False
        i += 1
    return True


def classify_raw_expr(col: String, expr: String) raises -> RawExprTerm:
    """Decide what a `COLVAL_RAW_EXPR` term means to a backend with no SQL
    evaluator. The vocabulary is CLOSED and every member is a shape with exactly
    one meaning on a document store:

      * `<col> + 1`              -> RAWEXPR_INCREMENT (read the column, add one).
        ⚠ The column named in the expression must be the column being ASSIGNED.
        `version = last_seen_at + 1` is a cross-column read and is REFUSED, not
        silently applied to the wrong field.
      * `true` / `false`         -> RAWEXPR_LITERAL, a `DbValue.bool_val`. Written
        through the backend's ORDINARY bool encoding, so a literal-set and a
        `DbColVal.bind(col, DbValue.bool_val(...))` store IDENTICAL bytes — there
        is no second representation for a bool.
      * `null`                   -> RAWEXPR_LITERAL, a typed NULL.
      * a signed decimal integer -> RAWEXPR_LITERAL, an INT8 (`0`, `1`, `-7`).
      * ANYTHING ELSE            -> RAWEXPR_UNEVALUABLE.

    ⛔ A quoted SQL string (`'pending'`) is deliberately NOT in the vocabulary.
    `DbColVal.bind` is what sets a column to a string; adding a SQL string-literal
    parser (escapes, `''` doubling, dialect quoting) to a document backend buys a
    second, subtly-different text encoder for no caller that exists.

    ⛔ AND UNEVALUABLE IS A REFUSAL AT THE CALL SITE, NOT A SKIP. A backend that
    drops the term it cannot read is indistinguishable from one that applied it.
    That is how a `revoked = true` term gets lost."""
    var e = _rawexpr_strip_spaces(expr)
    if e == _rawexpr_strip_spaces(col) + String("+1"):
        return RawExprTerm(RAWEXPR_INCREMENT, DbValue.null(LOGICAL_INT8))
    var lowered = _rawexpr_lower(e)
    if lowered == String("true"):
        return RawExprTerm(RAWEXPR_LITERAL, DbValue.bool_val(True))
    if lowered == String("false"):
        return RawExprTerm(RAWEXPR_LITERAL, DbValue.bool_val(False))
    if lowered == String("null"):
        return RawExprTerm(RAWEXPR_LITERAL, DbValue.null(LOGICAL_BOOL))
    if _rawexpr_is_decimal_int(e):
        return RawExprTerm(RAWEXPR_LITERAL, DbValue(LOGICAL_INT8, False, e^))
    return RawExprTerm(RAWEXPR_UNEVALUABLE, DbValue.null(LOGICAL_INT8))


def raw_expr_refusal(backend: String, col: String, expr: String) -> String:
    """The ONE refusal sentence both document backends raise for an expression
    they cannot evaluate. It names the backend, the column, the expression AND
    the remedy, because the author of the next unrecognised expression is the
    only person who can decide what it should mean."""
    return (
        backend
        + String(": REFUSED raw SQL expression `")
        + expr
        + String("` for column '")
        + col
        + String(
            "'. A document backend has no SQL evaluator. The closed RAW_EXPR"
            " vocabulary is `<col> + 1`, `true`, `false`, `null` and a signed"
            " decimal integer — use `DbColVal.bind(col, DbValue...)` for"
            " anything else. DROPPING the term would silently lose the write,"
            " which is how `revoked = true` became a no-op on the document"
            " backend while rows_affected still came back non-zero."
        )
    )


comptime POD_NAME_ID_TAIL_LEN: Int = 12
"""How many trailing characters of the job id's canonical text a `pod_name`
carries. 12 = the hyphenated UUID's FINAL group (`8-4-4-4-12`), i.e. bytes
[10..16) — 48 bits, entirely inside a UUIDv7's `rand_b` CSPRNG tail.

⭐ WHY 12. A shape such as `<prefix>-<id8>-<rand4>` (32 bits from the id plus
16 bits of per-CLAIM-BATCH CSPRNG) has only 32 per-ROW bits (a `rand4` minted
once per batch is ONE shared param), so its per-row collision resistance is 32
bits and the 16 random bits make the name UNDERIVABLE. Taking 12 characters
moves that budget inside the id: 48 per-row bits, every one of them
recomputable from the id alone. The name is therefore stronger against
collision AND a pure function.

⚠ THE FINAL GROUP CARRIES NO HYPHEN, and that is load-bearing TWICE OVER.
(a) It is the one slice of the canonical text that four backends can produce
identically — pg `RIGHT(id::text, 12)`, sqlite `lower(substr(hex(id), 21, 12))`,
and the two document drivers via `derive_pod_name` itself. A wider slice would
cross the `8-4-4-4-12` hyphen and the dialects would stop agreeing.
(b) The last 12 characters of the HYPHENATED form and of the BARE 32-character
hex are THE SAME 12 CHARACTERS, so `derive_pod_name` answers identically
whichever spelling a backend keeps in its `id` / partition-key field. That is
not a happy accident to rely on silently: it is why the two document drivers can
hand this function whatever their store recorded without normalising first."""


def derive_pod_name(prefix: String, id_text: String) -> String:
    """⭐⭐ THE ONE DEFINITION OF A PLACEMENT NAME: `<prefix>-<id-tail>`, a PURE
    FUNCTION of the job id.

    `id_text` is the id's canonical hyphenated text (`Uuid.to_hyphenated()`, or
    whatever the backend stores in its `id` / partition-key field); the result
    is `prefix`, a hyphen, and the LAST `POD_NAME_ID_TAIL_LEN` characters of it,
    ASCII-lowercased.

    ⛔⛔ IT MUST STAY PURE. The name is the ONLY address this system has for a
    cloud unit a `create` may have left behind, and the process that needs to
    recompute it is the one that lost everything it knew — a job manager that
    crashed between writing `pod_name` and calling `create`. A CSPRNG suffix
    would make a re-drive mint a name that can never address the previous
    attempt's unit; when that re-drive happens on EVERY recovery pass, a
    bounded strand becomes an unbounded billing re-place loop. Do NOT introduce
    ANY term this function cannot recompute from its arguments — no clock, no
    counter, no random suffix, nothing read off the environment. Same property,
    and the same reason, as `ecs_started_by_for` (`komira_aws_bridge`).

    ⚠ LOWERCASING IS NOT COSMETIC. sqlite's `hex()` answers in UPPERCASE while
    pg's `id::text` is lowercase, so without the fold the same job id would
    produce two different `pod_name`s on two backends — and an uppercase
    character is illegal in a Cloud Run resource name. Every producer lands on
    this one lowercase form.

    ⚠ It does NOT validate `prefix`. An empty prefix yields a leading `-`, which
    a consumer should treat as unowned; the refusals for an empty prefix live at the

    call sites that can say what the right prefix would have been.
    """
    var b = id_text.as_bytes()
    var start = len(b) - POD_NAME_ID_TAIL_LEN
    if start < 0:
        start = 0
    var out = String(prefix)
    out += String("-")
    for i in range(start, len(b)):
        var c = Int(b[i])
        # ASCII A-Z -> a-z. The id text is pure ASCII hex + `-`, so a byte-wise
        # fold is exact (no multi-byte sequence can reach here).
        if c >= 0x41 and c <= 0x5A:
            c += 0x20
        out += chr(c)
    return out^


struct PodNameMinter(Movable, Copyable):
    """The client-side per-row id mint the claim applies to each claimed row:
    `<prefix>-<id-tail>`, where the tail is the row's own id tail extracted by
    the backend (server-side in SQL, in `derive_pod_name` on the document
    drivers). relocation-safe (one String field).

    `prefix` names the pod_name prefix; an empty prefix disables the mint (no
    extra pod_name SET beyond `extra`).

    ⛔ THERE IS NO random-suffix FIELD, AND ADDING ONE IS A BUG. A
    per-claim-BATCH CSPRNG suffix makes the placement name unrecomputable from
    the job id — see `derive_pod_name`'s header for what that costs on a crash
    between the `pod_name` write and the `create`."""


    var prefix: String

    def __init__(out self):
        self.prefix = String("")

    def __init__(out self, var prefix: String):
        self.prefix = prefix^

    def is_active(self) -> Bool:
        return self.prefix.byte_length() > 0
