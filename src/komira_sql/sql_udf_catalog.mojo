# =============================================================================
# sql_udf_catalog.mojo — ★ NAME -> UDF, THE ONE THING SQL NEEDS AND THE OTHER
#                          THREE SURFACES DO NOT.
# =============================================================================
#
# SQL UDFs. SQL is the one authoring surface of the four that cannot hold a
# function value. The other three resolve the function at COMPTIME —
#
#   Mojo typed    `df.map[margin]()`                    f is a comptime param
#   Mojo untyped  `df.with_columns(affine(col("x")))`   `affine` is a VALUE
#   Python        `@komira.udf(returns="int64")`        the skin holds the obj
#
# — and `EXPR_UDF_CALL` (tag 25) is why the two Python skins need no
# syntax of their own: a UDF is already an ordinary expression node. SQL cannot reach
# any of that, because `SELECT affine(x) FROM t` hands the binder the STRING
# `"affine"` and nothing else. This file is that lookup.
#
# ── WHAT IT IS NOT ──────────────────────────────────────────────────────────
#
# ⛔ IT IS NOT A ROW IN `sql_fn_table.mojo`, AND IT MUST NOT BECOME ONE.
# `sql_scalar_fn_spec(name)` is a PURE FUNCTION of a string — a static table
# compiled into the binary — so it cannot see a registry that is populated at
# run time. A `FNK_UDF` kind added there would be a lowering kind no row could
# ever carry: WIRED, and UNREACHABLE. An op that is wired but has no row
# that reaches it is never executed and nothing reports it, so the UDF path is
# a separate resolution STEP in the binder rather than a kind that lies.
#
# ⛔ IT IS NOT A `CREATE FUNCTION` STATEMENT. There is no grammar for it. A UDF gets
# into this catalog by being REGISTERED through a surface that already exists
# and then DECLARED here:
#
#     var affine = ctx.register_scalar[affine_impl](String("affine"))
#     cat.declare_udf(affine)
#     var rb = run_sql(ctx, cat, String("SELECT affine(a) AS y FROM t"))
#
# ── ★ THE PROPERTY THIS FILE EXISTS TO HOLD ─────────────────────────────────
#
# `declare_udf` HAS NO NAME PARAMETER AND NO DTYPE PARAMETER. It takes the
# registered value and reads all four facts off it:
#
#   name      <- `udf.name()`     — from `register_scalar`'s ONE name argument
#   handle    <- `udf.handle()`   — minted by the registry
#   in_type   <- `U.IN_TYPE`      — comptime, from the function's signature
#   out_type  <- `U.OUT_TYPE`     — comptime, from the function's signature
#
# So the SQL door RESTATES NOTHING. There is no argument at this call site
# through which a second dtype (or a second name) could be written, which is
# strictly stronger than the Python bridge's position — `register_python_udf`
# takes both tags as arguments because a CPython callable has no signature to
# read, and relies on the Python bridge being their single writer. Here the compiler
# holds it. Full reasoning: `komira_plan_expr/declared_scalar_udf.mojo`.
#
# ⚠ AND THAT IS WHY THIS MODULE NEVER NAMES `ScalarUdf`. It is generic over
# `DeclaredScalarUdf`, a `komira_plan_expr` trait; the concrete engine type is
# supplied by the caller. `komira_sql` imports no engine package, and this
# file keeps it that way.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.declared_scalar_udf import DeclaredScalarUdf

from komira_sql.sql_ast import (
    SQLNAME_AGG_FASTPATH,
    SQLNAME_AGG_STATISTICAL,
    SQLNAME_FREE,
    SQLNAME_GRAMMAR_FORM,
    SQLNAME_RESERVED_WORD,
    SQLNAME_WINDOW_RANKING,
    sql_name_claimed_by_grammar,
)
from komira_sql.sql_fn_table import sql_scalar_fn_spec


def refuse_undeclarable_udf_name(imm display: String) raises:
    """★ THE NAMES SQL CANNOT CARRY — ONE implementation, TWO callers.

    `SqlUdfCatalog.declare` calls it, and so does the C ABI's SQL UDF
    declaration entry point, which has to
    make the SAME judgement at a DIFFERENT moment: the Python tier's SQL
    declaration is recorded on the session and replayed into a FRESH catalog on
    every execution door, so the only place the user's own call site is
    still on the stack is the declaring call — and that is where a refusal has
    to land.

    ⛔ IT IS EXTRACTED RATHER THAN RESTATED. Two copies of "which names SQL
    refuses" is the two-places-to-disagree shape this whole module is written
    against: the copy in the replay path would be the one nobody edits, and it
    would start ADMITTING a name the binder shadows — i.e. silently running a
    builtin in place of the user's function, which is refusal (2)'s exact
    failure mode wearing the bug it was written to prevent.

    ⚠ IT TAKES THE DISPLAY NAME AND LOWER-FOLDS INTERNALLY, so no caller can
    pass a pre-folded key and defeat the diagnostics — every message quotes the
    name AS REGISTERED, for the reason `SqlUdfEntry.display_name` states.

    Raises on: an EMPTY name; ANY name `sql_name_claimed_by_grammar` reports as
    claimed — which is every namespace that can take an identifier away from
    the general `name(args...)` call branch, and is deliberately NOT enumerated
    here; and the name of a built-in scalar function THAT ACTUALLY LOWERS.
    Returns normally otherwise; it makes no other judgement and in particular
    says NOTHING about whether the UDF is registered.

    ⛔ THAT SENTENCE NAMES THE PREDICATE AND DOES NOT ENUMERATE ITS ANSWERS.
    A prose list of what a delegated predicate answers is a second writing of
    that predicate with nobody to check it, which is the defect this whole
    module is written against, and it goes stale as soon as a namespace joins.

    ⛔⛔ THE THIRD TEST ASKS `spec.lowers_to_a_node`, NOT `spec.kind !=
    FNK_NONE`, AND THE DIFFERENCE IS EVERY REFUSAL ROW. `sql_scalar_fn_spec` returns a
    row for two DIFFERENT reasons: because the binder lowers the name to an
    `Expr`, or because the name is a real DuckDB function this engine
    deliberately REFUSES to lower (`FNK_REFUSED`, which is kind 7 — not 0).
    Comparing against the absent-row sentinel folds those two together and
    refuses every refusal row, telling the user their name is taken by a
    built-in scalar function that does not exist.

    ⭐ AND THE REFUSAL ROWS ARE THE CASE WHERE A UDF MATTERS MOST. A row that
    says "this engine will not approximate `geomean`" is precisely the
    situation in which a user wants to supply `geomean` themselves;
    declining to implement it AND declining to let them implement it leaves
    them with nothing. `_bind_scalar_call` resolves a declared UDF ahead of a
    refusal row for the same reason, so the declaration this admits is
    reachable rather than an unreachable row in a lookup table.

    ⚠ WHAT THE GUARD IS FOR, restated so the next edit keeps it: it prevents a
    user's UDF from being SILENTLY SHADOWED by something the binder
    resolves first. Only a row that becomes a node can do that. The predicate
    must therefore track "does this row produce an `Expr`", which is a fact
    about the ROW — so the table states it (`SqlFnSpec.lowers_to_a_node`,
    written by the constructor) instead of this file re-deriving it from a kind
    number it would have to keep in sync with every kind added elsewhere.
    """
    if display.byte_length() == 0:
        raise Error(
            "SQL UDF declare error: this UDF was registered with an EMPTY"
            " name, so no SQL text can name it. An empty name means a LIVE"
            " CLOSURE (usable in-process, refused at the wire); pass a name"
            " to `register_scalar` to make it callable from SQL."
        )
    var key = display.lower()

    # ⛔⛔ ONE QUESTION, ASKED OF EVERY NAMESPACE AT ONCE — see
    # `sql_name_claimed_by_grammar`. `sql_call_is_aggregate` alone is ONE
    # HALF of the aggregate vocabulary: the statistical aggregates that ride
    # the general `SX_CALL` grammar. The other half — `sum` `count` `min`
    # `max` `avg` `mean` — is claimed by the PARSER, in a table this file
    # cannot see, and asking only the first half ACCEPTS those names as UDF
    # names that the built-in aggregate then SILENTLY REPLACES at every call
    # site. ⚠ THAT SET GROWS: `mean` is in it as DuckDB's declared alias of
    # `avg`, and an ALIAS is claimed exactly as hard as a canonical name.
    var claim = sql_name_claimed_by_grammar(key)

    if claim == SQLNAME_AGG_FASTPATH:
        # ⭐ THE WORST OF THE FOUR, AND WHY IT GETS ITS OWN SENTENCE. These
        # five never reach an error at all: the parser routes `sum(x)` to
        # SX_AGG before the scalar-call branch exists, so the user's
        # function is not shadowed by a diagnostic — it is replaced by a
        # working built-in that returns ONE row where theirs returned N.
        raise Error(
            "SQL UDF declare error: '" + display + "' is a built-in"
            " AGGREGATE, and the SQL parser turns `" + display + "(x)` into an"
            " aggregate BEFORE it looks at any function name — so this"
            " declaration would never be reached and your function would be"
            " SILENTLY REPLACED by the built-in at every call site, with no"
            " error and a different row count. Register it under another name."
        )

    if claim == SQLNAME_AGG_STATISTICAL:
        raise Error(
            "SQL UDF declare error: '" + display + "' is the name of a"
            " built-in AGGREGATE, which the binder refuses in scalar"
            " position before it looks at any UDF. Declaring it would make"
            " every `" + display + "(x)` report an aggregate error about a"
            " function you did not call. Register it under another name."
        )

    if claim == SQLNAME_WINDOW_RANKING:
        raise Error(
            "SQL UDF declare error: '" + display + "' is a built-in ranking"
            " WINDOW function. The parser claims the name to require `"
            + display + "() OVER (...)`, so every `" + display + "(x)` would"
            " be a syntax error about arguments you did pass, and this"
            " declaration would never be reached. Register it under another"
            " name."
        )

    if claim == SQLNAME_GRAMMAR_FORM:
        raise Error(
            "SQL UDF declare error: '" + display + "' is SQL GRAMMAR, not a"
            " function name — the parser takes `" + display + "(` for a"
            " different construct entirely (CASE ... WHEN, EXTRACT(<field>"
            " FROM ...), CAST(<expr> AS <type>), TRY_CAST(<expr> AS <type>)),"
            " so every `" + display + "(x)` would be a syntax error about a"
            " form you did not write. Register it under another name."
        )

    if claim == SQLNAME_RESERVED_WORD:
        # ⛔⛔ THE FIFTH NAMESPACE. The message says SILENT for the same reason
        # the fast-path aggregate one does — `not(x)` comes back as the NOT
        # operator over the user's column with no diagnostic whatsoever —
        # and folding these into the grammar-form sentence ("a syntax error
        # about a form you did not write") would state something FALSE for
        # exactly the one that matters most.
        #
        # ⚠ AND IT SAYS SILENT FOR `not` ONLY, WHICH IS A MEASUREMENT AND NOT A
        # HEDGE. `distinct(x)` becomes `SELECT DISTINCT (x)`, whose plan is
        # DISTINCT -> PROJECT -> SCAN — a shape the DISTINCT executor may
        # decline — so it surfaces an error ABOUT DISTINCT rather than a wrong
        # answer. An error message is an API surface; a sentence promising
        # silence for a case that errors is the same defect one altitude up.
        raise Error(
            "SQL UDF declare error: '" + display + "' is a RESERVED WORD in"
            " SQL, which the parser reads before any function name exists — so"
            " `" + display + "(x)` never reaches a function lookup and this"
            " declaration would never be resolved. Depending on the word it is"
            " a syntax error about a construct you did not write (`exists(x)`"
            " wants a subquery), or a DIFFERENT QUERY entirely (`distinct(x)`"
            " is `SELECT DISTINCT (x)`, which the engine answers as a DISTINCT"
            " or refuses as one), or — worst — SILENT: `not(x)` parses as the"
            " NOT operator applied to your column, with no error at all."
            " Register it under another name."
        )

    if claim != SQLNAME_FREE:
        # ⛔⛔ THE CATCH-ALL. A namespace added to
        # `sql_name_claimed_by_grammar` and NOT given an arm above still
        # REFUSES here — with a worse message, never with a silent admission.
        # Omission degrades the diagnostic; it cannot admit a claimed name.
        raise Error(
            "SQL UDF declare error: '" + display + "' is claimed by the SQL"
            " grammar (claim class " + String(Int(claim)) + "), so a UDF"
            " declared under it could never be resolved. Register it under"
            " another name."
        )

    var builtin = sql_scalar_fn_spec(key)
    if builtin.lowers_to_a_node:
        # ⛔ `lowers_to_a_node`, NEVER `kind != FNK_NONE`. A row exists for two
        # unrelated reasons and only ONE of them shadows anything; see this
        # function's docstring for the long version of that sentence.
        raise Error(
            "SQL UDF declare error: '" + display + "' is a built-in scalar"
            " function THE BINDER LOWERS, and it resolves builtins BEFORE"
            " UDFs — so this declaration would never be reached and every `"
            + display + "(x)` would silently run the builtin instead of"
            " your function. Register it under another name."
            " ⚠ This is NOT the same as a name this engine merely declines to"
            " serve: a REFUSED name (one `SELECT " + display + "(x)` reports"
            " with a measured reason) lowers to nothing, shadows nothing, and"
            " IS declarable as a UDF."
        )


@fieldwise_init
struct SqlUdfEntry(Copyable, Movable):
    """One resolvable UDF: the four facts the binder needs to build the node.

    ⚠ EVERY FIELD IS A COPY OF SOMETHING DERIVED, NOT A DECLARATION. The only
    writer is `SqlUdfCatalog.declare_udf`, which reads all four off a
    `DeclaredScalarUdf` and is handed none of them.
    """

    var name: String
    """Lower-folded, because the parser lower-folds the call it must match."""

    var display_name: String
    """The name AS REGISTERED. ⚠ Kept separately and used in every diagnostic:
    a user who registered `Affine` and is told the engine knows no
    `affine` has been handed a false statement about their own program."""

    var handle: Int
    """The generation-carrying registry handle. PROCESS-LOCAL — see
    `UdfCallData.handle`; this is why the SQL door binds and executes in ONE
    process and does not go near the wire."""

    var in_type: ArrowType
    var out_type: ArrowType


struct SqlUdfCatalog(Copyable, Movable):
    """The set of UDFs a SQL query may call, by name.

    Held BY `SqlCatalog`, so the binder — which already threads a catalog
    through every scalar-expression call — needs no new parameter anywhere.
    """

    var _entries: List[SqlUdfEntry]

    def __init__(out self):
        self._entries = List[SqlUdfEntry]()

    def num_declared(self) -> Int:
        """How many UDFs are callable from SQL through this catalog.

        ⚠ NOT `__len__`. A `SqlUdfCatalog` is not a sequence — it is a name
        lookup — and giving it `len()` invites `for x in catalog`, which is not
        a thing it supports. The explicit verb also reads correctly at the one
        place that matters: `num_declared() == 0` after a REFUSED declaration.
        """
        return len(self._entries)

    def declare[U: DeclaredScalarUdf](mut self, imm udf: U) raises:
        """★ EXPOSE an already-registered UDF to SQL under its own name.

        ⛔ NO NAME ARGUMENT AND NO DTYPE ARGUMENT — see this file's header. All
        four facts are read off `udf` / `U`.

        REFUSES a name for one of THREE FAMILIES of reason, each because the
        alternative is a wrong answer that looks like a working program. ⚠ The
        third family is a SET of namespaces, not one table — see
        `refuse_undeclarable_udf_name`, which is the single implementation and
        the only place that list should ever be read from:

        1. AN EMPTY NAME. `register_scalar(String(""))` is legal — it mints a
           LIVE CLOSURE, usable in-process and refused at the wire — but no SQL
           text can name it, so declaring one would put an unreachable row in a
           lookup table.

        2. A NAME A BUILTIN ALREADY CLAIMS **AND LOWERS**. `sql_scalar_fn_spec`
           is consulted BEFORE this catalog by the binder, so a UDF called
           `upper` would sit in this list and never resolve — the user's
           function silently replaced by the builtin at every call site.
           Refusing at DECLARATION makes the shadowing a diagnosable event at
           the line that caused it, and makes the binder's ladder ORDER
           unobservable rather than load-bearing.

           ⛔ "HAS A ROW" IS NOT "CLAIMS THE NAME". An `FNK_REFUSED` row has no
           `op`, builds no `Expr` and shadows nothing — `geomean`, `wavg`,
           `date_add`, `json`, `list_sum`, `user`, `pg_typeof` and the rest of
           the refusal rows. Those names ARE declarable, and the binder
           resolves a declared UDF ahead of the refusal. Refusing them would be
           a false statement about the user's own program AND the removal of
           their one remedy for a function this engine chose not to serve.

        3. A NAME **ANY** OTHER NAMESPACE ALREADY CLAIMS — the list below is
           illustrative, not a list to trust from here.
           `refuse_undeclarable_udf_name` asks
           `sql_name_claimed_by_grammar`, ONE predicate over all of them:

             * the STATISTICAL aggregates (`median`, `stddev`, `corr`, ...).
               `_bind_scalar_call` refuses an aggregate name in scalar position
               before it consults anything, so a UDF named `median` could only
               ever produce "aggregate function 'median' is not allowed in this
               position" — an error about a function the user did not call.

             * ⛔⛔ the FAST-PATH aggregates — `sum` `count` `min` `max` `avg`,
               and `avg`'s declared DuckDB alias `mean`. These are the worst
               of the four: the PARSER routes `sum(x)` to `SX_AGG` before the
               call branch exists, so there is no error at all — the user's
               function is silently replaced by a working built-in that returns
               one row where theirs returned N. The two aggregate sets are
               DISJOINT, so a door that consults only one of them admits the
               other.

             * the RANKING window functions (`rank`, `row_number`,
               `dense_rank`, and `dense_rank`'s undeclared synonym
               `rank_dense`), which the parser claims to demand `() OVER (...)`.

             * the GRAMMAR FORMS `case` and `extract`, which are not functions
               and have no row in any table.

        RE-DECLARING A NAME REPLACES IT. That is deliberate and it is the one
        place this catalog's behaviour differs from the REGISTRY's, which
        "deliberately does not deduplicate by name" because two registrations
        are two instances. A lookup keyed on a name has to be a FUNCTION of
        that name — two rows spelled `affine` would make `SELECT affine(a)`
        resolve by list order — so the last declaration wins, exactly as
        `CREATE OR REPLACE FUNCTION` does. The superseded INSTANCE is untouched
        in the registry and any plan already holding its handle still runs.
        """
        var display = udf.name()
        refuse_undeclarable_udf_name(display)
        var key = display.lower()

        for i in range(len(self._entries)):
            if self._entries[i].name == key:
                self._entries[i] = SqlUdfEntry(
                    key, display^, udf.handle(), U.IN_TYPE, U.OUT_TYPE
                )
                return
        self._entries.append(
            SqlUdfEntry(
                key.copy(), display^, udf.handle(), U.IN_TYPE, U.OUT_TYPE
            )
        )

    def _find(self, name: String) -> Int:
        var target = name.lower()
        for i in range(len(self._entries)):
            if self._entries[i].name == target:
                return i
        return -1

    def has(self, name: String) -> Bool:
        return self._find(name) >= 0

    def resolve(self, name: String) -> Optional[SqlUdfEntry]:
        """The entry for `name`, or `None`.

        ⚠ NON-RAISING AND `Optional`-RETURNING, DELIBERATELY. The binder asks
        this question on the path where a name has NO builtin row, i.e. on the
        way to the unknown-function error; a raise here would replace that
        error's message with this one's.
        """
        var idx = self._find(name)
        if idx < 0:
            return None
        return Optional(self._entries[idx].copy())

    def declared_names(self) -> List[String]:
        """Every declared name, AS REGISTERED, in declaration order.

        For the unknown-function diagnostic: a user who misspelled
        `affine` is told what IS callable rather than only what is not.
        """
        var out = List[String]()
        for i in range(len(self._entries)):
            out.append(self._entries[i].display_name.copy())
        return out^
