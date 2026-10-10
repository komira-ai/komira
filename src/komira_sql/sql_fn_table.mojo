# =============================================================================
# sql_fn_table.mojo — THE SQL SCALAR-FUNCTION TABLE. ONE ROW PER FUNCTION.
# =============================================================================
#
# WHY THIS IS A TABLE AND NOT A LADDER, AND THE REASON IS OPERATIONAL
# -------------------------------------------------------------------
# A binder that dispatches on the function name through a chain of
# `sx.text == "..."` blocks gives every name its own arity check, its own
# argument binding and its own factory call, in one function; over DuckDB
# v1.5.3's 240 core scalar functions that is a branch per name. The cost is
# not reading it — it is WRITING it: two changes adding SQL functions in
# parallel collide inside that one chain and have to be resolved by hand.
#
# ⇒ THE PROPERTY THIS FILE EXISTS TO HAVE: **N changes adding N functions add N
#   rows and never touch the same line.** Every row is ONE line, rows are
#   grouped by lowering, and the binder-side code that consumes a row is
#   written ONCE per lowering rather than once per name.
#
# The table is DATA ONLY — it names no `Expr`, calls no binder, and imports
# nothing from `sql_binder`, the `sql_bind_*` modules or `sql_ast`. That lets a
# contributor add a function without opening the binder at all, and it keeps
# the dependency edge acyclic (`sql_bind_*` -> `sql_fn_table`, never back).
#
# ⚠⚠ THERE ARE THREE NAME SPACES HERE AND THEY ARE NOT THE SAME SET
# -----------------------------------------------------------------
#   1. `sql_scalar_fn_spec`  — the FUNCTION namespace:  `year(d)`, `upper(s)`
#   2. `sql_date_part_unit`  — the `date_part` / `EXTRACT(<f> FROM x)` SPECIFIER
#                              namespace: the first argument of `date_part`
#   3. `sql_date_trunc_unit` — the `date_trunc` PERIOD namespace
#
# ⛔ DO NOT COLLAPSE (1) AND (2) INTO ONE TABLE. It looks like tidying and it is
# a silent behaviour change. MEASURED against DuckDB v1.5.3:
# `date_part('dow', x)` = 0 while `select dow(x)` is a Catalog Error — a name
# that exists as a SPECIFIER and not as a FUNCTION; `doy` is the same, and so
# is every plural/short alias (`yrs`, `mins`, `secs`, `w`). Symmetrically (2)
# and (3) are not one set either — and the example is SHARPER
# than "one has a kernel": `millisecond` is in BOTH tables and MEANS SOMETHING
# DIFFERENT IN EACH. `date_part('ms', t)` READS 30123 (the seconds folded in);
# `date_trunc('ms', t)` ZEROES everything below the millisecond and returns a
# timestamp. Same spelling, different table, different answer and different
# output TYPE — which no shared table could express.
# ⛔ AND THE SECONDS REALLY ARE FOLDED IN: `millisecond` of `...:30.123456` is
# 30123, not 123. Mapping it onto "the fractional field" is wrong by three
# orders of magnitude and plausible while doing it.
#
# ⚠⚠ `dayofmonth` IS NOT A WITNESS FOR (1)-vs-(2). On v1.5.3,
# `dayofmonth` is a FUNCTION **and** a `date_part` SPECIFIER **and** a
# `date_trunc` PERIOD (15 / 15 / 2026-11-15). Refusing it in any one table
# would decline a spelling the parity target serves. A claim copied into
# several files agrees with itself however wrong it is, which is why nothing
# here derives one table from another even when they look alike — a wrong
# shared fact propagates, a wrong independent row does not.
#
# WORKED DATES. Where a date example is not marked MEASURED, its values are
# computed by the calendar rules DuckDB applies, and DuckDB gives the same
# values by the same rules. Which spelling binds and which error a spelling
# raises are v1.5.3 behaviour, whatever date an example uses.
#
# The three tables happen to AGREE on many names today. That agreement is a
# measured DuckDB fact, NOT an invariant, and nothing here enforces it —
# deliberately, because the day it stops being true is the day a shared table
# would start lying.
#
# HOW TO ADD A FUNCTION
# ---------------------
#   * it lowers to a node this binder already builds -> ONE LINE here, and
#     NOTHING in the `sql_bind_*` modules.
#   * it is a pure binder DESUGAR (the route most functions not yet served
#     will take) -> ONE LINE here naming a new `DSG_*`, plus one new `_bind_*`
#     helper function APPENDED to `sql_bind_fn_args.mojo` or
#     `sql_bind_fn_nested.mojo` (the modules that hold the desugar helpers)
#     and one line in the `FNK_DESUGAR` switch of `sql_bind_call.mojo`'s
#     `_bind_scalar_call`. Two changes adding two desugars append two
#     DIFFERENT functions and two DIFFERENT rows; they do not collide.
#   * it is a real DuckDB function this engine deliberately does NOT serve, or
#     one it CANNOT serve yet -> ONE LINE here with `FNK_REFUSED` and the
#     measured reason. A refusal whose reason lives only in a docstring is a
#     fact nobody can read at the point it fires.
#
#     ⛔ THE REASON MUST NAME THE MISSING PRIMITIVE. "Not supported" is what
#     the caller already knows; the row earns its line only by saying WHICH arm,
#     WHICH tag or WHICH kernel is absent, and by carrying the measurement that
#     establishes it. A reason is per-FAMILY, a row is per-NAME — the same
#     split `_fn_arity_msg` already makes.
#
#     ⛔⛔ NO COUNT IS WRITTEN HERE. A count quoted in prose describes the
#     draft it was written against, not the rows that exist, and it is wrong
#     the moment a row is added or removed. Both figures (refusal rows, reason
#     constants) move whenever rows change, and both are one command:
#
#         grep -oE 'SqlFnSpec[(][^)]*FNK_REFUSED' src/komira_sql/sql_fn_table.mojo | wc -l
#         grep -cE '^comptime _R_' src/komira_sql/sql_fn_table.mojo
#
#     ⛔ `[(]`, NOT the backslash form — see `SqlFnSpec.lowers_to_a_node`'s
#     docstring, which says why the backslash form stops the file compiling.
#
#     ⚠ AND A REFUSAL ROW IS A CLAIM THAT THE NAME IS REAL. Do not add one for
#     a spelling DuckDB does not have — that would tell a caller the parity
#     target serves something it does not.
#
# Encapsulation (the Mojo pointer rules): no `UnsafePointer` in any signature here,
# no wildcard origins, no `unsafe_from_address`, no partial moves.
# =============================================================================

from komira_plan_expr.expr import (
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_MOD,
    UN_ABS, UN_SIGN, UN_TRUNC, UN_ROUND, UN_BIT_COUNT,
    STRFN_UPPER, STRFN_LOWER, STRFN_TRIM, STRFN_LTRIM, STRFN_RTRIM,
    STRFN_LENGTH, STRFN_REVERSE,
    STRFN_ASCII, STRFN_UNICODE, STRFN_STRLEN, STRFN_BIT_LENGTH,
    STRFN_HEX, STRFN_BIN, STRFN_URL_ENCODE, STRFN_URL_DECODE,
    STRFN_REGEXP_ESCAPE,
    STRFN_MD5, STRFN_SHA1, STRFN_SHA256,
    MATH_SIN, MATH_COS, MATH_SQRT, MATH_ASIN, MATH_RADIANS, MATH_CEIL,
    MATH_FLOOR, MATH_LN, MATH_EXP, MATH_LOG10, MATH_LOG2, MATH_TAN,
    MATH_ATAN, MATH_ACOS, MATH_COT, MATH_DEGREES, MATH_CBRT, MATH_SINH,
    MATH_COSH, MATH_TANH, MATH_ACOSH, MATH_ASINH, MATH_ATANH, MATH_GAMMA,
    MATH2_ATAN2, MATH2_POW,
    STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH,
    STRFNN_CONCAT, STRFNN_CONCAT_WS, STRFNN_REPLACE, STRFNN_LPAD,
    STRFNN_RPAD, STRFNN_REPEAT, STRFNN_STRPOS,
    STRFNN_LEVENSHTEIN, STRFNN_DAMERAU_LEVENSHTEIN, STRFNN_HAMMING,
    STRFNN_JARO, STRFNN_JARO_WINKLER, STRFNN_JACCARD,
    STRFNN_TRANSLATE,
    EXTRACT_YEAR, EXTRACT_QUARTER, EXTRACT_MONTH, EXTRACT_DAY, EXTRACT_HOUR,
    EXTRACT_MINUTE, EXTRACT_SECOND,
    EXTRACT_DAYOFWEEK, EXTRACT_ISODOW, EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK, EXTRACT_ISOYEAR, EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND, EXTRACT_MICROSECOND,
    EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_QUARTER, EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MINUTE, EXTRACT_TRUNC_SECOND, EXTRACT_TRUNC_MILLISECOND,
    EXTRACT_TRUNC_MICROSECOND,
    REGEXP_LIKE, REGEXP_FULL_MATCH, REGEXP_REPLACE, REGEXP_EXTRACT,
    REGEXP_EXTRACT_ALL, REGEXP_SPLIT_TO_ARRAY,
)


# -----------------------------------------------------------------------------
# THE LOWERING KINDS — "which node does this name become".
#
# A kind is a CONTRACT WITH THE BINDER: it fixes how the arguments are bound,
# what arity message a bad call gets, and which `Expr` factory runs. Adding a
# name to an existing kind is therefore free; a genuinely new SHAPE is a new
# kind plus one arm in `_bind_scalar_call`.
# -----------------------------------------------------------------------------
comptime FNK_NONE: UInt8 = 0
"""Not a scalar function this binder knows. The table's absent-row sentinel."""

comptime FNK_STRING_FN: UInt8 = 1
"""`Expr.string_fn(op, child)` — EXPR_STRING_FN over one bound argument."""

comptime FNK_MATH_FN: UInt8 = 2
"""`Expr.math_fn(op, child)` — EXPR_MATH_FN over one bound argument. Output is
always FLOAT64 (the tag's contract)."""

comptime FNK_MATH_FN2: UInt8 = 3
"""`Expr.math_fn2(op, left, right)` — EXPR_MATH_FN2 over two bound arguments."""

comptime FNK_STRING_PRED: UInt8 = 4
"""`Expr.string_op(op, child, pattern)` — EXPR_STRING_OP. The PATTERN must be a
string LITERAL, because `StringOpData.pattern` is a `String` and not an `Expr`;
that is a property of the tag, not of the binder."""

comptime FNK_EXTRACT_FIELD: UInt8 = 5
"""`Expr.extract(unit, child)` — EXPR_EXTRACT over one bound argument, for the
bare field FUNCTIONS (`year(d)`). ⚠ This is namespace (1), not namespace (2):
see the header. `date_part` is a DESUGAR row because it reads its unit from an
argument at bind time."""

comptime FNK_STRING_FN_N: UInt8 = 8
"""`Expr.string_fn_n(op, args)` — EXPR_STRING_FN_N, the VARIADIC multi-argument
string family. ⚠ ITS ARITY IS NOT THIS TABLE'S TO STATE: every row uses
`FN_ARITY_OWN` and `_bind_string_fn_n` checks the ENGINE's `string_fn_n_arity`,
the same table the wire decoder and the evaluator read. Four producers, one
count."""

comptime FNK_DESUGAR: UInt8 = 6
"""A pure binder desugar — the row's `op` is a `DSG_*` selecting which. No new
tag, no kernel, no wire member, no pinned counter."""

comptime FNK_REGEXP: UInt8 = 9
"""`Expr.regexp(op, child, pattern, replacement, flags, group)` — EXPR_REGEXP.

⭐ THIS KIND EXISTS BECAUSE THE OPS WERE **UNREACHABLE, NOT MISSING**. Every
`REGEXP_*` op has a kernel (`komira_column_kernels/regexp_functions.mojo`), a
`compiler_eval_column` arm, an output-type arm in `walk_expr_field`, a wire
member, a proto enum, a round-trip pin, an optimizer arm, a purity-gate arm and
a `col_expr` DataFrame door — and NO row in this table, so no SQL text could
reach any of it. Closing it cost this kind plus one binder arm.

⚠ ARITY IS `FN_ARITY_OWN` ON EVERY ROW, because the four names do NOT share an
argument shape: `regexp_replace` puts a REPLACEMENT at position 2 and its
options at 3, `regexp_extract` puts a GROUP INDEX at 2 and its options at 3.
One family message cannot state both, so `_bind_regexp` owns the check."""

comptime FNK_UNARY_NUM: UInt8 = 10
"""`Expr.unary(op, child)` — EXPR_UNARY_OP over one bound argument, with the
`op` read in the `UN_*` namespace. The TYPE-PRESERVING numeric family.

⭐ THIS KIND EXISTS BECAUSE OF A TYPE RULE, NOT AN ARGUMENT SHAPE. `abs`,
`trunc` and `round` return the OPERAND's type (`abs(BIGINT)` is BIGINT on
DuckDB v1.5.3) and `sign` returns TINYINT for every operand; `FNK_MATH_FN`
cannot express either, because `EXPR_MATH_FN`'s contract is always-FLOAT64.
Routing these through it would be a silent type divergence — a column read
at the wrong width (int32 data read at an 8-byte stride) gives a plausible
value and no error, so it is worth a kind of its own.

⚠ ONE ARGUMENT, AND THE TWO-ARGUMENT FORMS ARE REFUSED WITH THEIR OWN MESSAGE
rather than by a generic count. DuckDB has `round(x, digits)` and
`trunc(x, digits)`; `EXPR_UNARY_OP` is unary and cannot carry the second
operand, and silently rounding to zero digits would answer a different
question. See `_fn_arity_msg`."""

comptime FNK_BINARY_OP: UInt8 = 11
"""`Expr.binary(op, left, right)` — EXPR_BINARY_OP, with the `op` read in the
`BIN_*` namespace. The FUNCTION SPELLINGS of the arithmetic operators.

⭐ THIS KIND ADDS NO OP, NO KERNEL AND NO WIRE MEMBER — every `BIN_*` it names
is executable independently of this table. What this kind adds is only
that DuckDB ALSO SPELLS FIVE OF THEM AS FUNCTIONS, and no census of the `EXPR_*`
op space can see that: an op census asks "which ops are unreachable" and these
were reachable, through `a + b`. `duckdb_functions()` carries them with a
first-class `alias_of` column that says so — `add -> '+'`, `subtract -> '-'`,
`multiply -> '*'`, `mod -> '%'`, `divide -> '//'`.

⛔⛔ `divide` IS `//`, NOT `/`, AND THAT IS THE ONE ROW WHERE THE ALIAS COLUMN
IS LOAD-BEARING. MEASURED v1.5.3: `divide(7,2)` = **3** and `divide(-7,2)` =
**-3** (truncating toward zero), while `7 / 2` there is **3.5** — DuckDB's `/`
promotes two integers to DOUBLE and its `//` does not. So `divide` is NOT the
function spelling of DuckDB's `/`. It happens to be the function spelling of
THIS engine's `/`, whose I64 arm is `EXPR_DIV_I64` — integer division,
truncating toward zero, the same answer. Binding it to `BIN_DIV` is therefore
right for the integer case BY MEASUREMENT rather than by symmetry with the
other four, and the FLOAT case agrees too (`divide(7.0,2.0)` = 3.5).

⛔ `xor` IS NOT A ROW. It is in the same family of operator-spellings
(`xor(5,3)` = 6, bitwise) and there is no `BIN_XOR` on this engine's wire —
routing it to any existing `BIN_*` would answer a different question.

⚠ `add` AND `subtract` HAVE UNARY OVERLOADS THERE and this kind serves them:
MEASURED `add(5)` = 5, `subtract(5)` = -5. The one-argument form is not a
binary node at all — it is the identity and `UN_NEGATE` — so the LOWERING
dispatches on the count, and the three other members refuse a single argument
through their row's `min_args` before the lowering ever runs."""


comptime FNK_REFUSED: UInt8 = 7
"""A real DuckDB function this engine deliberately does NOT serve. The row
carries the MEASURED reason and the binder raises it verbatim. A refusal with a
reason is worth more than an unknown-function error, because the reason is what
stops the next reader "fixing" it with a nearest-match that is silently wrong."""


comptime FNK_CONST: UInt8 = 12
"""A DuckDB MACRO WHOSE ENTIRE BODY IS A CONSTANT. The row's `op` is a
`CONST_*` selecting WHICH constant; the row's `min_args`/`max_args` state the
arity DuckDB DECLARES for that name.

⭐ THIS KIND EXISTS BECAUSE THE ARGUMENTS ARE NOT BOUND, AND THAT IS A MEASURED
DuckDB FACT RATHER THAN A SHORTCUT. v1.5.3, over a table whose only column is
`x`:

    select pg_table_is_visible(zzz), has_table_privilege(nope, alsonope) from t
    -> true, true

`zzz`, `nope` and `alsonope` do not exist and DuckDB does not care: a macro body
that never references its parameters never binds them. A `select current_user
from t where zzz = 1` in the SAME session IS a `Binder Error: Referenced column
"zzz" not found`, so the leniency is the macro's, not the parser's. ⇒ routing
these names through any kind that binds `args[0]` would REFUSE calls the parity
target answers, and it would do it on the argument that the answer does not
depend on.

⚠ THE ARITY IS STILL ENFORCED, FROM THE ROW, because DuckDB enforces it:
`pg_table_is_visible(1,2)` is a Binder Error naming the candidate
`pg_table_is_visible(table_oid)`. Ignoring an argument's VALUE and ignoring its
COUNT are different things, and only the first is what a constant body does.

⛔ NOT `FNK_DESUGAR`. Every desugar row uses `FN_ARITY_OWN` and states its own
arity message from inside its `_bind_*` helper; these 29 names have FIVE
distinct arities (0, 1, 2..3, 3..4) that DuckDB states per name, so the arity
belongs on the ROW and the message belongs to the FAMILY — which is exactly the
split `SqlFnSpec` + `_fn_arity_msg` already make, and it only works with a kind
of its own."""


# -----------------------------------------------------------------------------
# THE CONSTANT SELECTORS — WHICH constant an `FNK_CONST` row answers.
# -----------------------------------------------------------------------------
comptime CONST_TRUE: UInt8 = 0
"""BOOLEAN `true`. 24 of the 25 PG-compat predicate macros publish
`CAST('t' AS BOOLEAN)` as their entire body."""

comptime CONST_FALSE: UInt8 = 1
"""BOOLEAN `false` — `pg_is_other_temp_schema` alone, whose published body is
`CAST('f' AS BOOLEAN)`.

⛔ IT IS ITS OWN SELECTOR AND MUST STAY ONE. Folding it in with `CONST_TRUE`
"because they are both bool constants" answers `true` for a name whose whole
job is to answer `false`, on a fixture where nothing else in the family
disagrees — a wrong answer that no test over the other 24 can see."""

comptime CONST_USER: UInt8 = 2
"""VARCHAR `'duckdb'` — `current_user` / `session_user` / `current_role` /
`user`, whose published bodies are the literal `'duckdb'` (`user`'s is
`current_user`, which resolves to the same literal).

⚠⚠ THIS IS A COMPATIBILITY CONSTANT AND NOT AN IDENTITY, WHICH IS WHY A
HARD-CODED STRING IS THE FAITHFUL ANSWER AND NOT A PLACEHOLDER. Every DuckDB
v1.5.3 deployment answers `'duckdb'` here whatever OS user runs it (measured
over a column, VARCHAR), because these names exist for PostgreSQL tools that
need a non-null user string, not to report who is connected. ⛔ THE DAY THIS
ENGINE GROWS REAL SESSION IDENTITIES THIS ROW BECOMES A LIE and must be
rewritten to read one — it is transcribed from the parity target, not designed."""


comptime CONST_INT_ZERO: UInt8 = 3
"""INTEGER `0` — `pg_my_temp_schema` alone, whose published `macro_definition`
is the bare literal `0` and whose `duckdb_functions()` parameter list is EMPTY.

⚠⚠ THE WIDTH IS THE WHOLE ROW, AND IT IS THE REASON THIS IS ITS OWN SELECTOR
RATHER THAN AN INT64 LITERAL. MEASURED v1.5.3 over a column:
`typeof(pg_my_temp_schema())` = `INTEGER` — **int32, not bigint**. Answering
BIGINT here would be a wrong TYPE for a name whose entire value is PostgreSQL
wire compatibility, and a pgwire client reading the type OID is precisely the
caller that would notice. The binder arm is `ScalarValue.from_int32`.

⭐ THIS ROW BINDS ON AN EXECUTION OF THE INT32 ARM, NOT ON A READING OF IT.
The STRING arm and the BOOL arm of the same `broadcast_scalar` ladder were each
READ as present and found BROKEN the first time anything ran one (a constant
STRING projection declared NULL for the STRING column it built; `SELECT TRUE
AS b` raised `PHYSICAL LAYOUT CONFLICT` and TRUE/FALSE returned the IDENTICAL
batch). A plan-wire literal-rows test executes the int32 arm:

    SELECT <int32 0> AS t -> declared=int32 actual=int32:[0,0,0,0,0,0]

declared type, materialised type and VALUE all agreeing. It is the only one of
the three arms read off that ladder that worked — 2-for-3 broken is the base
rate, so a future INT32-typed row still needs its own execution, not this
precedent."""


# -----------------------------------------------------------------------------
# THE DESUGAR SELECTORS. One per desugar SHAPE; aliases of one shape share a
# selector, and two spellings that must behave DIFFERENTLY get two
# (`coalesce` is variadic, `ifnull` is exactly 2-ary, so they are two).
# -----------------------------------------------------------------------------
comptime DSG_DATE_DIFF: UInt8 = 0
comptime DSG_COALESCE: UInt8 = 1
comptime DSG_IFNULL: UInt8 = 2
comptime DSG_GREATEST: UInt8 = 3
comptime DSG_LEAST: UInt8 = 4
comptime DSG_DATE_PART: UInt8 = 5
comptime DSG_DATE_TRUNC: UInt8 = 6
comptime DSG_LEFT: UInt8 = 7
comptime DSG_RIGHT: UInt8 = 8
comptime DSG_SUBSTRING: UInt8 = 9
comptime DSG_PI: UInt8 = 10
comptime DSG_CENTURY: UInt8 = 11
comptime DSG_DECADE: UInt8 = 12
comptime DSG_MILLENNIUM: UInt8 = 13
comptime DSG_ERA: UInt8 = 14
comptime DSG_NANOSECOND: UInt8 = 15
comptime DSG_ISFINITE: UInt8 = 16
comptime DSG_ISINF: UInt8 = 17
comptime DSG_ISNAN: UInt8 = 18
comptime DSG_STRING_SPLIT: UInt8 = 19
comptime DSG_DATE_SUB: UInt8 = 20
comptime DSG_EVEN: UInt8 = 21
comptime DSG_FDIV: UInt8 = 22
comptime DSG_FMOD: UInt8 = 23
comptime DSG_NULLIF: UInt8 = 24
comptime DSG_DAYS_IN_MONTH: UInt8 = 25
comptime DSG_CAST: UInt8 = 26
comptime DSG_TRY_CAST: UInt8 = 27
comptime DSG_JSON_EXTRACT: UInt8 = 28
comptime DSG_JSON_EXTRACT_TEXT: UInt8 = 29
comptime DSG_STRUCT_EXTRACT: UInt8 = 30
comptime DSG_STRUCT_EXTRACT_AT: UInt8 = 31
comptime DSG_MAP_EXTRACT_VALUE: UInt8 = 32
"""The JSON extract selectors: the TWO leaf modes `EXPR_JSON_EXTRACT`
can express, and they are two selectors rather than one because DuckDB v1.5.3
gives them DIFFERENT ANSWERS on two of the six leaf shapes:

    payload `{"b":"hi","n":null}`      `json_extract`  `json_extract_string`
      $.b  (a JSON string)                  "hi"              hi
      $.n  (the JSON null literal)          null            SQL NULL

Everything else — numbers, booleans, objects, arrays, a missing key, a NULL
parent — is byte-identical between them, so a fixture without a STRING leaf AND
a JSON-null leaf cannot tell the two selectors apart.

⛔ THERE IS NO THIRD SELECTOR AND `json_value` IS NOT ONE OF THESE TWO — see
`_R_JSONLEAFMODE`."""

comptime DSG_MAKE_TS_US: UInt8 = 33
comptime DSG_MAKE_TS_MS: UInt8 = 34
comptime DSG_MAKE_TS_NS: UInt8 = 35
"""The epoch-count timestamp selectors: the ARITY-1 EPOCH-COUNT overloads of
`make_timestamp` / `make_timestamp_ms` / `make_timestamp_ns` — an integer count
of ticks since 1970-01-01, relabelled as the TIMESTAMP unit that count is in.

⭐ THREE SELECTORS AND NOT ONE, BECAUSE THE THREE NAMES DO NOT AGREE ON THE
OUTPUT UNIT. MEASURED on DuckDB v1.5.5, `typeof` on each:

    make_timestamp(m)     m MICROseconds  ->  TIMESTAMP      (i.e. _US)
    make_timestamp_ms(m)  m MILLIseconds  ->  TIMESTAMP      (i.e. _US)  ⚠
    make_timestamp_ns(m)  m NANOseconds   ->  TIMESTAMP_NS

So `_ms` is the ODD ONE: its INPUT is milliseconds and its OUTPUT is
microseconds, which is the only one of the three that is not a bare relabel —
it needs the `TIMESTAMP_MS -> TIMESTAMP_US` scale (x1000) on top. One shared
selector carrying "the timestamp unit" would have made `make_timestamp_ms`
answer 1000x small, and 1000x small is a plausible instant rather than a
visible failure.

⛔ THESE ARE THE EPOCH OVERLOADS ONLY. The CALENDAR-COMPONENT forms (the 6-ary
`make_timestamp`, `make_date(y, m, d)`, `make_time`) still refuse through
`_R_TSMINT`, whose missing primitive — civil-calendar-to-days — is REAL and is
untouched by this. See `_bind_make_timestamp_epoch`."""


# -----------------------------------------------------------------------------
# ⭐ THE TWO CAST DESUGAR NAMES — NAMES THE TOKENIZER CANNOT PRODUCE.
# -----------------------------------------------------------------------------
comptime CAST_DESUGAR_NAME: String = "cast as"
"""The `SX_CALL` name `CAST(x AS T)` and `x::T` both desugar to.

⛔⛔ THE SPACE IS LOAD-BEARING AND IS THE WHOLE POINT. `sql_token._is_ident`
accepts only `[A-Za-z0-9_]`, so NO SQL TEXT CAN EVER LEX TO THIS NAME — which
means this row claims a name and opens no second spelling. Had the row been
called `cast`, the name would have become callable as an ordinary two-argument
function (`cast(v, 'bigint')`), a spelling DuckDB does not have and nobody
asked for, reachable by anyone who guessed it and impossible to withdraw later
without breaking whoever did.

⚠ IT IS DECLARED HERE, NOT IN THE PARSER, so the producer (`sql_parser`) and
the consumer (`sql_scalar_fn_spec` + `sql_bind_call`) read ONE token. A desugar
name written down twice is a desugar that silently stops resolving the day one
copy is edited — and its failure mode is the generic unknown-function refusal,
which reads exactly like the feature never having existed.

⚠ AND `cast` / `try_cast` DELIBERATELY HAVE NO ROW OF THEIR OWN. The parser
intercepts both names when they are followed by `(` and raises its own
missing-AS syntax error, so neither ever reaches this table; a row for them
would be dead, and `lowers_to_a_node` on a dead row would claim the name
against a user's UDF for nothing."""

comptime TRY_CAST_DESUGAR_NAME: String = "try_cast as"
"""The `TRY_CAST(x AS T)` twin of `CAST_DESUGAR_NAME`. Same unlexable shape.

⭐ IT IS A SEPARATE SELECTOR RATHER THAN A FLAG ON THE CAST ROW BECAUSE THE TWO
DO NOT AGREE ON THIS ENGINE. `TRY_CAST` answers NULL where a strict cast
raises or wraps, and this engine's cast kernels have no null-on-failure arm at
all — so binding `TRY_CAST` to the strict lowering would answer a NUMBER where
DuckDB answers NULL. MEASURED in the committed v1.5.3 oracle:
`TRY_CAST(i64 AS INTEGER)` over INT64_MIN is `null` there; the truncating
kernel here would answer `0`. Two selectors is what lets the binder refuse one
by name while serving the other."""

comptime POSITION_IN_DESUGAR_NAME: String = "position in"
"""The `SX_CALL` name `POSITION(<needle> IN <haystack>)` desugars to,
with its arguments already in `strpos` order: (haystack, needle).

⛔ UNLEXABLE BY THE SAME CONSTRUCTION AS `CAST_DESUGAR_NAME` — the space. Only
the parser's POSITION arm can produce it, so the row it keys opens no second
calling spelling: `position(a, b)` stays the `_R_POSITION` refusal (a Parser
Error on DuckDB v1.5.3), and the name `position` is not taken from a UDF.

⭐ A NAME OF ITS OWN RATHER THAN `strpos`, BECAUSE THE RESULT COLUMN IS NAMED
AFTER IT. DuckDB prints `main."position"(s, 'b')` for `POSITION('b' IN s)`
(MEASURED v1.5.3); the renderer (`sql_bind_names._duckdb_expr_text`) keys on this
name to print the same, where a desugar to `strpos` would print `strpos(...)`."""

comptime FN_ARITY_OWN: Int = -1
"""`min_args` sentinel: the LOWERING checks its own arity and raises its own
message. Every `FNK_DESUGAR` row uses it — their messages carry measured facts
("greatest() takes exactly 2 arguments here ... folding a third would square
the plan") that a generic arity check cannot express."""

comptime FN_ARITY_UNBOUNDED: Int = -1
"""`max_args` sentinel: variadic above `min_args`."""


struct SqlFnSpec(Movable):
    """One row of the scalar-function table.

    `op` is read in the namespace the `kind` names: a `STRFN_*` for
    FNK_STRING_FN, a `MATH_*` for FNK_MATH_FN, a `MATH2_*` for FNK_MATH_FN2, a
    `STR_*` for FNK_STRING_PRED, an `EXTRACT_*` for FNK_EXTRACT_FIELD, a `DSG_*`
    for FNK_DESUGAR, and nothing at all for FNK_NONE / FNK_REFUSED.

    ARITY. `min_args`/`max_args` are INCLUSIVE and the BINDER enforces them, so
    the check cannot be forgotten by a new row. `min_args == FN_ARITY_OWN` hands
    the check to the lowering; `max_args == FN_ARITY_UNBOUNDED` is variadic.
    """

    var kind: UInt8
    var op: UInt8
    var min_args: Int
    var max_args: Int
    var reason: String

    var lowers_to_a_node: Bool
    """★ DOES THIS ROW ACTUALLY BECOME AN `Expr`? — THE TABLE STATING IT ABOUT
    ITSELF, RATHER THAN A CALLER DERIVING IT FROM `kind`.

    ⛔ A KIND-NUMBER COMPARISON GETS THIS WRONG, SILENTLY, SO THIS FIELD STATES
    IT. `kind != FNK_NONE` answers YES for every refusal row, because
    `FNK_REFUSED` is 7, not 0 — and a caller that read that as "a builtin
    claims this name" (`SqlUdfCatalog.declare` asks exactly that question)
    would tell a user that a built-in scalar function shadows their UDF. No
    such builtin exists: a refusal row is a name this engine declines to
    LOWER, and a name that lowers to nothing cannot shadow anything.

    ⚠ **THE REFUSAL COUNT IS A COUNT OF ROWS, AND `grep -c FNK_REFUSED` DOES
    NOT MEASURE IT.**
    That spelling counts LINES — it catches prose and the `comptime FNK_REFUSED`
    declaration itself, so it overstates the row count, and it DRIFTS as prose
    is edited even when no row changes. The row count itself also MOVES
    whenever a refusal row is added or a refused name starts to bind. ⛔ DO NOT
    QUOTE A NUMBER HERE. Re-derive by CONSTRUCTION:

        grep -oE 'SqlFnSpec[(][^)]*FNK_REFUSED' src/komira_sql/sql_fn_table.mojo | wc -l

    ⛔ `[(]`, NOT `\\(` — AND THAT IS NOT A STYLE PREFERENCE. The backslash form
    is the natural ERE, but the Mojo parser rejects the escape inside the
    docstring and the file stops compiling, which takes down every target that
    imports `komira_sql` — i.e. the engine. `[(]` is the identical bracket
    expression (MEASURED: both spellings return the same count over this
    file) and carries no backslash at all. The same class applies to any
    docstring in this repository (a `\\.` in a build-rule docstring makes a
    whole build unloadable), so a shell recipe pasted into a docstring must be
    written backslash-free.

    ⭐ THE ENCODING IS THE POINT, NOT THE VALUE. It is written by the
    CONSTRUCTOR, never derived from `kind` by a comparison a reader has to keep
    in sync — so a kind added tomorrow is classified by which constructor its
    rows call, which is a decision its author cannot skip:

      * the LOWERING constructor (`kind, op, min_args, max_args`) is the shape
        a row takes when it names a node and an arity  -> True;
      * the REFUSAL constructor (`kind, reason`) carries a sentence and no op
        -> False;
      * the ABSENT row (no arguments) -> False.

    A future non-lowering kind that needs a third shape has to add an `__init__`
    overload, and Mojo will not compile one that leaves this field unset. An
    exclusion list (`kind != FNK_NONE and kind != FNK_REFUSED`) has the opposite
    property: the new kind joins it by OMISSION, which is exactly how the door
    broke."""

    def __init__(out self):
        """The absent row. Lowers to nothing, so it shadows nothing."""
        self.kind = FNK_NONE
        self.op = 0
        self.min_args = FN_ARITY_OWN
        self.max_args = FN_ARITY_UNBOUNDED
        self.reason = String("")
        self.lowers_to_a_node = False

    def __init__(out self, kind: UInt8, op: UInt8, min_args: Int, max_args: Int):
        """A LOWERING row: `kind` names the factory, `op` its namespace member.

        Every row built here becomes an `Expr`, so every row built here CLAIMS
        the name against any UDF declared under it."""
        self.kind = kind
        self.op = op
        self.min_args = min_args
        self.max_args = max_args
        self.reason = String("")
        self.lowers_to_a_node = True

    def __init__(out self, kind: UInt8, reason: String):
        """A FNK_REFUSED row. Arity is never checked — the name refuses first.

        ⭐ IT LOWERS TO NOTHING, AND THAT IS WHY A UDF MAY TAKE THIS NAME. The
        row says the parity target HAS this function and this engine will not
        approximate it; a user supplying their own is the one remedy the
        row leaves open, so `lowers_to_a_node` is False and both the declare
        door and the binder read it that way."""
        self.kind = kind
        self.op = 0
        self.min_args = FN_ARITY_OWN
        self.max_args = FN_ARITY_UNBOUNDED
        self.reason = reason
        self.lowers_to_a_node = False


# =============================================================================
# THE REFUSAL REASONS. One `String` per FAMILY, named `_R_*`.
# =============================================================================
#
# ⭐ A REASON IS PER-FAMILY AND A ROW IS PER-NAME, WHICH IS THE SAME SPLIT
# `_fn_arity_msg` ALREADY MAKES: 25 names blocked on one missing arm of
# `broadcast_scalar` share one measured sentence, and each still gets its own
# greppable row so `git grep '"has_table_privilege"'` finds it.
#
# ⛔ EVERY SENTENCE BELOW NAMES THE MISSING PRIMITIVE AND CARRIES A MEASUREMENT.
# "not supported" is not a reason — it is what the caller already knows. The
# reason exists so the next reader does not close the gap with a nearest-match
# that is silently wrong, which is the failure this whole table is arranged
# against (a census that filters to `function_type='scalar'` reports
# `split_part` as "a PostgreSQL name, not in v1.5.3"; it is a v1.5.3 macro).
#
# ⚠ MEASURED AGAINST DuckDB v1.5.3, and the bodies are quoted
# from `duckdb_functions().macro_definition` — the PUBLISHED definition, not a
# reconstruction.
#
# THE COUNT, RE-DERIVE IT, DO NOT QUOTE IT:
#   python3 -c "import duckdb;print(duckdb.connect().execute(
#     \"select count(distinct function_name) from duckdb_functions()
#        where function_type='macro'\").fetchone())"
# =============================================================================

# ⛔ A REASON CONSTANT NO ROW REFERENCES IS DELETED, NOT KEPT. It is a sentence
# that cannot be read at the point it fires, which is the one thing this section
# exists to prevent — the correct lifecycle for a refusal whose primitive now
# exists is DELETION, not retirement in place. That is why there is no reason
# for the 25 PG-compat boolean macros (they are `FNK_CONST` rows below) and none
# for `current_user`/`session_user`/`current_role`/`user` (they bind, because
# `expr_walk.walk_expr_field` declares a bare STRING literal as a STRING).

comptime _R_AGGR: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 MACRO bodied "
    "`list_aggr(l, '<agg>')` — a per-row reduction over the ELEMENTS of "
    "one LIST value. THE MISSING PRIMITIVE IS `list_aggr` ITSELF: this "
    "engine has no expression tag for reducing a list cell (no `EXPR_*` "
    "member in `komira_plan_expr/expr.mojo` takes a List operand and "
    "returns a scalar), and its `EXPR_AGG_FN` aggregates ACROSS ROWS, "
    "not within a cell — a different operation with a different answer. "
    "The operand is already reachable (`string_split` lowers to "
    "REGEXP_SPLIT_TO_ARRAY, so a List<Utf8> column exists in SQL "
    "today); the reduction is not. 31 macro names unblock on it, but it "
    "is a kernel FAMILY (~29 distinct aggregates), not one arm."
)

comptime _R_NULLC: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 MACRO whose entire "
    "body is the bare literal `NULL`, and its declared type there is "
    "the special \"NULL\" type (measured: `typeof(inet_client_addr())` = "
    "'\"NULL\"'). THE MISSING PRIMITIVE IS A NULL-TYPED NULL: "
    "`broadcast_scalar`'s null arm carries exactly TWO logical types, "
    "float64 and int64, so the closest this engine can answer is a "
    "BIGINT NULL. Every VALUE would agree and every TYPE would not — "
    "the same wall that keeps `dayname`/`monthname` unbound. Bound on "
    "that approximation this would be a silent type divergence, which "
    "is worth less than the missing name."
)

comptime _R_BUILD: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 MACRO bodied over "
    "`list_concat` and `list_value` (measured: `list_append(l,e)` is "
    "`list_concat(l, list_value(e))`). THE MISSING PRIMITIVES ARE LIST "
    "CONSTRUCTION AND CONCATENATION: this engine has no expression that "
    "BUILDS a list cell — `REGEXP_SPLIT_TO_ARRAY` is the only producer "
    "of a List column and it splits a string; there is no `list_value` "
    "and no `list_concat` node in `komira_plan_expr/expr.mojo`."
)

comptime _R_SLICE: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 MACRO bodied over "
    "LIST SLICING or INDEXING (measured bodies: `array_pop_front` is "
    "`arr[2:]`, `array_pop_back` is `arr[:(len(arr) - 1)]`, "
    "`list_reverse` is `l[:-:-1]`, `split_part` is "
    "`COALESCE(string_split(s,d)[pos], '')`). THE MISSING PRIMITIVE IS "
    "A LIST SUBSCRIPT: this engine has no expression that indexes or "
    "slices a list cell. ⛔ `split_part` IS NOT ABSENT FROM DuckDB — the "
    "record that called it a PostgreSQL name was a measurement against "
    "the scalar tier only; it is blocked here, "
    "not missing there."
)

comptime _R_CATALOG: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 MACRO that reads "
    "the CATALOG — its body is a catalog scalar or a literal subquery "
    "over `duckdb_types()` / `duckdb_views()` / `duckdb_constraints()` "
    "(measured: `current_database` is "
    "`\"system\".main.current_database()`, `pg_get_viewdef` is `(SELECT "
    "\"sql\" FROM duckdb_views() ...)`). THE MISSING PRIMITIVE IS A "
    "QUERYABLE CATALOG: `SqlCatalog` here resolves table and column "
    "names for binding and exposes no relation a query can select FROM, "
    "so there is nothing for these bodies to read. ⚠ Four of these — "
    "current_database, current_schema, current_schemas, current_query — "
    "are the ONLY names in v1.5.3 that are BOTH a scalar and a macro."
)

comptime _R_AGGMACRO: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 aggregate MACRO — "
    "an AGGREGATE with a scalar wrapped around it (measured bodies: "
    "`geomean(x)` is `exp(avg(ln(x)))`, `wavg(v,w)` is a SUM ratio). "
    "Every primitive it needs is already served here (avg, sum, exp, "
    "ln, CASE, BIN_MUL, BIN_DIV, IS NOT NULL). ⚠⚠ THE SHAPE IS NOT THE "
    "BLOCKER: an aggregate plus a post-aggregate scalar over it is "
    "SERVED. "
    "`_extract_and_bind_post_agg` recurses into call arguments for "
    "`FNK_MATH_FN2` (the `pow(corr(v1,v2),2)` shape), `FNK_MATH_FN` and "
    "`FNK_UNARY_NUM`, so "
    "`exp(avg(ln(v)))` — `geomean`'s PUBLISHED body, spelled by hand — "
    "BINDS. ⚠ IT DOES NOT YET EXECUTE, and the wall it hits is a "
    "THIRD one, measured: `materialize_subplan: "
    "computed PROJECT over a breaker carries an output expr outside the "
    "monolith-free evaluator's envelope`. ⛔ THE GAP IS PER **OP**, NOT "
    "PER FAMILY, AND THE ONE-QUERY VERSION OF THE MEASUREMENT SAID "
    "OTHERWISE: `sqrt(avg(v))` over the same fixture ANSWERS "
    "(2.6457513110645907 / 3.6055512754639891, the DuckDB values), "
    "`exp(avg(v))` does not, and `abs(sum(v) - 100.0)` answers 79 and "
    "61 on the `EXPR_UNARY_OP` twin. "
    "`komira_dispatch_project/lower_untyped_expr.mojo:_translate_node`'s "
    "EXPR_MATH_FN arm admits FIVE ops — MATH_SQRT, MATH_SIN, MATH_COS, "
    "MATH_ASIN, MATH_RADIANS — of the 24 this table lowers, and widening "
    "it is a ONE-place edit (that arm has no mirror elsewhere). "
    "TWO BLOCKERS REMAIN, and they are "
    "independent. (1) THE EVALUATOR: `MATH_EXP` (and `MATH_LN`, for the "
    "inner term) in that five-op set. (2) THE AGGREGATE "
    "CLASSIFICATION, ONE LAYER UP: `_bind_aggregate` routes a SELECT "
    "item by `SqlExpr.is_aggregate()` / `.contains_aggregate()`, both "
    "of which read `sql_call_is_aggregate` in `sql_ast.mojo` — a set "
    "this table cannot reach and which does not name `geomean`, so "
    "`SELECT k, geomean(v) ... GROUP BY k` is refused before any "
    "lowering runs. ⚠ IT IS REFUSED WITH **THIS** REASON, not the "
    "generic GROUP-BY sentence, which would be FALSE about the query — "
    "no edit to a GROUP BY clause can help a name that resolves to "
    "nothing. `_bind_aggregate`'s non-column arm binds the item as a "
    "scalar first, so a name this table refuses states its own reason in "
    "the grouped position too. Binding these four means teaching the AST "
    "that "
    "a call can CONTAIN an aggregate without BEING one, which is a "
    "third classification that grammar does not yet have. ⛔⛔ "
    "AND THE OBVIOUS TRANSCRIPTION OF `wavg` IS WRONG: DuckDB ZEROES "
    "THE WEIGHT WHEN THE VALUE IS NULL (`sum(CASE WHEN value IS NOT "
    "NULL THEN weight ELSE 0 END)`). Measured over a grouped column, "
    "rows ('b',9,3),('b',3,NULL),('b',NULL,5): DuckDB answers 9 and the "
    "naive `sum(x*w)/sum(w)` answers 3.375. On any fixture with no "
    "NULLs the two forms are byte-identical, so a test written without "
    "the `nulls` variant cannot see it."
)

comptime _R_JSONMAP: String = (
    "SQL not supported: this name AGGREGATES rows into one JSON cell, "
    "or asks a MAP-typed cell a membership question, on DuckDB v1.5.3. "
    "⚠ THE MISSING PRIMITIVE IS NOT 'THE SQL DOOR' — SQL reaches "
    "`EXPR_JSON_EXTRACT`, which four `json_extract*` rows in this table "
    "lower to. What each of these six still needs is something "
    "else. (a) `json_group_array` / `json_group_object` / "
    "`json_group_structure` are macros whose PUBLISHED BODIES FOLD "
    "ROWS — `string_agg(...)` in the first two, "
    "`json_structure(json_group_array(x)) -> 0` in the third — so no "
    "SCALAR row can express any of them; they need a JSON-BUILDING "
    "ACCUMULATOR and nothing under `unified/agg/storage/` builds a "
    "JSON cell. ⚠ THEIR `duckdb_functions().function_type` READS "
    "'macro', NOT 'aggregate' — the aggregate is INSIDE the body — "
    "which is exactly why a census filtered on `function_type` files "
    "them in the SCALAR set this table answers. (b) "
    "`map_contains_entry` / `map_contains_value` are macros over "
    "`contains(map_entries(m), struct_pack(...))` and "
    "`contains(map_values(m), v)`, so each needs THREE absent things: a "
    "MAP-TYPED COLUMN OPERAND (the gap `_R_NESTEDDOOR` measures), a "
    "LIST CONSTRUCTOR for `map_entries`/`map_values` (`_R_LISTCTOR`) "
    "and list membership (`_R_LISTCELL`). `EXPR_MAP_GET` answers 'what "
    "is at this key', never 'does this value occur anywhere', so it is "
    "the wrong node for either even after all three land."
)

comptime _R_INTERVAL: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 MACRO over the "
    "INTERVAL type (measured bodies: `date_add(date, interval)` is "
    "`(date + \"interval\")`, `ago(i)` is `(current_timestamp - CAST(i AS "
    "INTERVAL))`). THE MISSING PRIMITIVE IS AN INTERVAL OPERAND: this "
    "engine has no INTERVAL literal reachable from SQL and no "
    "date+interval arm, so there is no second operand to add. ⚠ NOT the "
    "same as `date_diff`/`date_sub`, whose output is an INT64 DAY COUNT and "
    "which read no interval at all. ⚠ THOSE TWO DO MORE THAN "
    "'constant-FOLD two DATE literals' — they fold two literals, and over "
    "columns they lower to `CAST(b AS BIGINT) - CAST(a AS BIGINT)`. "
    "Either way the OUTPUT is an integer, "
    "which is why neither of them unblocks this family."
)

comptime _R_ROUNDN: String = (
    "SQL not supported: `round_even`/`roundbankers` are DuckDB v1.5.3 "
    "MACROs and THREE separate things block them, of which arity is the "
    "weakest. (1) Measured, they are 2-ARGUMENT-ONLY there — "
    "`round_even(2.5)` is a Binder Error naming `round_even(x, n)` — so "
    "there is no unary form to bind. (2) This engine's `UN_ROUND` is "
    "UNARY: `EXPR_UNARY_OP` cannot carry a digits operand, so `round(x, "
    "n)` is inexpressible whatever the arity check says. (3) The "
    "published body needs `%` (`(abs(x) * power(10, n+1)) % 10 = 5`); "
    "`BIN_MOD` has a `compiler_eval_column` projection arm, so this "
    "one is NOT A BLOCKER and is recorded as discharged rather than "
    "omitted — (1) and (2) are what "
    "refuse this name, and widening the `round` row fixes neither."
)

comptime _R_TABLEFN: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 MACRO whose body "
    "is a TABLE function — it calls `unnest(...)` (measured: "
    "`regexp_split_to_table` is `unnest(string_split_regex(text, "
    "pattern))`). THE MISSING PRIMITIVE IS `unnest`: a scalar call here "
    "binds to one output column of one row per input row, and unnest "
    "produces MANY rows per input row, which is a plan node this engine "
    "does not have and not an expression at all."
)

comptime _R_BITS: String = (
    "SQL not supported: `md5_number_lower`/`md5_number_upper` are "
    "DuckDB v1.5.3 MACROs bodied over `md5_number` and the BIT type "
    "(measured: `CAST(CAST(CAST(CAST(md5_number(param) AS BIT(1)) AS "
    "VARCHAR)[:64] AS BIT(1)) AS ...)`). TWO MISSING PRIMITIVES: "
    "`md5_number`, whose output is a HUGEINT and this engine has no "
    "int128 column; and the BIT type with its string slicing."
)
"""⚠ THIS REASON DOES NOT NAME THE DIGEST KERNEL AS A BLOCKER, BECAUSE IT IS
NOT ONE. `md5` / `sha1` / `sha256` LOWER (`STRFN_MD5` / `STRFN_SHA1` /
`STRFN_SHA256`, kernels in `komira_column_kernels/digest_functions.mojo`), so a
sentence saying the engine has no MD5 kernel would tell a caller the engine
lacks something it executes. The refusal STANDS on the two primitives it names
— `md5_number` returns a HUGEINT and the BIT type is absent."""


comptime _R_INT128: String = (
    "SQL not supported: this engine has no int128 (HUGEINT/UHUGEINT) "
    "column type, and these names are DECLARED to return one on DuckDB "
    "v1.5.3 — `md5_number(VARCHAR) -> HUGEINT`, `factorial(INTEGER) -> "
    "HUGEINT` (measured: `typeof(factorial(21))` = 'HUGEINT' and "
    "factorial(21) = 51090942171709440000, which exceeds INT64). "
    "Narrowing the result to BIGINT would answer correctly on small "
    "inputs and silently overflow on the ones the wide type exists for."
)

comptime _R_CLOCK: String = (
    "SQL not supported: `pg_conf_load_time`/`pg_postmaster_start_time` "
    "are DuckDB v1.5.3 MACROs whose body is `current_timestamp` "
    "(measured). THE MISSING PRIMITIVE IS A TIMESTAMP LITERAL FROM THE "
    "CLOCK: this engine has no `current_timestamp` and "
    "`broadcast_scalar` cannot materialize a TIMESTAMP literal either — "
    "a `ScalarValue` TIMESTAMP is `_kind`-tagged with `dtype` left at "
    "its default, so it reaches the `else` tail and becomes an INT64 "
    "zero. ⚠ AND A CLOCK READ IS NOT A CONSTANT: folding one at bind "
    "time would make the plan cache key a lie."
)

comptime _R_PGCASE: String = (
    "SQL not supported: `format_pg_type`/`map_to_pg_oid` are DuckDB "
    "v1.5.3 MACROs whose body is a long CASE over a type NAME. "
    "⛔⛔ `format_pg_type`'s BLOCKER IS NOT A STRING-TYPED NULL, "
    "although 'its CASE has string arms and its ELSE is NULL' reads "
    "plausibly. `format_pg_type` HAS NO NULL IN IT. MEASURED "
    "v1.5.3: ONE overload, TWO parameters (`logical_type`, "
    "`type_name`), 14 arms, ELSE `lower(logical_type)`, and "
    "`regexp_matches(macro_definition,'NULL')` is FALSE — "
    "`format_pg_type('WIDGET','x')` answers the VARCHAR 'widget' off "
    "that ELSE and never NULL. THE TWO HALVES OF THIS PAIR ARE EASY TO "
    "SWAP: it is `map_to_pg_oid` whose ELSE is NULL (19 INTEGER "
    "arms; `map_to_pg_oid('nope')` -> NULL), and INTEGER arms ride the "
    "int64 null arm — so the string-NULL wall that keeps "
    "`dayname`/`monthname` unbound applies to NEITHER of these two. "
    "⭐ THE REAL BLOCKER FOR `format_pg_type` IS A STRING-LITERAL CASE "
    "ARM. Its THEN arms are string LITERALS ('float4', 'float8', ...) "
    "and this engine's Utf8 CASE evaluator states its offsets "
    "contract only for THEN arms that are column references, while "
    "every Utf8 CASE test of that evaluator drives string COLUMNS and "
    "not one literal. ⚠ THAT A STRING LITERAL FAILS "
    "THERE IS **NOT** ESTABLISHED — only that nothing has ever run one. "
    "The cheap experiment is a searched CASE with a string-literal "
    "THEN and a `lower(col)` ELSE, and it settles both names. Behind "
    "it sit two more unmeasured questions: string EQUALITY as a CASE "
    "condition (`upper(logical_type) = 'FLOAT'`), and a 14-arm "
    "two-parameter desugar where the largest CASE any `DSG_*` builds "
    "today is `nullif`'s ONE arm. Both names are PostgreSQL "
    "wire-protocol plumbing and worth nothing to an analytics caller, "
    "which is why neither is scheduled."
)

comptime _R_SLEEP: String = (
    "SQL not supported: `pg_sleep` is a DuckDB v1.5.3 MACRO bodied "
    "`sleep_ms(CAST(seconds * 1000 AS BIGINT))` (measured) — a "
    "SIDE-EFFECTING call, not a value. ⛔ REFUSED BY POLICY, NOT BLOCKED "
    "BY A MISSING PRIMITIVE: a scalar expression that sleeps would be "
    "evaluated once per ROW per BATCH by this engine's vectorized "
    "evaluator, so the same query would sleep a different length of "
    "time depending on batch size and parallelism. There is no correct "
    "answer to implement."
)

comptime _R_TYPEOF: String = (
    "SQL not supported: `pg_typeof` is a DuckDB v1.5.3 MACRO bodied "
    "`lower(typeof(expression))` (measured). The binder DOES know the "
    "operand's output type, so this could fold to a STRING literal with "
    "no kernel — what is missing is a faithful type-NAME table, and it "
    "is not a lookup. MEASURED v1.5.3: `pg_typeof(1.5::DECIMAL(6,5))` = "
    "'decimal(6,5)' WITH PRECISION AND SCALE, `pg_typeof(1)` = "
    "'integer' (not 'bigint'), `pg_typeof(1::TINYINT)` = 'tinyint', and "
    "`pg_typeof(NULL)` = '\"null\"' WITH THE QUOTES. Every integer width, "
    "every decimal (p,s) and the quoting are parity hazards a "
    "reconstruction gets wrong silently, and a wrong TYPE NAME is "
    "exactly the answer a caller cannot check."
)

comptime _R_SIZE: String = (
    "SQL not supported: `pg_size_pretty` is a DuckDB v1.5.3 MACRO "
    "bodied `format_bytes(bytes)` (measured). THE MISSING PRIMITIVE IS "
    "`format_bytes` — a numeric-to-VARCHAR formatter this engine does "
    "not have: no `STRFN_*` op formats a number, and the family's "
    "kernels all take a string operand. ⚠ THIS IS NOT ALSO 'the "
    "string-producing-projection wall' (a bare STRING literal "
    "projection declaring the wrong Arrow type): "
    "`expr_walk.walk_expr_field` reads `sv.is_string()`, so naming that "
    "here would make one live blocker look like two and send the next "
    "reader to the wrong file."
)


comptime _R_MATH2: String = (
    "SQL not supported: `nextafter` is a real DuckDB v1.5.3 SCALAR function — "
    "TWO overloads, `DOUBLE(DOUBLE, DOUBLE)` and `FLOAT(FLOAT, FLOAT)` — and "
    "THE MISSING PRIMITIVE IS A `MATH2_` OP. `EXPR_MATH_FN2` carries exactly "
    "TWO members on this engine\'s wire, `MATH2_ATAN2` (engine 0) and "
    "`MATH2_POW` (engine 1), pinned by `MATH_FN2_WIRE_MEMBERS = 2` in "
    "`plan_wire_vocabulary.mojo`, and neither computes a next-representable "
    "step. ⚠ THE COST IS WHY THIS IS A REFUSAL AND NOT A ONE-LINE ROW: a new "
    "`MATH2_` member reaches `scalar_math.eval_math_binary`, "
    "the wire vocabulary\'s member COUNT and its "
    "engine/wire MIN and MAX as well as its to_wire/from_wire pair, "
    "`plan.proto` + `plan_vocabulary.proto`, `expr.mojo`, "
    "`lower_untyped_expr`, `xl_scalar_numeric` and this table — a "
    "strictly wider surface than a `STRFN_` tag, and the wire codec REFUSES an "
    "op it does not carry rather than silently dropping it. ⚠ "
    "`compiler_eval_column` is NOT on that list: it reaches a "
    "`MATH2_` op ONLY through `eval_math_binary` and therefore needs no "
    "per-member edit at all. "
    "⛔ AND NO EXISTING OP IS NEAR ENOUGH TO BORROW, WHICH IS THE PART A "
    "NEAREST-MATCH FIX WOULD GET WRONG. MEASURED v1.5.3 through "
    "`printf(\'%.17g\')` (a bare `duckdb -csv` does not round-trip a double): "
    "`nextafter(1.0, 2.0)` = 1.0000000000000002 but `nextafter(1.0, 0.0)` = "
    "0.99999999999999989 — the two steps have DIFFERENT magnitudes because the "
    "binade changes below 1.0; `nextafter(0.0, 1.0)` = 4.9406564584124654e-324, "
    "the smallest SUBNORMAL and not an epsilon; and `nextafter(1.0, 1.0)` = 1.0, "
    "so equal operands are the IDENTITY and not a step. Every one of those is a "
    "property of the IEEE-754 bit pattern rather than of arithmetic over the "
    "operands, so any approximation would be wrong at exactly the call sites "
    "that ask for this function."
)


# =============================================================================
# ★★ THE SCALAR BACKLOG — 231 REFUSAL ROWS OVER 22 FAMILIES. THE SCALAR
#    COUNTERPART OF THE AGGREGATE REFUSALS BELOW.
# =============================================================================
#
# ⛔⛔ WHAT THIS BLOCK IS FOR. DuckDB v1.5.3's catalog holds 683 user-facing
# scalar/macro IDENTIFIERS, measured the same way as the aggregate tier.
# Without these rows this table names 259 of them, and the other 424 sit in
# NEITHER the numerator NOR the denominator of any coverage figure — a gap
# that is measured is better than an invisible one, but it is still not a
# decision. These 231 rows are decisions: each name is REFUSED BY NAME with
# the primitive that blocks it.
#
# ⇒ SCALAR COVERAGE, against that external denominator: these rows take NAMED
#   from 259/683 to 490/683.
#   ⛔ NOT SERVED. Nothing here binds and nothing here is claimed to. 231 names
#   move from INVISIBLE to MEASURED; 193 remain unnamed.
#
# ★ AND THE OTHER HALF OF THE PROBE, MEASURED AGAINST THIS ENGINE WITH EVERY
# ONE OF THESE 231 ROWS DELETED: `ok=0 bound=0 unknown_name=231
# wrong_family=0`. ⇒ **NOT ONE of the 231 is secretly served** — through an
# alias, a macro expansion or a generic kernel — which is the question worth
# asking first, because coverage we already have is worth more than a refusal
# row. (`duckdb_functions().alias_of` carries 656 alias edges and exactly ONE
# of the 424 aliases a name this table serves: `position -> instr`, and
# DuckDB's own grammar takes that spelling away. See `_R_POSITION`.)
#
# ★ EVERY ONE OF THE 231 IS PROBED IN DuckDB v1.5.3 BEFORE IT GETS A ROW, in
# the `SELECT <name>()` shape, with the error CLASS recorded — because a refusal
# row is a CLAIM THAT THE NAME IS REAL and a wrong one tells a caller the parity
# target serves something it does not. Of the 424: 388 answer `Binder Error`
# (the name resolves, the 0-ary call does not), 28 ANSWER outright as 0-ary
# calls, 7 give an `Invalid Input Error` naming their own minimum arity, and
# exactly ONE — `position` — gives a `Parser Error`, because DuckDB's grammar
# rewrites `position(...)` into `__internal_position_operator` and the callable
# spelling is `POSITION(x IN y)`. That one is `_R_POSITION` below and its reason
# says so; the other 423 are ordinary callable functions.
#
# ⛔⛔ THE ROWS BELOW ARE ALL LOWERCASE, AND A CATALOG COMPARISON MUST BE
# CASE-INSENSITIVE. Exactly TWO of the 683 scalar names are not lowercase —
# `formatReadableSize` and `formatReadableDecimalSize` — and this function's
# `name` argument is LOWER-FOLDED by the parser before it arrives. A row written
# in the catalog's camelCase spelling COMPILES, READS CORRECTLY and NEVER FIRES,
# while a comparison of row text to catalog text that is case-SENSITIVE counts
# it as covered: coverage reported over a surface nothing serves.
#
# ⭐⭐ THE ORDERING IS BY TRAFFIC AND THE LARGEST SINGLE FINDING IS STRUCTURAL:
# **135 of the 424 — 32% of the whole backlog — are `icu_collate_<locale>`**,
# one machine-generated entry point per ICU locale, every one
# `VARCHAR(VARCHAR)`. They are in the denominator only because the pinned build
# statically links the `icu` extension (`SELECT extension_name FROM
# duckdb_extensions() WHERE loaded` -> autocomplete, core_functions, icu, json,
# parquet, shell). They are ONE decision, not 135, and `_R_ICUCOLL` says so
# rather than pretending to 135 independent judgements.
#
# ⛔ THE VACUITY THIS BLOCK IS WRITTEN AGAINST: 231 ROWS SHARING ONE BOILERPLATE
# REASON. That would make the table 100% "named" and 0% informative, and it
# would let a catalog comparison report a surface as decided that nobody looked
# at. The 22 reasons below each name a DIFFERENT missing piece — a tag, a
# payload slot, an output TYPE that no tag can produce, a type the columnar
# layer has no array for — and each carries the measurement that establishes
# it. `test_sql_fn_table_refusal_rows.mojo` pins every row to its family's
# reason, so a row wired to a sibling family's reason goes RED.
# =============================================================================

comptime _R_ICUCOLL: String = (
    "SQL not supported: this name produces an ICU COLLATION SORT KEY — a "
    "byte string whose ORDER is the locale's collation order. MEASURED "
    "v1.5.3: `icu_collate_de('strasse')` returns the opaque blob "
    "4F514D2B4F4F330142700601C1D305, not text, and there are 135 of these, "
    "one per locale, all `VARCHAR(VARCHAR)` — a machine-generated family the "
    "`icu` extension registers in a loop (it is LOADED in the pinned build: "
    "`SELECT extension_name FROM duckdb_extensions() WHERE loaded`). "
    "`icu_sort_key(s, locale)` is the same function with the locale as an "
    "argument and `create_sort_key(ANY) -> BLOB` is its type-generic "
    "sibling. THE MISSING PRIMITIVE IS A UNICODE COLLATION ELEMENT TABLE: "
    "this engine's only ordering over strings is the BYTE order its "
    "comparison kernels apply, `EXPR_SORT_KEY` carries sort DIRECTION and "
    "null placement rather than a collation, and no `STRFN_*` op consults a "
    "locale. ⛔ MAPPING ANY OF THE 135 ONTO A BYTE-ORDER KEY WOULD BE WRONG "
    "FOR EVERY LOCALE AT ONCE and wrong invisibly — the keys would compare, "
    "just in the wrong order, which is the one defect a caller cannot see in "
    "a single value."
)

comptime _R_GRAPHEME: String = (
    "SQL not supported: this name counts or slices by GRAPHEME-CLUSTER BREAK "
    "— user-perceived characters, not codepoints. DuckDB v1.5.3 signatures: "
    "`length_grapheme(VARCHAR) -> BIGINT`, `left_grapheme`/`right_grapheme`/"
    "`substring_grapheme` all `VARCHAR`. THE MISSING PRIMITIVE IS THE UNICODE "
    "GRAPHEME BREAK TABLE: `STRFN_LENGTH` counts CODEPOINTS and `STRFN_STRLEN` "
    "counts BYTES, and neither is a cluster count — a combining mark, a "
    "regional-indicator pair or an emoji ZWJ sequence is several codepoints "
    "and ONE grapheme. ⛔ BINDING THESE ONTO THE CODEPOINT FAMILY WOULD AGREE "
    "WITH DuckDB ON EVERY ASCII FIXTURE and disagree on exactly the inputs the "
    "function exists for, which is why this table refuses all four "
    "by NAME."
)

comptime _R_UNORM: String = (
    "SQL not supported: `nfc_normalize` and `strip_accents` are DuckDB v1.5.3 "
    "`VARCHAR(VARCHAR)` scalars that rewrite text through a UNICODE "
    "NORMALIZATION TABLE — canonical composition for the first, canonical "
    "DEcomposition plus combining-mark removal for the second. THE MISSING "
    "PRIMITIVE IS THAT TABLE: the `STRFN_*` family carries case mapping "
    "(`STRFN_UPPER`/`STRFN_LOWER`) and byte/codepoint measurement, and nothing "
    "in `komira_column_kernels` holds canonical decomposition or combining-class "
    "data. ⚠ NOT the same wall as `_R_GRAPHEME`: that one needs the BREAK "
    "property, this one needs the DECOMPOSITION mapping. The two are separate "
    "Unicode data files and landing either buys nothing for the other."
)

comptime _R_FMTSTR: String = (
    "SQL not supported: `printf` and `format` are DuckDB v1.5.3 VARIADIC "
    "scalars — `VARCHAR(VARCHAR, ANY...)` — whose first argument is a "
    "FORMAT-STRING INTERPRETER program read at RUN time. THE MISSING "
    "PRIMITIVE IS ARGUMENT-TYPE DISPATCH DRIVEN BY DATA: `EXPR_STRING_FN_N` "
    "is the only variadic tag here and its arity, its operand types and its "
    "output type are all fixed PER OP at bind time "
    "(`expr_walk.walk_expr_field` chooses INT64 or Utf8 from "
    "`string_fn_n_returns_int` and has no third answer), whereas `printf`'s "
    "conversion of argument k is chosen by the k-th directive in a string "
    "that may itself be a column. ⚠ AND THE TWO ARE NOT ONE FUNCTION: "
    "`printf` takes C-style `%s`/`%d` while `format` takes Python-style `{}` "
    "— one row each, one shared blocker."
)

comptime _R_NUMFMT: String = (
    "SQL not supported: this name is a NUMBER-TO-TEXT FORMATTER, or its "
    "inverse. DuckDB v1.5.3: `format_bytes`/`formatReadableSize`/"
    "`formatReadableDecimalSize` are `VARCHAR(BIGINT)`, `bar` is "
    "`VARCHAR(DOUBLE, DOUBLE, DOUBLE[, DOUBLE])`, `to_base` is "
    "`VARCHAR(BIGINT, INTEGER[, INTEGER])` and `parse_formatted_bytes` is the "
    "inverse `UBIGINT(VARCHAR)`. THE MISSING PRIMITIVE IS A NUMERIC OPERAND "
    "ON A STRING-PRODUCING TAG: every `STRFN_*` and `STRFN_N_*` op takes a "
    "STRING operand, and the two tags that take numbers — `EXPR_MATH_FN` and "
    "`EXPR_MATH_FN2` — are typed FLOAT64 unconditionally by "
    "`expr_walk.walk_expr_field` ('every scalar math fn is FLOAT64 whatever "
    "its op'), so neither side of the boundary can express number-in / "
    "text-out. ⚠ `_R_SIZE` names `format_bytes` as `pg_size_pretty`'s "
    "blocker; THIS reason is what blocks `format_bytes` itself, and the two "
    "must not be merged — one is a macro over the other."
)

comptime _R_BINCODEC: String = (
    "SQL not supported: this name encodes to, or decodes from, a BLOB "
    "OPERAND. MEASURED v1.5.3: `base64`/`to_base64` are `VARCHAR(BLOB)`, "
    "`decode` is `VARCHAR(BLOB)`, and `from_base64`/`encode`/`unhex`/"
    "`from_hex`/`unbin`/`from_binary` all RETURN `BLOB`. THE MISSING "
    "PRIMITIVE IS THE BLOB LOGICAL TYPE AS AN EXPRESSION VALUE: no `EXPR_*` "
    "tag in `komira_plan_expr/expr.mojo` declares a BINARY output — "
    "`expr_walk.walk_expr_field` chooses between INT64 and Utf8 for the "
    "string families and has no binary answer — so a decoder has nowhere to "
    "put its result and an encoder has no operand to read. ⚠ THE ONE-WAY "
    "HALF IS ALREADY SERVED AND THAT IS WHY THIS IS NOT A KERNEL GAP: `hex` "
    "and `bin` LOWER here (`STRFN_HEX`, `STRFN_BIN`) because they are "
    "`VARCHAR(VARCHAR)` and never touch a BLOB. It is the RETURN type, not "
    "the algorithm, that refuses their inverses."
)


comptime _R_LIKEESC: String = (
    "SQL not supported: this name is LIKE with a caller-supplied ESCAPE "
    "CHARACTER — `like_escape`/`ilike_escape`/`not_like_escape`/"
    "`not_ilike_escape`, all `BOOLEAN(VARCHAR, VARCHAR, VARCHAR)` on DuckDB "
    "v1.5.3, the third argument being the escape. TWO MISSING PRIMITIVES, "
    "and the arity one is the weaker. (1) THE PAYLOAD HAS NO THIRD SLOT: "
    "`Expr.string_op(op, child, pattern)` builds `StringOpData` with exactly "
    "an op, a child and a pattern STRING, so there is nowhere to carry an "
    "escape character even if the matcher honoured one. (2) THE OP "
    "VOCABULARY HAS NO ILIKE AND NO NEGATION: `STR_*` has FOUR members — "
    "STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH, STR_LIKE — so "
    "case-insensitive matching and `NOT LIKE` are absent independently of "
    "the escape, and two of these four names need both."
)

comptime _R_PATHSPLIT: String = (
    "SQL not supported: this name is a FILESYSTEM-PATH SPLITTER — "
    "`parse_dirname`/`parse_dirpath`/`parse_filename` are `VARCHAR` and "
    "`parse_path` is `VARCHAR[]` on DuckDB v1.5.3, each taking an optional "
    "second argument naming the separator convention. TWO MISSING "
    "PRIMITIVES. (1) `parse_path` RETURNS A LIST and the only List-producing "
    "expression here is `REGEXP_SPLIT_TO_ARRAY`, which splits on a REGEX and "
    "carries no path semantics. (2) THE OTHER THREE NEED A SEPARATOR "
    "CONVENTION AS A BOUND ARGUMENT: the `STRFN_*` family is one op per "
    "fixed behaviour with no configuration operand, so 'system' vs "
    "'forward_slash' vs 'backslash' cannot be expressed — and picking one is "
    "what makes the answer silently wrong on the other platform's paths."
)

comptime _R_POSITION: String = (
    "SQL not supported: `position` is REAL on DuckDB v1.5.3 but it is NOT A "
    "CALL THERE — it is the POSITION(x IN y) GRAMMAR FORM. MEASURED: "
    "`position('b','abc')` is `Parser Error: syntax error at or near \",\"`, "
    "`position()` is `Parser Error: Wrong number of arguments to "
    "__internal_position_operator`, and `position('b' IN 'abc')` answers 2. "
    "It is the ONLY one of the 424 backlog names whose probe returned a "
    "PARSER error rather than a binder or catalog one. THE MISSING PRIMITIVE "
    "IS THE `IN`-FORM GRAMMAR, NOT A KERNEL: this engine already computes the "
    "same answer as `strpos('abc','b')` = 2 via `STRFNN_STRPOS`, and "
    "`duckdb_functions()` records `position` as `alias_of instr`, which this "
    "table also serves. ⛔ DO NOT 'FIX' THIS BY BINDING `position(a, b)` AS "
    "A TWO-ARGUMENT CALL — that spelling is a syntax error on the parity "
    "target, so serving it would invent a function DuckDB does not have. "
    "⭐ THE `IN` FORM IS SERVED: write `POSITION('b' IN s)`; "
    "this refusal is the COMMA / call spelling only."
)

comptime _R_WALLCLOCK: String = (
    "SQL not supported: this name is a WALL-CLOCK READ — `now`, `today`, "
    "`current_date`, `current_localtime`, `current_localtimestamp`, "
    "`get_current_time`, `get_current_timestamp` and `transaction_timestamp` "
    "are the 0-ary DuckDB v1.5.3 scalars that answered outright in the probe "
    "(`SELECT now()` -> a TIMESTAMP WITH TIME ZONE). THE MISSING PRIMITIVE "
    "IS THE ONE `_R_CLOCK` ALREADY NAMES, reached directly instead of "
    "through a pg-compat macro: `broadcast_scalar` cannot materialize a "
    "TIMESTAMP literal (a TIMESTAMP `ScalarValue` is `_kind`-tagged with "
    "`dtype` left at its default, so it falls to the else tail and becomes "
    "an INT64 zero), and there is no clock-reading expression at all. ⚠ AND "
    "A CLOCK READ IS NOT A CONSTANT: folding one at bind time would make the "
    "plan cache key a lie. ⚠ THE RETURN TYPES ALSO DIVERGE — DATE, TIME, "
    "TIMESTAMP, TIME WITH TIME ZONE and TIMESTAMP WITH TIME ZONE across "
    "these eight — so one shared 'current timestamp' kernel would be wrong "
    "for six of them."
)

comptime _R_TSFORMAT: String = (
    "SQL not supported: `strftime`, `strptime` and `try_strptime` carry a "
    "TEMPORAL FORMAT DIRECTIVE string — `strftime` renders a temporal value "
    "to VARCHAR and the other two PARSE a VARCHAR to TIMESTAMP on DuckDB "
    "v1.5.3. TWO MISSING PRIMITIVES, one per direction. (1) RENDER: no "
    "expression here converts a temporal column to text — `EXPR_EXTRACT` "
    "answers INT64 for field units and, for trunc units, carries the CHILD's "
    "own temporal type through unchanged, so there is no temporal-to-string "
    "route at all. (2) PARSE: a string-to-timestamp conversion needs a "
    "CALENDAR-FIELDS-TO-INSTANT step — the parsed year/month/day have to "
    "become a tick count — which is the SAME civil-calendar-to-days primitive "
    "`_R_TSMINT` measures absent for `make_date(y, m, d)`. ⚠ THE EPOCH-COUNT "
    "`make_timestamp` OVERLOADS DO NOT SERVE THIS: `make_timestamp(<n>)` labels a "
    "tick count that is ALREADY an instant, and a format directive never "
    "produces one — it produces fields. ⚠ `try_strptime` DIFFERS FROM "
    "`strptime` ONLY IN FAILURE "
    "(NULL instead of an error), so it cannot be served before its strict "
    "twin is."
)

comptime _R_TSMINT: String = (
    "SQL not supported: this name MINTS A TEMPORAL VALUE from non-temporal "
    "parts by CALENDAR ARITHMETIC or in a ZONE-AWARE type — `make_date(y, m, "
    "d)`, `make_time(h, m, s)`, the SIX-ARY `make_timestamp(y, m, d, h, mi, "
    "s)`, `make_timestamptz` and `to_timestamp(<epoch DOUBLE>)` on DuckDB "
    "v1.5.5. TWO MISSING PRIMITIVES, one per half. (1) CIVIL-CALENDAR-TO-DAYS "
    "— `make_date(y, m, d)` needs month lengths and leap years, and no "
    "`EXPR_*` tag or binder desugar computes it. (2) A ZONE-AWARE TEMPORAL "
    "VALUE — `make_timestamptz` and `to_timestamp` both return TIMESTAMP WITH "
    "TIME ZONE, which nothing in the `sql_bind_*` modules produces or consumes (the "
    "same wall `_R_TZFN` measures). "
    "⛔ THE RELABEL IS NOT A SERVING ROUTE FOR EITHER HALF, AND THAT IS WHY "
    "THEY STAY REFUSED WHILE THEIR EPOCH SIBLINGS ARE SERVED: `CAST(<an "
    "integer> AS DATE)` reinterprets whatever the integer is as a day count, "
    "which for `make_date(2026, 10, 4)` would answer a wrong date rather "
    "than raising. "
    "⭐ THIS ROW IS NARROW BY OVERLOAD, NOT BY NAME. It does not refuse "
    "`make_timestamp`/`make_timestamp_ms`/`make_timestamp_ns` on this "
    "calendar-arithmetic ground, because their ARITY-1 overloads carry NO "
    "calendar arithmetic at all. MEASURED "
    "v1.5.5: `make_timestamp(1)` is `1970-01-01 00:00:00.000001`, i.e. the "
    "argument is MICROSECONDS SINCE EPOCH and not a year (the catalog names "
    "that parameter `year`, which is a red herring). A tick count relabelled "
    "as the unit it is already in is exactly `EXPR_CAST`'s `INT64 -> "
    "TIMESTAMP_*` arm. Refusing them by NAME would decline three overloads "
    "for a missing primitive those overloads never need (ClickBench Q18 and "
    "Q42 call them). Those three lower through "
    "`DSG_MAKE_TS_US`/`_MS`/`_NS`; what is refused here is the half the "
    "measurement supports."
)

comptime _R_EPOCHCONV: String = (
    "SQL not supported: this name is an EPOCH-COUNT CONVERSION across the "
    "temporal boundary — `epoch(ts) -> DOUBLE`, `epoch_us`/`epoch_ns -> "
    "BIGINT`, and `epoch_ms` with TWO overloads on DuckDB v1.5.3 that point "
    "in OPPOSITE directions (`BIGINT(TIMESTAMP)` and `TIMESTAMP(BIGINT)`). "
    "THE MISSING PRIMITIVE IS A TEMPORAL-TO-NUMERIC UNIT CONVERSION: "
    "`EXPR_EXTRACT` reads CALENDAR FIELDS (year, month, day, hour, minute, "
    "second) and has no unit that answers 'the whole instant as a count "
    "since 1970' — which is why `epoch` and `julian` are also refused in the "
    "`date_part` SPECIFIER namespace by `sql_date_part_unit`, a DIFFERENT "
    "table and the same measured gap. ⭐ `epoch_ms`'s MINTING DIRECTION "
    "(`TIMESTAMP(BIGINT)`) IS NOT THE BLOCKER — it is byte-for-byte what "
    "`make_timestamp_ms` lowers to. "
    "⛔ THAT DOES NOT MAKE `epoch_ms` SERVABLE, AND THE REASON IS OVERLOAD "
    "RESOLUTION RATHER THAN A KERNEL: this table dispatches on the NAME and "
    "this one name means BOTH directions on v1.5.3, so a row would have to "
    "choose by the ARGUMENT's type, and the reading it would have to get right "
    "for the other direction — TIMESTAMP in, BIGINT out — is the "
    "unit-conversion this row measures absent. Serving half an overload set by "
    "name is how `<ts>` silently takes the `<bigint>` arm. "
    "⛔ AND THE `TIMESTAMP_* -> INT64` RELABEL ARM IN "
    "`compiler_eval_column`'s EXPR_CAST LADDER IS NOT A SERVING ROUTE FOR "
    "ANY OF THE FOUR, stated here because it looks like one: it is a "
    "RELABEL, so it hands back the column's STORED integer unchanged "
    "whatever unit the column is in. `CAST(ts AS BIGINT)` over a "
    "TIMESTAMP_US answers microseconds and over a TIMESTAMP_NS answers "
    "nanoseconds — the SAME expression, two answers 1000x apart, neither "
    "labelled — so it cannot even serve `epoch_us`, the one name whose "
    "output is microseconds. The conversion has to READ THE UNIT, and "
    "nothing in the ladder does. ⚠ THERE IS ALSO NO VERIFIED ORACLE ROW "
    "TO SERVE AGAINST: the scalar-function oracle carries "
    "REFUSEDFN rows for all four and no QUERY row for any of them, so a "
    "lowering added without one would be graded by nothing."
)

comptime _R_TZFN: String = (
    "SQL not supported: `timezone`, `timezone_hour` and `timezone_minute` "
    "read or apply a TIME-ZONE DATABASE. MEASURED v1.5.3: `timezone` has two "
    "overloads (`TIMESTAMP WITH TIME ZONE` and `BIGINT`) and the other two "
    "return BIGINT offsets. THE MISSING PRIMITIVE IS A ZONE-AWARE TEMPORAL "
    "VALUE THE SQL DOOR CAN REACH: nothing in the `sql_bind_*` modules produces or "
    "consumes a TIMESTAMP WITH TIME ZONE, and `expr_walk.walk_expr_field`'s "
    "only interaction with a timestamp's tz is to CARRY the child's field "
    "through `date_trunc` — a fix recorded there precisely because the bare "
    "3-arg `Field` ctor had DROPPED it. ⚠ ALL THREE ARE ALSO REFUSED AS "
    "`date_part` SPECIFIERS by `sql_date_part_unit`, which measured them as "
    "0 on a NAIVE timestamp: the same gap seen from the other namespace."
)

comptime _R_DATENAME: String = (
    "SQL not supported: `dayname` and `monthname` are `VARCHAR(DATE)` "
    "CALENDAR NAME LOOKUPs on DuckDB v1.5.3 — a temporal value in, a "
    "locale-independent English name out. THE MISSING PRIMITIVE IS A "
    "STRING-PRODUCING TEMPORAL EXPRESSION: `EXPR_EXTRACT` is the only tag "
    "that reads a temporal operand and `expr_walk.walk_expr_field` types it "
    "INT64 for every field unit, so the seven-element and twelve-element "
    "name tables have nowhere to be returned to. ⚠ THIS IS THE SAME WALL "
    "`_R_NULLC` NAMES IN PASSING ('the same wall that keeps "
    "dayname/monthname unbound') and this row is where it is measured rather "
    "than mentioned; it is NOT the string-LITERAL wall, which is fixed "
    "and must not be quoted here."
)

comptime _R_INTERVALCTOR: String = (
    "SQL not supported: this name has an INTERVAL-TYPED OUTPUT or operand — "
    "the fourteen `to_<unit>` constructors (`to_years` .. `to_microseconds`), "
    "`age`, `normalized_interval` and `time_bucket` on DuckDB v1.5.3. THE "
    "MISSING PRIMITIVE IS AN INTERVAL-PRODUCING EXPRESSION: "
    "`komira_arrow` DOES carry the three Arrow interval types "
    "(INTERVAL_YEAR_MONTH, INTERVAL_DAY_TIME, INTERVAL_MONTH_DAY_NANO) and "
    "`expr_walk` has an INTERVAL_MDN arm for interval +/- interval, so this "
    "is NOT a columnar gap — it is that no `EXPR_*` tag MINTS one from a "
    "number, and the `sql_bind_*` modules have no INTERVAL literal, so the SQL door "
    "cannot reach the arms that exist. VERIFIED: "
    "`Column` builds an INTERVAL_MDN column (the (int32 months, int32 days, "
    "int64 nanos) triple), "
    "`compiler_eval_column` adds and subtracts two of them, and "
    "`ScalarValue.interval_month_day_nano` constructs the literal — all "
    "live, all unreachable. ⛔ THREE THINGS ARE MISSING AND ONLY THE FIRST "
    "IS OBVIOUS: (1) `sql_ast` has no `SX_INTERVAL`, so the text cannot be "
    "said; (2) an interval LITERAL would still be SIX INT64 ZEROS — "
    "`broadcast_scalar` has no interval arm and `walk_expr_field` declares "
    "`ArrowType.NULL` for it, the matched-pair defect that DATE32 and "
    "TIMESTAMP are fixed out of and INTERVAL is NOT (the recipe is "
    "materializer arm first, then the declared type); and "
    "(3) these sixteen names take a NUMBER or a TIMESTAMP, not a literal, "
    "so even a literal would not serve them — `to_days(n)` over a column "
    "needs a kernel that builds the month/day/nano triple per row, and "
    "there is no `EXPR_*` tag that does. ⚠ DISTINCT FROM `_R_INTERVAL`, WHICH "
    "IS THE OTHER HALF: that reason is about macros needing an interval "
    "OPERAND to add to a date; these names are about the interval VALUE "
    "itself having no producer."
)

comptime _R_DATEMINT: String = (
    "SQL not supported: `last_day` and `julian` return a CALENDAR "
    "ARITHMETIC RESULT that is not a field of the input — `last_day(DATE) -> "
    "DATE` (the month's final day, needing month-length and leap-year "
    "arithmetic) and `julian(TIMESTAMP) -> DOUBLE` (a fractional Julian day "
    "number) on DuckDB v1.5.3. TWO DIFFERENT MISSING PRIMITIVES under one "
    "family because both are temporal arithmetic with no `EXTRACT_*` unit: "
    "`last_day` needs the temporal-MINTING route `_R_TSMINT` measures "
    "absent, and `julian` needs the whole-instant-as-a-number route "
    "`_R_EPOCHCONV` measures absent. ⚠ `julian` IS ALSO A `date_trunc` "
    "PERIOD IN THIS FILE — `sql_date_trunc_unit` maps it to "
    "EXTRACT_TRUNC_DAY — and that is a DIFFERENT NAMESPACE with a different "
    "meaning; the FUNCTION `julian(x)` has no row until this one."
)

comptime _R_BITFN: String = (
    "SQL not supported: this name operates on the BIT STRING TYPE or on a "
    "bitwise BINARY integer op. MEASURED v1.5.3: `bit_position(BIT,BIT) -> "
    "INTEGER`, `get_bit(BIT,INTEGER) -> INTEGER`, `set_bit(BIT,INTEGER,"
    "INTEGER) -> BIT`, `bitstring(VARCHAR,INTEGER) -> BIT` (measured: "
    "`bitstring('1010',8)` = `00001010`, typed BIT), and `xor` "
    "over TEN integer widths plus BIT — eleven overloads in all, and six of "
    "the ten are UNSIGNED. TWO MISSING PRIMITIVES. (1) THE "
    "BIT TYPE: this engine has no BIT array and no `EXPR_*` tag declaring "
    "one, which is the same wall `_R_BITS` names for the md5_number pair — "
    "`bit_position` / `get_bit` / `set_bit` / `bitstring` need it and NOTHING "
    "ELSE will do, since three of the four RETURN or CONSUME a BIT value. "
    "(2) NO BITWISE BINARY OP: `BIN_AND` (20) and `BIN_OR` (21) are annotated "
    "`# Logical` in `komira_plan_expr/expr.mojo` and operate on BOOL, and the "
    "arithmetic members stop at `BIN_MOD` (4) — so `xor` has no "
    "integer-bitwise node even where no BIT value is involved. "
    "⭐ `bit_count` IS NOT IN THIS FAMILY: it is the whole of what the two "
    "primitives above do NOT block — it is UNARY and its operand is an "
    "ordinary integer column, so it needs one `UN_*` member (`UN_BIT_COUNT` "
    "= 8) and one kernel, and it lowers. ⛔ DO NOT READ THAT AS 'THE BITWISE "
    "HALF IS CHEAP'. Closing "
    "(2) would serve exactly ONE more name here — `xor` — and **ZERO** "
    "aggregates: `bit_and` / `bit_or` / `bit_xor` are refused under "
    "`_R_AGGMONOID`, a different blocker in a different module. "
    "⛔ AND THE `BIN_*` SPACE IS FAIL-**OPEN** WHERE THE `UN_*` SPACE IS "
    "FAIL-SAFE, WHICH IS WHY `bit_count` IS A UNARY MEMBER. "
    "Many non-test modules read a `BIN_*` (`git grep -l BIN_ -- src`), and "
    "`komira_kernels/expr_interpreter._eval_binary` ends `return "
    "EvalScalar.null()` — so a member wired into the plan and missed by one "
    "of those ladders answers SQL NULL FOR EVERY ROW rather than refusing. "
    "That is the exact hazard `expr.mojo`'s `BIN_CONCAT` note records. Every "
    "reader of a `UN_*`, by contrast, is an ALLOWLIST, so an unknown member "
    "there is a column demote or a named raise. "
    "⚠ AND THREE MEASURED FACTS A `BIN_*` BITWISE IMPLEMENTATION MUST GET "
    "RIGHT, none of which is carried by the tag: `xor(12,10)` = 6 and "
    "PRESERVES the operand width (INTEGER in, INTEGER out — it is NOT "
    "promoted to BIGINT); `(-1)::BIGINT >> 1` = -1, i.e. the shift is "
    "ARITHMETIC and not logical; and six of `xor`'s ten integer overloads are "
    "UNSIGNED widths this engine has no column type for at all."
)

comptime _R_INTPAIR: String = (
    "SQL not supported: `gcd`, `lcm` and their long spellings "
    "`greatest_common_divisor`/`least_common_multiple` are "
    "INTEGER-PRESERVING BINARY NUMERIC functions — `BIGINT(BIGINT, BIGINT)` "
    "(and a HUGEINT overload) on DuckDB v1.5.3. THE MISSING PRIMITIVE IS A "
    "TWO-ARGUMENT NUMERIC TAG THAT KEEPS ITS OPERAND TYPE: `EXPR_MATH_FN2` "
    "is the only two-argument numeric tag and `expr_walk.walk_expr_field` "
    "types it FLOAT64 unconditionally ('every scalar math fn is FLOAT64 "
    "whatever its op'), while `EXPR_BINARY_OP`, which IS type-preserving, "
    "carries only ADD/SUB/MUL/DIV/MOD. ⛔ ROUTING THESE THROUGH FLOAT64 "
    "WOULD BE WRONG WHERE IT MATTERS MOST: gcd/lcm exist for exact integer "
    "arithmetic and a double cannot hold every BIGINT, so the answer would "
    "be right on small fixtures and silently wrong past 2^53."
)

comptime _R_NONDET: String = (
    "SQL not supported: `random()` and `setseed(DOUBLE)` are "
    "NON-DETERMINISTIC PER ROW by definition. ⛔ REFUSED BY POLICY AS WELL AS "
    "BY A MISSING PRIMITIVE, and the policy half is the one that matters: "
    "this engine's vectorized evaluator may run a projection expression once "
    "per BATCH, per MORSEL and on several cores, so a per-row random would "
    "produce a different column for the same query depending on batch size "
    "and parallelism — there is no correct answer to implement, the shape "
    "`_R_SLEEP` already refuses for `pg_sleep`. `setseed` additionally has "
    "NO VALUE: measured v1.5.3 its return type is the special \"NULL\" type "
    "and its whole purpose is a SIDE EFFECT on session state, which a pure "
    "scalar expression has no way to hold."
)

comptime _R_MATHGAP: String = (
    "SQL not supported: THE MISSING PRIMITIVE IS A UNARY MATH OP MEMBER — "
    "`lgamma` and `signbit` each need one this engine does not carry, and "
    "they fail differently. "
    "`lgamma(DOUBLE) -> DOUBLE` is shape-compatible with `EXPR_MATH_FN` — "
    "`MATH_GAMMA` (23) is already a member — so the only thing absent is the "
    "op itself, and adding one is the wide edit `_R_MATH2` enumerates for "
    "`nextafter` (the kernel, `compiler_eval_column`, the wire vocabulary's "
    "member COUNT and MIN/MAX, `lower_untyped_expr`). ⛔ `signbit` CANNOT "
    "USE THAT ROUTE AT ALL: it is "
    "`BOOLEAN(DOUBLE)` on DuckDB v1.5.3 and `expr_walk.walk_expr_field` "
    "types EVERY `EXPR_MATH_FN` node FLOAT64 whatever its op, so a new member "
    "would declare FLOAT64 over a boolean column — a declared-type / "
    "data-type divergence."
)


# =============================================================================
# ★★ THE AGGREGATE REFUSALS — ONE ROW PER DuckDB v1.5.3 AGGREGATE THIS ENGINE
#    DOES NOT SERVE
# =============================================================================
#
# ⛔ WHY THESE ROWS EXIST AT ALL, WHEN NONE OF THEM MAKES A QUERY WORK.
# Without a row, `SELECT g, arg_max(x, y) FROM t GROUP BY g` is answered with
# "SQL not supported: scalar function 'arg_max'" — the UNKNOWN-NAME error, the
# same sentence a typo gets. That is not merely a worse message: it makes the
# gap INVISIBLE. A name with no row appears in no table any tool reads, so no
# refusal test can fire on it and the shortfall is in neither the numerator
# nor the denominator of anything this repo reports. A silent gap is worse
# than a red one.
#
# ★ THE DENOMINATOR IS EXTERNAL AND IT IS RE-DERIVABLE. DuckDB v1.5.3 states
# its own aggregate vocabulary:
#
#     select count(distinct function_name) from duckdb_functions()
#     where function_type = 'aggregate';          -- 88, measured
#
# Each of the 88, bound through `plan_from_sql` in the grouped position, is
# one of three things:
#   * SERVED — it binds and executes;
#   * claimed by the PARSER as a ranking window function and refused with its
#     own message demanding `OVER (...)` — rank row_number dense_rank
#     rank_dense. They get NO row here: `sql_win_ranking_code` takes the name
#     before the call branch exists, so a row would be unreachable;
#   * REFUSED by a row below.
#
# ⚠ A REFUSAL ROW IS A CLAIM THAT THE NAME IS REAL, so every one of these rows
# comes out of `duckdb_functions()` and not out of a list somebody remembered.
# ⚠ AND A REFUSAL ROW MUST NOT SHADOW A UDF: `FNK_REFUSED` sets
# `lowers_to_a_node = False`, so all of them stay DECLARABLE as user UDFs and
# `_bind_scalar_call` resolves a declared UDF ahead of the refusal.
#
# THE REASONS ARE PER-FAMILY AND THE FAMILY IS THE MISSING PRIMITIVE, not the
# DuckDB documentation category — each naming which tag, which state or which
# vocabulary member is absent, with the measurement that establishes it.
# ⛔ NO COUNT IS WRITTEN HERE: a family leaves this block when its names are
# SERVED, so a number frozen in this banner is wrong the next time one is.
# Derive it — `git grep -c "^comptime _R_AGG" src/komira_sql/sql_fn_table.mojo`.
# Several are NOT the same size of gap, and saying so is the point:
# `_R_AGGMONOID`'s three names are blocked by an EXACTNESS property of the
# extended fold's F64 intern (not by a missing tag — its sibling names
# `bool_and` `bool_or` `product` are served by an existing tag), while
# `_R_AGGNESTED` and `_R_AGGSTRCAT` are blocked by the `PodState` compile-time
# gate.
# =============================================================================
# ⭐⭐ THERE IS NO BIVARIATE-REGRESSION REFUSAL. `covar_pop` `covar_samp` and
# the nine `regr_*` are SERVED: `AGG_CORR` is the two-child tag and
# `CorrelationState` carries `[n | mean_x | mean_y | C | Sx | Sy]`, the
# complete sufficient statistics for all eleven, so each name is one FINALIZE
# with no new accumulation, no new merge and no new parallel-stability proof.
# ⇒ Before believing a refusal reason's implied cost, re-read the state it
# would use.
comptime _R_AGGARGEXTREME: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 PAYLOAD-CARRYING EXTREMUM "
    "aggregate — it returns the value of ONE column at the row where ANOTHER "
    "column is extreme. THE MISSING PRIMITIVE IS THE ACCUMULATOR STATE: "
    "`AGG_MIN` / `AGG_MAX` reduce a SINGLE column and keep no companion value, "
    "so there is nothing to return the payload from; a two-column extremum "
    "needs a new `AGG_*` tag whose per-group state carries both the key and the "
    "payload. ⛔ IT IS NOT `max(x)` WITH A JOIN, AND SUBSTITUTING ONE IS WRONG "
    "ON TIES AND ON NULLS — that is precisely what the `_null` / `_nulls_last` "
    "spellings in this family exist to disambiguate. MEASURED v1.5.3 over "
    "(g,x,y) rows (0,1,2),(0,2,3),(0,6,5),(1,10,1),(1,20,4),(1,30,1): "
    "`arg_max(x, y)` = 6.0 / 20.0 per group while `max(x)` = 6.0 / 30.0 — the "
    "two DISAGREE on group 1, so a substitution would be silently wrong."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

# ⭐⭐ `any_value` `arbitrary` `first` `last` ARE SERVED, AND THEY ARE NOT ONE
# STATISTIC. MEASURED v1.5.3 over x = {NULL, 7.0, NULL, 9.0, NULL},
# `any_value(x)` = 7.0 while `arbitrary(x)` = `first(x)` = NULL — `any_value`
# is the first NON-NULL value, `first` / `arbitrary` the value AT the first
# ROW. That is why `AGG_ANY_VALUE` is a separate tag instead of an alias onto
# `AGG_FIRST`.
#
# They need no new column accumulator: the extended fold's per-group state
# carries a scalar and two flags, which is EXACTLY the state an arrival-order
# pick needs, so the three tags are three `elif`s in `_ext_fold_one_row`, three
# finalize arms and one state field.
comptime _R_AGGWINVALUE: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 VALUE-WINDOW function — "
    "it is defined over a window FRAME and an OFFSET, not over a group, so it "
    "cannot be called as an aggregate or a scalar. ⭐ `lag` / `lead` / "
    "`first_value` / `last_value` / `nth_value` ARE served WITH an OVER clause "
    "— write `lag(v, 1, 0) OVER (PARTITION BY g ORDER BY o)`; "
    "this refusal is the call WITHOUT one. So are the distribution windows "
    "`percent_rank()` / `cume_dist()` / `ntile(k)`: write "
    "`ntile(4) OVER (ORDER BY k)`. `fill` alone has no window form at this "
    "door at all: THE MISSING PRIMITIVE FOR IT IS A WINDOW VOCABULARY MEMBER "
    "— `SXWIN_*` in `komira_sql/sql_ast.mojo` has no interpolating member. "
    "⚠ THE `OVER (...)` SHAPE ITSELF IS SERVED — `rank() OVER (PARTITION BY g "
    "ORDER BY x)` and `sum(x) OVER (PARTITION BY g)` both bind and execute — "
    "so the gap is this FUNCTION, not the clause."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

comptime _R_AGGNESTED: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 aggregate whose OUTPUT IS "
    "A NESTED VALUE — a LIST, a MAP or a BITSTRING, one cell per group. TWO "
    "MISSING PRIMITIVES, and the second is a hard compile-time gate rather "
    "than a missing feature. (1) THE OUTPUT TYPE: every `AGG_*` tag here "
    "finalizes to a SCALAR Arrow type and the only List-producing expression "
    "in `komira_plan_expr/expr.mojo` is `REGEXP_SPLIT_TO_ARRAY`, which splits "
    "a string rather than accumulating one. (2) THE STATE: a user aggregate's "
    "`State` MUST conform to `PodState` (`komira_udf/agg_fn.mojo`) — a "
    "fixed-size POD whose fields are `PodScalar` or `InlineArray`, because "
    "`flush_partial_to_column` Arrow-columnar-dumps the raw state slab, so a "
    "`List` / `String` / `Set` field CORRUPTS MEMORY at parallel-merge time "
    "and is refused by the trait-conformance check. An unbounded accumulation "
    "therefore cannot be expressed as an `AggFn` at all; it needs a spilling "
    "accumulator this engine does not have. MEASURED v1.5.3: `array_agg(x)` = "
    "[1.0, 2.0, 6.0] / [10.0, 20.0, 30.0] per group over the fixture above."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

comptime _R_AGGSTRCAT: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 CONCATENATED-STRING "
    "aggregate — N rows folded into ONE varchar with a separator. THE MISSING "
    "PRIMITIVE IS AN UNBOUNDED-STATE ACCUMULATOR, and the wall is the same "
    "`PodState` gate the nested-output family hits: an `AggFn.State` may hold "
    "`PodScalar` fields and `InlineArray` only (`komira_udf/agg_fn.mojo`), "
    "because the partial-flush Arrow-columnar-dumps the raw slab — so a "
    "growing `String` field cannot be a per-group state. ⚠ THE PIECES THAT "
    "LOOK SUFFICIENT ARE NOT: `STRFNN_CONCAT` and `STRFNN_CONCAT_WS` are "
    "SCALAR row-wise ops that combine N COLUMNS of ONE row; folding N ROWS is "
    "an aggregate and there is no `AGG_*` tag for it. MEASURED v1.5.3: "
    "`string_agg(CAST(i AS VARCHAR), ',')` = '6,14,10' / '12,28,20' per group "
    "over the fixture above."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

# ⭐⭐ `var_pop` `stddev_pop` `sem` ARE SERVED, and the gap they closed was a
# VOCABULARY one, not a kernel one. `WelfordState` `[count | mean | m2]` and
# its Chan parallel merge are shared with `AGG_STDDEV_SAMP` and `AGG_VAR_SAMP`;
# each name is ONE FINALIZE. The difference is REAL rather than cosmetic —
# `var_samp(x)` = 7.0 / 100.0 per group against `var_pop(x)` =
# 4.666666666666667 / 66.66666666666667, so an alias would be a wrong answer
# rather than a missing one.
#
# ⛔⛔ `sem` IS `stddev_POP / sqrt(n)`, NOT `sqrt(M2 / (count - 1)) /
# sqrt(count)`. MEASURED v1.5.3 over `{1, 2, 3, 4, 10}`: `sem` =
# 1.4142135623730951, where the sample formula gives 1.5811388300841895 — a
# wrong answer on every group of size > 1 that passes every bind test.
# ⇒ A REFUSAL REASON IS READ AS A SPEC;
# a formula in one has to be MEASURED, not recalled.


comptime _R_AGGQUANTILE: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 PARAMETERISED QUANTILE. "
    "ONE MISSING PRIMITIVE, THE PARAMETER: `AGG_MEDIAN` (10) hardcodes "
    "p = 0.5 — it is the only order-statistic tag here and it takes no "
    "percentile argument. THE RETENTION IS NOT MISSING: the route every "
    "door's `median(x)` reaches, the extended fold's `_ext_median_inplace`, "
    "keeps EVERY value of a group and selects exactly at any group size "
    "(MEASURED at every user-facing door "
    "over groups of 189-389 values arriving largest first, and a "
    "route-witness mutation of each median body), as does the typed "
    "catalog's `MedianOp[dt]`. So the gap is the PARAMETER and its plumbing "
    "(a tag or tag argument, the wire, the binder, a q threaded to that "
    "finalize), not the state. (The 64-value `MedianState` reservoir still "
    "in the tree is reached by NO plan route.) A per-group state is held in "
    "memory; a group larger than "
    "memory is a separate, unsolved limit. ⚠ THE ORDINARY DEFAULT IS "
    "SERVED: `median(x)` binds and executes, exactly."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

comptime _R_AGGRETAIN: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 aggregate that needs THE "
    "WHOLE SAMPLE OR A PER-DISTINCT-VALUE TALLY, not a fixed-width summary. "
    "`mode` and `entropy` need one counter PER DISTINCT VALUE; `mad` (median "
    "absolute deviation) needs a second pass over every retained value. THE "
    "MISSING PRIMITIVE IS UNBOUNDED PER-GROUP STATE: an `AggFn.State` must be "
    "`PodState` — fixed-size POD, `InlineArray` at widest "
    "(`komira_udf/agg_fn.mojo`). ⚠ THAT IS A LIMIT OF THE `AggFn` DOOR, NOT "
    "OF THE ENGINE: `AGG_MEDIAN` already keeps EVERY value of a group, "
    "unbounded and exact (a `List` per group in the extended fold, the "
    "route every door reaches; `MedianState[dt]` in the typed catalog) — so the "
    "buffer these names need exists, and what is missing is their finalize "
    "and their tag. "
    "⚠ `AGG_COUNT_DISTINCT` (5) PROVES THE HASH SIDE EXISTS but it returns a "
    "CARDINALITY and keeps no per-value count, so it cannot be borrowed. "
    "MEASURED v1.5.3 over the fixture above: `mode(x)` = 1.0 / 10.0 per group."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

comptime _R_AGGSKETCH: String = (
    "SQL not supported: this name is a DuckDB v1.5.3 APPROXIMATE aggregate — "
    "its answer is defined BY ITS SKETCH STATE (HyperLogLog, t-digest, or a "
    "reservoir sample), not by a closed-form fold. THE MISSING PRIMITIVE IS "
    "THAT STATE AND ITS MERGE: no `AGG_*` tag in "
    "`komira_plan_expr/agg_expr.mojo` carries a sketch, and a sketch needs a "
    "merge that is exact over PARTIALS even though the result is approximate "
    "over rows. ⛔ AN EXACT SUBSTITUTE IS NOT A FIX: `approx_count_distinct` "
    "may not be answered with `AGG_COUNT_DISTINCT` (5) — a user who asked "
    "for the approximate one asked for its COST, and the exact one is the "
    "operator they were avoiding. `approx_top_k` additionally returns a LIST "
    "cell, which this engine has no aggregate output type for. MEASURED "
    "v1.5.3 over the fixture above: `approx_quantile(x, 0.5)` = 2.0 / 20.0 "
    "per group."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

# ⭐⭐ `count_star` `count_if` `countif` ARE SERVED. `count_star` costs only a
# name — a binder arm over `AGG_COUNT` with an empty child slot, no tag and no
# kernel.
#
# ⛔⛔ `count_if(b)` IS NOT `count(*) FILTER (WHERE b)`, AND ITS NO-FILTER
# LOOKALIKE `sum(CASE WHEN b THEN 1 ELSE 0 END)` IS NOT EITHER, although both
# are built from parts this engine lowers. MEASURED DuckDB v1.5.3 over a group
# whose every row is NULL:
#
#     count_if(b)                            NULL
#     count(*) FILTER (WHERE b)              0
#     sum(CASE WHEN b THEN 1 ELSE 0 END)     0
#
# BOTH lookalikes are wrong, in the same direction, on exactly that group. The
# one true equivalent is `sum(b::BIGINT)`, which carries the NULL-skip AND the
# empty-fold NULL. Together with `sem` above this makes it a class and not an
# incident: ⛔ A REFUSAL REASON IS READ AS A SPEC, so an unmeasured formula in
# one is worse than no row at all.

# ⭐⭐ `_R_AGGCOMPENSATED` HOLDS **ONE** NAME. `fsum` / `kahan_sum` /
# `sumkahan` / `favg` are SERVED — ONE Float64 register
# (`_ExtAggState.kahan_c`) and two finalizes, because the extended fold has NO
# per-worker COMBINE (a group is whole on one worker in original-row order),
# which is exactly the property an order-dependent compensated sum needs.
#
# ⛔⛔ `sum_no_overflow` IS NOT "a width-checked integer sum" THIS ENGINE
# CANNOT COMPUTE. MEASURED v1.5.3:
#
#     D select sum_no_overflow(i) from t group by g;
#     Binder Error: sum_no_overflow is for internal use only!
#
# It is IN `duckdb_functions()` — which is why the 88-name denominator counts
# it — and DuckDB REFUSES TO BIND IT from SQL at all. Its own catalog
# description says "Internal only." So there is no oracle answer to match: a
# served `sum_no_overflow` would be answering a query v1.5.3 declines, and the
# only honest verdict is a refusal that says why.

comptime _R_AGGCOMPENSATED: String = (
    "SQL not supported: `sum_no_overflow` is a DuckDB v1.5.3 INTERNAL-ONLY "
    "aggregate. ⛔⛔ THERE IS NO ORACLE ANSWER TO MATCH, WHICH IS A DIFFERENT "
    "KIND OF REFUSAL FROM EVERY OTHER ROW IN THIS TABLE. It appears in "
    "`duckdb_functions()` (so it is one of the 88 names the denominator "
    "counts) and v1.5.3 REFUSES TO BIND IT FROM SQL: `select "
    "sum_no_overflow(i) from t` answers `Binder Error: sum_no_overflow is for "
    "internal use only!`, and its own catalog description is \"Internal only. "
    "Calculates the sum value for all tuples in arg without overflow "
    "checks.\" Serving it would mean answering a query the oracle declines, "
    "so there is nothing to value-grade against and a passing parity test "
    "would be grading this engine against itself. ⚠ ITS FOUR COMPENSATED-SUM "
    "NEIGHBOURS ARE SERVED AND IT IS NOT A CAPABILITY GAP THAT SEPARATES "
    "THEM: `fsum` / `kahan_sum` / `sumkahan` / `favg` run on one "
    "Float64 compensation register. ⚠ AND IF THE INTERNAL GATE EVER LIFTS, THE "
    "SECOND WALL IS REAL AND IS THE ONE `bit_and` HITS: its signature is "
    "`(BIGINT) -> HUGEINT`, an EXACT integer sum wider than Float64, and the "
    "extended fold interns every input column to **Float64** "
    "(`_ExtColData.vals`, `komira_op_agg_row_hash/agg_extended_grouped.mojo`), "
    "exact only to 2^53. What is absent is an INT64/128 LANE in `_ExtColData`, "
    "not an `AGG_*` tag."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

# ⭐⭐ `skewness` `kurtosis` `kurtosis_pop` ARE SERVED, and they are three
# statistics rather than spellings of one — MEASURED v1.5.3 over
# {1, 2, 3, 4, 10}, `kurtosis` = 3.151999999999994 against `kurtosis_pop` =
# -0.21200000000000152. A small fixture cannot grade them: `kurtosis` is NULL
# on any group of fewer than four rows. `WelfordState` is `[count | mean | M2]`
# and has no M3 or M4 slot, so they need a wider state.
#
# ⛔⛔ BUT THEY DO NOT NEED A HIGHER-MOMENT PARALLEL MERGE, the blocker it is
# natural to assume (Chan's two-term combine does not extend to higher moments
# without its own correction terms). THE EXTENDED FOLD HAS NO MERGE. It
# partitions ROWS by group-key hash so every row of a group lands on ONE worker
# and is folded in ascending original-row order (`agg_extended_grouped.mojo`'s
# header states it; MEDIAN and the arrival-order picks depend on the same
# property). The family is TWO Float64 registers and three finalizes — no
# combine, no proof. ⇒ A REFUSAL REASON IS READ AS A SPEC, and a blocker named
# in one has to be RE-READ AGAINST THE CODE, not recalled.

comptime _R_AGGMONOID: String = (
    "SQL not supported: this name REDUCES A COLUMN OVER A MONOID this engine "
    "has no EXACT accumulator for — bitwise AND / OR / XOR over an integer "
    "column. ⭐⭐ THE MISSING PRIMITIVE IS NOT A TAG, AND SAYING SO IS THE "
    "WHOLE VALUE OF THIS ROW: the sibling monoid names `bool_and` "
    "`bool_or` `product` are SERVED by an existing tag, and the three bitwise "
    "ones are NOT, because "
    "they need something the other three do not. THE EXTENDED FOLD INTERNS "
    "EVERY INPUT COLUMN TO **Float64** (`_ExtColData.vals`, "
    "`komira_op_agg_row_hash/agg_extended_grouped.mojo`), and Float64 holds "
    "an exact integer only up to 2^53. A bitwise fold is EXACT BY DEFINITION — "
    "`bit_xor` of two values differing in bit 60 is a different answer, not a "
    "rounded one — so routing it through that intern would answer WRONGLY "
    "rather than approximately on any column with a value past 9007199254740992. "
    "What is absent is an INT64 LANE in `_ExtColData` (or a bitwise cell on "
    "`agg_node_exec`'s fixed-cell descriptor route), not an `AGG_*` tag. "
    "MEASURED v1.5.3 over the fixture above: `bit_and(i)` = 2 / 4, "
    "`bit_or(i)` = 14 / 28, `bit_xor(i)` = 2 / 4 per group; and over "
    "{-1, 0}: `bit_and` = 0, `bit_or` = -1, `bit_xor` = -1, so the fold is "
    "two's-complement over the full signed width and not over magnitudes."
    " ⛔ AND THE `register_scalar` REMEDY THE BINDER APPENDS BELOW CANNOT "
    "SERVE THIS NAME. `SqlCatalog` declares exactly ONE UDF door — "
    "`declare_udf[U: DeclaredScalarUdf]` (`komira_sql/sql_catalog.mojo`) — "
    "and a SCALAR UDF returns one value per ROW where an aggregate returns "
    "one per GROUP. There is no aggregate-UDF door on this surface, so for "
    "an AGGREGATE name the appended sentence names a remedy that cannot "
    "work; it is said here rather than left to be found by following it."
)

# =============================================================================
# ★★ THE COMPOSITE-TYPE AND SESSION-STATE BACKLOG.
#
# Without this block, 193 of the 683 catalog scalar names are absent from this
# table, and they are NOT a leftover tail: they are DuckDB v1.5.3's entire
# COMPOSITE-TYPE surface — LIST, ARRAY, STRUCT, MAP, JSON, UNION, VARIANT,
# ENUM, GEOMETRY, UUID — plus session state and a handful of singletons. The
# 27 reasons below are 7.15 names per reason; every one names a DIFFERENT
# missing primitive and every one carries the measurement that establishes it.
#
# ★ PROBED BEFORE CLASSIFIED, and the probe found something worth more than the
#   rows: `duckdb_functions().alias_of` records 47 alias edges among these 193
#   and NOT ONE of them lands on a name this table already serves — every edge
#   points at another member of the 193 (`array_contains`->`list_contains`,
#   `element_at`->`map_extract`, `list_pack`->`list_value`, ...). There is no
#   free coverage hiding in the aliases. Measured directly, with these rows
#   deleted the engine reports `ok=0 bound=0 unknown_name=193`.
#
# ⭐⭐ AND THE NESTED-READ NAMES ARE CHEAP TO SERVE RATHER THAN REFUSE — SAID
#   LOUDLY BECAUSE IT IS THE FINDING. They sit on FOUR EXPRESSION TAGS THAT
#   EXECUTE HERE (`EXPR_MAP_GET`, `EXPR_STRUCT_FIELD`, `EXPR_STRUCT_FIELD_IDX`,
#   `EXPR_JSON_EXTRACT` — 19 evaluator arms and 23 wire-codec references
#   between them, each with its own passing test). Most of them lower through
#   the `DSG_JSON_EXTRACT*` / `DSG_STRUCT_EXTRACT*` / `DSG_MAP_EXTRACT_VALUE`
#   rows; `_R_NESTEDDOOR` holds the two whose RETURN SHAPE no tag can produce.
#
# ⚠ AND THE LARGEST BLOCK IS NOT CHEAP: 82 of the 193 are the LIST/ARRAY
#   surface behind EIGHT missing primitives (subscript, constructor, element
#   search, set op, intra-cell ordering, lambda parameter, named-aggregate
#   reduction, fixed-width vector distance). The
#   ordering:
#   the SUBSCRIPT has an operand today (`regexp_split_to_array` already
#   produces a List<Utf8> column from SQL), the constructor does not.
# =============================================================================

comptime _R_JSONLEAFMODE: String = (
    "SQL not supported: `json_value(j, path)` is a THIRD JSON leaf mode "
    "on DuckDB v1.5.3 and `EXPR_JSON_EXTRACT` can express only TWO. "
    "MEASURED over `{\"a\":1,\"b\":\"hi\",\"c\":{\"d\":7},"
    "\"e\":[10,20],\"n\":null}`:\n"
    "            json_extract   json_extract_string   json_value\n"
    "  $.a          1                  1                 1\n"
    "  $.b         \"hi\"                hi               \"hi\"\n"
    "  $.c       {\"d\":7}            {\"d\":7}            NULL\n"
    "  $.e      [10,20]            [10,20]              NULL\n"
    "  $.n         null              SQL NULL          SQL NULL\n"
    "⇒ `json_value` agrees with `json_extract` on every SCALAR leaf "
    "(quotes kept: `$.b` is `\"hi\"`, not `hi`) and answers SQL NULL on "
    "an OBJECT or ARRAY leaf, where both served modes return the "
    "container's text. So it is neither of the two, and it is NOT "
    "`json_extract_string` with a different name. THE MISSING PRIMITIVE "
    "IS A THIRD LEAF MODE ON THE TAG: `JsonExtractData."
    "preserve_extension_metadata` is a `Bool`, which cannot carry three "
    "states, and it is the same `Bool` on the wire "
    "(`plan_wire_codec.mojo`) and in `Expr.json_extract_from_parts`. "
    "Widening it to an enum is a WIRE CHANGE plus a kernel arm that "
    "distinguishes a container leaf from a scalar one — "
    "`_extract_value_at` already branches on exactly that, so the "
    "kernel half is small, but the wire half is not this table's to "
    "make. ⛔ DO NOT ALIAS IT ONTO "
    "`json_extract`: the two disagree on `$.c` and `$.e`, which is a "
    "wrong answer under a right-looking name."
)

comptime _R_JSONMINIFY: String = (
    "SQL not supported: `json(x)` is a DuckDB v1.5.3 MACRO whose "
    "published body is literally `json_extract(x, '$')` — and this "
    "engine SERVES `json_extract`, "
    "so the blocker is NOT the function and NOT the door. "
    "IT IS THE `'$'` PATH ITSELF. MEASURED: "
    "`json('  {\"a\" :  1 }  ')` = `{\"a\":1}` and "
    "`json_extract('  {\"a\" :  1 }  ', '$')` = `{\"a\":1}` — DuckDB "
    "MINIFIES the whole document. `json_extract_kernel.extract_column`'s "
    "zero-segment arm returns `payload.copy()`, the bytes VERBATIM, so "
    "it would answer `  {\"a\" :  1 }  `. THE MISSING PRIMITIVE IS A "
    "JSON CANONICALISER: nothing under `komira_json` "
    "re-emits a parsed document (`json_writer.mojo` writes Arrow "
    "columns OUT as JSON, it does not round-trip one value's text). "
    "⚠ DuckDB ALSO VALIDATES here — `json('not json')` is an Invalid "
    "Input Error — where this kernel is LENIENT and nulls the row, so "
    "serving `json` would diverge twice. `_bind_json_extract` refuses "
    "the `'$'` path by name for the same measurement, which is what "
    "keeps the four served `json_extract*` rows honest."
)

comptime _R_NESTEDDOOR: String = (
    "SQL not supported: this name reads ONE VALUE OUT OF A MAP CELL on "
    "DuckDB v1.5.3 and answers it AS A LIST. ⚠⚠ THE BLOCKER IS NOT THE "
    "NESTED DOOR — read the next paragraph before citing this constant. "
    "⛔ 'there is no executable path for a nested column through this "
    "front door' IS FALSE, AND ONE ARM IS WHAT MAKES IT FALSE. "
    "`komira_dispatch_project/compute_project` is the ONLY project evaluator "
    "on the in-memory route; it dispatches a family to `_eval_column_expr` "
    "through an `_is_<family>_output` helper, and "
    "`_is_nested_extract_output` is the helper for "
    "`EXPR_STRUCT_FIELD` / `EXPR_STRUCT_FIELD_IDX` / `EXPR_MAP_GET` / "
    "`EXPR_JSON_EXTRACT`, which `_eval_column_expr` has armed, tested "
    "arms for. `struct_extract`, `struct_extract_at` and `map_extract_value` "
    "are SERVED through it — without it a decline is not even reported as "
    "itself: the caller falls through to the parquet-shape detector and the "
    "user gets `materialize_subplan: non-breaker child is not a "
    "parquet-collect shape ... nor a bare in-memory leaf`, an error about "
    "plan TOPOLOGY naming neither the function nor the missing arm. "
    "⚠ THE SERVED ROWS ARE IN-MEMORY ONLY, and that is a property of the "
    "other door rather than a narrowing of these: a parquet-side test "
    "asserts over the whole input domain that THE PARQUET SCAN'S TYPE MAP "
    "NEVER RETURNS A NESTED ARROW TYPE, and that "
    "`nested.reconstruct_{struct,list,map}_column` have zero non-test "
    "callers. A STRUCT column cannot come out of `read_parquet` at all, so a "
    "`struct_extract` over one fails at COLUMN RESOLUTION far upstream of "
    "the binder. "
    "⛔⛔ SO WHAT KEEPS THESE TWO REFUSED IS A DIFFERENT, NARROWER AND "
    "WHOLLY INDEPENDENT GAP — THE RETURN SHAPE. MEASURED v1.5.3: "
    "`map_extract(map(['a','b'],['x','y']),'a')` and its alias `element_at` "
    "(`duckdb_functions().alias_of` records the edge) = **['x']**, a "
    "one-element LIST typed `VARCHAR[]`, and on a MISS = **[]**, an EMPTY "
    "list — where `map_extract_value` of the same is the bare `'x'` and "
    "NULL. `EXPR_MAP_GET` is the bare-value shape, so routing these two "
    "through it answers a different VALUE and a different TYPE on the hit "
    "path AND the miss path. THE MISSING PRIMITIVE IS A LIST-CELL "
    "CONSTRUCTOR (`_R_LISTCTOR`) — nothing in `komira_plan_expr/expr.mojo` "
    "builds a list cell from N scalars, so not even the one-element hit "
    "case can be spelled, let alone the empty-list miss. ⇒ the list "
    "constructor is what moves these two, and NOTHING about the nested door "
    "blocks them."
)

comptime _R_LISTCELL: String = (
    "SQL not supported: this name INDEXES, SLICES OR GATHERS POSITIONS "
    "out of one LIST cell on DuckDB v1.5.3 "
    "(`list_extract([10,20,30],2)` = 20, `list_slice([1,2,3,4],2,3)` = "
    "[2, 3], `list_where([1,2,3],[true,false,true])` = [1, 3], "
    "`array_length([1,2,3])` = 3). THE MISSING PRIMITIVE IS A LIST CELL "
    "SUBSCRIPT: there is no `EXPR_*` member in "
    "`komira_plan_expr/expr.mojo` that takes a List operand and a "
    "position and returns the element — `EXPR_LIST_EXTRACT` does not "
    "exist (grep: zero hits in the whole tree) — and nothing reports a "
    "list cell's length either. ⚠ NOT THE SAME GAP AS `_R_SLICE`, which "
    "is about DuckDB MACROS whose published bodies happen to use "
    "`arr[2:]`; these are the NATIVE functions that macro layer is "
    "built on, so they would still refuse after every one of those "
    "macros was desugared."
)

comptime _R_LISTCTOR: String = (
    "SQL not supported: this name BUILDS A LIST CELL, or joins/reshapes "
    "two into one, on DuckDB v1.5.3 (measured: `list_value(1,2,3)` = "
    "[1, 2, 3] typed INTEGER[], `range(3)` = [0, 1, 2] and "
    "`generate_series(1,3)` = [1, 2, 3] IN SCALAR POSITION, "
    "`flatten([[1,2],[3]])` = [1, 2, 3], `list_zip([1,2],['a','b'])` = "
    "[(1, a), (2, b)], `equi_width_bins(0,10,2,false)` = [5, 10]). THE "
    "MISSING PRIMITIVE IS A LIST CELL CONSTRUCTOR: "
    "`REGEXP_SPLIT_TO_ARRAY` is the ONLY expression in "
    "`komira_plan_expr/expr.mojo` that produces a List column and it "
    "splits a string, so there is no way to build a list from N "
    "scalars, no way to concatenate two list cells and no way to "
    "flatten a nested one. ⚠ `range` and `generate_series` are "
    "DUAL-TIER on v1.5.3 (`function_type` is both 'scalar' and "
    "'table'); the TABLE spelling is blocked by the separate `unnest` "
    "gap `_R_TABLEFN` names, and the SCALAR spelling measured above is "
    "blocked HERE, so serving either one does not serve the other. "
    "⭐⭐ AND THE THING EVERYONE ASSUMES BLOCKS THIS FIRST — A RECURSIVE "
    "`Field` — MOSTLY DOES NOT. MEASURED against the pinned Mojo compiler, "
    "three spellings: "
    "(1) DIRECT recursion is REFUSED. `var children: List[Self]` inside "
    "`struct Field` fails to compile with `field 'children' has "
    "non-'Deinitable' type 'List[Field]'`, and the obvious escape — "
    "`List[OwnedPointer[Self]]` — fails with the IDENTICAL diagnostic, "
    "because the check is on the TYPE's conformance and not on its LAYOUT. "
    "(2) ⭐ BUT ONE INDIRECTION THROUGH A SECOND NAMED STRUCT COMPILES, RUNS, "
    "MOVES AND COPIES AT ARBITRARY DEPTH. A `struct ChildBag` declared FIRST "
    "and holding `List[Field]`, with `Field` holding a `ChildBag`, breaks the "
    "conformance cycle; a 3-level nest was built, traversed, moved and copied "
    "with correct values at every level. ⇒ THE FLAT ARENA IS NOT THE ONLY "
    "FALLBACK and should not be adopted by default; it also compiles, but it "
    "trades a one-struct forward declaration for index bookkeeping in three "
    "more parallel lists. "
    "(3) ⛔ AND FOR *THIS* REASON'S NAMES, NEITHER IS NEEDED AT ALL. "
    "`Field.list_of_string` (`schema.mojo`) is literally "
    "`Field(name, LIST, nullable)` + `add_child('item', STRING, ...)`, and "
    "the three flat child lists carry exactly `(name, type_id, nullable)` — "
    "everything a PRIMITIVE item type needs. So `Field.list_of(T)` for T in "
    "the primitive families is a sibling static method and NOT a type-system "
    "project; `list_value(1,2,3)` -> `INTEGER[]` needs no recursion. What "
    "genuinely needs (2) is a LIST whose item is itself nested or "
    "parameterised — LIST-of-LIST (`flatten`), LIST-of-STRUCT, and "
    "LIST-of-DECIMAL / LIST-of-TIMESTAMP-with-tz, whose (p,s) and `_tz` have "
    "no slot in the flat child lists at all. "
    "⚠ AND THE FLATTENING IS IN **THREE** PLACES, NOT TWO: `Field` "
    "(`_child_names` / `_child_types` / `_child_nullables`), `SchemaBuilder` "
    "and `Schema` (each re-flattening them AGAIN as `List[List[...]]`). Any "
    "widening has to move all three or `field_at` silently drops what "
    "`add_field` was given. "
    "⭐ THE SCHEMA HALF EXISTS, so "
    "do not rebuild it. `Field.list_of(name, item_type, nullable, "
    "item_nullable)` is in `komira_arrow/schema.mojo` beside "
    "`list_of_string`, which is a thin forward to it. NONE OF THESE 16 "
    "NAMES IS SERVED ON THAT ACCOUNT — the schema helper is not the "
    "blocker, and saying so is the point of this paragraph. "
    "⛔ AND IT CANNOT REFUSE, WHICH IS THE NON-OBVIOUS PART. `Field.list_of` "
    "is TOTAL and NON-RAISING, because the only place a list-producing "
    "expression's output Field is inferred is "
    "`expr_walk.walk_expr_field`, which carries its own capitalised "
    "hard constraint that it MUST NOT RAISE (`LogicalPlan.project` / "
    "`.aggregate` are non-raising constructors that synthesize "
    "`output_schema` through it). ⇒ the loss check is a SEPARATE, non-raising "
    "predicate `Field.list_item_type_is_lossless(item_type)`, and THE BINDER "
    "— not the walker — is the raising context that must gate on it and "
    "refuse by name. It is an ALLOW-LIST on purpose: as a deny-list every "
    "ArrowType added later would default to lossless and ship with its "
    "parameters silently dropped. It says NO to DECIMAL128/256 (p,s), every "
    "TIMESTAMP* (`_tz` — a tz-bearing and a naive item have the SAME type id, "
    "so this family is the one that looks safe and is not), DICTIONARY, "
    "UNION_*, FIXED_SIZE_BINARY and every nested item type. "
    "⭐ AND THE ARROW HALF EXISTS TOO: "
    "`ListArray.to_column` carries an arbitrary child `Column` "
    "and `ListArray.from_int_lists` builds LIST<Int64>, so "
    "nothing in the columnar layer blocks these names either. "
    "⇒ WHAT IS ACTUALLY LEFT IS EXACTLY ONE THING: an `EXPR_*` TAG. There is "
    "still no expression that takes N scalar operands and yields one list "
    "cell. The shape to copy is `EXPR_STRING_FN_N` (tag 26), which is "
    "already the N-ary carrier — `StringFnNData(op, List[Expr])`, i.e. the "
    "SAME one-indirection-through-a-named-struct that clause (2) above "
    "found for `Field`, already shipping in that tag. Budget it by that "
    "tag's footprint: the non-test files "
    "`git grep -l EXPR_STRING_FN_N -- src | grep -v /tests/` lists, of which the "
    "substantive ones are `expr.mojo` (payload + accessors), "
    "`plan_wire_codec`/`plan_wire_values` (serialization), "
    "`compiler_eval_column` (the evaluator), `expr_walk` (the output Field — "
    "this is where `Field.list_of` gets its caller) and "
    "`sql_bind_call`/`sql_fn_table`; the other ten are one-arm walkers. "
    "⛔ AND DO NOT FORGET THE ASYMMETRY THAT IS EASIEST TO MISS: a new "
    "tag ALSO needs an `_is_*_output` arm in "
    "`komira_dispatch_project/compute_project`, or it executes over PARQUET "
    "and raises over an IN-MEMORY table."
)

comptime _R_LISTSEARCH: String = (
    "SQL not supported: this name ASKS WHETHER A VALUE IS AMONG THE "
    "ELEMENTS OF ONE LIST CELL, or where it sits, on DuckDB v1.5.3 "
    "(`list_contains([1,2],2)` = true, `list_position([1,2],2)` = 2 "
    "typed INTEGER, `list_has_all([1,2,3],[1,3])` = true). THE MISSING "
    "PRIMITIVE IS A LIST ELEMENT SEARCH KERNEL: this engine compares "
    "two SCALARS per row (`EXPR_BINARY_OP`, `EXPR_COMPARE`) and has no "
    "expression whose left operand is a list CELL and whose loop runs "
    "over that cell's elements. ⛔ AND `IN (...)` IS NOT THE SAME "
    "OPERATION AND MUST NOT BE OFFERED AS ONE: `x IN (1,2,3)` tests one "
    "scalar against a bind-time literal SET fixed for the whole query, "
    "where `list_contains(l, x)` tests against a different set on EVERY "
    "ROW. Twelve names ride this one kernel, six of them `array_*` "
    "aliases DuckDB's own `alias_of` column points at the `list_*` "
    "spelling."
)

comptime _R_LISTSETOP: String = (
    "SQL not supported: this name performs a SET OPERATION over the "
    "elements INSIDE one list cell on DuckDB v1.5.3 "
    "(`list_distinct([1,1,2])` = [1, 2], `list_intersect([1,2],[2,3])` "
    "= [2], and `typeof(list_unique([1,1,2]))` is UBIGINT — a COUNT, "
    "not a list, which is the one member of this family whose name "
    "reads like the others and whose return type does not). THE MISSING "
    "PRIMITIVE IS A LIST SET OPERATION KERNEL: hashing and dedup exist "
    "in this engine only ACROSS ROWS (the aggregate and join hash "
    "tables), and there is no expression that builds a hash set from "
    "the elements of one cell. ⚠ `list_unique` ALSO needs the unsigned "
    "64-bit result type this engine does not have — a second, "
    "independent blocker, recorded so that landing the kernel alone "
    "does not read as landing the name."
)

comptime _R_LISTORDER: String = (
    "SQL not supported: this name SORTS the elements inside one list "
    "cell, or returns the permutation that would (`list_sort([3,1,2])` "
    "= [1, 2, 3], `list_grade_up([3,1,2])` = [2, 3, 1]), and every one "
    "of them takes OPTIONAL VARCHAR modifiers on v1.5.3 — "
    "`list_sort(l,'DESC','NULLS FIRST')` is a real three-argument "
    "overload. THE MISSING PRIMITIVE IS AN INTRA-CELL ORDERING KERNEL: "
    "this engine's only sort is the SORT PLAN NODE, which orders ROWS "
    "of a batch; nothing orders the values within one cell, and no "
    "expression carries a sort-direction or null-ordering modifier as "
    "an argument. ⚠ Reproducing the modifier vocabulary is the half "
    "that gets skipped — a kernel that sorts ascending with nulls last "
    "and ignores the two VARCHARs answers a question the caller did not "
    "ask, silently, which is worse than refusing."
)

comptime _R_LAMBDA: String = (
    "SQL not supported: this name takes a LAMBDA on DuckDB v1.5.3 — its "
    "catalog signature says so literally, `(ANY[], LAMBDA) -> ANY[]` — "
    "and is called `list_transform(l, x -> x * 2)`. THE MISSING "
    "PRIMITIVE IS A LAMBDA PARAMETER: `sql_parser.mojo` has no `->` "
    "lambda arm, `SqlExpr` has no variant that binds a parameter NAME "
    "to a per-element value, and `komira_plan_expr/expr.mojo` has no "
    "expression whose child is evaluated once per ELEMENT of a list "
    "cell under a fresh scope. ⛔ THIS IS A SCOPE-INTRODUCING GRAMMAR "
    "FORM, NOT A FUNCTION, so no row in this table can ever serve it on "
    "its own — `sql_scalar_fn_spec` is a pure function of a name and "
    "cannot see an argument that is a binding construct. The eleven "
    "names here are three operations (transform, filter, reduce) behind "
    "one grammar gap."
)

comptime _R_LISTREDUCE: String = (
    "SQL not supported: this name REDUCES ONE LIST CELL WITH AN "
    "AGGREGATE CHOSEN BY STRING at run time (measured: "
    "`list_aggregate([1,2,3],'sum')` = 6; the signature is `(ANY[], "
    "VARCHAR, ANY...) -> ANY`). THE MISSING PRIMITIVE IS A "
    "NAMED-AGGREGATE LIST REDUCTION: `EXPR_AGG_FN` aggregates ACROSS "
    "ROWS and its fold is chosen by an `AGG_*` TAG AT BIND TIME, so "
    "even with a list subscript there is nothing that folds the "
    "elements of one cell, and nothing that resolves an aggregate NAME "
    "out of a VARCHAR argument. ⚠ THESE FIVE ARE THE PRIMITIVE "
    "`_R_AGGR` NAMES AS MISSING, not more members of that family: "
    "`_R_AGGR` covers 31 DuckDB MACROS whose published bodies CALL "
    "`list_aggr`, and this row is `list_aggr` itself. Discharging those "
    "31 requires discharging these 5 first."
)

comptime _R_VECDIST: String = (
    "SQL not supported: this name is a VECTOR SIMILARITY KERNEL on "
    "DuckDB v1.5.3 (measured: "
    "`list_distance([1.0,2.0]::DOUBLE[2],[3.0,4.0]::DOUBLE[2])` = "
    "2.8284271247461903). TWO MISSING PRIMITIVES, and the second is the "
    "one that gets forgotten. (1) THE FIXED-WIDTH VECTOR DISTANCE "
    "KERNEL itself: no `EXPR_*` member reduces two list operands to one "
    "DOUBLE. (2) THE FIXED-SIZE ARRAY TYPE THE `array_*` HALF IS "
    "DECLARED OVER: their catalog signatures are `DOUBLE[ANY]` / "
    "`FLOAT[ANY]`, i.e. `ArrowType.FIXED_SIZE_LIST`, whose per-row "
    "element count is part of the TYPE — `typeof([1.0,2.0]::DOUBLE[2])` "
    "is 'DOUBLE[2]' and `typeof([1,2,3])` is 'INTEGER[]', two different "
    "types on v1.5.3. A kernel written for variable-length lists serves "
    "the eight `list_*` names and NOT the seven `array_*` ones, and "
    "`array_cross_product` is narrower still — `DOUBLE[3]` only."
)

comptime _R_MAPTYPE: String = (
    "SQL not supported: this name CONSTRUCTS OR INTERROGATES A MAP "
    "VALUE on DuckDB v1.5.3 (measured: `typeof(map([1],['a']))` = "
    "'MAP(INTEGER, VARCHAR)' printing as {1=a}, `switch(1, "
    "map([1,2],['a','b']))` = 'a', `typeof(cardinality(map([1],[2])))` "
    "= UBIGINT). THE MISSING PRIMITIVE IS THE MAP LOGICAL TYPE AS A SQL "
    "VALUE: `ArrowType.MAP` exists in this engine's type table and "
    "`EXPR_MAP_GET` can read one, but nothing CONSTRUCTS a map cell, "
    "nothing enumerates its keys or entries, and the SQL front door "
    "names no nested `ArrowType` at all. ⚠ `switch` IS NOT A CASE "
    "EXPRESSION despite the spelling — it is a MAP LOOKUP with a "
    "default, so widening this engine's CASE would not serve it; and "
    "`cardinality` needs the unsigned 64-bit result type as a second "
    "blocker."
)

comptime _R_STRUCTTYPE: String = (
    "SQL not supported: this name ASSEMBLES, EDITS OR ENUMERATES A "
    "STRUCT VALUE on DuckDB v1.5.3 (measured: "
    "`typeof(struct_pack(a:=1,b:='x'))` = 'STRUCT(a INTEGER, b "
    "VARCHAR)', `typeof(row(1,'x'))` = 'STRUCT(INTEGER, VARCHAR)' — "
    "POSITIONAL fields, an unnamed struct). THE MISSING PRIMITIVE IS "
    "STRUCT VALUE ASSEMBLY: `EXPR_STRUCT_FIELD` can READ a field out of "
    "a struct column, but no expression BUILDS a struct cell from N "
    "operands, adds a field to one, or returns its field names — and "
    "the field-name set is part of the OUTPUT TYPE, so building one "
    "changes the schema the binder must compute. ⛔ `row` ALSO COLLIDES "
    "WITH THE GRAMMAR: `sql_parser.mojo` already compares an identifier "
    "against 'row' for the window-frame clause `ROWS BETWEEN`, so "
    "serving `row(...)` as a call is a parser change and not only a "
    "table row."
)

comptime _R_JSONDOC: String = (
    "SQL not supported: this name ASKS A STRUCTURAL QUESTION OF A JSON "
    "DOCUMENT on DuckDB v1.5.3 — is it valid, what type is it, what are "
    "its keys, how long is the array, does this path exist (measured: "
    "`typeof(json_array_length('[1,2]'))` = UBIGINT). THE MISSING "
    "PRIMITIVE IS JSON DOCUMENT INTERROGATION AS AN EXPRESSION: "
    "`komira_json` holds a decoder, a structural index and "
    "`json_extract_kernel`, and `EXPR_JSON_EXTRACT` reaches exactly ONE "
    "of those — path extraction. Nothing reports a document's TYPE, its "
    "key set, its array length or its validity, and `from_json(x, "
    "'<schema>')` needs a SECOND thing this engine cannot express: a "
    "RETURN TYPE computed from a VARCHAR argument at bind time. ⚠ "
    "Distinct from `_R_JSONMAP`, which is about DuckDB macros bodied "
    "over `json_extract`; these are the native functions beside it."
)

comptime _R_JSONBUILD: String = (
    "SQL not supported: this name TURNS SQL VALUES INTO A JSON DOCUMENT "
    "on DuckDB v1.5.3 (measured: `typeof(to_json([1,2]))` = JSON, "
    "printing as [1,2]). THE MISSING PRIMITIVE IS A JSON SERIALISER "
    "REACHABLE FROM AN EXPRESSION: `komira_json/json_writer.mojo` "
    "writes JSON for the OUTPUT SINK — a whole result set to a file or "
    "a buffer — and there is no `EXPR_*` member that renders one VALUE "
    "per row into a JSON cell, nor a JSON logical type for such a cell "
    "to have. ⛔ AND THE VARIADIC ARGUMENT SHAPE IS A SECOND WALL: "
    "`json_object(ANY...)`, `json_array(ANY...)` and "
    "`row_to_json(ANY...)` take an unbounded, HETEROGENEOUSLY TYPED "
    "argument list, which no `FNK_*` lowering in this table can carry — "
    "every variadic row here (`concat`, `concat_ws`) is homogeneous in "
    "its operand type."
)

comptime _R_SQLSERDE: String = (
    "SQL not supported: this name CONVERTS BETWEEN SQL TEXT AND A JSON "
    "REPRESENTATION OF DuckDB'S OWN PARSE TREE (measured: "
    "`json_serialize_sql('select 1')` returns a 500-byte document with "
    "'SELECT_NODE', 'cte_map', 'aggregate_handling':'STANDARD_HANDLING' "
    "— DuckDB's internal node names). ⛔ REFUSED BY DEFINITION, NOT "
    "BLOCKED BY A MISSING PRIMITIVE THAT COULD BE BUILT: the return "
    "value IS DuckDB's parse-tree schema. This engine's plan IR "
    "(`komira_plan_wire/plan_wire_codec.mojo`) is a DIFFERENT tree with "
    "different node names, so any output here would either be a "
    "reimplementation of DuckDB's serializer — which the next DuckDB "
    "release changes — or a document with the right function name and "
    "the wrong contents. `json_deserialize_sql` is the same document in "
    "the other direction."
)

comptime _R_GEOM: String = (
    "SQL not supported: this name is part of DuckDB v1.5.3's SPATIAL "
    "surface and is declared over the GEOMETRY type "
    "(`st_astext(GEOMETRY) -> VARCHAR`, `st_geomfromwkb(BLOB) -> "
    "GEOMETRY`). THE MISSING PRIMITIVE IS THE GEOMETRY LOGICAL TYPE: "
    "this engine has no geometry column type, no WKB reader or writer, "
    "no coordinate reference system field and no spatial predicate. "
    "`ArrowType` in `komira_arrow/arrow_types.mojo` carries no "
    "geometry or extension-typed member that these could decode into. ⚠ "
    "THESE EIGHT ARE NOT THE WHOLE `st_*` SURFACE — they are the ones "
    "DuckDB v1.5.3's BASE catalog registers without loading the spatial "
    "extension, which is why they and not the several hundred others "
    "appear in this engine's parity denominator at all."
)

comptime _R_UUIDT: String = (
    "SQL not supported: this name GENERATES OR DECODES A UUID on DuckDB "
    "v1.5.3 (measured: `typeof(uuid())` = UUID, "
    "`typeof(uuid_extract_version(uuid()))` = UINTEGER). TWO MISSING "
    "PRIMITIVES. (1) THE UUID LOGICAL TYPE: `ArrowType` has no 16-byte "
    "fixed-width UUID member, so there is nothing for the generator to "
    "return or the extractor to read. (2) A CSPRNG SOURCE: "
    "`uuid`/`uuidv4`/`gen_random_uuid` are RANDOM, so the same "
    "objection that refuses `random` applies — a scalar expression "
    "evaluated once per row per batch by a vectorized evaluator has no "
    "defined number of draws, and folding one at bind time would make "
    "the plan cache key a lie. ⚠ `uuidv7` is NOT in class (2): it is "
    "time-ordered, so it needs the clock read `_R_CLOCK` names instead, "
    "and its sortability is the reason callers pick it."
)

comptime _R_TAGGED: String = (
    "SQL not supported: this name reads or builds a value whose RUNTIME "
    "TYPE VARIES ROW BY ROW on DuckDB v1.5.3 — a UNION or a VARIANT "
    "(measured: `typeof(union_value(a:=1))` = 'UNION(a INTEGER)', "
    "`union_tag(union_value(a:=1))` = 'a'). THE MISSING PRIMITIVE IS A "
    "PER-ROW TYPE TAG: every column in this engine has ONE `ArrowType` "
    "for the whole column, `expr_walk.walk_expr_field` computes exactly "
    "one output type per expression, and there is no discriminator "
    "buffer alongside the values. ⛔ AND THE SUBSTITUTION IS NOT "
    "AVAILABLE: a UNION is not a STRUCT with nulls — `union_tag` must "
    "report WHICH member is populated, which a struct of nullable "
    "fields cannot answer when a member's value is legitimately NULL. "
    "`variant_to_parquet_variant` additionally names a Parquet encoding "
    "this writer does not emit."
)

comptime _R_ENUMT: String = (
    "SQL not supported: this name interrogates an ENUM TYPE's value "
    "domain on DuckDB v1.5.3 (measured: "
    "`typeof(enum_range(NULL::ENUM('a','b')))` = 'VARCHAR[]' — the "
    "answer is a LIST of the declared labels, and the ARGUMENT is a "
    "value of the enum type whose declaration carries them). THE "
    "MISSING PRIMITIVE IS THE ENUM VALUE DOMAIN: this engine has "
    "`ArrowType.DICTIONARY` for dictionary-encoded storage, but a "
    "dictionary is a per-BATCH encoding whose value set can differ "
    "between batches, where an ENUM's label list is fixed by the TYPE "
    "and identical in every batch. There is no place in this engine's "
    "schema to record that list, so "
    "`enum_first`/`enum_last`/`enum_range` have nothing to read and "
    "`enum_code` has no ordinal to return. ⚠ Answering these off a "
    "batch's dictionary would give a DIFFERENT answer per batch for the "
    "same column."
)

comptime _R_TYPEVAL: String = (
    "SQL not supported: this name treats a TYPE as a VALUE on DuckDB "
    "v1.5.3 (measured: `typeof(get_type(1))` is the literal type "
    "'TYPE', printing as 'INTEGER'; `make_type('INTEGER')` returns a "
    "TYPE; `can_cast_implicitly(1::INTEGER, 1::BIGINT)` = true; "
    "`vector_type(1)` = 'CONSTANT_VECTOR'). THE MISSING PRIMITIVE IS A "
    "FIRST-CLASS TYPE VALUE: `ArrowType` here is comptime metadata the "
    "binder reasons WITH, not something an expression can return, and "
    "there is no implicit-cast lattice to query. ⛔ `typeof` IS NOT THE "
    "CHEAP ONE IT LOOKS LIKE, and `_R_TYPEOF` already carries the "
    "measurement: the answer must be DuckDB's own type NAME with every "
    "integer width and every decimal (p,s) reproduced, and a wrong type "
    "name is exactly the answer a caller cannot check. `alias` and "
    "`vector_type` additionally report BIND-TIME and EXECUTION-TIME "
    "facts about the expression rather than about its value."
)

comptime _R_SESSION: String = (
    "SQL not supported: this name reads STATE THAT IS NOT A FUNCTION OF "
    "THE INPUT ROWS on DuckDB v1.5.3 — the connection, the transaction, "
    "a sequence, a setting, a variable, the process environment or the "
    "build (measured: `version()` = 'v1.5.3', "
    "`typeof(current_transaction_id())` = UBIGINT). THE MISSING "
    "PRIMITIVE IS A PER-SESSION SERVER STATE OBJECT: `EngineContext` "
    "carries a `HardwareTopology` and nothing else a query can read — "
    "no connection id, no transaction, no settings map, no variable "
    "table, no sequence catalog — and `SqlCatalog` resolves table and "
    "column names only. ⛔ `getenv` IS REFUSED FOR A SECOND AND STRONGER "
    "REASON: this repo's standing rule says "
    "a binary's configuration is specified with FLAGS, and a SQL "
    "function that reads the deployment's environment would put that "
    "channel back, per row, past every flag declaration. ⚠ `version` is "
    "the one name here that is trivially IMPLEMENTABLE and still wrong "
    "to serve: answering it would return THIS engine's version under a "
    "name whose parity contract is DuckDB's."
)

comptime _R_SIDEEFFECT: String = (
    "SQL not supported: this name has an OBSERVABLE SIDE EFFECT instead "
    "of, or as well as, a value on DuckDB v1.5.3 — it raises, sleeps or "
    "writes to the log (measured: `error('boom')` is an Invalid Input "
    "Error carrying the caller's own string, and its declared return "
    "type is the special \"NULL\" type; `sleep_ms(BIGINT) -> "
    "\"NULL\"`). ⛔ REFUSED BY POLICY, NOT BLOCKED BY A MISSING "
    "PRIMITIVE: this engine's evaluator is VECTORIZED and its batch "
    "size, morsel split and degree of parallelism are not part of the "
    "query, so the NUMBER OF TIMES a scalar expression runs is not "
    "defined by the SQL text. A function whose whole meaning is how "
    "many times it fired therefore has no correct answer to implement — "
    "the same argument `_R_SLEEP` makes for `pg_sleep`, stated here for "
    "the primitive `sleep_ms` that macro is bodied over."
)

comptime _R_DUCKINTERNAL: String = (
    "SQL not supported: this name's ANSWER IS A DESCRIPTION OF DuckDB'S "
    "OWN INTERNAL STATE, not a fact about the data (measured: "
    "`stats(1)` = '[Min: 1, Max: 1][Has Null: false, Has No Null: "
    "true][Approx Unique: 1]' — that optimizer's statistics object "
    "rendered as text; `parse_duckdb_log_message` parses DuckDB's own "
    "log format; `is_histogram_other_bin` tests for the sentinel "
    "DuckDB's `histogram` aggregate uses for its overflow bucket). ⛔ "
    "REFUSED BY DEFINITION: there is no MISSING PRIMITIVE whose arrival "
    "would make these answerable, because a faithful answer would have "
    "to describe a DIFFERENT engine's internals. Producing this "
    "engine's statistics under the same name would be a silent "
    "divergence in the direction callers cannot check — the string "
    "parses, the numbers are from the wrong optimizer."
)

comptime _R_AGGSTATE: String = (
    "SQL not supported: `combine` and `finalize` operate on DuckDB "
    "v1.5.3's AGGREGATE_STATE type — their catalog signatures say so "
    "literally, `(AGGREGATE_STATE<?>, ANY) -> AGGREGATE_STATE<?>` and "
    "`(AGGREGATE_STATE<?>) -> INVALID` — i.e. a PARTIAL AGGREGATE "
    "handed around as a value. THE MISSING PRIMITIVE IS AN "
    "AGGREGATE_STATE VALUE: this engine's accumulators live inside the "
    "aggregate operator (`komira_plan_expr/agg_expr.mojo`, thirteen "
    "`AGG_*` tags), are never materialized into a column and have no "
    "wire encoding, so there is nothing for a scalar expression to "
    "receive or return. ⚠ THE EXCHANGE THIS ENABLES IS REAL AND "
    "SEPARATE: shipping partial states between nodes is how distributed "
    "aggregation works, and it is a plan-level project, not a "
    "scalar-function row."
)

comptime _R_UKEY: String = (
    "SQL not supported: this name returns a value DECLARED UBIGINT on "
    "DuckDB v1.5.3 (measured: `typeof(hash('a'))` = UBIGINT; "
    "`timetz_byte_comparable('12:00:00+00'::TIMETZ)` = "
    "1691126595584057599, an order-preserving encoding of a TIMETZ). "
    "TWO MISSING PRIMITIVES. (1) AN UNSIGNED 64-BIT KEY TYPE: "
    "`ArrowType` has unsigned members but no column in this SQL front "
    "door is ever built as one, and narrowing to INT64 would make half "
    "the hash space come back NEGATIVE — values that compare and sort "
    "wrongly against DuckDB's. (2) THE FUNCTION ITSELF: `hash` must "
    "reproduce DuckDB's murmur-derived finalizer BIT FOR BIT to be "
    "worth anything (callers use it for bucketing across systems), and "
    "`timetz_byte_comparable` needs the TIMETZ type this engine does "
    "not have."
)

comptime _R_CODEPOINT: String = (
    "SQL not supported: `chr(INTEGER) -> VARCHAR` maps a Unicode "
    "codepoint to the one-character string holding it (measured v1.5.3: "
    "`chr(65)` = 'A'). THE MISSING PRIMITIVE IS A CODEPOINT-TO-TEXT "
    "ENCODER: this engine has both INVERSE directions already — "
    "`STRFN_ASCII` and `STRFN_UNICODE` read a codepoint OUT of a string "
    "— and no operation in the `STRFN_*` family goes the other way, "
    "because every member of it takes a string operand and this one "
    "takes an integer. ⚠ AND THE OUTPUT IS UTF-8 AND VARIABLE-WIDTH: "
    "`chr(233)` is the two-byte 'é', so the kernel must encode a "
    "codepoint rather than write a byte, and a byte-writing version "
    "would be correct on exactly the ASCII range the tests would be "
    "written over."
)

comptime _R_BLOBLEN: String = (
    "SQL not supported: `octet_length` on DuckDB v1.5.3 has exactly TWO "
    "overloads, `(BLOB) -> BIGINT` and `(BIT) -> BIGINT`, AND NO "
    "VARCHAR ONE — measured: `octet_length('abc')` is a Binder Error "
    "listing the candidates, while `octet_length('abc'::BLOB)` = 3. THE "
    "MISSING PRIMITIVE IS A BLOB COLUMN TYPE REACHABLE FROM SQL: this "
    "front door can produce no BLOB and no BIT value, so there is no "
    "operand of either declared type to measure. ⛔ AND THE PLAUSIBLE "
    "SHORTCUT IS WRONG: serving it over VARCHAR would answer a call "
    "DuckDB REFUSES, so a query that works here would fail on the "
    "parity target — a divergence in the direction that looks like "
    "extra capability. The byte length of a string is already served, "
    "spelled `strlen`."
)

comptime _R_SHORTCIRCUIT: String = (
    "SQL not supported: `constant_or_null(a, b, ...)` returns `a` "
    "unless ANY later argument is NULL, in which case it returns NULL "
    "(measured v1.5.3: `constant_or_null(5, 1)` = 5, "
    "`constant_or_null(5, NULL)` = NULL). THE MISSING PRIMITIVE IS "
    "SHORT-CIRCUIT NULL PROPAGATION AS AN EXPRESSION: this engine "
    "propagates nulls per-KERNEL, each arm handling its own validity "
    "bitmap, and has no expression that takes a VARIADIC list of "
    "operands evaluated only for their NULLNESS and discards their "
    "values. ⚠ THE `CASE WHEN b IS NULL THEN NULL ELSE a END` REWRITE "
    "IS NOT EQUIVALENT AT ARITY > 2: the real function ORs the "
    "null-ness of every trailing argument, so the desugar needs a fold "
    "whose length is the call's arity — which this table's fixed-arity "
    "`DSG_*` lowerings cannot express."
)

def sql_scalar_fn_spec(name: String) -> SqlFnSpec:
    """NAMESPACE (1) — the SQL scalar FUNCTION table. `name` is lower-folded by
    the parser before it gets here.

    ★ ONE ROW PER FUNCTION, ALIASES ON THE ROW THEY ALIAS. Returns an
    `FNK_NONE` row for a name that is not one, which the binder turns into the
    unknown-function error.

    ⚠ EVERY ALIAS BELOW IS MEASURED AGAINST DuckDB v1.5.3's own
    `duckdb_functions()` AND EVALUATED, NOT GUESSED — `ucase('a')` = `A`,
    `len('abc')` = 3, `character_length('héllo')` = 5, and `prefix`/`suffix`
    really are `BOOLEAN(VARCHAR, VARCHAR)` synonyms of `starts_with`/`ends_with`.
    """
    # -- EXPR_STRING_FN: the one-argument string family ------------------------
    #
    # ⚠ ARITY IS REFUSED, NOT TRUNCATED, AND `trim` IS WHY. DuckDB's
    # `trim(s, chars)` is a DIFFERENT function with an explicit strip set;
    # widening this row to 1..2 would silently ignore the caller's `chars` and
    # answer a question they did not ask.
    #
    # ⛔ `strlen` IS NOT AN ALIAS OF `length`. `strlen('héllo')` = 6 (BYTES)
    # while `length('héllo')` = 5 (CHARACTERS). It IS a row — its own, on
    # `STRFN_STRLEN`, below — and it must never join THIS row.
    if name == "upper" or name == "ucase": return SqlFnSpec(FNK_STRING_FN, STRFN_UPPER, 1, 1)
    if name == "lower" or name == "lcase": return SqlFnSpec(FNK_STRING_FN, STRFN_LOWER, 1, 1)
    if name == "trim": return SqlFnSpec(FNK_STRING_FN, STRFN_TRIM, 1, 1)
    if name == "ltrim": return SqlFnSpec(FNK_STRING_FN, STRFN_LTRIM, 1, 1)
    if name == "rtrim": return SqlFnSpec(FNK_STRING_FN, STRFN_RTRIM, 1, 1)
    if name == "length" or name == "len" or name == "char_length" or name == "character_length": return SqlFnSpec(FNK_STRING_FN, STRFN_LENGTH, 1, 1)
    if name == "reverse": return SqlFnSpec(FNK_STRING_FN, STRFN_REVERSE, 1, 1)
    # -- the STRING -> INT bucket -----------------------------------------
    #
    # ⚠⚠ `strlen` IS SERVED, BUT NEVER AS `length`. `STRFN_STRLEN` counts
    # BYTES and `STRFN_LENGTH` counts CHARACTERS, so both names can be right
    # at the same time.
    # MEASURED v1.5.3: `strlen('héllo')` = 6, `length('héllo')` = 5.
    #
    # ⛔ `ascii` AND `unicode` ARE TWO ROWS, NOT AN ALIAS PAIR, AND THE EMPTY
    # STRING IS THE ONLY WITNESS. MEASURED: `ascii('')` = 0 while
    # `unicode('')` = `ord('')` = -1; on every non-empty input the two are the
    # same number. Aliasing them would be correct on every fixture that has no
    # empty string in it — the same shape of defect as binding `strlen` to a
    # character count. `ord` IS a true alias of `unicode` (both -1).
    #
    # ⛔ `octet_length` IS NOT A ROW AND IS NOT MISSING — AND IT IS NOT ABSENT
    # FROM DuckDB EITHER. The NAME resolves there; what it has no overload for
    # is VARCHAR. MEASURED v1.5.3: `octet_length('héllo')` is
    # `Binder Error: Could not choose a best candidate function ... Candidate
    # functions: octet_length(BIT) -> BIGINT, octet_length(BLOB) -> BIGINT`,
    # while `octet_length('abc'::BLOB)` = 3 and `octet_length(encode('héllo'))`
    # = 6 both answer. ⚠ A `Binder Error` (overload) and a `Catalog Error`
    # (absence — what `regexp_count` gives) are DIFFERENT findings, and this
    # one is the first. Offering a
    # VARCHAR `octet_length` would be a spelling the parity target rejects. `length_grapheme` is genuinely absent: it counts GRAPHEME
    # CLUSTERS, which needs a Unicode break table this engine does not carry,
    # and mapping it onto the codepoint count would be wrong for every
    # combining mark and every emoji ZWJ sequence.
    if name == "ascii": return SqlFnSpec(FNK_STRING_FN, STRFN_ASCII, 1, 1)
    if name == "unicode" or name == "ord": return SqlFnSpec(FNK_STRING_FN, STRFN_UNICODE, 1, 1)
    if name == "strlen": return SqlFnSpec(FNK_STRING_FN, STRFN_STRLEN, 1, 1)
    if name == "bit_length": return SqlFnSpec(FNK_STRING_FN, STRFN_BIT_LENGTH, 1, 1)

    # -- the BYTE-TRANSFORM bucket ---------------------------------------
    #
    # ⭐ THESE FIVE ARE **EXACT** AGAINST DuckDB ON NON-ASCII INPUT BY
    # CONSTRUCTION: they are defined on the UTF-8 BYTES in DuckDB TOO, so
    # there is no character mapping to get wrong. (`upper`/`lower` need a
    # Unicode case table for the same exactness, which
    # `komira_column_kernels/unicode_case.mojo` carries.) MEASURED v1.5.3:
    # `hex('é')` = 'C3A9',
    # `bin('é')` = '1100001110101001', `url_encode('é')` = '%C3%A9',
    # `regexp_escape('é.b')` = 'é\.b'.
    #
    # ⛔ `to_hex` IS AN ALIAS **ONLY OVER VARCHAR**. `to_hex('abc')` and
    # `hex('abc')` are both '616263' (measured), so the two names share this
    # row — but `to_hex(255)` = 'FF' while `hex('255')` = '323535', two
    # different functions under one name. The integer overloads of `hex`,
    # `to_hex` and `bin` are NOT bound here; an integer argument reaches the
    # STRING-column check in the eval arm and is refused BY NAME.
    #
    # ⛔ AND `bin` OVER AN INTEGER STRIPS LEADING ZEROS WHILE THIS ONE DOES
    # NOT. `bin(5)` = '101' there; `bin('abc')` = '011000010110001001100011' —
    # 24 digits for 3 bytes, the leading zero of `a` KEPT. A kernel written
    # against the integer intuition is wrong for every string.
    #
    # ⛔ `url_decode` HAS THREE MEASURED BEHAVIOURS THAT ARE EACH THE OPPOSITE
    # OF THE OBVIOUS GUESS: `+` IS NOT A SPACE (`url_decode('a+b')` = 'a+b' —
    # this is URI decoding, not form decoding); a MALFORMED escape is left
    # verbatim rather than raising (`'a%zz'`, `'a%2'`, `'100%'` all come back
    # unchanged); and an escape that decodes to INVALID UTF-8 RAISES
    # (`url_decode('%FF')`). All three are implemented.
    #
    # ⛔ `regexp_escape` IS A `STRFN_*` AND NOT A MEMBER OF THE `REGEXP_*`
    # FAMILY ABOVE. It compiles no pattern and reads no `RegexpData`; it is an
    # ordinary unary string transform named after the family its output feeds.
    # Its rule is "escape everything that is not `[A-Za-z0-9_]`", MEASURED by
    # running bytes 1..127 through v1.5.3 — a hand-written metacharacter list
    # is a strict subset and would leave `-`, `/`, `:` and space unescaped.
    #
    # ⛔⛔ AND IT CANNOT FEED `regexp_matches` HERE, WHICH IS THE ONE THING IT
    # EXISTS FOR. `regexp_matches(s, regexp_escape(s))` is REFUSED at bind —
    # `RegexpData.pattern` is a `String` and the NFA is compiled once per
    # BATCH, so a per-row pattern is an operation that tag cannot express. It
    # is still usable over a literal, and as an ordinary transform whose output
    # goes somewhere other than a pattern slot. MEASURED, not assumed: a
    # composing test that asserts the working form gets the refusal. Lifting
    # it means making the pattern an `Expr`; answering a
    # computed pattern with the literal it is not would be a wrong ANSWER.
    #
    # ⛔ `base64` / `to_base64` / `from_base64` / `unhex` / `unbin` ARE NOT
    # ROWS AND ARE NOT AN OVERSIGHT: all five are declared over **BLOB** in
    # v1.5.3 (`base64 :: VARCHAR <- [BLOB]`), a type this table's STRING-column
    # contract does not reach. `md5` / `sha1` / `sha256` DO have VARCHAR
    # overloads, and their three rows are just below. They are real digest
    # kernels, not a byte transform.
    if name == "hex" or name == "to_hex": return SqlFnSpec(FNK_STRING_FN, STRFN_HEX, 1, 1)
    # ⭐ `to_binary` IS A MEASURED ALIAS OF `bin`, NOT A GUESS. v1.5.3 registers
    # it with `alias_of = 'bin'` AND carries the same `VARCHAR -> VARCHAR`
    # overload: `to_binary('abc')` = `bin('abc')` = '011000010110001001100011'.
    # ⛔ Its SIBLING `from_binary`/`unbin` is NOT an alias of anything here —
    # it returns BLOB, a type this engine has no column for.
    if name == "bin" or name == "to_binary": return SqlFnSpec(FNK_STRING_FN, STRFN_BIN, 1, 1)
    if name == "url_encode": return SqlFnSpec(FNK_STRING_FN, STRFN_URL_ENCODE, 1, 1)
    if name == "url_decode": return SqlFnSpec(FNK_STRING_FN, STRFN_URL_DECODE, 1, 1)
    if name == "regexp_escape": return SqlFnSpec(FNK_STRING_FN, STRFN_REGEXP_ESCAPE, 1, 1)
    # -- the three cryptographic digests. --------------------------------
    #
    # ⛔ LOWERCASE HEX, WHERE `hex`/`to_hex` ABOVE ARE UPPERCASE. Both families
    # render bytes as hex into a VARCHAR and they disagree on case; `hex('abc')`
    # = '616263' is digit-only and hides it, so the witness is `hex('é')` =
    # 'C3A9' against `md5('é')` = '66ddcd97cfdeabb2f6fb8a999b4bc76f'.
    #
    # ⛔ THE DIGEST IS OVER UTF-8 BYTES, NOT CODEPOINTS — that same `é` value is
    # the digest of the two bytes C3 A9, measured on v1.5.3 over a COLUMN.
    #
    # ⭐ THE ORACLE FOR THESE IS NOT DuckDB. All three have fixed published
    # vectors (RFC 1321 §A.5, RFC 3174, FIPS 180-2 §B.1) and the kernels are
    # pinned to those; v1.5.3 was measured too and agrees byte for byte.
    #
    # ⛔ THERE IS NO `sha512` OR `sha384` ROW BECAUSE DuckDB HAS NEITHER.
    # MEASURED: the whole digest family on v1.5.3 is exactly `md5`,
    # `md5_number`, `md5_number_lower`, `md5_number_upper`, `sha1`, `sha256`
    # and `hash`. A refusal row for `sha512` would claim the parity target
    # serves a name it does not.
    if name == "md5": return SqlFnSpec(FNK_STRING_FN, STRFN_MD5, 1, 1)
    if name == "sha1": return SqlFnSpec(FNK_STRING_FN, STRFN_SHA1, 1, 1)
    if name == "sha256": return SqlFnSpec(FNK_STRING_FN, STRFN_SHA256, 1, 1)

    # -- EXPR_MATH_FN: the one-argument math family ----------------------------
    #
    # ⛔ `log` IS `log10`, NOT `ln`, AND THAT IS MEASURED. DuckDB v1.5.3 follows
    # the PostgreSQL convention: `log(100)` = 2.0 while `ln(100)` =
    # 4.605170185988092. Mapping `log` to the natural logarithm — the reading a
    # C or Python background makes obvious — is a silent wrong ANSWER of the
    # worst kind: same type, same nullability, plausible magnitude.
    #
    # ⚠ OUTPUT IS ALWAYS FLOAT64, which matches DuckDB for every name here over
    # INTEGER, FLOAT and DECIMAL input with ONE stated exception: `ceil`/`floor`
    # over a DECIMAL column return DECIMAL there and FLOAT64 here.
    if name == "sin": return SqlFnSpec(FNK_MATH_FN, MATH_SIN, 1, 1)
    if name == "cos": return SqlFnSpec(FNK_MATH_FN, MATH_COS, 1, 1)
    if name == "sqrt": return SqlFnSpec(FNK_MATH_FN, MATH_SQRT, 1, 1)
    if name == "asin": return SqlFnSpec(FNK_MATH_FN, MATH_ASIN, 1, 1)
    if name == "radians": return SqlFnSpec(FNK_MATH_FN, MATH_RADIANS, 1, 1)
    if name == "ceil" or name == "ceiling": return SqlFnSpec(FNK_MATH_FN, MATH_CEIL, 1, 1)
    if name == "floor": return SqlFnSpec(FNK_MATH_FN, MATH_FLOOR, 1, 1)
    if name == "ln": return SqlFnSpec(FNK_MATH_FN, MATH_LN, 1, 1)
    if name == "exp": return SqlFnSpec(FNK_MATH_FN, MATH_EXP, 1, 1)
    if name == "log10" or name == "log": return SqlFnSpec(FNK_MATH_FN, MATH_LOG10, 1, 1)
    if name == "log2": return SqlFnSpec(FNK_MATH_FN, MATH_LOG2, 1, 1)
    if name == "tan": return SqlFnSpec(FNK_MATH_FN, MATH_TAN, 1, 1)
    if name == "atan": return SqlFnSpec(FNK_MATH_FN, MATH_ATAN, 1, 1)
    if name == "acos": return SqlFnSpec(FNK_MATH_FN, MATH_ACOS, 1, 1)
    if name == "cot": return SqlFnSpec(FNK_MATH_FN, MATH_COT, 1, 1)
    if name == "degrees": return SqlFnSpec(FNK_MATH_FN, MATH_DEGREES, 1, 1)
    if name == "cbrt": return SqlFnSpec(FNK_MATH_FN, MATH_CBRT, 1, 1)
    if name == "sinh": return SqlFnSpec(FNK_MATH_FN, MATH_SINH, 1, 1)
    if name == "cosh": return SqlFnSpec(FNK_MATH_FN, MATH_COSH, 1, 1)
    if name == "tanh": return SqlFnSpec(FNK_MATH_FN, MATH_TANH, 1, 1)
    # -- the INVERSE HYPERBOLICS and GAMMA.
    #
    # ⚠ THESE FOUR HAVE NO OUTPUT-TYPE DIVERGENCE AT ALL, which is why they are
    # the right members for an always-FLOAT64 tag and `abs`/`round`/`sign` are
    # not. MEASURED on v1.5.3: each is declared `DOUBLE(DOUBLE)` and has ONE
    # overload — there is no DECIMAL-preserving arm to lose (`ceil`/`floor`
    # have one) and no FLOAT-preserving arm to lose either.
    #
    # ⚠ `gamma` IS `tgamma`, NOT `lgamma`, AND NOT A FACTORIAL. `gamma(5.0)` =
    # 24.0 = 4!, i.e. `gamma(n) = (n-1)!`. `lgamma` is deliberately NOT a row —
    # its kernel would be right and the PYTHON ORACLE is what diverges; the
    # measurement is written on `MATH_GAMMA` in `expr.mojo`.
    if name == "acosh": return SqlFnSpec(FNK_MATH_FN, MATH_ACOSH, 1, 1)
    if name == "asinh": return SqlFnSpec(FNK_MATH_FN, MATH_ASINH, 1, 1)
    if name == "atanh": return SqlFnSpec(FNK_MATH_FN, MATH_ATANH, 1, 1)
    if name == "gamma": return SqlFnSpec(FNK_MATH_FN, MATH_GAMMA, 1, 1)

    # -- EXPR_MATH_FN2: the two-argument math family ---------------------------
    #
    # ⭐ WITHOUT THIS ROW `atan2` IS UNREACHABLE, NOT MISSING. `MATH2_ATAN2` is
    # engine op 0 — it predates `MATH2_POW`, it has a libm kernel
    # (`scalar_math.eval_math_binary`), a wire member, a round-trip pin, a
    # `compiler_eval_column` arm, a `lower_untyped_expr._translate_node` arm
    # and a DataFrame door (`col_expr.atan2`). The ONLY thing SQL text needs to
    # reach that kernel is a row in this table: this line.
    #
    # ⚠ ITS TYPE IS THE REASON IT BELONGS HERE AND `abs`/`round`/`sign` DO NOT.
    # MEASURED on v1.5.3: `typeof(atan2(1,2))` = DOUBLE and
    # `typeof(atan2(1::FLOAT,2::FLOAT))` = DOUBLE — DuckDB has ONE overload,
    # `DOUBLE(DOUBLE, DOUBLE)`, so the always-FLOAT64 contract of EXPR_MATH_FN2
    # is not a narrowing here, it is an exact match. There is no divergence to
    # state, which is not true of every name that rides this tag.
    if name == "atan2": return SqlFnSpec(FNK_MATH_FN2, MATH2_ATAN2, 2, 2)
    if name == "pow" or name == "power": return SqlFnSpec(FNK_MATH_FN2, MATH2_POW, 2, 2)
    #
    # ⛔ `nextafter` IS THE THIRD MEMBER DuckDB HAS AND THIS ENGINE DOES NOT,
    # and it is a REFUSAL rather than a row because the family has no op for
    # it — see `_R_MATH2`, which carries the measurement and the surface list.
    if name == "nextafter": return SqlFnSpec(FNK_REFUSED, _R_MATH2)

    # -- EXPR_UNARY_OP: the TYPE-PRESERVING numeric family ---------------------
    #
    # ⭐ THE ONE PROPERTY THAT PUTS THESE FOUR HERE AND NOT ON `FNK_MATH_FN`:
    # THEIR OUTPUT TYPE DEPENDS ON THE INPUT. Read against the `EXPR_MATH_FN`
    # block above, which is always FLOAT64 and correct to be — DuckDB v1.5.3
    # gives `ceil(BIGINT)` a DOUBLE (measured; `ceil` has NO integer overload).
    # These do not:
    #     abs   [BIGINT]->BIGINT  [DOUBLE]->DOUBLE  [DECIMAL]->DECIMAL  ...
    #     round [BIGINT]->BIGINT  [DOUBLE]->DOUBLE  [DECIMAL]->DECIMAL  ...
    #     trunc [BIGINT]->BIGINT  [DOUBLE]->DOUBLE  [DECIMAL]->DECIMAL  ...
    #     sign  EVERY overload -> TINYINT
    # all read off `duckdb_functions()`, not off a docs page.
    #
    # ⛔ AND THE CHEAP ROUTE THAT IS WRONG: `abs` desugared to
    # `CASE WHEN x < 0 THEN -x ELSE x END`. Its TYPE reasoning is correct and
    # it has two silent wrong answers — `abs(-0.0)` comes out `-0.0` (DuckDB:
    # `+0.0`, proved by `1/abs(-0.0)` = `inf`) and `abs(INT64_MIN)` WRAPS to a
    # negative absolute value (DuckDB: `Out of Range Error`). The kernel gets
    # both right; see `UN_ABS` in `komira_plan_expr/expr.mojo`.
    #
    # ⚠ `round`/`trunc` ARE 1-ARG HERE AND DuckDB ALSO HAS A 2-ARG FORM. The
    # max_args of 1 makes that a NAMED refusal via `_fn_arity_msg`, not a
    # silent zero-digit round.
    #
    # ⛔⛔ DO NOT CLOSE THE 2-ARG FORM WITH THE OBVIOUS DESUGAR
    # `round(x * power(10,n)) / power(10,n)`. IT OVERFLOWS TO ±inf AND DuckDB
    # DOES NOT. MEASURED v1.5.3 over a real DOUBLE column (not a
    # literal — `values (2.345)` is DECIMAL(4,3) there and rounds by a
    # different rule): the desugar is byte-exact on 52 of 60 (x, n) cells,
    # INCLUDING every half-way case the rounding rule could differ on
    # (0.5/1.5/2.5 at n=0; 2.345/2.675/1.005/-2.345/0.145/8.835 at n=2;
    # 1234.5678 at n=-2). It DIVERGES on the other 8, all the same way:
    #
    #     round(1e300, 10)   duckdb 1e+300     desugar inf
    #     round(1e300, 15)   duckdb 1e+300     desugar inf
    #     round(-2.345, 308) duckdb -2.345     desugar -inf
    #     round(1234.56789, 308)  duckdb 1234.57   desugar inf
    #
    # The condition is |x| * 10^n > DBL_MAX, and `x` is a RUNTIME COLUMN VALUE
    # — so no plan-time guard on `n` can exclude it, and the wrong answer is
    # `inf`, which poisons every downstream SUM and AVG rather than being
    # visibly wrong in one cell. `trunc(x, n)` has the identical shape and
    # DIVERGES on 6 of 45 cells for the identical reason.
    #
    # ⇒ THE 2-ARG FORM NEEDS A REAL KERNEL, not a desugar. Held out as a
    # NAMED refusal until one exists, because "we have round(x,n)" that answers
    # inf on a large column is worse than "we do not have it". A spot check
    # of the desugar passes if its probes are all small magnitudes at small n,
    # the region where it is genuinely exact — so a handful of green probes is
    # not evidence for it.
    #
    # ⛔ NOT ROWS, DELIBERATELY: `round_even` / `roundbankers` are DuckDB
    # MACROS that take (x, n) — a two-argument, banker's-rounding shape that
    # shares neither this arity nor this rounding rule (measured: they are
    # 2-arg-only on v1.5.3, so there is no unary form to bind). `@` is DuckDB's
    # prefix ABS OPERATOR, a grammar entry rather than a function name.
    if name == "abs": return SqlFnSpec(FNK_UNARY_NUM, UN_ABS, 1, 1)
    if name == "sign": return SqlFnSpec(FNK_UNARY_NUM, UN_SIGN, 1, 1)
    if name == "trunc": return SqlFnSpec(FNK_UNARY_NUM, UN_TRUNC, 1, 1)
    if name == "round": return SqlFnSpec(FNK_UNARY_NUM, UN_ROUND, 1, 1)
    # ---- `bit_count`: THE ONE BIT FUNCTION THAT NEEDS NEITHER THE BIT TYPE
    #      NOR A BITWISE BINARY NODE, and it is served
    #      here and not through `FNK_MATH_FN` because `EXPR_MATH_FN` is ALWAYS
    #      FLOAT64 while `bit_count` is TINYINT on all five of its DuckDB
    #      v1.5.3 integer overloads. Its five siblings are refused: see
    #      `_R_BITFN` for which primitive each one is missing.
    if name == "bit_count": return SqlFnSpec(FNK_UNARY_NUM, UN_BIT_COUNT, 1, 1)

    # -- the OPERATOR NAMES: EXPR_BINARY_OP under a FUNCTION name --------
    #
    # ⭐ FOUND BY THE **ALIAS** CENSUS, NOT THE OP CENSUS, AND THAT IS THE POINT.
    # `duckdb_functions()` has an `alias_of` column; reading it turns up five
    # arithmetic operators that DuckDB ALSO registers as ordinary scalar
    # functions. An op census cannot see any of them — every op below was
    # already reachable from SQL, through the INFIX grammar. They were missing
    # a NAME, not a lowering.
    #
    # ⛔⛔ `divide` IS `//` AND NOT `/`. MEASURED v1.5.3: `divide(7,2)` = 3,
    # `divide(-7,2)` = -3, while `7/2` there = 3.5. Reading it as "the function
    # spelling of `/`" and checking it against `7/2` in DuckDB would report a
    # divergence this engine does not have; reading it as `//` and checking it
    # against THIS engine's I64 `/` (`EXPR_DIV_I64`, truncating toward zero)
    # is the comparison that is actually true. See `FNK_BINARY_OP`.
    #
    # ⚠ `mod` FOLLOWS THE SIGN OF THE DIVIDEND, as C does: measured
    # `mod(7,3)` = 1 and `mod(-7,3)` = **-1**, not 2. A Python-`%` reading is
    # wrong for exactly the negative dividends and right everywhere else.
    #
    # ⚠ THE UNARY OVERLOADS ARE REAL AND ONLY TWO NAMES HAVE THEM. MEASURED:
    # `add(5)` = 5, `subtract(5)` = -5, and `multiply(5)` / `divide(5)` /
    # `mod(5)` are all Binder Errors there. Hence 1..2 on two rows and 2..2 on
    # the other three — the arity the row states is DuckDB's, per name.
    #
    # ⛔ `xor` IS DELIBERATELY NOT A ROW: BITWISE xor, and this engine's
    # `BIN_*` space has no bitwise member at all. Binding it to anything here
    # would answer a different question, and there is no near-miss to be
    # tempted by — which is why it gets a comment rather than a refusal row.
    if name == "add": return SqlFnSpec(FNK_BINARY_OP, BIN_ADD, 1, 2)
    if name == "subtract": return SqlFnSpec(FNK_BINARY_OP, BIN_SUB, 1, 2)
    if name == "multiply": return SqlFnSpec(FNK_BINARY_OP, BIN_MUL, 2, 2)
    if name == "divide": return SqlFnSpec(FNK_BINARY_OP, BIN_DIV, 2, 2)
    if name == "mod": return SqlFnSpec(FNK_BINARY_OP, BIN_MOD, 2, 2)

    # -- the TEMPORAL fields that are ARITHMETIC ------------------------
    #
    # ⭐ FIVE TEMPORAL FUNCTIONS WITH NO `EXTRACT_*` UNIT AND NO KERNEL. Each
    # one is a closed-form expression over a unit this engine ALREADY extracts,
    # so all five are binder desugars onto `EXPR_EXTRACT` plus
    # `EXPR_BINARY_OP`, costing no op, no wire member and no pinned counter.
    #
    # ⚠ EVERY FORMULA BELOW WAS DERIVED FROM MEASURED VALUES ON SIX DATES
    # (2026-09-04, 2000-01-01, 1999-12-31, 1900-06-15, 0001-01-01, 2100-03-03),
    # not from the definition a reader would guess:
    #
    #     date       year  century  decade  millennium
    #     2026-09-04 2026    21      202        3
    #     2000-01-01 2000    20      200        2
    #     1999-12-31 1999    20      199        2
    #     1900-06-15 1900    19      190        2
    #     0001-01-01    1     1        0        1
    #     2100-03-03 2100    21      210        3
    #
    # ⛔ `century` IS **NOT** `year / 100`. Year 2000 is century 20, not 20 by
    # accident — 1999 is ALSO 20 and 2100 is 21, i.e. the boundary is at
    # ...01, not at ...00. The formula is `(year - 1) / 100 + 1`, and the naive
    # one is off by one for every year ending in 01..99 of a century's first
    # year. `millennium` has the identical shape at 1000. ⛔ `decade` DOES NOT
    # share it — `decade(2000)` = 200 and `decade(0001)` = 0, so decade is the
    # PLAIN truncating `year / 10`. Three functions, two different rules, and
    # applying either rule to all three is wrong for a third of all years.
    #
    # ⚠ THE `-1` MAKES THESE CORRECT ONLY FOR AD YEARS, WHICH IS EVERY YEAR
    # THIS ENGINE CAN REPRESENT. `BIN_DIV` over I64 truncates toward zero, so
    # a BC year (year <= 0, unrepresentable in this engine's DATE) would round
    # the wrong way; DuckDB's own answers there are a separate measurement.
    #
    # ⛔ `nanosecond` FOLDS THE SECONDS IN, exactly as `millisecond` and
    # `microsecond` do. MEASURED on `12:30:45.123456`: `second` = 45,
    # `millisecond` = 45123, `microsecond` = 45123456, `nanosecond` =
    # 45123456000 — so it is `microsecond * 1000` and NOT "the nanosecond
    # field", which would be 123456000. Mapping it onto a fractional field is
    # wrong by the seconds and plausible while doing it.
    #
    # ⛔ `epoch` / `julian` ARE NOT ROWS AND ARE NOT DERIVABLE THIS WAY. Both
    # return DOUBLE and both need the raw temporal value, not a field of it
    # (`epoch('2026-09-04 12:30:45')` = 1788525045.0, `julian('2026-09-04')` =
    # 2461288.0). They need new `EXTRACT_*` units, which no desugar supplies.
    #
    # ⛔ `timezone_hour` / `timezone_minute` ARE NOT ROWS. They read 0 for every
    # naive TIMESTAMP, which is every timestamp this engine has — so a literal
    # 0 would be green on every fixture AND would be a wrong answer the moment
    # a TIMESTAMPTZ column exists. A constant that is right only because the
    # feature is missing is the worst kind of row.
    if name == "century": return SqlFnSpec(FNK_DESUGAR, DSG_CENTURY, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "decade": return SqlFnSpec(FNK_DESUGAR, DSG_DECADE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "millennium": return SqlFnSpec(FNK_DESUGAR, DSG_MILLENNIUM, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "era": return SqlFnSpec(FNK_DESUGAR, DSG_ERA, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "nanosecond": return SqlFnSpec(FNK_DESUGAR, DSG_NANOSECOND, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- the three IEEE CLASSIFIERS --------------------------------------
    #
    # ⭐ ROUTE C — three DuckDB functions with no kernel, no op and no wire
    # member, expressed entirely in comparisons this engine already runs:
    #
    #     isfinite(x) == x > -inf AND x < inf
    #     isinf(x)    == x  =  inf OR  x  = -inf
    #     isnan(x)    == NOT isfinite(x) AND NOT isinf(x)
    #
    # Verified against v1.5.3 over {1.5, nan, inf, -inf, 0.0, -1e308, NULL}:
    # all seven rows, all three functions, EXACT — including NULL, which
    # propagates through the comparisons the same way it propagates through
    # the builtin.
    #
    # ⛔⛔ THE OBVIOUS `isnan(x) == x <> x` IS **WRONG AGAINST DuckDB**, AND
    # THAT IS NOT A DuckDB BUG TO WORK AROUND — IT IS ITS COMPARISON MODEL.
    # MEASURED v1.5.3: `'nan'::double = 'nan'::double` is **TRUE** and
    # `'nan'::double > 'inf'::double` is **TRUE**. DuckDB orders floats
    # TOTALLY (NaN sorts above +inf, and equals itself) rather than by IEEE-754,
    # so `x <> x` answers FALSE for a NaN there — the exact opposite of the
    # C/Python/IEEE idiom every reader will reach for, and green on any fixture
    # with no NaN in it.
    #
    # ⭐ WHICH IS WHY THE FORMS ABOVE WERE CHOSEN: EACH IS CORRECT UNDER **BOTH**
    # ORDERINGS. `x > -inf AND x < inf` is false for a NaN under IEEE (both
    # comparisons false) and false under DuckDB's total order (`nan < inf` is
    # false) — so this engine's own float comparison semantics, whichever they
    # are, cannot make the answer wrong. A desugar whose correctness depends on
    # a comparison model neither side has written down is not a desugar, it is
    # a bet.
    #
    # ⛔ `signbit` IS NOT A ROW. It reads the SIGN BIT, which no comparison can
    # see: `-0.0 = 0.0` is TRUE, so `x < 0` is FALSE for a negative zero — the
    # same blindness that made the `abs` CASE-desugar wrong. Reaching it needs
    # a real kernel, and DuckDB's own constant folder normalises `-1.0*0.0` to
    # `+0.0` there, so even the ORACLE has to be read off a column.
    #
    # ⚠ DuckDB ALSO OVERLOADS `isfinite`/`isinf` FOR DATE AND TIMESTAMP
    # (infinite dates). This engine has no infinite temporal value, so those
    # overloads are absent rather than wrong; over a temporal column these rows
    # will fail in the comparison, which is a refusal and not an answer.
    if name == "isfinite": return SqlFnSpec(FNK_DESUGAR, DSG_ISFINITE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "isinf": return SqlFnSpec(FNK_DESUGAR, DSG_ISINF, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "isnan": return SqlFnSpec(FNK_DESUGAR, DSG_ISNAN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- the PLAIN-TEXT split family -------------------------------------
    #
    # ⭐ FOUR NAMES ON THE OP THIS ENGINE ALREADY HAS. `regexp_split_to_array`
    # is reachable through its `FNK_REGEXP` row; `string_split` is the SAME
    # operation with a LITERAL separator instead of a pattern, so the binder
    # runs the separator through `regexp_escape` and builds the same node.
    #
    # ⚠ THE EQUIVALENCE IS MEASURED, INCLUDING THE TWO EDGES A READER WOULD
    # ASSUME DIFFER. v1.5.3: `string_split('a.b.c','.')` = ['a','b','c'] and
    # `regexp_split_to_array('a.b.c','\.')` = ['a','b','c'] (the escape is what
    # stops `.` matching every character); `string_split('abc','')` =
    # ['a','b','c'] and the regexp form with an empty pattern gives the SAME
    # ['a','b','c']; `string_split('abc','x')` = ['abc'] (no match, one part);
    # `string_split('','x')` = [''] (one EMPTY part, not an empty list);
    # `string_split(NULL,'.')` = NULL, as the regexp form is.
    #
    # ⛔ THE ESCAPE IS NOT OPTIONAL AND IS NOT A METACHARACTER LIST. Without
    # it `string_split('a.b.c','.')` would split on EVERY character. The rule
    # (`regexp_escape_bytes` in `komira_column_kernels/regexp_functions.mojo`) is
    # "escape everything that is not `[A-Za-z0-9_]`", read off all 127 bytes of
    # v1.5.3's own `regexp_escape` — and it has ONE producer, shared with
    # the kernel that serves `regexp_escape` itself, because two copies of a
    # measured 127-byte table drift silently.
    #
    # ⚠ THE SEPARATOR MUST BE A PLAN-TIME LITERAL, and that is the SAME
    # envelope `regexp_split_to_array` already has: `RegexpData.pattern` is a
    # `String` field, not an `Expr`, because the NFA is compiled once per batch
    # rather than once per row. A column-valued separator is refused BY NAME.
    #
    # ⛔⛔ `split_part` IS NOT "A PostgreSQL NAME THAT DOES NOT EXIST in
    # v1.5.3", which is what a census over `function_type='scalar'` reports —
    # a tier `split_part` is not in. It IS callable on v1.5.3, as a `macro`, and its
    # published body is `COALESCE(string_split(s, d)[pos], '')`. So it is
    # BLOCKED, not absent: the blocker is LIST INDEXING, which this engine has
    # no expression for. See the MACROS block below for the tier the
    # scalar census cannot see.
    if name == "string_split" or name == "str_split" or name == "string_to_array" or name == "split": return SqlFnSpec(FNK_DESUGAR, DSG_STRING_SPLIT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    #
    # ---- the JSON PATH EXTRACT family.
    #
    # ⭐ FOUR NAMES, NO NEW TAG, NO NEW KERNEL, NO WIRE CHANGE. `EXPR_JSON_EXTRACT`
    # (tag 19) has a `compiler_eval_column` arm, a `json_extract_kernel`
    # driver, a `walk_expr_field` output-type arm and 7 `plan_wire_codec`
    # references independently of these rows; without them no SQL text reaches
    # any of it. Reaching it costs two `DSG_*` selectors and one
    # `_bind_json_extract`.
    #
    # ⚠ AND THE OPERAND IS A PLAIN VARCHAR COLUMN. The eval arm's own
    # precondition is "parent must be STRING"; JSON here is JSON *text*. That is
    # why these four separate cleanly from the MAP/STRUCT names below, which
    # need a nested column operand that only the in-memory route produces.
    #
    # THE PAIRING IS MEASURED, NOT ASSUMED (v1.5.3). `json_extract`
    # and `json_extract_path` agree on every probe; so do `json_extract_string`
    # and `json_extract_path_text`. The two GROUPS disagree on exactly two leaf
    # shapes — a JSON string (`"hi"` vs `hi`) and the JSON null literal (`null`
    # vs SQL NULL) — which is why they are two selectors and not one.
    #
    # ⛔ ARITY IS `FN_ARITY_OWN`: `_bind_json_extract` refuses a non-literal path
    # in the same breath as the count, and a family message stating "2" would
    # say nothing about the literal requirement — the half that actually bites.
    if name == "json_extract" or name == "json_extract_path": return SqlFnSpec(FNK_DESUGAR, DSG_JSON_EXTRACT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "json_extract_string" or name == "json_extract_path_text": return SqlFnSpec(FNK_DESUGAR, DSG_JSON_EXTRACT_TEXT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    # ---- NESTED-VALUE EXTRACTION out of a MAP or STRUCT CELL.
    # These bind to `EXPR_STRUCT_FIELD` / `EXPR_STRUCT_FIELD_IDX` /
    # `EXPR_MAP_GET`, which have evaluator arms and are EXECUTABLE through
    # `compute_project._is_nested_extract_output` — the in-memory route is the
    # ONLY door that can produce a nested column operand, and that arm is what
    # gives it an evaluator for these tags.
    # ⛔ THEIR THREE NEIGHBOURS ARE REFUSED and the reasons are NOT the same
    # one: `map_extract`/`element_at` answer a LIST (`_R_LISTCTOR`) and
    # `json_value` is a third leaf mode on the wire (`_R_JSONLEAFMODE`).
    if name == "struct_extract": return SqlFnSpec(FNK_DESUGAR, DSG_STRUCT_EXTRACT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "struct_extract_at": return SqlFnSpec(FNK_DESUGAR, DSG_STRUCT_EXTRACT_AT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "map_extract_value": return SqlFnSpec(FNK_DESUGAR, DSG_MAP_EXTRACT_VALUE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- DATE SUB --------------------------------------------------------
    #
    # ⛔⛔ `date_sub` IS **NOT** AN ALIAS OF `date_diff`, AND ITS OWN SELECTOR
    # IS THE POINT. On v1.5.3, over 2027-01-31 -> 2027-03-01,
    # `date_diff('month', ...)` = **2** (boundaries CROSSED) and
    # `date_sub('month', ...)` = **1** (COMPLETE periods). They agree for
    # 'day' — 63 and 63 over 2027-01-01 -> 2027-03-05 — which is the ONLY unit
    # this engine serves, so aliasing them would be correct today and would
    # become a silent wrong answer the DAY somebody widens the day-only fold.
    # Two selectors, two folds, two messages: the widening then has to be done
    # twice, deliberately, instead of once by accident.
    if name == "date_sub" or name == "datesub": return SqlFnSpec(FNK_DESUGAR, DSG_DATE_SUB, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- EVEN ------------------------------------------------------------
    #
    # ⛔ `even` ROUNDS AWAY FROM ZERO TO THE NEXT EVEN INTEGER, and it is NOT
    # "round to even" (banker's rounding), which is what the name reads like.
    # MEASURED v1.5.3: `even(0.5)` = 2, `even(1.0)` = **2**, `even(2.0)` = 2,
    # `even(3.0)` = 4, `even(2.3)` = 4, `even(-2.3)` = -4, `even(-0.5)` = -2.
    # Note `even(1.0)` = 2 and `even(3.0)` = 4: an ALREADY-INTEGER odd input
    # still moves. Banker's rounding of 0.5 is 0 and of 1.0 is 1, so the two
    # readings disagree on most inputs — including every odd integer.
    #
    # It is `ceil(|x| / 2) * 2 * sign(x)`, expressed as a CASE over the sign so
    # that `ceil` and `floor` do the work: no op, no kernel, no wire member.
    # DuckDB declares DOUBLE for the only overload it has, which is what
    # `EXPR_MATH_FN`'s always-FLOAT64 contract already gives.
    if name == "even": return SqlFnSpec(FNK_DESUGAR, DSG_EVEN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- MACROS: the family `function_type='scalar'` HIDES --------------
    #
    # ⭐⭐ A CENSUS OVER `duckdb_functions() WHERE function_type='scalar'`
    # CANNOT SEE ANY OF THESE. v1.5.3 has SIX function_type values and 118
    # `macro` rows; `nullif`, `fdiv`, `fmod`, `split_part`, `round_even`,
    # `days_in_month` and `date_add` are all MACROS, so every gap list built
    # from the scalar tier alone reports them as absent from DuckDB. They are
    # callable there and a caller cannot tell the difference.
    #
    # ⚠ AND THE MACRO BODY IS PUBLISHED — `duckdb_functions().macro_definition`
    # is the DEFINITION, not a guess, which is what makes these safe to desugar:
    #     fdiv(x,y)   -> floor(x / y)
    #     fmod(x,y)   -> x - y * floor(x / y)
    #     nullif(a,b) -> CASE WHEN a = b THEN NULL ELSE a END
    #
    # ⛔⛔ `fdiv` IS **FLOOR** DIVISION, NOT FLOAT DIVISION. The name reads like
    # the second and the body is the first: MEASURED `fdiv(7,2)` = **3.0** (a
    # DOUBLE, so the type reading is right and the value is not) and
    # `fdiv(-7,2)` = **-4.0**. A `x/y`-as-double reading answers 3.5 and -3.5 —
    # wrong on every input that does not divide exactly, and the type is
    # identical either way.
    #
    # ⛔⛔ `fmod` IS **FLOOR** MODULO AND IS NOT C'S `fmod`. MEASURED
    # `fmod(-7,2)` = **1.0**, where C's `fmod(-7,2)` is -1.0 and this table's
    # own `mod(-7,3)` is -1. So the two modulo spellings DuckDB ships disagree
    # on the sign of a negative dividend, `mod` follows C and `fmod` does not,
    # and both are right. They agree on every non-negative input.
    #
    # ⚠ `nullif`'s NULL IS TYPED, AND THE TYPE IS PICKED FROM THE FIRST
    # OPERAND. `broadcast_scalar`'s null arm has exactly two types — float64
    # and int64 — so a STRING operand has no expressible NULL and is REFUSED BY
    # NAME rather than raising mid-execution. Same wall that keeps
    # `dayname`/`monthname` unbound.
    #
    # ⛔ `split_part` IS A MACRO AND IS REACHABLE THERE — a measurement against
    # the scalar tier ONLY reports it as "does not exist in v1.5.3, it is a
    # PostgreSQL name". Its body is `COALESCE(string_split(s, d)[pos], '')`,
    # i.e. LIST INDEXING, which this engine has no expression for; it is
    # BLOCKED, not absent. ⇒ IT IS A ROW — an `FNK_REFUSED` one carrying that
    # sentence, in the blocked macro tier at the bottom of this table.
    #
    # ⛔ `round_even` / `roundbankers` are also `FNK_REFUSED` ROWS, and their
    # reason names THREE candidate blockers where the note above `abs` names
    # only the weakest. Arity is real (measured 2-ARGUMENT-ONLY on v1.5.3;
    # `round_even(2.5)` is a Binder Error naming `round_even(x, n)`) but a
    # future reader could "fix" it by widening the `round` row, and that would
    # not close the other one that still holds: `UN_ROUND` is unary and cannot
    # carry a digits operand at all. (The published body's `%` is served; see
    # `_R_ROUNDN`.)
    if name == "fdiv": return SqlFnSpec(FNK_DESUGAR, DSG_FDIV, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "fmod": return SqlFnSpec(FNK_DESUGAR, DSG_FMOD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "nullif": return SqlFnSpec(FNK_DESUGAR, DSG_NULLIF, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "days_in_month": return SqlFnSpec(FNK_DESUGAR, DSG_DAYS_IN_MONTH, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- CAST / TRY_CAST ---------------------------------------------
    # ⚠ THESE TWO NAMES CANNOT BE TYPED. See `CAST_DESUGAR_NAME` — the space
    # makes them unlexable, so they are reachable ONLY from the parser's CAST
    # arm and its `::` suffix, and they open no second calling spelling.
    if name == CAST_DESUGAR_NAME: return SqlFnSpec(FNK_DESUGAR, DSG_CAST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == TRY_CAST_DESUGAR_NAME: return SqlFnSpec(FNK_DESUGAR, DSG_TRY_CAST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    # -- POSITION(x IN y) --------------------------------------------
    # ⚠ UNTYPABLE for the same reason — see `POSITION_IN_DESUGAR_NAME`. The
    # parser has already put the operands in `strpos` order, so this is the
    # `strpos` lowering and `string_fn_n_arity` checks the count.
    if name == POSITION_IN_DESUGAR_NAME: return SqlFnSpec(FNK_STRING_FN_N, STRFNN_STRPOS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- EXPR_STRING_OP: the two-argument string PREDICATES --------------------
    #
    # ⛔ `position` IS DELIBERATELY ABSENT AND IS NOT A MISSING ROW. It is in
    # `duckdb_functions()` as `BIGINT(VARCHAR, VARCHAR)` and it is NOT CALLABLE
    # WITH A COMMA even in DuckDB — `select position('hello','ll')` is a PARSER
    # ERROR there, because `position` is reserved syntax
    # (`position(needle IN haystack)`). `strpos`/`instr` are the callable
    # FUNCTION spellings and they need an operand-shaped tag, not this one —
    # they are `FNK_STRING_FN_N` rows below.
    #
    # ⛔⛔ BUT `position` IS NOT "NOT CALLABLE AS A FUNCTION", FULL STOP.
    # MEASURED v1.5.3: `select position('b' in 'abc')` returns **2**. It is
    # callable, in its own grammar, with the operand order REVERSED from
    # `strpos` — needle first here, haystack first there. The REASON to refuse
    # the comma form stands (a reversed-operand alias would silently answer a
    # different question); the name is not ABSENT. The fuller statement is the
    # `position` block further down this file.
    if name == "contains": return SqlFnSpec(FNK_STRING_PRED, STR_CONTAINS, 2, 2)
    if name == "starts_with" or name == "prefix": return SqlFnSpec(FNK_STRING_PRED, STR_STARTS_WITH, 2, 2)
    if name == "ends_with" or name == "suffix": return SqlFnSpec(FNK_STRING_PRED, STR_ENDS_WITH, 2, 2)

    # -- EXPR_STRING_FN_N: the VARIADIC multi-argument string family ----------
    #
    # (These rows live HERE and not in a second name table, because two tables
    # over ONE namespace is the ambiguity this file exists to remove — a
    # contributor adding a name would have to know which file owns it, and a
    # name in both would resolve by ladder position again. The LOWERING,
    # `_bind_string_fn_n`, owns arity.)
    #
    # ⚠ THE MEASURED REASON FOR EACH ALIAS:
    #   * `concat` / `concat_ws` — DuckDB's are VARARG over ANY and stringify
    #     their arguments (`concat(1,'a',2.5)` = `'1a2.5'`). This engine requires
    #     STRING arguments and refuses anything else BY NAME at eval; a STATED
    #     NARROWING, never an implicit cast.
    #   * `replace` — the LITERAL-substring form. ⛔ NOT `regexp_replace`, which
    #     is a different DuckDB function on a different tag here.
    #   * `lpad` / `rpad` — three arguments, ALWAYS. DuckDB has NO two-argument
    #     form (measured: `lpad('abc',5)` is a Binder Error there), so a "pad
    #     defaults to space" convenience would accept a call DuckDB rejects.
    #   * `repeat` — DuckDB also overloads it for BLOB and LIST. Only the
    #     VARCHAR overload exists here; a non-string argument is refused at eval.
    #   * `strpos` / `instr` — MEASURED as the same function on v1.5.3
    #     (`instr('abc','b')` = `strpos('abc','b')` = 2).
    #
    # ⛔⛔ `position` IS DELIBERATELY ABSENT AND THE REASON IS NOT PURITY. It
    # appears in `duckdb_functions()` beside `strpos`/`instr`, so a census driven
    # by that table calls it a third alias. It is not CALLABLE that way:
    # `position('b','abc')` is a PARSER ERROR in v1.5.3 — `position` is reserved
    # syntax, spelled `position(<needle> IN <haystack>)`. AND ITS ARGUMENT ORDER
    # IS THE REVERSE OF `strpos`'s: `position('b' IN 'abc')` = 2 puts the NEEDLE
    # first, `strpos('abc','b')` puts the HAYSTACK first. Accepting
    # `position(a, b)` as an alias would not merely be an extension DuckDB
    # refuses — it would silently answer a DIFFERENT question for anyone who
    # wrote it with DuckDB's own operand order in mind. Reaching it correctly is
    # a PARSER change and its own decision.
    #
    # ⚠ A ROW HERE IS NOT ENOUGH TO ADD ONE OF THESE. The op must also exist in
    # `expr.mojo` with a row in `string_fn_n_arity` and a kernel arm in
    # `_eval_column_expr`. An op with no arity row is refused BY NAME at every
    # producer, which is the fail-closed direction.
    if name == "concat": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_CONCAT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "concat_ws": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_CONCAT_WS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "replace": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_REPLACE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "lpad": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_LPAD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "rpad": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_RPAD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "repeat": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_REPEAT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "strpos" or name == "instr": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_STRPOS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    # -- the EDIT-DISTANCE family ----------------------------------------
    #
    # ⛔ ALL THREE COMPARE BYTES, NOT CHARACTERS, AND DuckDB IS WHERE THAT WAS
    # MEASURED rather than where it was assumed: `levenshtein('é','')` = 2
    # ('é' is one CHARACTER and two bytes), `levenshtein('😀','x')` = 4, and
    # `hamming('é','e')` RAISES "must be of equal length" for two operands
    # that are one character each. Every textbook writes these over characters
    # and a character kernel is right on all of ASCII.
    #
    # ⛔ `damerau_levenshtein` IS THE **UNRESTRICTED** VARIANT, NOT OSA.
    # MEASURED: `damerau_levenshtein('ca','abc')` = 2; the Optimal String
    # Alignment distance — the two-row version nearly every library ships
    # under this name — answers 3. They agree on `('ab','ba')` = 1 and on most
    # short inputs, so this one call is the whole witness.
    #
    # ⛔ `hamming` RAISES ON TWO EMPTY STRINGS, which `levenshtein` accepts
    # (answering 0). A kernel that answered 0 here would look right and would
    # accept a call the parity target rejects.
    #
    if name == "levenshtein" or name == "editdist3": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_LEVENSHTEIN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "damerau_levenshtein": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_DAMERAU_LEVENSHTEIN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "hamming" or name == "mismatches": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_HAMMING, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    # -- TRANSLATE -------------------------------------------------------
    #
    # ⛔⛔ CHARACTER-BASED, AND IT IS THE ONLY MEMBER OF THIS KIND THAT IS. The
    # three edit-distance members two lines up are BYTE-based on this very tag.
    # MEASURED v1.5.3: `translate('héllo','é','e')` = 'hello' — a two-byte
    # codepoint matched and replaced as ONE unit. A byte-wise kernel would emit
    # INVALID UTF-8 here, which is worse than a wrong answer.
    #
    # ⛔ A SHORTER `to` DELETES: `translate('abcd','abc','xy')` = 'xyd'. A
    # duplicate in `from` takes the FIRST mapping: `translate('abc','aa','xy')`
    # = 'xbc'. Both measured; both the opposite of the obvious guess.
    if name == "translate": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_TRANSLATE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    # -- the STRING-SIMILARITY family, THE FLOAT64-RETURNING MEMBERS OF THIS
    #    KIND -------------------------------------------------------------
    #
    # ⭐ WHAT THESE THREE NEED IS A FLOAT OUTPUT ON `EXPR_STRING_FN_N`; the
    # kernels themselves are the cheap half. That output is
    # `string_fn_n_returns_float` in `expr.mojo`, a FLOAT64 arm in
    # `expr_walk.walk_expr_field` and a FLOAT64 arm in `compiler_eval_column`;
    # the tag's output type is a THREE-way choice.
    #
    # ⛔⛔ ALL THREE ARE BYTE-BASED, LIKE THE EDIT-DISTANCE FAMILY ABOVE AND
    # UNLIKE `translate`. MEASURED v1.5.3:
    #   `jaro_similarity('Ünïcodé','Unicode')` = 0.65714285714285714 — 4 byte
    #   matches over (10, 7). A CHARACTER kernel answers 0.71428571428571430
    #   (4 over (7, 7)), and the two agree on every ASCII input.
    #   `jaccard('Ünïcodé','Unicode')` = 0.36363636363636365 = 4/11, the BYTE
    #   set intersection over the BYTE set union; the character sets answer 0.4.
    #
    # ⛔ `jaccard` IS OVER SINGLE BYTES, NOT BIGRAMS, which is what almost every
    # "jaccard on strings" library means by the name. MEASURED:
    # `jaccard('martha','marhta')` = 1 and `jaccard('abc','cba')` = 1 — same
    # characters, different order — where a bigram kernel answers 0.2 and 0.
    #
    # ⛔ `jaccard` RAISES ON AN EMPTY OPERAND WHERE `jaro_similarity` ANSWERS 0.
    # Measured: `jaccard('abc','')` -> "Jaccard Function: An argument too
    # short!"; `jaro_similarity('abc','')` = 0 and `jaro_similarity('','')` = 0.
    # Two members of ONE family disagreeing about the empty string is exactly
    # the split `hamming` vs `levenshtein` already has one screen up.
    #
    # ⚠⚠ A STATED NARROWING: DuckDB gives the first two a THREE-argument
    # overload whose third operand is a SCORE CUTOFF (measured:
    # `jaro_similarity('dixon','dicksonx',0.9)` = 0 against 0.76666666666666661
    # for the 2-argument call). `string_fn_n_arity` declares all three EXACTLY
    # 2, so the cutoff form is REFUSED with an arity message rather than
    # silently ignored — ignoring a cutoff would answer a different question.
    # `jaccard` has no 3-argument overload there at all.
    if name == "jaro_similarity": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_JARO, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "jaro_winkler_similarity": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_JARO_WINKLER, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "jaccard": return SqlFnSpec(FNK_STRING_FN_N, STRFNN_JACCARD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- EXPR_REGEXP: the regular-expression family ----------------------------
    #
    # ⭐ THESE FOUR OPS WERE FULLY WIRED AND UNREACHABLE. See `FNK_REGEXP`.
    #
    # ⚠ EVERY VALUE BELOW IS MEASURED AGAINST DuckDB v1.5.3, NOT ASSUMED:
    #   * `regexp_matches` IS UNANCHORED and `regexp_full_match` IS ANCHORED —
    #     `regexp_matches('abcde','bcd')` = true, `regexp_full_match('abcde',
    #     'bcd')` = false, `regexp_full_match('abcde','a.*e')` = true. They are
    #     two functions, not a flag. ⛔ `regexp_like` is NOT a DuckDB v1.5.3
    #     name (it is Oracle/Snowflake) and is deliberately not a row, even
    #     though `REGEXP_LIKE` is what the op constant is called here.
    #   * `regexp_replace` REPLACES THE FIRST MATCH ONLY unless the options
    #     string contains `g`: `regexp_replace('aXbXc','X','-')` = `a-bXc`,
    #     `regexp_replace('aXbXc','X','-','g')` = `a-b-c`. This engine's
    #     `split_g_flag` implements exactly that split, so the default is right
    #     without a special case.
    #   * THE REPLACEMENT TEMPLATE IS BACKSLASH-NUMBERED, NOT DOLLAR-NUMBERED.
    #     `regexp_replace('2026-09','(\d+)-(\d+)','\2/\1')` = `09/2026`;
    #     the `$2/$1` spelling every JavaScript and .NET reader will try comes
    #     back as the LITERAL `$2/$1` in DuckDB too. Same convention here.
    #   * NO MATCH IS THE EMPTY STRING, NOT NULL: `regexp_extract('abc','z+')`
    #     = `''` and `regexp_extract('abc','z+') IS NULL` is false. So is an
    #     out-of-range group: `regexp_extract('2026-09','(\d+)-(\d+)',3)` =
    #     `''`, not an error. Both match this engine's kernel.
    #   * A NULL SUBJECT IS NULL FOR ALL FOUR.
    #
    # ⛔ `regexp_count` / `regexp_instr` / `regexp_substr` ARE **NOT** DuckDB
    # v1.5.3 NAMES AND ARE DELIBERATELY NOT ROWS, even though this engine has
    # `REGEXP_COUNT` / `REGEXP_INSTR` / `REGEXP_SUBSTR` ops with kernels and
    # eval arms sitting right beside the four above. Verified against
    # `duckdb_functions()`: the regexp names there are `regexp_escape`,
    # `regexp_extract`, `regexp_extract_all`, `regexp_full_match`,
    # `regexp_matches`, `regexp_replace`, `regexp_split_to_array`,
    # `str_split_regex`, `string_split_regex` — and nothing else. Those three
    # are PostgreSQL/Oracle spellings; binding them buys ZERO parity and
    # invents surface the parity target does not have.
    #
    # ⛔ `regexp_escape` IS A REAL DuckDB NAME AND IS NOT IN THIS BLOCK: it is
    # an ordinary string transform (`STRFN_REGEXP_ESCAPE`, in the BYTE-TRANSFORM
    # bucket above), not a `REGEXP_*` op.
    if name == "regexp_matches": return SqlFnSpec(FNK_REGEXP, REGEXP_LIKE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "regexp_full_match": return SqlFnSpec(FNK_REGEXP, REGEXP_FULL_MATCH, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "regexp_replace": return SqlFnSpec(FNK_REGEXP, REGEXP_REPLACE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "regexp_extract": return SqlFnSpec(FNK_REGEXP, REGEXP_EXTRACT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    # -- the two LIST-returning members ---------------------------------------
    #
    # ⚠ THESE ARE THE FIRST SQL SCALAR FUNCTIONS IN THIS TABLE WHOSE OUTPUT
    # COLUMN IS NOT A FLAT TYPE. `walk_expr_field` declares them
    # `Field.list_of_string`, `compiler_eval_column` builds them with
    # `Column.from_list`, and `compute_project`'s `_is_regexp_output` routes a
    # top-level (or alias-wrapped) regexp output to that evaluator — so the
    # whole path exists independently of this row exactly like the four above.
    # What these add is a LIST column leaving a SQL SELECT, and that is why
    # they are their own block with their own executing test rather than more
    # names on the line above.
    #
    # ⚠ MEASURED v1.5.3, and the two are NOT the same function inverted:
    #   regexp_split_to_array('a1b22c','[0-9]+') = ['a','b','c']   (the GAPS)
    #   regexp_extract_all('a1b22c','[0-9]+')    = ['1','22']      (the MATCHES)
    #   a NO-MATCH splits to the WHOLE SUBJECT — ['abc'] — while extract_all
    #   gives the EMPTY LIST []. A row that pointed one name at the other's op
    #   would look plausible on any subject where matches and gaps alternate.
    #
    # ⚠ `str_split_regex` / `string_split_regex` ARE REAL v1.5.3 ALIASES of
    # `regexp_split_to_array` and are measured identical
    # (`str_split_regex('a1b22c','[0-9]+')` = `['a','b','c']`). ⛔ They are NOT
    # `str_split` / `string_split`, which take a LITERAL separator and have no
    # op here at all — one missing `_regex` suffix is a different function.
    #
    # ⛔ ONE KNOWN DIVERGENCE, ALREADY DOCUMENTED ON THE KERNEL: a capture
    # group that did not PARTICIPATE in a given match yields `''` here and a
    # NULL element in DuckDB. That predates this row (it is stated at
    # `eval_regexp_extract_all`) and is not reachable without a
    # non-participating alternation group.
    if name == "regexp_extract_all": return SqlFnSpec(FNK_REGEXP, REGEXP_EXTRACT_ALL, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "regexp_split_to_array" or name == "str_split_regex" or name == "string_split_regex": return SqlFnSpec(FNK_REGEXP, REGEXP_SPLIT_TO_ARRAY, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- EXPR_EXTRACT: the bare temporal FIELD functions -----------------------
    #
    # ⚠ NAMESPACE (1). `dayofmonth` sits on the `day` row because DuckDB
    # exposes it as a FUNCTION synonym. ⛔ IT IS **ALSO** A SPECIFIER AND A
    # PERIOD THERE, whatever a quick reading suggests (see the header, and
    # `sql_date_part_unit`'s docstring).
    # The live witness for the two-table split is `dow`/`doy`, which run the
    # asymmetry the other way.
    if name == "year": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_YEAR, 1, 1)
    if name == "quarter": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_QUARTER, 1, 1)
    if name == "month": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_MONTH, 1, 1)
    if name == "day" or name == "dayofmonth": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_DAY, 1, 1)
    if name == "hour": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_HOUR, 1, 1)
    if name == "minute": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_MINUTE, 1, 1)
    if name == "second": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_SECOND, 1, 1)
    # -- the DAY-INDEX family --------------------------------------------
    #
    # ⛔⛔ `dow` AND `doy` ARE NOT ROWS HERE AND THEY ARE NOT MISSING. They are
    # `date_part` SPECIFIERS ONLY. On v1.5.3, `select dow(DATE
    # '2026-11-15')` is `Catalog Error: Scalar Function with name dow does not
    # exist! Did you mean "dayofweek"?` and `doy(...)` is the same error — while
    # `date_part('dow', ...)` = 0 and `date_part('doy', ...)` = 319 both work.
    # They are the EXACT MIRROR of `dayofmonth`, which is a function and not a
    # specifier, and between them they are the reason namespaces (1) and (2)
    # are two tables: the asymmetry runs in BOTH directions, so neither table
    # can be derived from the other by adding exceptions.
    #
    # ⛔ `dayofweek` AND `isodow` ARE TWO ROWS ON TWO UNITS, NOT ONE ROW AND AN
    # OFFSET, AND A SUNDAY IS THE ONLY WITNESS. On v1.5.3, on 2026-11-15
    # (a Sunday): `dayofweek` = **0** and `isodow` = **7**; on the Monday after,
    # both = 1. Five of seven weekdays cannot tell the two mappings apart, so a
    # fixture without a Sunday row scores green on either — including on
    # "isodow IS dayofweek", which is off by 7 exactly once a week.
    #
    # ⚠ `weekday` IS A TRUE ALIAS OF `dayofweek` AND NOT OF `isodow`, WHICH IS
    # THE READING THE NAME INVITES: `weekday(DATE '2026-11-15')` = 0,
    # i.e. it is the SUNDAY-ZERO one. Pointing it at `isodow` would answer 7 for
    # the same call.
    #
    # ⚠ ALL THREE RETURN BIGINT AND ALL THREE ACCEPT A **DATE** AS WELL AS A
    # TIMESTAMP — unlike `hour`/`minute`/`second`, there is no "a DATE has no
    # such component" case to answer, because every one of them is a property
    # of the DAY: `dayofyear(DATE '2026-11-15')` = 319.
    if name == "dayofweek" or name == "weekday": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_DAYOFWEEK, 1, 1)
    if name == "isodow": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_ISODOW, 1, 1)
    if name == "dayofyear": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_DAYOFYEAR, 1, 1)
    # -- the ISO WEEK-DATE family ----------------------------------------
    #
    # ⛔⛔ `isoyear` IS NOT AN ALIAS OF `year` AND `week` IS NOT
    # `dayofyear / 7`. On v1.5.3, the four rows that separate them, and
    # nothing else does:
    #     year(DATE '2027-01-01') = 2027   isoyear(DATE '2027-01-01') = 2026
    #     year(DATE '2029-12-31') = 2029   isoyear(DATE '2029-12-31') = 2030
    #     week(DATE '2027-01-01') = 53     (a JANUARY date, week 53)
    #     week(DATE '2029-12-31') = 1      (a DECEMBER date, week 1)
    # An ISO week belongs to the year containing its THURSDAY, so both units
    # disagree with the civil calendar for up to three days at each end of
    # every year — ~99% of days agree, which is exactly why a fixture has to
    # be authored to catch it.
    #
    # ⚠ `weekofyear` IS A TRUE ALIAS OF `week` (both 46 for
    # 2026-11-15), and the ISO reading is the ONLY one DuckDB has — there is
    # no `week(x, firstday)` overload in v1.5.3 to lose.
    #
    # ⛔ `yearweek` IS `isoyear * 100 + week`, NOT `year * 100 + week`.
    # On v1.5.3, `yearweek(DATE '2027-01-01')` = **202653**. Composing it from
    # the CIVIL year gives 202753 — the right shape, the wrong year, on
    # exactly the dates anyone would write this function for.
    #
    # ⛔ `isoweek` IS NOT A ROW AND IS NOT MISSING: `date_part('isoweek', ...)`
    # is a Conversion Error in v1.5.3 (measured) and there is no `isoweek`
    # function. It is the PostgreSQL spelling; binding it would invent surface
    # the parity target does not have.
    if name == "week" or name == "weekofyear": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_WEEK, 1, 1)
    if name == "isoyear": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_ISOYEAR, 1, 1)
    if name == "yearweek": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_YEARWEEK, 1, 1)
    # -- the SUB-SECOND family -------------------------------------------
    #
    # ⛔⛔ THE SECONDS ARE FOLDED IN, AND BOTH ROWS EXIST TO GET THAT RIGHT.
    # On v1.5.3, on
    # `TIMESTAMP '2026-11-15 13:45:30.123456'`:
    #     second(ts)      = 30
    #     millisecond(ts) = 30123      (= 30 * 1000    + 123)
    #     microsecond(ts) = 30123456   (= 30 * 1000000 + 123456)
    # The obvious reading — "the fractional field" — gives 123 and 123456,
    # wrong by three and six orders of magnitude with the right type and a
    # plausible value. The kernel implements the folded reading.
    #
    # ⚠ OVER A **DATE** BOTH ARE 0, not an error (v1.5.3:
    # `millisecond(DATE '2026-11-15')` = 0) — the same answer `hour`/`minute`/
    # `second` give there, served by the same one kernel.
    #
    # ⛔ `nanosecond` IS NOT A ROW, AND IT IS THE MIRROR OF `dow`/`doy`: it IS
    # a v1.5.3 FUNCTION (`nanosecond(ts)` = 30123456000) and is NOT
    # a `date_part` specifier there (`date_part('nanosecond', ...)` is a
    # Conversion Error). It is absent because a TIMESTAMP_NS column is the
    # only input for which it carries information this engine does not
    # already expose, and the unit space below 16 has ONE slot left — see
    # `expr.mojo`. Its absence is a decision, not an oversight.
    if name == "millisecond": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_MILLISECOND, 1, 1)
    if name == "microsecond": return SqlFnSpec(FNK_EXTRACT_FIELD, EXTRACT_MICROSECOND, 1, 1)

    # -- BINDER DESUGARS — no new tag, no kernel, no pinned counter --
    #
    # Every one of these owns its own arity check because every one of their
    # messages carries a measured fact a generic check cannot state.
    if name == "date_diff" or name == "datediff": return SqlFnSpec(FNK_DESUGAR, DSG_DATE_DIFF, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "coalesce": return SqlFnSpec(FNK_DESUGAR, DSG_COALESCE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "ifnull": return SqlFnSpec(FNK_DESUGAR, DSG_IFNULL, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "greatest": return SqlFnSpec(FNK_DESUGAR, DSG_GREATEST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "least": return SqlFnSpec(FNK_DESUGAR, DSG_LEAST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "date_part" or name == "datepart": return SqlFnSpec(FNK_DESUGAR, DSG_DATE_PART, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "date_trunc" or name == "datetrunc": return SqlFnSpec(FNK_DESUGAR, DSG_DATE_TRUNC, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "left": return SqlFnSpec(FNK_DESUGAR, DSG_LEFT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "right": return SqlFnSpec(FNK_DESUGAR, DSG_RIGHT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "substring" or name == "substr": return SqlFnSpec(FNK_DESUGAR, DSG_SUBSTRING, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    # ⭐ `pi()` IS THE CHEAPEST ROW IN THIS FILE: a ZERO-ARGUMENT function that
    # desugars to a FLOAT64 LITERAL. No tag, no kernel, no wire member, no
    # pinned counter, and no column read — the constant is folded at BIND time
    # and every optimizer pass downstream sees an ordinary literal.
    #
    # ⚠ THE PARSER ALREADY ACCEPTS AN EMPTY ARGUMENT LIST (`sql_parser` guards
    # its argument loop with `if self._kind() != TK_RPAREN`), so `pi()` needed
    # no grammar change either. It is the first zero-argument scalar function
    # this table carries; `_bind_pi` refuses any argument BY COUNT so that
    # `pi(1)` is a clean error rather than a silently ignored operand.
    #
    # MEASURED v1.5.3: `pi()` = 3.141592653589793, `typeof(pi())` = DOUBLE —
    # bit-identical to CPython's `math.pi` and to the value below.
    #
    # ⛔ `random()` AND `txid_current()` ARE THE OTHER ZERO-ARGUMENT NAMES IN
    # THAT TIER AND NEITHER IS A ROW. They are NON-DETERMINISTIC, so folding
    # them to a literal at bind time — the only thing this lowering does —
    # would evaluate them ONCE for the whole query and hand every row the same
    # value. That is a wrong answer, not a limitation.
    if name == "pi": return SqlFnSpec(FNK_DESUGAR, DSG_PI, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)

    # -- FNK_REFUSED: real DuckDB functions this engine will not approximate ---
    #
    # ⚠ TURNING A NAME THAT WOULD ANSWER THE GENERIC UNKNOWN-FUNCTION ERROR
    # INTO A NAMED REFUSAL IS A BEHAVIOUR CHANGE, so every refusal row is its
    # own reviewed decision rather than a side effect of a refactor.

    # -- MACROS: THE BLOCKED MACRO TIER, WITH ITS REASONS ----------------
    #
    # ⭐⭐ THESE ROWS SIT BELOW EVERY BINDING ROW, so a name that BINDS can
    # never be shadowed by one.
    #
    # 118 distinct names in v1.5.3 carry `function_type='macro'`, and EVERY ONE
    # of them has a row: some BIND, the rest carry the measured reason they
    # cannot. ⛔ NO PER-CLUSTER COUNT IS WRITTEN HERE: a count names a blocker,
    # and when the blocker's primitive arrives the sentence still reads as a
    # live blocker for a wall that is gone. The rows are the record.
    #
    # ⭐ THE POINT OF THE SECTION: zero macro names fall through to the generic
    # unknown-function error. Re-derive any count from the rows
    # (`SqlFnSpec[(][^)]*FNK_REFUSED`), never from this comment.
    #
    # ⚠ A ROW HERE IS A CLAIM THAT THE NAME IS REAL. `pg_typeof` and
    # `list_sum` produce a sentence naming what is missing instead of "no UDF
    # is declared under that name", which is true and tells the caller nothing
    # about whether DuckDB has it.
    #
    # ---- THE PG-COMPAT BOOLEAN CONSTANTS — 25 NAMES, AND THEY BIND -----------
    #
    # ⭐⭐ ALL 25 DEPEND ON ONE PIECE: the bool arm of `broadcast_scalar`
    # (`komira_column_kernels/compiler_helpers.mojo`, a bit-packed
    # `BooleanArray`), with `plan_wire_values._literal_is_materializable`
    # matching its own stated mirror. Without that arm a bool literal falls to
    # the `else` tail and materializes as a column of INT64 ZEROS — it would
    # answer 0 where DuckDB answers true — and these rows would have to be
    # refusals.
    #
    # ⚠ THE ARITIES ARE PER NAME AND MEASURED, NOT PER FAMILY. From
    # `duckdb_functions().parameters` on v1.5.3: 12 of these are 1-ary, 10
    # `has_*` plus `pg_has_role` are 2..3, and `has_column_privilege` ALONE is
    # 3..4 (`(table, column, privilege)` / `(user, table, column, privilege)`).
    # A single family arity would be wrong for `has_column_privilege` whichever
    # number it named, which is why `SqlFnSpec` states arity per ROW.
    #
    # ⚠ `pg_is_other_temp_schema` IS THE ONE THAT ANSWERS FALSE. Its published
    # body is `CAST('f' AS BOOLEAN)` where the other 24 are `CAST('t' AS
    # BOOLEAN)` — measured, and it has its own selector so that no edit to the
    # family can quietly flip it.
    if name == "pg_collation_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_conversion_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_function_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_opclass_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_operator_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_opfamily_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_table_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_ts_config_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_ts_dict_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_ts_parser_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_ts_template_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_type_is_visible": return SqlFnSpec(FNK_CONST, CONST_TRUE, 1, 1)
    if name == "pg_is_other_temp_schema": return SqlFnSpec(FNK_CONST, CONST_FALSE, 1, 1)
    if name == "has_any_column_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_database_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_foreign_data_wrapper_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_function_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_language_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_schema_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_sequence_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_server_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_table_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_tablespace_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "pg_has_role": return SqlFnSpec(FNK_CONST, CONST_TRUE, 2, 3)
    if name == "has_column_privilege": return SqlFnSpec(FNK_CONST, CONST_TRUE, 3, 4)
    #
    # ---- THE `list_aggr` FAMILY — 31 names, the largest macro cluster
    if name == "array_to_string": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "array_to_string_comma_default": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_any_value": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_approx_count_distinct": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_avg": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_bit_and": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_bit_or": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_bit_xor": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_bool_and": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_bool_or": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_count": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_entropy": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_first": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_histogram": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_kurtosis": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_kurtosis_pop": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_last": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_mad": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_max": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_median": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_min": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_mode": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_product": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_sem": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_skewness": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_stddev_pop": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_stddev_samp": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_string_agg": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_sum": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_var_pop": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    if name == "list_var_samp": return SqlFnSpec(FNK_REFUSED, _R_AGGR)
    #
    # ---- THE `NULL`-BODIED PG STUBS
    if name == "col_description": return SqlFnSpec(FNK_REFUSED, _R_NULLC)
    if name == "inet_client_addr": return SqlFnSpec(FNK_REFUSED, _R_NULLC)
    if name == "inet_client_port": return SqlFnSpec(FNK_REFUSED, _R_NULLC)
    if name == "inet_server_addr": return SqlFnSpec(FNK_REFUSED, _R_NULLC)
    if name == "inet_server_port": return SqlFnSpec(FNK_REFUSED, _R_NULLC)
    if name == "obj_description": return SqlFnSpec(FNK_REFUSED, _R_NULLC)
    if name == "shobj_description": return SqlFnSpec(FNK_REFUSED, _R_NULLC)
    #
    # ---- LIST CONSTRUCTION
    if name == "array_append": return SqlFnSpec(FNK_REFUSED, _R_BUILD)
    if name == "array_prepend": return SqlFnSpec(FNK_REFUSED, _R_BUILD)
    if name == "array_push_back": return SqlFnSpec(FNK_REFUSED, _R_BUILD)
    if name == "array_push_front": return SqlFnSpec(FNK_REFUSED, _R_BUILD)
    if name == "list_append": return SqlFnSpec(FNK_REFUSED, _R_BUILD)
    if name == "list_prepend": return SqlFnSpec(FNK_REFUSED, _R_BUILD)
    #
    # ---- LIST SLICING AND INDEXING
    if name == "array_pop_back": return SqlFnSpec(FNK_REFUSED, _R_SLICE)
    if name == "array_pop_front": return SqlFnSpec(FNK_REFUSED, _R_SLICE)
    if name == "array_reverse": return SqlFnSpec(FNK_REFUSED, _R_SLICE)
    if name == "list_reverse": return SqlFnSpec(FNK_REFUSED, _R_SLICE)
    if name == "split_part": return SqlFnSpec(FNK_REFUSED, _R_SLICE)
    #
    # ---- THE CATALOG READERS
    if name == "current_catalog": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "current_database": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "current_query": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "current_schema": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "current_schemas": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "format_type": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "get_block_size": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "pg_get_constraintdef": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "pg_get_expr": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    if name == "pg_get_viewdef": return SqlFnSpec(FNK_REFUSED, _R_CATALOG)
    #
    # ---- THE AGGREGATE MACROS — one new SHAPE, and a measured NULL trap
    if name == "geomean": return SqlFnSpec(FNK_REFUSED, _R_AGGMACRO)
    if name == "geometric_mean": return SqlFnSpec(FNK_REFUSED, _R_AGGMACRO)
    if name == "wavg": return SqlFnSpec(FNK_REFUSED, _R_AGGMACRO)
    if name == "weighted_avg": return SqlFnSpec(FNK_REFUSED, _R_AGGMACRO)
    #
    # ---- ★★ THE AGGREGATE REFUSALS. Denominator: `duckdb_functions()` where
    #      function_type='aggregate' = 88 names on v1.5.3. 4 are claimed by the
    #      ranking-window grammar; the served ones are named by
    #      `sql_ast.sql_call_is_aggregate`; the rest are the rows below. See the
    #      block above `sql_scalar_fn_spec` for the method and the per-family
    #      reasons.
    #
    # ---- ⭐⭐ BIVARIATE — `covar_pop` `covar_samp` and the nine `regr_*` HAVE
    #      NO ROWS HERE. They are SERVED: `sql_ast.sql_call_is_aggregate` names
    #      them, the binder gives each its own `AGG_*` tag, and all eleven
    #      finalize off the `CorrelationState` that `AGG_CORR` folds.
    #
    # ⛔ A NAME IS IN EXACTLY ONE OF THIS TABLE AND `sql_call_is_aggregate`. A
    # name in BOTH breaks the disjointness the hoisted aggregate check in
    # `_bind_scalar_call` depends on — asserted by
    # `test_the_aggregate_set_and_the_scalar_table_are_disjoint`.
    #
    # ---- PAYLOAD-CARRYING EXTREMUM — arg_max/arg_min/max_by and their NULL spellings
    if name == "arg_max": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "arg_max_null": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "arg_max_nulls_last": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "arg_min": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "arg_min_null": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "arg_min_nulls_last": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "argmax": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "argmin": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "max_by": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    if name == "min_by": return SqlFnSpec(FNK_REFUSED, _R_AGGARGEXTREME)
    #
    # ---- ⭐⭐ ARRIVAL-ORDER PICK — NO ROWS. `any_value`
    # `arbitrary` `first` `last` are SERVED by three arms of the extended
    # fold's per-group state. ⛔ Do NOT add a row here for any of them —
    # `sql_call_is_aggregate` claims the four names before this table is
    # consulted, so a row would be unreachable.
    #
    # ---- VALUE-WINDOW — the five value windows are served WITH OVER (the
    # parser takes `lag(...) OVER` before this table); these rows answer the
    # call WITHOUT one, and the four names with no SXWIN_* member at all
    if name == "cume_dist": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "fill": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "first_value": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "lag": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "last_value": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "lead": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "nth_value": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "ntile": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    if name == "percent_rank": return SqlFnSpec(FNK_REFUSED, _R_AGGWINVALUE)
    #
    # ---- NESTED OUTPUT — a LIST/MAP/BITSTRING cell per group; PodState forbids the state
    if name == "array_agg": return SqlFnSpec(FNK_REFUSED, _R_AGGNESTED)
    if name == "bitstring_agg": return SqlFnSpec(FNK_REFUSED, _R_AGGNESTED)
    if name == "histogram": return SqlFnSpec(FNK_REFUSED, _R_AGGNESTED)
    if name == "histogram_exact": return SqlFnSpec(FNK_REFUSED, _R_AGGNESTED)
    if name == "list": return SqlFnSpec(FNK_REFUSED, _R_AGGNESTED)
    #
    # ---- CONCATENATED STRING — same PodState wall, different output type
    if name == "group_concat": return SqlFnSpec(FNK_REFUSED, _R_AGGSTRCAT)
    if name == "listagg": return SqlFnSpec(FNK_REFUSED, _R_AGGSTRCAT)
    if name == "string_agg": return SqlFnSpec(FNK_REFUSED, _R_AGGSTRCAT)
    #
    # ---- ⭐⭐ POPULATION FINALIZE — `var_pop` `stddev_pop` `sem` HAVE NO ROWS.
    #      They are SERVED: `sql_ast.sql_call_is_aggregate` names them, the
    #      binder gives each its own `AGG_*` tag, and all three finalize off
    #      the `WelfordState` that `AGG_STDDEV_SAMP` folds.
    #
    # ⛔⛔ `sem` IS NOT `sqrt(M2 / (count - 1)) / sqrt(count)` — the textbook
    # standard error, built on the SAMPLE deviation. MEASURED v1.5.3 over
    # `{1,2,3,4,10}`: `sem` = 1.4142135623730951, which is
    # `stddev_POP / sqrt(n)`; the sample reading gives 1.5811388300841895. A
    # refusal row is READ AS A SPEC by the next person to serve the name, so a
    # wrong formula in one is worse than no row at all. The derivation lives
    # at `PopulationWelfordFinalize`.
    #
    # ---- HIGHER MOMENTS — the Welford state has no M3/M4 slot
    #
    # ---- PARAMETERISED QUANTILE — AGG_MEDIAN hardcodes p=0.5 (its routes keep
    #      EVERY value; the 64-row `MedianState` reservoir is reached by no
    #      plan route)
    if name == "quantile": return SqlFnSpec(FNK_REFUSED, _R_AGGQUANTILE)
    if name == "quantile_cont": return SqlFnSpec(FNK_REFUSED, _R_AGGQUANTILE)
    if name == "quantile_disc": return SqlFnSpec(FNK_REFUSED, _R_AGGQUANTILE)
    #
    # ---- FULL-SAMPLE / PER-DISTINCT-VALUE STATE
    if name == "entropy": return SqlFnSpec(FNK_REFUSED, _R_AGGRETAIN)
    if name == "mad": return SqlFnSpec(FNK_REFUSED, _R_AGGRETAIN)
    if name == "mode": return SqlFnSpec(FNK_REFUSED, _R_AGGRETAIN)
    #
    # ---- SKETCH STATE — HLL / t-digest / reservoir
    if name == "approx_count_distinct": return SqlFnSpec(FNK_REFUSED, _R_AGGSKETCH)
    if name == "approx_quantile": return SqlFnSpec(FNK_REFUSED, _R_AGGSKETCH)
    if name == "approx_top_k": return SqlFnSpec(FNK_REFUSED, _R_AGGSKETCH)
    if name == "reservoir_quantile": return SqlFnSpec(FNK_REFUSED, _R_AGGSKETCH)
    #
    # ---- COUNT SPELLINGS — NO ROWS, all three names SERVED.
    #      `count_star` `count_if` `countif`; see the note above
    #      `_R_AGGCOMPENSATED` for the `count_if` equivalence trap.
    #
    # ---- COMPENSATED SUM — a DIFFERENT statistic, measured, not an alias
    if name == "sum_no_overflow": return SqlFnSpec(FNK_REFUSED, _R_AGGCOMPENSATED)
    #
    # ---- REDUCTION MONOID — the BITWISE three only. `bool_and` `bool_or`
    #      `product` are SERVED; these three need an EXACT INT64 lane rather
    #      than the tag that serves their siblings.
    if name == "bit_and": return SqlFnSpec(FNK_REFUSED, _R_AGGMONOID)
    if name == "bit_or": return SqlFnSpec(FNK_REFUSED, _R_AGGMONOID)
    if name == "bit_xor": return SqlFnSpec(FNK_REFUSED, _R_AGGMONOID)
    #
    # ---- JSON / MAP
    if name == "json": return SqlFnSpec(FNK_REFUSED, _R_JSONMINIFY)
    if name == "json_group_array": return SqlFnSpec(FNK_REFUSED, _R_JSONMAP)
    if name == "json_group_object": return SqlFnSpec(FNK_REFUSED, _R_JSONMAP)
    if name == "json_group_structure": return SqlFnSpec(FNK_REFUSED, _R_JSONMAP)
    if name == "map_contains_entry": return SqlFnSpec(FNK_REFUSED, _R_JSONMAP)
    if name == "map_contains_value": return SqlFnSpec(FNK_REFUSED, _R_JSONMAP)
    #
    # ---- THE INTERVAL TYPE
    if name == "ago": return SqlFnSpec(FNK_REFUSED, _R_INTERVAL)
    if name == "date_add": return SqlFnSpec(FNK_REFUSED, _R_INTERVAL)
    #
    # ---- TWO-ARGUMENT ROUNDING
    if name == "round_even": return SqlFnSpec(FNK_REFUSED, _R_ROUNDN)
    if name == "roundbankers": return SqlFnSpec(FNK_REFUSED, _R_ROUNDN)
    #
    # ---- TABLE-FUNCTION BODIES (`unnest`)
    if name == "generate_subscripts": return SqlFnSpec(FNK_REFUSED, _R_TABLEFN)
    if name == "regexp_split_to_table": return SqlFnSpec(FNK_REFUSED, _R_TABLEFN)
    #
    # ---- MD5 + THE BIT TYPE
    if name == "md5_number_lower": return SqlFnSpec(FNK_REFUSED, _R_BITS)
    if name == "md5_number_upper": return SqlFnSpec(FNK_REFUSED, _R_BITS)
    # ⚠ `md5_number` NEEDS ITS OWN ROW because `_R_BITS` two lines up NAMES
    # it as the missing primitive — without one, a caller who typed the name
    # the reason pointed them at would get a bare unknown-function error
    # instead of a reason. It is refused for its OUTPUT
    # TYPE, not for the digest: `md5` lowers and `md5_number` cannot,
    # because HUGEINT has no column here. `factorial` is refused for exactly
    # the same reason and is the other member of that pair.
    if name == "md5_number": return SqlFnSpec(FNK_REFUSED, _R_INT128)
    if name == "factorial": return SqlFnSpec(FNK_REFUSED, _R_INT128)
    #
    # ---- CLOCK READS
    if name == "pg_conf_load_time": return SqlFnSpec(FNK_REFUSED, _R_CLOCK)
    if name == "pg_postmaster_start_time": return SqlFnSpec(FNK_REFUSED, _R_CLOCK)
    #
    # ---- POSTGRES WIRE PLUMBING
    if name == "format_pg_type": return SqlFnSpec(FNK_REFUSED, _R_PGCASE)
    if name == "map_to_pg_oid": return SqlFnSpec(FNK_REFUSED, _R_PGCASE)
    #
    # ---- SIDE-EFFECTING
    if name == "pg_sleep": return SqlFnSpec(FNK_REFUSED, _R_SLEEP)
    #
    # ---- BIND-TIME `typeof`
    if name == "pg_typeof": return SqlFnSpec(FNK_REFUSED, _R_TYPEOF)
    #
    # ---- BYTE FORMATTING
    if name == "pg_size_pretty": return SqlFnSpec(FNK_REFUSED, _R_SIZE)

    #
    # ---- THE ZERO-ARGUMENT CONSTANTS. `pi()` proves the SHAPE works (it
    #      folds to a bare FLOAT64 literal and executes), so these five look
    #      like five free rows. Four of them are STRING and the fifth is
    #      INT32, and EACH of those literal kinds has to be executed before it
    #      can be believed — never on the other's execution.
    # ---- THE PG-COMPAT USER CONSTANTS — 4 NAMES, AND THEY BIND ---------------
    #
    # ⭐ THEY DEPEND ON THE STRING-LITERAL ARM DECLARING THE TYPE IT BUILDS. A
    # string `ScalarValue` carries `dtype == DTYPE_NONE` (its value is
    # discriminated by `_kind`), and `ArrowType.from_dtype` maps every dtype it
    # does not know to `ArrowType.NULL` — so deriving a bare STRING literal's
    # Arrow type through `ArrowType.from_dtype(sv.dtype)` BUILDS arrow id 13
    # (STRING) and DECLARES arrow id 0 (NULL) for the same column, while a
    # numeric constant projection passes. `expr_walk.walk_expr_field`'s
    # EXPR_LITERAL arm reads `sv.is_string()` first, so the two halves agree.
    #
    # ⚠ ZERO ARGUMENTS, AND THE PARENTHESISED SPELLING IS THE ONE SERVED.
    # DuckDB accepts both `current_user` and `current_user()`; this engine's
    # parser resolves a bare identifier as a COLUMN, so `SELECT current_user`
    # is a column error here and `SELECT current_user()` binds. That is a
    # PARSER gap, not a table one, and it is a refusal rather than a wrong
    # answer — written down so the next reader does not go looking for a
    # missing row.
    if name == "current_user": return SqlFnSpec(FNK_CONST, CONST_USER, 0, 0)
    if name == "session_user": return SqlFnSpec(FNK_CONST, CONST_USER, 0, 0)
    if name == "current_role": return SqlFnSpec(FNK_CONST, CONST_USER, 0, 0)
    if name == "user": return SqlFnSpec(FNK_CONST, CONST_USER, 0, 0)
    #
    # ---- THE PG-COMPAT INT32 CONSTANT — 1 NAME, AND IT BINDS ----------------
    #
    # ⭐ IT BINDS ON A MEASUREMENT: a bare INT32 literal projection derives
    # INT32, executed by a plan-wire literal-rows test; see `CONST_INT_ZERO`.
    # ⚠ ZERO ARGUMENTS: `duckdb_functions()` gives this
    # macro an EMPTY parameter list and `pg_my_temp_schema(1)` is a Binder
    # Error there naming the candidate `pg_my_temp_schema()`, so the row says
    # `0, 0` and the family message states the shape.
    if name == "pg_my_temp_schema": return SqlFnSpec(FNK_CONST, CONST_INT_ZERO, 0, 0)


    # -- THE SCALAR BACKLOG: 231 NAMES, DECIDED --------------------------
    #
    # 231 of the 424 scalar names this table otherwise lacks. Every row is
    # PROBED in DuckDB v1.5.3 before it is written (see the reason block above for
    # the probe's four error classes), and every reason names the missing
    # primitive rather than restating the refusal. Ordered by TRAFFIC: ICU
    # collation (the largest cluster), then string, date/time and numeric.
    #
    # ⚠ THESE ARE APPENDED BELOW EVERY BINDING ROW, so a name that BINDS can
    # never be shadowed by one, and `FNK_REFUSED` leaves
    # `lowers_to_a_node = False` so all 231 stay DECLARABLE as user UDFs.
    #
    # ---- ICU COLLATION — 137 names, and 135 of them are ONE machine-generated
    #      per-locale family. THE SINGLE LARGEST CLUSTER IN THE 424.
    if name == "create_sort_key": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_af": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_am": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ar": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ar_sa": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_as": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_az": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_be": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_bg": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_blo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_bn": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_bo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_br": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_bs": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ca": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ceb": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_chr": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_cs": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_cy": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_da": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_de": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_de_at": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_dsb": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_dz": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ee": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_el": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_en": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_en_us": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_eo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_es": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_et": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fa": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fa_af": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ff": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fi": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fil": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fr": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fr_ca": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_fy": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ga": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_gl": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_gu": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ha": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_haw": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_he": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_he_il": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_hi": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_hr": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_hsb": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_hu": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_hy": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_id": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_id_id": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ig": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_is": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_it": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ja": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ka": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_kk": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_kl": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_km": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_kn": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ko": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_kok": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ku": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ky": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_lb": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_lij": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_lkt": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ln": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_lo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_lt": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_lv": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_mk": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ml": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_mn": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_mr": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ms": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_mt": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_my": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_nb": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_nb_no": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ne": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_nl": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_nn": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_no": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_noaccent": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_nso": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_om": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_or": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_pa": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_pa_in": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_pl": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ps": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_pt": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ro": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ru": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sa": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_se": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_si": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sk": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sl": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_smn": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sq": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sr": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sr_ba": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sr_me": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sr_rs": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_st": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sv": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_sw": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ta": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_te": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_th": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_tk": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_tn": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_to": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_tr": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ug": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_uk": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_ur": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_uz": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_vi": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_wae": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_wo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_xh": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_yi": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_yo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_zh": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_zh_cn": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_zh_hk": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_zh_mo": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_zh_sg": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_zh_tw": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_collate_zu": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    if name == "icu_sort_key": return SqlFnSpec(FNK_REFUSED, _R_ICUCOLL)
    #
    # ---- GRAPHEME-CLUSTER string ops — 4 names
    if name == "left_grapheme": return SqlFnSpec(FNK_REFUSED, _R_GRAPHEME)
    if name == "length_grapheme": return SqlFnSpec(FNK_REFUSED, _R_GRAPHEME)
    if name == "right_grapheme": return SqlFnSpec(FNK_REFUSED, _R_GRAPHEME)
    if name == "substring_grapheme": return SqlFnSpec(FNK_REFUSED, _R_GRAPHEME)
    #
    # ---- UNICODE NORMALIZATION — 2 names
    if name == "nfc_normalize": return SqlFnSpec(FNK_REFUSED, _R_UNORM)
    if name == "strip_accents": return SqlFnSpec(FNK_REFUSED, _R_UNORM)
    #
    # ---- FORMAT-STRING interpreters — 2 names
    if name == "format": return SqlFnSpec(FNK_REFUSED, _R_FMTSTR)
    if name == "printf": return SqlFnSpec(FNK_REFUSED, _R_FMTSTR)
    #
    # ---- NUMBER -> TEXT formatters and their inverse — 6 names
    if name == "bar": return SqlFnSpec(FNK_REFUSED, _R_NUMFMT)
    # ⛔⛔ THESE TWO ARE SPELLED LOWERCASE AND THE CATALOG SPELLS THEM
    # `formatReadableSize` / `formatReadableDecimalSize`. THEY ARE THE ONLY TWO
    # NON-LOWERCASE NAMES IN DuckDB v1.5.3's 683-name scalar tier, and the
    # camelCase spelling here is an UNREACHABLE LINE: this function's own
    # docstring says `name` is lower-folded by the parser before it arrives.
    # Written camelCase they compile, read correctly, and NEVER FIRE —
    # `formatReadableDecimalSize(i)` gets the unknown-function error while a
    # case-sensitive catalog comparison counts both as covered. Only a test
    # that BINDS the name, instead of reading the table, sees it.
    # ⚠ SQL identifiers ARE case-insensitive on the parity target — measured
    # v1.5.3: `formatreadablesize(1024)` and `formatReadableSize(1024)` both
    # answer '1.0 KiB' — so the lower-folded spelling is the CORRECT one and
    # the camelCase one must never be restored.
    if name == "formatreadabledecimalsize": return SqlFnSpec(FNK_REFUSED, _R_NUMFMT)
    if name == "formatreadablesize": return SqlFnSpec(FNK_REFUSED, _R_NUMFMT)
    if name == "format_bytes": return SqlFnSpec(FNK_REFUSED, _R_NUMFMT)
    if name == "parse_formatted_bytes": return SqlFnSpec(FNK_REFUSED, _R_NUMFMT)
    if name == "to_base": return SqlFnSpec(FNK_REFUSED, _R_NUMFMT)
    #
    # ---- BLOB codecs — 9 names
    if name == "base64": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "decode": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "encode": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "from_base64": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "from_binary": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "from_hex": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "to_base64": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "unbin": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    if name == "unhex": return SqlFnSpec(FNK_REFUSED, _R_BINCODEC)
    #
    # ---- DOUBLE-valued string similarity — 3 names
    #
    # ---- LIKE with an explicit ESCAPE — 4 names
    if name == "ilike_escape": return SqlFnSpec(FNK_REFUSED, _R_LIKEESC)
    if name == "like_escape": return SqlFnSpec(FNK_REFUSED, _R_LIKEESC)
    if name == "not_ilike_escape": return SqlFnSpec(FNK_REFUSED, _R_LIKEESC)
    if name == "not_like_escape": return SqlFnSpec(FNK_REFUSED, _R_LIKEESC)
    #
    # ---- FILESYSTEM-PATH splitters — 4 names
    if name == "parse_dirname": return SqlFnSpec(FNK_REFUSED, _R_PATHSPLIT)
    if name == "parse_dirpath": return SqlFnSpec(FNK_REFUSED, _R_PATHSPLIT)
    if name == "parse_filename": return SqlFnSpec(FNK_REFUSED, _R_PATHSPLIT)
    if name == "parse_path": return SqlFnSpec(FNK_REFUSED, _R_PATHSPLIT)
    #
    # ---- THE GRAMMAR-FORM ONE. The only PARSER-error probe of the 424
    if name == "position": return SqlFnSpec(FNK_REFUSED, _R_POSITION)
    #
    # ---- WALL-CLOCK reads — 8 names
    if name == "current_date": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    if name == "current_localtime": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    if name == "current_localtimestamp": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    if name == "get_current_time": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    if name == "get_current_timestamp": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    if name == "now": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    if name == "today": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    if name == "transaction_timestamp": return SqlFnSpec(FNK_REFUSED, _R_WALLCLOCK)
    #
    # ---- TEMPORAL format/parse directives — 3 names
    if name == "strftime": return SqlFnSpec(FNK_REFUSED, _R_TSFORMAT)
    if name == "strptime": return SqlFnSpec(FNK_REFUSED, _R_TSFORMAT)
    if name == "try_strptime": return SqlFnSpec(FNK_REFUSED, _R_TSFORMAT)
    #
    # ---- TEMPORAL CONSTRUCTORS — 7 names, SPLIT 3 SERVED / 4 REFUSED
    #
    # ⭐ THE SPLIT IS BY OVERLOAD SHAPE, NOT BY NAME, AND IT IS THE WHOLE POINT
    # OF THIS BLOCK. An EPOCH-COUNT constructor takes a tick count that is
    # ALREADY a temporal quantity and only has to be labelled with its unit; a
    # CALENDAR-COMPONENT constructor has to do civil-calendar arithmetic this
    # engine cannot do. Refusing all seven on the second ground would be false
    # of the first three — see `_R_TSMINT`'s own text.
    #
    # ⚠ `make_timestamp` IS IN BOTH CATEGORIES AT ONCE: v1.5.5 gives it an
    # arity-1 epoch overload AND an arity-6 component overload. The row cannot
    # decide that, so it is `FN_ARITY_OWN` and `_bind_make_timestamp_epoch`
    # refuses the 6-ary spelling with the calendar reason.
    if name == "make_timestamp": return SqlFnSpec(FNK_DESUGAR, DSG_MAKE_TS_US, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "make_timestamp_ms": return SqlFnSpec(FNK_DESUGAR, DSG_MAKE_TS_MS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "make_timestamp_ns": return SqlFnSpec(FNK_DESUGAR, DSG_MAKE_TS_NS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    if name == "make_date": return SqlFnSpec(FNK_REFUSED, _R_TSMINT)
    if name == "make_time": return SqlFnSpec(FNK_REFUSED, _R_TSMINT)
    if name == "make_timestamptz": return SqlFnSpec(FNK_REFUSED, _R_TSMINT)
    if name == "to_timestamp": return SqlFnSpec(FNK_REFUSED, _R_TSMINT)
    #
    # ---- EPOCH-COUNT conversions — 4 names
    if name == "epoch": return SqlFnSpec(FNK_REFUSED, _R_EPOCHCONV)
    if name == "epoch_ms": return SqlFnSpec(FNK_REFUSED, _R_EPOCHCONV)
    if name == "epoch_ns": return SqlFnSpec(FNK_REFUSED, _R_EPOCHCONV)
    if name == "epoch_us": return SqlFnSpec(FNK_REFUSED, _R_EPOCHCONV)
    #
    # ---- TIME-ZONE reads — 3 names
    if name == "timezone": return SqlFnSpec(FNK_REFUSED, _R_TZFN)
    if name == "timezone_hour": return SqlFnSpec(FNK_REFUSED, _R_TZFN)
    if name == "timezone_minute": return SqlFnSpec(FNK_REFUSED, _R_TZFN)
    #
    # ---- CALENDAR NAME lookups — 2 names
    if name == "dayname": return SqlFnSpec(FNK_REFUSED, _R_DATENAME)
    if name == "monthname": return SqlFnSpec(FNK_REFUSED, _R_DATENAME)
    #
    # ---- INTERVAL producers and consumers — 16 names
    if name == "age": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "normalized_interval": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "time_bucket": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_centuries": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_days": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_decades": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_hours": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_microseconds": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_millennia": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_milliseconds": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_minutes": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_months": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_quarters": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_seconds": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_weeks": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    if name == "to_years": return SqlFnSpec(FNK_REFUSED, _R_INTERVALCTOR)
    #
    # ---- CALENDAR ARITHMETIC results — 2 names
    if name == "julian": return SqlFnSpec(FNK_REFUSED, _R_DATEMINT)
    if name == "last_day": return SqlFnSpec(FNK_REFUSED, _R_DATEMINT)
    #
    # ---- BIT type and integer-bitwise ops — 6 names
    if name == "bit_position": return SqlFnSpec(FNK_REFUSED, _R_BITFN)
    if name == "bitstring": return SqlFnSpec(FNK_REFUSED, _R_BITFN)
    if name == "get_bit": return SqlFnSpec(FNK_REFUSED, _R_BITFN)
    if name == "set_bit": return SqlFnSpec(FNK_REFUSED, _R_BITFN)
    if name == "xor": return SqlFnSpec(FNK_REFUSED, _R_BITFN)
    #
    # ---- INTEGER-PRESERVING binary numerics — 4 names
    if name == "gcd": return SqlFnSpec(FNK_REFUSED, _R_INTPAIR)
    if name == "greatest_common_divisor": return SqlFnSpec(FNK_REFUSED, _R_INTPAIR)
    if name == "lcm": return SqlFnSpec(FNK_REFUSED, _R_INTPAIR)
    if name == "least_common_multiple": return SqlFnSpec(FNK_REFUSED, _R_INTPAIR)
    #
    # ---- NON-DETERMINISTIC / side-effecting — 2 names
    if name == "random": return SqlFnSpec(FNK_REFUSED, _R_NONDET)
    if name == "setseed": return SqlFnSpec(FNK_REFUSED, _R_NONDET)
    #
    # ---- MISSING unary math op members — 2 names
    if name == "lgamma": return SqlFnSpec(FNK_REFUSED, _R_MATHGAP)
    if name == "signbit": return SqlFnSpec(FNK_REFUSED, _R_MATHGAP)
    #
    # ---- NESTED-VALUE EXTRACTION — the two nested reads that are refused.
    # The four `json_extract*` names and `struct_extract` / `struct_extract_at`
    # / `map_extract_value` are served (their rows are above), and `json_value`
    # has its own reason. TWO stay, and NOT for lack of a nested door:
    # `map_extract` and its alias `element_at` answer a one-element LIST
    # on a hit and an EMPTY list on a miss, where `EXPR_MAP_GET` is the bare
    # value — a different value AND a different type on both paths. They need
    # a LIST-CELL CONSTRUCTOR (`_R_LISTCTOR`). See `_R_NESTEDDOOR`.
    if name == "element_at": return SqlFnSpec(FNK_REFUSED, _R_NESTEDDOOR)
    if name == "map_extract": return SqlFnSpec(FNK_REFUSED, _R_NESTEDDOOR)
    if name == "json_value": return SqlFnSpec(FNK_REFUSED, _R_JSONLEAFMODE)
    #
    # ---- LIST CELL SUBSCRIPT — 10 names
    if name == "array_extract": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "list_extract": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "list_element": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "list_slice": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "array_slice": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "list_select": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "array_select": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "list_where": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "array_where": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    if name == "array_length": return SqlFnSpec(FNK_REFUSED, _R_LISTCELL)
    #
    # ---- LIST CELL CONSTRUCTOR — 16 names
    if name == "list_value": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "list_pack": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "array_value": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "list_concat": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "list_cat": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "array_cat": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "array_concat": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "list_resize": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "array_resize": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "flatten": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "unpivot_list": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "list_zip": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "array_zip": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "generate_series": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "range": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    if name == "equi_width_bins": return SqlFnSpec(FNK_REFUSED, _R_LISTCTOR)
    #
    # ---- LIST ELEMENT SEARCH — 12 names
    if name == "list_contains": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "list_has": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "array_contains": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "array_has": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "list_has_all": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "list_has_any": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "array_has_all": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "array_has_any": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "list_position": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "list_indexof": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "array_position": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    if name == "array_indexof": return SqlFnSpec(FNK_REFUSED, _R_LISTSEARCH)
    #
    # ---- LIST SET OPERATION — 6 names
    if name == "list_distinct": return SqlFnSpec(FNK_REFUSED, _R_LISTSETOP)
    if name == "array_distinct": return SqlFnSpec(FNK_REFUSED, _R_LISTSETOP)
    if name == "list_intersect": return SqlFnSpec(FNK_REFUSED, _R_LISTSETOP)
    if name == "array_intersect": return SqlFnSpec(FNK_REFUSED, _R_LISTSETOP)
    if name == "list_unique": return SqlFnSpec(FNK_REFUSED, _R_LISTSETOP)
    if name == "array_unique": return SqlFnSpec(FNK_REFUSED, _R_LISTSETOP)
    #
    # ---- INTRA-CELL ORDERING — 7 names
    if name == "list_sort": return SqlFnSpec(FNK_REFUSED, _R_LISTORDER)
    if name == "array_sort": return SqlFnSpec(FNK_REFUSED, _R_LISTORDER)
    if name == "list_reverse_sort": return SqlFnSpec(FNK_REFUSED, _R_LISTORDER)
    if name == "array_reverse_sort": return SqlFnSpec(FNK_REFUSED, _R_LISTORDER)
    if name == "list_grade_up": return SqlFnSpec(FNK_REFUSED, _R_LISTORDER)
    if name == "array_grade_up": return SqlFnSpec(FNK_REFUSED, _R_LISTORDER)
    if name == "grade_up": return SqlFnSpec(FNK_REFUSED, _R_LISTORDER)
    #
    # ---- LAMBDA PARAMETER — 11 names
    if name == "apply": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "array_apply": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "list_apply": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "list_transform": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "array_transform": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "filter": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "list_filter": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "array_filter": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "reduce": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "list_reduce": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    if name == "array_reduce": return SqlFnSpec(FNK_REFUSED, _R_LAMBDA)
    #
    # ---- NAMED-AGGREGATE LIST REDUCTION — 5 names
    if name == "aggregate": return SqlFnSpec(FNK_REFUSED, _R_LISTREDUCE)
    if name == "array_aggr": return SqlFnSpec(FNK_REFUSED, _R_LISTREDUCE)
    if name == "array_aggregate": return SqlFnSpec(FNK_REFUSED, _R_LISTREDUCE)
    if name == "list_aggr": return SqlFnSpec(FNK_REFUSED, _R_LISTREDUCE)
    if name == "list_aggregate": return SqlFnSpec(FNK_REFUSED, _R_LISTREDUCE)
    #
    # ---- FIXED-WIDTH VECTOR DISTANCE — 15 names
    if name == "array_cosine_distance": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "array_cosine_similarity": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "array_cross_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "array_distance": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "array_dot_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "array_inner_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "array_negative_dot_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "array_negative_inner_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "list_cosine_distance": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "list_cosine_similarity": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "list_distance": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "list_dot_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "list_inner_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "list_negative_dot_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    if name == "list_negative_inner_product": return SqlFnSpec(FNK_REFUSED, _R_VECDIST)
    #
    # ---- MAP LOGICAL TYPE — 9 names
    if name == "map": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "map_concat": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "map_contains": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "map_entries": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "map_from_entries": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "map_keys": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "map_values": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "cardinality": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    if name == "switch": return SqlFnSpec(FNK_REFUSED, _R_MAPTYPE)
    #
    # ---- STRUCT VALUE ASSEMBLY — 12 names
    if name == "struct_concat": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_contains": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_has": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_indexof": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_insert": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_keys": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_pack": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_position": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_update": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "struct_values": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "remap_struct": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    if name == "row": return SqlFnSpec(FNK_REFUSED, _R_STRUCTTYPE)
    #
    # ---- JSON DOCUMENT INTERROGATION — 13 names
    if name == "json_array_length": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_contains": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_exists": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_keys": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_pretty": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_structure": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_transform": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_transform_strict": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_type": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_valid": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "from_json": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "from_json_strict": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    if name == "json_merge_patch": return SqlFnSpec(FNK_REFUSED, _R_JSONDOC)
    #
    # ---- JSON SERIALISER — 6 names
    if name == "json_array": return SqlFnSpec(FNK_REFUSED, _R_JSONBUILD)
    if name == "json_object": return SqlFnSpec(FNK_REFUSED, _R_JSONBUILD)
    if name == "json_quote": return SqlFnSpec(FNK_REFUSED, _R_JSONBUILD)
    if name == "to_json": return SqlFnSpec(FNK_REFUSED, _R_JSONBUILD)
    if name == "array_to_json": return SqlFnSpec(FNK_REFUSED, _R_JSONBUILD)
    if name == "row_to_json": return SqlFnSpec(FNK_REFUSED, _R_JSONBUILD)
    #
    # ---- DuckDB'S OWN PARSE TREE — 3 names
    if name == "json_deserialize_sql": return SqlFnSpec(FNK_REFUSED, _R_SQLSERDE)
    if name == "json_serialize_plan": return SqlFnSpec(FNK_REFUSED, _R_SQLSERDE)
    if name == "json_serialize_sql": return SqlFnSpec(FNK_REFUSED, _R_SQLSERDE)
    #
    # ---- GEOMETRY LOGICAL TYPE — 8 names
    if name == "st_asbinary": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    if name == "st_astext": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    if name == "st_aswkb": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    if name == "st_aswkt": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    if name == "st_crs": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    if name == "st_geomfromwkb": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    if name == "st_intersects_extent": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    if name == "st_setcrs": return SqlFnSpec(FNK_REFUSED, _R_GEOM)
    #
    # ---- UUID LOGICAL TYPE — 6 names
    if name == "uuid": return SqlFnSpec(FNK_REFUSED, _R_UUIDT)
    if name == "uuidv4": return SqlFnSpec(FNK_REFUSED, _R_UUIDT)
    if name == "uuidv7": return SqlFnSpec(FNK_REFUSED, _R_UUIDT)
    if name == "gen_random_uuid": return SqlFnSpec(FNK_REFUSED, _R_UUIDT)
    if name == "uuid_extract_timestamp": return SqlFnSpec(FNK_REFUSED, _R_UUIDT)
    if name == "uuid_extract_version": return SqlFnSpec(FNK_REFUSED, _R_UUIDT)
    #
    # ---- PER-ROW TYPE TAG — 7 names
    if name == "union_extract": return SqlFnSpec(FNK_REFUSED, _R_TAGGED)
    if name == "union_tag": return SqlFnSpec(FNK_REFUSED, _R_TAGGED)
    if name == "union_value": return SqlFnSpec(FNK_REFUSED, _R_TAGGED)
    if name == "variant_extract": return SqlFnSpec(FNK_REFUSED, _R_TAGGED)
    if name == "variant_normalize": return SqlFnSpec(FNK_REFUSED, _R_TAGGED)
    if name == "variant_to_parquet_variant": return SqlFnSpec(FNK_REFUSED, _R_TAGGED)
    if name == "variant_typeof": return SqlFnSpec(FNK_REFUSED, _R_TAGGED)
    #
    # ---- ENUM VALUE DOMAIN — 5 names
    if name == "enum_code": return SqlFnSpec(FNK_REFUSED, _R_ENUMT)
    if name == "enum_first": return SqlFnSpec(FNK_REFUSED, _R_ENUMT)
    if name == "enum_last": return SqlFnSpec(FNK_REFUSED, _R_ENUMT)
    if name == "enum_range": return SqlFnSpec(FNK_REFUSED, _R_ENUMT)
    if name == "enum_range_boundary": return SqlFnSpec(FNK_REFUSED, _R_ENUMT)
    #
    # ---- FIRST-CLASS TYPE VALUE — 8 names
    if name == "typeof": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    if name == "get_type": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    if name == "make_type": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    if name == "vector_type": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    if name == "can_cast_implicitly": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    if name == "cast_to_type": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    if name == "replace_type": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    if name == "alias": return SqlFnSpec(FNK_REFUSED, _R_TYPEVAL)
    #
    # ---- PER-SESSION SERVER STATE — 11 names
    if name == "current_connection_id": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "current_query_id": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "current_transaction_id": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "txid_current": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "currval": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "nextval": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "current_setting": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "getvariable": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "in_search_path": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "getenv": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    if name == "version": return SqlFnSpec(FNK_REFUSED, _R_SESSION)
    #
    # ---- OBSERVABLE SIDE EFFECT — 3 names
    if name == "error": return SqlFnSpec(FNK_REFUSED, _R_SIDEEFFECT)
    if name == "sleep_ms": return SqlFnSpec(FNK_REFUSED, _R_SIDEEFFECT)
    if name == "write_log": return SqlFnSpec(FNK_REFUSED, _R_SIDEEFFECT)
    #
    # ---- DuckDB'S OWN INTERNAL STATE — 3 names
    if name == "parse_duckdb_log_message": return SqlFnSpec(FNK_REFUSED, _R_DUCKINTERNAL)
    if name == "stats": return SqlFnSpec(FNK_REFUSED, _R_DUCKINTERNAL)
    if name == "is_histogram_other_bin": return SqlFnSpec(FNK_REFUSED, _R_DUCKINTERNAL)
    #
    # ---- AGGREGATE_STATE VALUE — 2 names
    if name == "combine": return SqlFnSpec(FNK_REFUSED, _R_AGGSTATE)
    if name == "finalize": return SqlFnSpec(FNK_REFUSED, _R_AGGSTATE)
    #
    # ---- UNSIGNED 64-BIT KEY — 2 names
    if name == "hash": return SqlFnSpec(FNK_REFUSED, _R_UKEY)
    if name == "timetz_byte_comparable": return SqlFnSpec(FNK_REFUSED, _R_UKEY)
    #
    # ---- CODEPOINT-TO-TEXT ENCODER — 1 names
    if name == "chr": return SqlFnSpec(FNK_REFUSED, _R_CODEPOINT)
    #
    # ---- BLOB COLUMN TYPE — 1 names
    if name == "octet_length": return SqlFnSpec(FNK_REFUSED, _R_BLOBLEN)
    #
    # ---- SHORT-CIRCUIT NULL PROPAGATION — 1 names
    if name == "constant_or_null": return SqlFnSpec(FNK_REFUSED, _R_SHORTCIRCUIT)
    return SqlFnSpec()


def sql_date_part_unit(name: String) -> Optional[UInt8]:
    """NAMESPACE (2) — the `date_part(<unit>, x)` SPECIFIER table.

    Serves BOTH spellings of the same construct: `date_part('year', ts)` and
    the grammar `EXTRACT(YEAR FROM ts)`, which the parser rewrites into exactly
    the former — so they land on one table and cannot drift apart.

    ⛔ WHAT IS ABSENT HERE, AND WHY IT IS ABSENT RATHER THAN WRONG.
    `epoch` / `julian` / `timezone` / `timezone_hour` / `timezone_minute` are
    REAL DuckDB date parts with no `EXTRACT_*` unit and no kernel in this
    engine. Mapping one onto the nearest unit that DOES exist is exactly the
    silent-wrong-answer shape this table is written to avoid.

    ⛔⛔ AND NOTHING ELSE BELONGS ON THAT LIST. Measured against the pinned
    `duckdb` CLI v1.5.3 and against this file:

      * `era` / `century` / `decade` / `millennium` — **SERVED HERE**, by
        `sql_date_part_desugar` below. They have no `EXTRACT_*` unit, but
        "no unit" is not "absent": `date_part('century', ts)` binds through
        that route.
      * `nanosecond` — **NOT A DuckDB SPECIFIER AT ALL.** `date_part(
        'nanosecond', TIMESTAMP '2026-11-15 13:45:30.123456')` is `Conversion
        Error: extract specifier "nanosecond" not recognized`, and so are
        `nanoseconds` and `ns`. There is nothing there to be missing.
        (`nanosecond(x)` IS a real FUNCTION there and binds here — namespace
        (1), a different table.)

    ⇒ The absence set is not restated in prose anywhere. It is DERIVED,
    by `sql_date_part_supported_summary()`, from these rows and the measured
    v1.5.3 universe in `sql_date_part_universe()`.

    ⚠ `week` / `weekofyear` / `isoyear` / `yearweek` / `millisecond` /
    `microsecond` ARE SERVED BY THEIR OWN KERNELS, not by being aliased onto
    something near them. The `millisecond` case is the one worth remembering:
    `date_part('millisecond', TIMESTAMP '2026-11-15 13:45:30.123456')` is
    **30123** — the SECONDS folded in, not the fractional part — so the alias
    that looks obvious is wrong by three orders of magnitude.

    ⛔⛔ `dayofmonth` IS A SPECIFIER TOO, whatever a quick reading of the
    two-table design suggests. On v1.5.3, all three spellings:

        select dayofmonth(DATE '2026-11-15')            -> 15
        select date_part('dayofmonth', DATE '2026-11-15') -> 15
        select date_trunc('dayofmonth', DATE '2026-11-15') -> 2026-11-15

    `dayofmonth` is a FUNCTION, a SPECIFIER **and** a PERIOD there, so each
    table has a row for it. A claim that it is a function only, copied into
    several places, agrees with every copy of itself — which is what a single
    mis-measurement propagated by copying looks like.

    ⭐ THE DESIGN DOES NOT REST ON `dayofmonth`, because a CORRECT witness
    exists and runs the OTHER way: `dow` and `doy` are specifiers here
    and are NOT functions (`select dow(DATE '2026-11-15')` is `Catalog Error:
    Scalar Function with name dow does not exist! Did you mean "dayofweek"?`),
    and so is every plural/short alias below — `yrs`, `mins`, `secs` are
    specifiers and no function of those names exists. Two tables, still.

    ⭐ AND `dow` / `doy` RUN THE ASYMMETRY THE OTHER WAY — they are rows HERE
    and deliberately NOT rows in namespace (1). On v1.5.3, `date_part(
    'dow', DATE '2026-11-15')` = 0 while `dow(DATE '2026-11-15')` is a Catalog
    Error ("Did you mean \"dayofweek\"?"). With `dayofmonth` going the opposite
    way, NEITHER table is the other plus exceptions, which is the fact that
    makes the two-table design load-bearing rather than tidy.
    """
    # -- the TEMPORAL ALIASES --------------------------------------------
    #
    # ⚠ EVERY SPELLING BELOW WAS PROBED INDIVIDUALLY AGAINST v1.5.3, NOT
    # PATTERNED. The set is NOT "singular + plural + first letter": `quarter`
    # has NO short form at all (`qtr`, `q` are both Conversion Errors), `month`
    # has `mon`/`mons` but NOT `mo`, and `day` has `d` but NOT `dd` or `dom`.
    # A generated alias table would have accepted four names DuckDB rejects.
    #
    # ⛔⛔ `m` IS **MINUTE**, NOT MONTH: `date_part('m', TIMESTAMP
    # '2026-11-15 13:45:30')` = 45. Every other one-letter alias is the
    # obvious one (`y` year, `d` day, `h` hour, `s` second, `w` week) which is
    # exactly what makes this one dangerous: a reader who pattern-matched
    # `m` -> month gets a number in 1..12's range for half the day, and it is
    # the WRONG FIELD with a plausible magnitude.
    if name == "year" or name == "years" or name == "yr" or name == "yrs" or name == "y": return Optional[UInt8](EXTRACT_YEAR)
    if name == "quarter" or name == "quarters": return Optional[UInt8](EXTRACT_QUARTER)
    if name == "month" or name == "months" or name == "mon" or name == "mons": return Optional[UInt8](EXTRACT_MONTH)
    if name == "day" or name == "days" or name == "d" or name == "dayofmonth": return Optional[UInt8](EXTRACT_DAY)
    if name == "hour" or name == "hours" or name == "h" or name == "hr" or name == "hrs": return Optional[UInt8](EXTRACT_HOUR)
    if name == "minute" or name == "minutes" or name == "min" or name == "mins" or name == "m": return Optional[UInt8](EXTRACT_MINUTE)
    if name == "second" or name == "seconds" or name == "s" or name == "sec" or name == "secs": return Optional[UInt8](EXTRACT_SECOND)
    # -- the DAY-INDEX specifiers ----------------------------------------
    #
    # ⚠ FIVE SPELLINGS OVER THREE UNITS, EVERY ONE MEASURED AGAINST v1.5.3 AND
    # NOT INFERRED FROM THE FUNCTION TABLE: `date_part('dayofweek', ...)` = 0,
    # `date_part('dow', ...)` = 0, `date_part('weekday', ...)` = 0,
    # `date_part('isodow', ...)` = 7, `date_part('doy', ...)` =
    # `date_part('dayofyear', ...)` = 74. `dow` and `doy` exist ONLY here.
    if name == "dayofweek" or name == "dow" or name == "weekday": return Optional[UInt8](EXTRACT_DAYOFWEEK)
    if name == "isodow": return Optional[UInt8](EXTRACT_ISODOW)
    if name == "dayofyear" or name == "doy": return Optional[UInt8](EXTRACT_DAYOFYEAR)
    # -- the ISO WEEK-DATE specifiers. `w` is the ONLY one-letter week alias (`wk`, `wks`
    # and `ww` are all Conversion Errors, measured); `isoweek` is rejected
    # there too.
    if name == "week" or name == "weeks" or name == "weekofyear" or name == "w": return Optional[UInt8](EXTRACT_WEEK)
    if name == "isoyear": return Optional[UInt8](EXTRACT_ISOYEAR)
    if name == "yearweek": return Optional[UInt8](EXTRACT_YEARWEEK)
    # -- the SUB-SECOND specifiers. SEVEN and FIVE spellings, each probed against
    # v1.5.3 (`msec`, `msecs`, `ms`, `msecond`, `mseconds` all = 30123;
    # `usec`, `usecs`, `us`, `usecond`, `useconds` all = 30123456).
    #
    # ⚠ THESE NAMES ALREADY EXIST IN NAMESPACE (3) AS `date_trunc` PERIODS AND
    # MEAN SOMETHING DIFFERENT THERE: `date_trunc('ms', t)` ZEROES everything
    # below the millisecond, while `date_part('ms', t)` READS 30123. Same
    # spelling, two tables, two meanings — which is the header's point.
    if name == "millisecond" or name == "milliseconds" or name == "msec" or name == "msecs" or name == "ms" or name == "msecond" or name == "mseconds": return Optional[UInt8](EXTRACT_MILLISECOND)
    if name == "microsecond" or name == "microseconds" or name == "usec" or name == "usecs" or name == "us" or name == "usecond" or name == "useconds": return Optional[UInt8](EXTRACT_MICROSECOND)
    return None


def sql_date_part_desugar(name: String) -> Optional[UInt8]:
    """NAMESPACE (2b) — the `date_part` specifiers that lower to a DESUGAR
    instead of to an `EXTRACT_*` wire unit.

    ⛔⛔ THIS IS A SEPARATE FUNCTION FROM `sql_date_part_unit` BECAUSE THE
    RETURN TAGS LIVE IN DIFFERENT VOCABULARIES. Both are `UInt8`; one is an
    `EXTRACT_*` unit that goes ON THE WIRE and the other is a `DSG_*` binder
    tag that never does. `EXTRACT_YEAR` and `DSG_CENTURY` are both small
    integers, so a single table returning "the tag" would type-check while
    encoding a desugar id into a plan as though it were an extract unit — a
    wrong answer no arity check and no test of the FUNCTION spellings can see.
    The caller knows which table it asked, and that is the only thing keeping
    the two vocabularies apart.

    ★ EVERY NAME HERE ALREADY EXECUTES UNDER ITS FUNCTION SPELLING. `century(
    v)` is a year-derived desugar; without this table `date_part(
    'century', v)` and `EXTRACT(CENTURY FROM v)` would raise, purely because the
    binder reads namespace (2) and namespace (2) has no such row. So this is a
    ROUTE, not a lowering: no op, no kernel, no wire member, no proto enum, no
    round-trip pin, no PLAN_WIRE bump.

    ⚠ MEASURED v1.5.3, all three spellings and six dates spanning
    1900/1999/2000/2001/2026/2100 — `century(x)`, `date_part('century', x)`
    and `EXTRACT(CENTURY FROM x)` AGREE on every cell, for all four names.
    That agreement is what makes the route safe; it is not assumed.

        year   century  decade  millennium  era
        1900     19      190        2        1
        1999     20      199        2        1
        2000     20      200        2        1     <- century/millennium do
        2001     21      200        3        1        NOT tick here
        2026     21      202        3        1
        2100     21      210        3        1     <- century does NOT tick

    ⛔ `centuries`/`cent`, `decades`/`dec`/`decs`, `millennia`/`mil`/`mils` ARE
    NOT A GENERATED PLURAL-AND-PREFIX PATTERN — every one was probed
    individually, the same discipline namespace (2) records, because that
    pattern is exactly what would invent four names DuckDB rejects. `era` has
    NO alias at all (`eras` is a Conversion Error, measured).

    ⚠ THREE OF THE FOUR EXECUTE END TO END OVER AN IN-MEM LEAF; `decade` DOES
    NOT. The rule is the SHAPE OF THE ROOT, not the name: the in-mem PROJECT
    door's overlay is matched at the TOP of an output expression, so an
    `EXPR_WHEN` root runs and an `EXPR_EXTRACT` under arithmetic does not.
    `era` is `EXPR_WHEN`-rooted; so are `century`/`millennium` (DuckDB's
    century numbering skips zero, so the BC arm needs a branch —
    `sql_bind_fn_args._year_derived_over`), and `decade` is a bare `BIN_DIV` and
    bind-level there. Over a PARQUET scan all four run. This route neither
    creates nor widens that limit.

    ⛔⛔ AND THE BC ROW IS NOT A HYPOTHETICAL. With the AD formula alone,
    `century` answers **1** for 44 BC (DuckDB: -1) and `millennium` answers
    **0** for 1000 BC (DuckDB: -2). This engine's DATE32 cannot hold a BC
    instant, but a TIMESTAMP built from raw int64 microseconds can, and
    `EXTRACT_YEAR` decodes it. ⚠ The table above is an AD table — every one
    of its six dates agrees under BOTH the AD-only formula and the branched
    one, which is exactly why it cannot see this.
    """
    # ⚠ NOT DERIVED FROM `sql_scalar_fn_spec`'s rows for the same four names.
    # A specifier is not a function (`dow` is a specifier and no function;
    # `date_part('epoch', …)` is served there and refused here), and the file
    # header's rule is that a wrong SHARED fact propagates while a wrong
    # INDEPENDENT row does not.
    if name == "century" or name == "centuries" or name == "cent": return Optional[UInt8](DSG_CENTURY)
    if name == "decade" or name == "decades" or name == "dec" or name == "decs": return Optional[UInt8](DSG_DECADE)
    if name == "millennium" or name == "millennia" or name == "mil" or name == "mils": return Optional[UInt8](DSG_MILLENNIUM)
    if name == "era": return Optional[UInt8](DSG_ERA)
    return None


def sql_date_part_universe() -> List[String]:
    """★ THE DuckDB v1.5.3 `date_part` SPECIFIER UNIVERSE — every spelling the
    PARITY TARGET accepts, whether or not this engine serves it.

    ⛔⛔ THIS IS A FACT ABOUT DuckDB, NOT ABOUT THIS ENGINE, AND THAT IS THE
    WHOLE POINT. `sql_date_part_supported_summary()` renders the refusal
    message by asking `sql_date_part_unit` / `sql_date_part_desugar` about each
    name below, so a name MOVES from the refused half to the served half the
    day a row is added, with NO EDIT to the message. A hand-written list in
    `_bind_date_part` would be printed VERBATIM to whoever typed an
    unrecognised unit, and the first time it went stale it would send users
    away from a feature that exists. A list goes stale; a derivation cannot.

    ⚠ EVERY NAME BELOW WAS PROBED INDIVIDUALLY against
    the pinned `duckdb` CLI v1.5.3, the same discipline
    the two tables above record — `select date_part('<name>', ts)` over a
    TIMESTAMP either returned a value or raised
    `Conversion Error: extract specifier "<name>" not recognized`.

    ⛔ `nanosecond` / `nanoseconds` / `ns` ARE **NOT** IN THIS UNIVERSE,
    although it is natural to list `nanosecond` among the "REAL DuckDB date
    parts" this engine refuses. MEASURED: all three spellings are
    `Conversion Error: extract specifier "nanosecond" not recognized` on
    v1.5.3 — there is nothing there to be missing. (`nanosecond(x)` IS a real
    DuckDB FUNCTION and binds here, which is exactly the namespace confusion
    the two-table design exists to keep apart.)
    """
    return [
        # -- namespace (2): the spellings `sql_date_part_unit` resolves -------
        String("year"), String("years"), String("yr"), String("yrs"),
        String("y"),
        String("quarter"), String("quarters"),
        String("month"), String("months"), String("mon"), String("mons"),
        String("day"), String("days"), String("d"), String("dayofmonth"),
        String("hour"), String("hours"), String("h"), String("hr"),
        String("hrs"),
        String("minute"), String("minutes"), String("min"), String("mins"),
        String("m"),
        String("second"), String("seconds"), String("s"), String("sec"),
        String("secs"),
        String("dayofweek"), String("dow"), String("weekday"),
        String("isodow"),
        String("dayofyear"), String("doy"),
        String("week"), String("weeks"), String("weekofyear"), String("w"),
        String("isoyear"),
        String("yearweek"),
        String("millisecond"), String("milliseconds"), String("msec"),
        String("msecs"), String("ms"), String("msecond"), String("mseconds"),
        String("microsecond"), String("microseconds"), String("usec"),
        String("usecs"), String("us"), String("usecond"), String("useconds"),
        # -- namespace (2b): the spellings `sql_date_part_desugar` resolves ---
        String("century"), String("centuries"), String("cent"),
        String("decade"), String("decades"), String("dec"), String("decs"),
        String("millennium"), String("millennia"), String("mil"),
        String("mils"),
        String("era"),
        # -- REAL v1.5.3 SPECIFIERS THIS ENGINE REFUSES ----------------------
        # Values on `TIMESTAMP '2026-11-15 13:45:30.123456'` (computed):
        # epoch 1794750330.123456, julian 2461360.573265318, and 0 for all
        # three timezone reads on a NAIVE timestamp. Each one's measured
        # blocker is stated in the refusal message below;
        # the day one grows a row above it leaves the refused half of the
        # rendered message BY ITSELF.
        String("epoch"), String("julian"),
        String("timezone"), String("timezone_hour"),
        String("timezone_minute"),
    ]


def sql_date_part_supported_summary() -> String:
    """★ THE `date_part` REFUSAL MESSAGE'S BODY, **DERIVED** FROM THE TABLES.

    Walks `sql_date_part_universe()` and asks the two live lookup functions
    about each name, so the served half and the refused half are both a
    CONSEQUENCE of the rows rather than a second statement about them. A row
    added to `sql_date_part_unit` or `sql_date_part_desugar` changes this
    string on the next call; a row deleted changes it back.

    ⚠ IT IS NOT `comptime`. The two lookups are ordinary `def`s over a `String`
    argument, and this runs once, on the refusal path, for a query that is
    already about to raise.
    """
    var served = String("")
    var refused = String("")
    var uni = sql_date_part_universe()
    for i in range(len(uni)):
        var n = uni[i]
        if sql_date_part_unit(n) or sql_date_part_desugar(n):
            if served.byte_length() > 0:
                served += ", "
            served += n
        else:
            if refused.byte_length() > 0:
                refused += ", "
            refused += n
    return (
        String("this engine serves ") + served
        + ". It does NOT serve " + refused
        + ", each of which IS a real v1.5.3 specifier with a measured blocker"
        + " (epoch / julian"
        + " read a RAW value no unit on this wire carries; the timezone reads"
        + " answer 0 for every naive timestamp and are refused rather than"
        + " served as a plausible zero). This list is DERIVED from the"
        + " specifier tables, not written beside them"
    )


def sql_date_trunc_unit(name: String) -> Optional[UInt8]:
    """NAMESPACE (3) — the `date_trunc(<period>, x)` PERIOD table.

    ⛔ NOT THE SAME SET AS NAMESPACE (2), AND `millisecond` IS THE PROOF: it
    truncates here and has no field extract. `decade` / `century` / `millennium`
    ARE absent and ARE real DuckDB periods (`date_trunc('decade', TIMESTAMP
    '2031-03-15 …')` = 2030-01-01); there is no `EXTRACT_TRUNC_DECADE` unit on
    this engine's wire, so they raise rather than rounding to the nearest period
    this engine happens to have — which would answer 2031-01-01 for a decade.

    ⛔⛔ `isoyear` IS THE SHARPEST OF THOSE AND IS DELIBERATELY NOT AN ALIAS OF
    `year`. On v1.5.3, `date_trunc('isoyear', TIMESTAMP '2027-03-14 …')`
    = **2027-01-04**, the Monday the ISO year begins on — not 2027-01-01. It is
    a period this engine has no unit for, and the "obvious" alias would be
    wrong by three days on 2027 and by a different amount every year.

    ★ THE FIELD-NAME-AS-PERIOD SET IS SERVED. DuckDB lets a FIELD name stand
    in for the period at that
    field's RESOLUTION, and the resolution is not what the name reads like:

        dayofweek dow weekday isodow dayofyear doy julian -> the DAY
        weekofyear yearweek                               -> the WEEK
        epoch                                             -> the SECOND

    ⛔⛔ `dow` TRUNCATES TO THE **DAY**, NOT TO THE WEEK. It is the one that
    reads backwards — "day of week" sounds like a week bucket — and mapping it
    to `EXTRACT_TRUNC_WEEK` is a silent wrong answer of up to six days that is
    INVISIBLE ON A MONDAY. The examples use four dates for exactly that reason:
    2026-11-15 (Sun), 1999-12-31 (Fri), 2100-07-04 and 2001-01-01 — and the
    LAST of those is a Monday, where `day` and `week` truncation COINCIDE, so
    it is the one date in the set that cannot discriminate. A fixture of
    Mondays proves nothing here.

    ⚠ `julian` AND `epoch` ARE PERIODS HERE AND ARE REFUSED AS
    `date_part` SPECIFIERS — namespace (2) reads a raw DOUBLE for both
    (2461360.43…, 1794738030.12…) which no `EXTRACT_*` unit on this wire
    carries, while the PERIOD meaning is a plain truncation this engine
    already does. Same spelling, two tables, one served and one not.

    ⚠ VERIFIED PRE-EPOCH, because a seconds-resolution truncation is where a
    floor-vs-truncate-toward-zero split would show: `date_trunc('epoch',
    TIMESTAMP '1969-12-31 23:59:59.750000')` = 1969-12-31 23:59:59, equal to
    `date_trunc('second', …)` on the same value.

    All of it was measured by a probe that compares each alias to
    the canonical spelling of the unit it maps to rather than to a set.
    """
    # -- the TEMPORAL ALIASES --------------------------------------------
    #
    # ⚠ THIS IS NOT THE SAME ALIAS SET AS NAMESPACE (2), EVEN WHERE THE UNITS
    # ARE THE SAME. MEASURED, both probed exhaustively on v1.5.3: `date_trunc`
    # accepts `yrs`/`hr`/`hrs`/`mins`/`sec`/`secs`/`m`, and `date_part` accepts
    # those too — but `date_part` REJECTS nothing that `date_trunc` accepts
    # here only because this engine serves a smaller unit set. The two lists
    # are written out independently, not derived from one another, for the
    # reason the header gives: the day one of them changes is the day a shared
    # list starts lying.
    #
    # ⛔ `m` IS **MINUTE** HERE TOO (`date_trunc('m', TIMESTAMP '2026-11-15
    # 13:45:30')` = 13:45:00, not 2026-11-01). Same trap, same answer.
    if name == "year" or name == "years" or name == "yr" or name == "yrs" or name == "y": return Optional[UInt8](EXTRACT_TRUNC_YEAR)
    if name == "quarter" or name == "quarters": return Optional[UInt8](EXTRACT_TRUNC_QUARTER)
    if name == "month" or name == "months" or name == "mon" or name == "mons": return Optional[UInt8](EXTRACT_TRUNC_MONTH)
    if name == "week" or name == "weeks" or name == "w" or name == "weekofyear" or name == "yearweek": return Optional[UInt8](EXTRACT_TRUNC_WEEK)
    if name == "day" or name == "days" or name == "d" or name == "dayofmonth" or name == "dayofweek" or name == "dow" or name == "weekday" or name == "isodow" or name == "dayofyear" or name == "doy" or name == "julian": return Optional[UInt8](EXTRACT_TRUNC_DAY)
    if name == "hour" or name == "hours" or name == "h" or name == "hr" or name == "hrs": return Optional[UInt8](EXTRACT_TRUNC_HOUR)
    if name == "minute" or name == "minutes" or name == "min" or name == "mins" or name == "m": return Optional[UInt8](EXTRACT_TRUNC_MINUTE)
    if name == "second" or name == "seconds" or name == "s" or name == "sec" or name == "secs" or name == "epoch": return Optional[UInt8](EXTRACT_TRUNC_SECOND)
    if name == "millisecond" or name == "milliseconds" or name == "msec" or name == "msecs" or name == "ms" or name == "msecond" or name == "mseconds": return Optional[UInt8](EXTRACT_TRUNC_MILLISECOND)
    if name == "microsecond" or name == "microseconds" or name == "usec" or name == "usecs" or name == "us" or name == "usecond" or name == "useconds": return Optional[UInt8](EXTRACT_TRUNC_MICROSECOND)
    return None
