# =============================================================================
# komira_sql/sql_parser.mojo
#   Hand-written recursive-descent parser for the analytical SQL frontend.
# =============================================================================
#
# Consumes the `List[Token]` from `sql_token.tokenize` and produces a
# `SelectStmt` AST (`sql_ast.mojo`). Precedence-climbing expression grammar:
#
#   query   := SELECT select_list FROM table [WHERE pred] [GROUP BY cols]
#              [ORDER BY keys] [LIMIT int] [;]
#   expr    := or_expr
#   or_expr := and_expr (OR and_expr)*
#   and_expr:= cmp_expr (AND cmp_expr)*
#   cmp_expr:= add_expr ((= <> < <= > >=) add_expr)?
#   add_expr:= mul_expr ((+ -) mul_expr)*
#   mul_expr:= unary ((* /) unary)*
#   unary   := ('-')? primary          # a negated literal folds to a literal
#   primary := INT | FLOAT | STRING | agg '(' (expr|'*') ')' | col | '(' expr ')'
#   col     := IDENT ('.' IDENT)?      # qualifier kept on the node
#
# No parser-generator dependency. Every unexpected token raises a clean
# `Error` (never a crash) — the negative-corpus contract.
# =============================================================================

from std.builtin.swap import swap

from komira_collections.slab import Slab

from .sql_token import (
    Token,
    TK_EOF, TK_IDENT, TK_INT, TK_FLOAT, TK_STRING, TK_LPAREN, TK_RPAREN,
    TK_COMMA, TK_SEMI, TK_STAR, TK_DOT, TK_PLUS, TK_MINUS, TK_SLASH,
    TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE, TK_DCOLON, TK_DSLASH, TK_PERCENT,
    TK_CARET, TK_CARET_AT, TK_AT, TK_DPIPE, TK_LIKE_SYM, TK_TILDE, TK_NTILDE,
)
from .sql_fn_table import CAST_DESUGAR_NAME as _CAST_DESUGAR_NAME, TRY_CAST_DESUGAR_NAME as _TRY_CAST_DESUGAR_NAME
from .sql_fn_table import POSITION_IN_DESUGAR_NAME as _POSITION_IN_DESUGAR_NAME
from .sql_ast import (
    SqlExpr, SelectItem, OrderKey, SelectStmt, FromRelation, CteDef, SubqueryDef,
    JoinClause, SqlWindowData, SqlStatement, TvfOptions, FROM_LESS_RELATION,
    TVF_PARQUET, TVF_CSV, TVF_JSON, TVF_AVRO,
    SX_COLUMN, SX_STAR, SX_UNARY, SX_BOOL, SX_AGG, SX_CALL, SX_BINARY,
    SXUN_NOT, SXUN_IS_NULL, SXUN_IS_NOT_NULL, SXUN_NEGATE, SXUN_ABS, SXLIKE_LIKE, SXLIKE_ILIKE,
    JK_CROSS, JK_LEFT, JK_RIGHT, JK_FULL, JK_SEMI, JK_ANTI,
    SUBQ_SCALAR, SUBQ_EXISTS, SUBQ_NOT_EXISTS, SUBQ_IN, SUBQ_NOT_IN, SUBQ_DERIVED,
    SUBQ_UNION_ALL,
    STMT_QUERY, STMT_COPY, STMT_CREATE_TABLE_AS,
    SXOP_EQ, SXOP_NE, SXOP_LT, SXOP_LE, SXOP_GT, SXOP_GE,
    SXOP_AND, SXOP_OR, SXOP_ADD, SXOP_SUB, SXOP_MUL, SXOP_DIV, SXOP_IDIV, SXOP_MOD,
    SXOP_POW, SXOP_CONCAT, SXOP_STARTS_WITH,
    SXAGG_SUM, SXAGG_COUNT, SXAGG_MIN, SXAGG_MAX, SXAGG_AVG,
    SXWIN_ROW_NUMBER, SXWIN_RANK, SXWIN_DENSE_RANK,
    SXWIN_SUM, SXWIN_COUNT, SXWIN_MIN, SXWIN_MAX, SXWIN_AVG,
    SXWIN_LAG, SXWIN_LEAD, SXWIN_FIRST_VALUE, SXWIN_LAST_VALUE, SXWIN_NTH_VALUE,
    SXWIN_PERCENT_RANK, SXWIN_CUME_DIST, SXWIN_NTILE,
    SX_INT, SX_FLOAT, SX_STRING, SX_DATE,
    SXFRAME_ROWS, SXFRAME_RANGE,
    SXFRAME_UNBOUNDED_PRECEDING, SXFRAME_PRECEDING, SXFRAME_CURRENT_ROW,
    SXFRAME_FOLLOWING, SXFRAME_UNBOUNDED_FOLLOWING,
    sql_agg_code, sql_win_ranking_code, sql_win_value_code, sql_win_dist_code,
    sql_call_is_aggregate,
)
# ⚠ THE WRITE VOCABULARY IS `komira_arrow`-OWNED, NOT `sql_ast`-OWNED: it
# crosses `komira.plan.v1.WirePlanEnvelope.write_target`, and a
# wire vocabulary declared outside the codec's `komira_arrow` import closure is
# one the plan-wire coverage lint structurally cannot see.
from komira_arrow.write_target import (
    WFMT_PARQUET, WFMT_CSV, WFMT_JSONL,
    WCOMP_SNAPPY, WCOMP_UNCOMPRESSED, WCOMP_ZSTD, WCOMP_GZIP, WCOMP_LZ4,
    write_format_name, write_codec_name, write_target_supported,
)


struct _Parser(Movable):
    var tokens: List[Token]
    var pos: Int
    # Flat side-table of every parsed subquery body — scalar `(SELECT ...)`,
    # predicate subqueries (`[NOT] EXISTS`, `x [NOT] IN`), and derived tables
    # (`FROM (SELECT ...) a`). Each is a `SubqueryDef` (body + kind + metadata). A
    # SX_SUBQUERY `SqlExpr` stores only its INDEX into this table (not the body),
    # so the `SqlExpr` AST never owns a `SelectStmt` (avoids the recursive-
    # destructor deadlock in the Mojo AOT compiler). Attached to the top-level
    # `SelectStmt` in `parse()`.
    var subqueries: Slab[SubqueryDef]
    # How many UNALIASED derived tables the CURRENT SELECT level has named so
    # far — DuckDB calls them `unnamed_subquery`, `unnamed_subquery2`, ...,
    # counting per FROM clause and restarting in every nested SELECT (measured
    # v1.5.3). Saved / reset / restored by `_parse_select_stmt`; see
    # `_parse_derived_table`.
    var unnamed_derived: Int

    def __init__(out self, var tokens: List[Token]):
        self.tokens = tokens^
        self.pos = 0
        self.subqueries = Slab[SubqueryDef]()
        self.unnamed_derived = 0

    @always_inline
    def _kind(self) -> UInt8:
        return self.tokens[self.pos].kind

    @always_inline
    def _is_kw(self, word: String) -> Bool:
        return self.tokens[self.pos].kind == TK_IDENT and self.tokens[self.pos].text == word

    @always_inline
    def _advance(mut self):
        if self.pos + 1 < len(self.tokens):
            self.pos += 1

    def _expect(mut self, kind: UInt8, what: String) raises:
        if self._kind() != kind:
            raise Error("SQL syntax error: expected " + what)
        self._advance()

    def _expect_kw(mut self, word: String) raises:
        if not self._is_kw(word):
            raise Error("SQL syntax error: expected keyword '" + word + "'")
        self._advance()

    # -------------------------------------------------------------------------
    # Top-level statement (dispatch beyond SELECT — COPY / CTAS)
    # -------------------------------------------------------------------------
    def parse(mut self) raises -> SqlStatement:
        """Top-level statement: dispatch on the first keyword into `COPY` /
        `CREATE ... AS ...` / a plain query (`WITH? SELECT`), then finalize
        (trailing `;`/EOF + attach the subquery side-table). Every kind is a thin
        wrapper over a source `SelectStmt` parsed by the SAME re-entrant helpers a
        top-level query uses, so the COPY/CTAS source gets the entire SELECT
        grammar and can never drift from the query path."""
        if self._is_kw("copy"):
            var st = self._parse_copy()
            self._finalize(st)
            return st^
        if self._is_kw("create"):
            var st = self._parse_create_table_as()
            self._finalize(st)
            return st^
        # else: a plain query (WITH... / SELECT...).
        var query = self._parse_query_body()
        var st = SqlStatement(STMT_QUERY, query^)
        self._finalize(st)
        return st^

    def _finalize(mut self, mut st: SqlStatement) raises:
        """Consume the optional trailing `;`, assert EOF, and attach every parsed
        subquery body (CTE bodies + the source SELECT + nested subqueries) as the
        source query's flat side-table. `SX_SUBQUERY` nodes index into it.
        Done LAST (the final use of `self.subqueries`) so the field-move leaves no
        live partial-moved `self`."""
        if self._kind() == TK_SEMI:
            self._advance()
        if self._kind() != TK_EOF:
            raise Error("SQL syntax error: unexpected trailing tokens after query")
        var subs = Slab[SubqueryDef]()
        swap(subs, self.subqueries)
        st.query.subqueries = subs^

    def _parse_query_body(mut self) raises -> SelectStmt:
        """Parse `WITH? SELECT ...` into a `SelectStmt` (WITHOUT the trailing
        `;`/EOF or the subquery-table attach — those belong to `_finalize`). This
        is the shared query primitive: the top-level query, a `COPY (…)` source,
        and a `CREATE TABLE … AS …` body all reuse it."""
        # WITH name AS (<select>) [, name2 AS (<select>)]*  — parsed first so a
        # `WITH ...` query does not die at `_expect_kw("select")`.
        var ctes = Slab[CteDef]()
        if self._is_kw("with"):
            ctes = self._parse_with_clause()
        var stmt = self._parse_select_stmt()
        self._parse_set_operator_tail(stmt)
        stmt.ctes = ctes^
        return stmt^

    def _parse_set_operator_tail(mut self, mut lhs: SelectStmt) raises:
        """★ UNION ALL. `<select> UNION ALL <select>`.

        Without a set-operator production `_parse_select_stmt` would return
        after the first SELECT and `_finalize` would report the `UNION` keyword
        as "unexpected trailing tokens after query" — a message that names the
        symptom and not the missing clause.

        ⭐ THE OPERATOR IS **NOT** A SEPARATE ENGINE CAPABILITY. `PLAN_UNION`
        (tag 12) and `LogicalPlan.union` serve the untyped-Mojo door too; this
        production is the SQL spelling of that node.

        ⛔ BARE `UNION` IS REFUSED BY NAME AND MUST STAY REFUSED. `UNION`
        without `ALL` DEDUPLICATES, and `PLAN_UNION` does not: binding it to
        the same node would silently return duplicate rows for a query whose
        whole point is that it does not. The refusal names the rewrite
        (`SELECT DISTINCT * FROM (a UNION ALL b)`) rather than the node.

        ⛔ `INTERSECT` / `EXCEPT` likewise — there is no set-difference or
        set-intersection operator in this engine, and lowering either to a
        UNION answers a strict superset of the right rows.

        ⚠ IT LOOPS, so `A UNION ALL B UNION ALL C` is three branches rather
        than a syntax error at the second `UNION`. Each branch is parsed by
        `_parse_select_stmt` — the SAME helper the first branch used — so a
        branch gets the whole SELECT grammar and cannot drift from it.
        """
        var last = -1
        while (
            self._is_kw("union") or self._is_kw("intersect") or self._is_kw("except")
        ):
            if self._is_kw("intersect") or self._is_kw("except"):
                var word = String(self.tokens[self.pos].text).upper()
                raise Error(
                    "SQL not supported: the " + word + " set operator. This"
                    " engine's only set operator is UNION ALL (the PLAN_UNION"
                    " node, which CONCATENATES branches); " + word + " needs a"
                    " set-difference / set-intersection primitive that no plan"
                    " node here computes, and lowering it to a concatenation"
                    " would answer a strict SUPERSET of the right rows with a"
                    " success code. Express it as a SEMI / ANTI join"
                    " (`WHERE [NOT] EXISTS (...)`), which this engine does"
                    " serve."
                )
            self._advance()  # 'union'
            if not self._is_kw("all"):
                raise Error(
                    "SQL not supported: bare UNION. UNION without ALL"
                    " DEDUPLICATES its result and this engine's PLAN_UNION node"
                    " CONCATENATES — binding the two to one node would return"
                    " duplicate rows out of the one query written to exclude"
                    " them, with no diagnostic. Write UNION ALL, or"
                    " `SELECT DISTINCT * FROM (<a> UNION ALL <b>) u` for the"
                    " deduplicating form."
                )
            self._advance()  # 'all'
            var rhs = self._parse_select_stmt()
            # ⚠ APPENDED **AFTER** THE BRANCH IS PARSED, so a nested subquery
            # inside the branch takes a LOWER index than the branch itself —
            # the same inner-before-outer ordering every other producer here
            # maintains, which is what lets `_bind_query` pre-bind by index.
            var idx = len(self.subqueries)
            self.subqueries.append(SubqueryDef(rhs^, SUBQ_UNION_ALL, String(""), String("")))
            if last < 0:
                lhs.union_all_idx = idx
            else:
                # Chain: hang each further branch off the PREVIOUS one, so the
                # binder walks a single-linked list from the root and never has
                # to recurse through a branch body.
                self.subqueries[last].body.union_all_idx = idx
            last = idx

    def _parse_copy(mut self) raises -> SqlStatement:
        """Parse `COPY <source> TO '<path>' [ (<opt> [, <opt>]*) ]`.
        `<source>` is either a bare table name (synthesized to `SELECT * FROM
        <table>`) or a parenthesized query `(WITH? SELECT …)`. Binds to a
        STMT_COPY statement the exec layer writes through the EXISTING
        `SinkVariant` file arms (`sql_exec`) — no new writer."""
        self._expect_kw("copy")
        var source: SelectStmt
        if self._kind() == TK_LPAREN:
            self._advance()  # '('
            source = self._parse_query_body()
            self._expect(TK_RPAREN, "')' to close the COPY source query")
        else:
            if self._kind() != TK_IDENT:
                raise Error("SQL syntax error: COPY expects a table name or `(SELECT ...)`")
            var tname = String(self.tokens[self.pos].text)
            self._advance()
            if self._kind() == TK_DOT:  # optional schema qualifier s.t
                self._advance()
                if self._kind() != TK_IDENT:
                    raise Error("SQL syntax error: expected identifier after '.'")
                tname = String(self.tokens[self.pos].text)
                self._advance()
            source = _select_star_from(tname)
        self._expect_kw("to")
        if self._kind() != TK_STRING:
            raise Error("SQL syntax error: COPY ... TO expects a string path")
        var dest = String(self.tokens[self.pos].text)
        self._advance()
        var fmt = WFMT_PARQUET
        var codec = WCOMP_SNAPPY
        if self._kind() == TK_LPAREN:
            var opts = self._parse_copy_options()
            fmt = opts[0]
            codec = opts[1]
        return SqlStatement(STMT_COPY, source^, dest, String(""), fmt, codec, False)

    def _parse_copy_options(mut self) raises -> Tuple[UInt8, UInt8]:
        """Parse the parenthesized COPY option list -> (fmt, codec).

        Grammar (the subset the DuckDB parity corpus writes, and no more):

            FORMAT <parquet|csv|json>       value: quoted OR bareword, lower-folded
            COMPRESSION <codec-word>
            COMPRESSION_LEVEL <int>
            HEADER <true|false>             csv only
            ARRAY <true|false>              json only

        TWO PASSES, deliberately. Every option is COLLECTED first and validated
        only once the list is closed, because the meaning of HEADER / ARRAY /
        COMPRESSION_LEVEL depends on the FORMAT and DuckDB does not require
        FORMAT to come first. Validating in stream order would make
        `(HEADER true, FORMAT 'csv')` behave differently from
        `(FORMAT 'csv', HEADER true)`.

        AN OPTION IS NEVER ACCEPTED-AND-IGNORED. An ignored option produces a
        file that is not what the SQL asked for, and no row-count or
        wall-clock gate can see that. So an option we cannot honour — `HEADER
        false` (our CSV sink always emits the header row), `ARRAY true` (the
        JSONL sink is newline-delimited by construction), a COMPRESSION_LEVEL
        other than the one the wired sink is parameterized on — is a clean
        raise naming what we would have done instead."""
        self._expect(TK_LPAREN, "'(' to open COPY options")
        # --- pass 1: collect ---------------------------------------------------
        # No FORMAT clause => parquet (DuckDB would infer from the extension; the
        # corpus always states it, and inferring silently is exactly the
        # accepted-and-ignored failure mode this parser refuses).
        var fmt = WFMT_PARQUET
        var codec_word = String("")
        var saw_codec = False
        var level = 0
        var saw_level = False
        var header = True
        var saw_header = False
        var array_opt = False
        var saw_array = False
        while True:
            if self._kind() != TK_IDENT:
                raise Error(
                    "SQL syntax error: expected a COPY option (FORMAT / COMPRESSION /"
                    " COMPRESSION_LEVEL / HEADER / ARRAY)"
                )
            var opt = String(self.tokens[self.pos].text)
            self._advance()
            if opt == "format":
                fmt = _format_word(self._copy_option_word())
            elif opt == "compression" or opt == "codec":
                codec_word = self._copy_option_word()
                saw_codec = True
            elif opt == "compression_level":
                level = self._copy_option_int()
                saw_level = True
            elif opt == "header":
                header = self._copy_option_bool(String("HEADER"))
                saw_header = True
            elif opt == "array":
                array_opt = self._copy_option_bool(String("ARRAY"))
                saw_array = True
            else:
                raise Error(
                    "SQL not supported: COPY option '" + opt + "' (FORMAT /"
                    " COMPRESSION / COMPRESSION_LEVEL / HEADER / ARRAY)"
                )
            if self._kind() == TK_COMMA:
                self._advance()
                continue
            break
        self._expect(TK_RPAREN, "')' to close COPY options")
        # --- pass 2: validate, now that FORMAT is known ------------------------
        # Default codec is per-format: parquet's is snappy (DuckDB's default page
        # codec), csv/json have no container so theirs is "no compression".
        var codec = WCOMP_UNCOMPRESSED if fmt != WFMT_PARQUET else WCOMP_SNAPPY
        if saw_codec:
            codec = _codec_word(codec_word)
        if not write_target_supported(fmt, codec):
            raise Error(
                "SQL not supported: COPY ... (FORMAT '" + write_format_name(fmt)
                + "', COMPRESSION '" + write_codec_name(codec)
                + "') — no wired write sink for that pair"
            )
        if saw_header:
            if fmt != WFMT_CSV:
                raise Error(
                    "SQL not supported: COPY option HEADER applies to FORMAT 'csv',"
                    " not '" + write_format_name(fmt) + "'"
                )
            if not header:
                raise Error(
                    "SQL not supported: COPY ... (HEADER false) — the CSV sink"
                    " always emits the header row; suppressing it would write a"
                    " file the SQL did not ask for"
                )
        if saw_array:
            if fmt != WFMT_JSONL:
                raise Error(
                    "SQL not supported: COPY option ARRAY applies to FORMAT 'json',"
                    " not '" + write_format_name(fmt) + "'"
                )
            if array_opt:
                raise Error(
                    "SQL not supported: COPY ... (ARRAY true) — the JSONL sink"
                    " writes newline-delimited objects (DuckDB's ARRAY false); it"
                    " cannot emit a single JSON array"
                )
        if saw_level:
            var want = _codec_fixed_level(codec)
            if want < 0:
                raise Error(
                    "SQL not supported: COPY ... (COMPRESSION_LEVEL "
                    + String(level) + ") — codec '" + write_codec_name(codec)
                    + "' takes no level"
                )
            if level != want:
                raise Error(
                    "SQL not supported: COPY ... (COMPRESSION '"
                    + write_codec_name(codec) + "', COMPRESSION_LEVEL "
                    + String(level) + ") — the wired sink is parameterized on"
                    " level " + String(want) + "; writing a different level"
                    " silently would not be the file the SQL asked for"
                )
        return (fmt, codec)

    def _copy_option_word(mut self) raises -> String:
        """Read a COPY option VALUE — a quoted string ('parquet') or a bareword
        (parquet) — lower-folded, and advance past it."""
        if self._kind() == TK_STRING:
            var s = String(self.tokens[self.pos].text).lower()
            self._advance()
            return s
        if self._kind() == TK_IDENT:
            var s = String(self.tokens[self.pos].text)  # already lower-folded
            self._advance()
            return s
        raise Error("SQL syntax error: expected a COPY option value")

    def _small_int_tok(
        self,
        what: String,
        duck: String = (
            "DuckDB v1.5.3 raises a Conversion Error: the value is out of"
            " range for the destination type INT64"
        ),
    ) raises -> Int64:
        """The current TK_INT token's value, REFUSED BY NAME when the literal is
        past BIGINT. `tokenize` keeps such a
        literal's DIGITS in `text` and only its WRAPPED bits in `int_val`, so
        a slot that read `int_val` directly would answer with the wrap:
        `LIMIT 18446744073709551616` would return 0 rows, `LIMIT 18446744073709551617`
        one, `lag(v, 1, 18446744073709551615)` would default to -1. DuckDB 1.5.3
        raises `Conversion Error: Type INT128 with value <n> can't be cast
        because the value is out of range for the destination type INT64` for
        every one of these slots (MEASURED: LIMIT, OFFSET, lag/lead offset and
        default, ntile, nth_value, a ROWS frame bound)."""
        ref t = self.tokens[self.pos]
        if t.text.byte_length() > 0:
            raise Error(
                "SQL bind error: the " + what + " " + t.text + " is out of range"
                " for BIGINT (" + duck + ")"
            )
        return t.int_val

    def _copy_option_int(mut self) raises -> Int:
        """Read an INTEGER COPY option value (`COMPRESSION_LEVEL 3`)."""
        if self._kind() != TK_INT:
            raise Error("SQL syntax error: expected an integer COPY option value")
        var v = Int(self._small_int_tok("COPY option value"))
        self._advance()
        return v

    def _copy_option_bool(mut self, opt: String) raises -> Bool:
        """Read a BOOLEAN COPY option value (`HEADER true` / `ARRAY false`),
        accepting the bareword and the quoted spellings DuckDB accepts."""
        var w = self._copy_option_word()
        if w == "true" or w == "1" or w == "on":
            return True
        if w == "false" or w == "0" or w == "off":
            return False
        raise Error(
            "SQL syntax error: COPY option " + opt + " expects true/false, got '"
            + w + "'"
        )

    def _parse_create_table_as(mut self) raises -> SqlStatement:
        """Parse `CREATE [OR REPLACE] TABLE [IF NOT EXISTS] <name> AS <select>`.
        The `AS` body is a query (`WITH? SELECT`, optionally parenthesized);
        binds to a STMT_CREATE_TABLE_AS statement the exec layer materializes +
        registers in the catalog under `<name>`."""
        self._expect_kw("create")
        var replace = False
        if self._is_kw("or"):
            self._advance()
            self._expect_kw("replace")
            replace = True
        self._expect_kw("table")
        if self._is_kw("if"):  # optional IF NOT EXISTS
            self._advance()
            self._expect_kw("not")
            self._expect_kw("exists")
        if self._kind() != TK_IDENT:
            raise Error("SQL syntax error: expected a table name after CREATE TABLE")
        var tname = String(self.tokens[self.pos].text)
        self._advance()
        self._expect_kw("as")
        var wrapped = False
        if self._kind() == TK_LPAREN:
            self._advance()
            wrapped = True
        var body = self._parse_query_body()
        if wrapped:
            self._expect(TK_RPAREN, "')' to close the CREATE TABLE AS body")
        return SqlStatement(
            STMT_CREATE_TABLE_AS, body^, String(""), tname, WFMT_PARQUET, WCOMP_SNAPPY, replace
        )

    def _parse_with_clause(mut self) raises -> Slab[CteDef]:
        """Parse `WITH name AS (<select>) [, name2 AS (<select>)]*` — the leading
        WITH is at the current position. Each body is a full nested SELECT parsed
        by `_parse_select_stmt` (reused, so CTE bodies get the entire grammar:
        joins, GROUP BY, HAVING, ORDER BY, LIMIT). `WITH RECURSIVE` is not
        supported (raises cleanly — no recursive-CTE corpus query)."""
        self._expect_kw("with")
        if self._is_kw("recursive"):
            raise Error("SQL not supported: WITH RECURSIVE (recursive CTEs)")
        var ctes = Slab[CteDef]()
        while True:
            if self._kind() != TK_IDENT or self._is_structural_kw():
                raise Error("SQL syntax error: expected CTE name after WITH")
            var cname = String(self.tokens[self.pos].text)
            self._advance()
            self._expect_kw("as")
            self._expect(TK_LPAREN, "'(' after CTE name")
            var body = self._parse_select_stmt()
            self._expect(TK_RPAREN, "')' to close the CTE body")
            ctes.append(CteDef(cname, body^))
            if self._kind() == TK_COMMA:
                self._advance()
                continue
            break
        return ctes^

    def _select_body_ends_here(self) -> Bool:
        """The select list is followed by the END of a SELECT body — end of
        input, `;`, `)`, or a clause keyword that may follow a FROM-less
        select list in DuckDB (WHERE / GROUP / HAVING / ORDER / LIMIT / OFFSET
        / FETCH / WINDOW / QUALIFY / a set operator)."""
        var k = self._kind()
        if k == TK_EOF or k == TK_SEMI or k == TK_RPAREN:
            return True
        return (
            self._is_kw("where") or self._is_kw("group") or self._is_kw("having")
            or self._is_kw("order") or self._is_kw("limit") or self._is_kw("offset")
            or self._is_kw("fetch") or self._is_kw("window") or self._is_kw("qualify")
            or self._is_kw("union") or self._is_kw("except") or self._is_kw("intersect")
        )

    def _parse_select_stmt(mut self) raises -> SelectStmt:
        """Parse ONE SELECT body (SELECT..LIMIT/FETCH) into a `SelectStmt`,
        WITHOUT consuming a trailing `;`/EOF and WITHOUT a leading WITH — those
        belong to the top-level driver. This is the re-entrant nested-SELECT
        primitive: a CTE body (`(SELECT ...)`) reuses it verbatim, and the
        top-level final SELECT reuses it too."""
        var stmt = SelectStmt()
        # DuckDB numbers unaliased derived tables PER SELECT LEVEL, so a nested
        # SELECT starts its own count and the enclosing one resumes after it.
        var outer_unnamed = self.unnamed_derived
        self.unnamed_derived = 0
        self._expect_kw("select")
        # SELECT DISTINCT ... — a row-level distinct over the SELECT output.
        # `distinct` here is at the top of the SELECT list, DISTINCT from the
        # COUNT(DISTINCT col) form (which the aggregate parser handles inside `(`).
        if self._is_kw("distinct"):
            self._advance()
            stmt.distinct = True
            # ⛔ `DISTINCT ON (k) ...` keeps ONE row per k. Without this arm
            # `on (k)` would parse as a call to a function named `on` (and `k`,
            # the next word, as its alias), and die at bind on "scalar function
            # 'on'" — naming neither DISTINCT ON nor the misread.
            if (
                self._is_kw("on")
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_LPAREN
            ):
                raise Error(
                    "SQL not supported: SELECT DISTINCT ON (...) (one row per"
                    " key). Plain SELECT DISTINCT is served."
                )
        stmt.select_items = self._parse_select_list()
        # ★ FROM-LESS SELECT: `SELECT 7/2`, `SELECT 1 +
        # 1 AS a WHERE ...`. Recognised ONLY where the select list ends the
        # body (end of input, `;`, `)`, or a clause keyword DuckDB accepts
        # there), so a typo such as `SELECT a b c` still fails on the missing
        # FROM. Recorded as the `FROM_LESS_RELATION` relation — one row, read by
        # the binder, which refuses `SELECT *` over it in DuckDB's own words.
        var from_less = not self._is_kw("from") and self._select_body_ends_here()
        if not from_less:
            self._expect_kw("from")
        # FROM clause: table_ref ( , table_ref
        #   | [NATURAL] [INNER|CROSS] JOIN table_ref [ON pred | USING (c,...)]
        #   | [NATURAL] (LEFT|RIGHT|FULL) [OUTER] JOIN table_ref
        #                                    (ON pred | USING (c,...))
        #   | [NATURAL] (SEMI|ANTI) JOIN table_ref (ON pred | USING (c,...)) )*.
        # (`ASOF` / `POSITIONAL` JOIN are recognised and REFUSED BY NAME.)
        # INNER/CROSS/comma ON predicates are ANDed into where_pred (the binder
        # cross-joins those from_tables + filters the full predicate; the optimizer
        # folds the equi-conjuncts into inner joins). LEFT/RIGHT/FULL ON predicates
        # are kept on the join: they lower to a real OUTER-join node so the
        # unmatched rows null-extend (folding ON into WHERE would collapse that into
        # inner-join semantics). One `JoinClause` is appended per subsequent
        # relation (parallel to `from_tables[1:]`).
        #
        # ⛔ NATURAL / USING DO **NOT** FOLD INTO WHERE AT ANY KIND. Both
        # COALESCE the shared key -- one `k` out, where `ON l.k = r.k` emits `k`
        # AND `k_right` -- so the clause records the INTENT and the binder
        # derives the keys from the two schemas (which the parser cannot see).
        #
        # ⚠ BOTH WORDS ARE STRUCTURAL, OR THE ALIAS ARM EATS THEM AND THE QUERY
        # STILL ANSWERS. `FROM K NATURAL JOIN M` would parse as
        # `FROM K AS natural JOIN M` with no ON -- a bare JOIN, i.e. JK_CROSS
        # with nothing for the optimizer to push down -- and return 3x3 = 9
        # rows where DuckDB v1.5.3 returns 2, with the key emitted twice as
        # ['k','a','k_right','b']. `JOIN M USING (k)` would eat `using` as M's
        # alias and then die on `(k)` with "unexpected trailing tokens after
        # query", and `LEFT JOIN M USING (k)` would die at the ON check instead
        # -- three messages, none naming the missing production. Listing both
        # words in `_is_structural_kw` stops the silent wrong answer; the
        # productions below serve the query.
        #
        # ⚠⚠ THE SAME HOLDS FOR FOUR MORE JOIN KEYWORDS — `semi`, `anti`,
        # `asof`, `positional`. As an alias, `FROM L SEMI JOIN R ON lk = rk`
        # would parse as `FROM L AS semi JOIN R` and answer an INNER join (5
        # fanned-out rows with R's columns appended, where DuckDB v1.5.3
        # answers 3 rows of L's); `L POSITIONAL JOIN R` would answer a CROSS
        # JOIN; and the ALIASED spellings (`L AS a SEMI JOIN ...`) would die on
        # "unexpected trailing tokens" because the alias slot is already full.
        # A derived table and a `read_parquet(...)` take the same alias arm.
        # SEMI / ANTI bind to JOIN_SEMI / JOIN_ANTI; ASOF / POSITIONAL are
        # refused BY NAME.
        var where_acc: Optional[SqlExpr] = None
        if from_less:
            stmt.from_tables.append(FromRelation.named(String(FROM_LESS_RELATION)))
        else:
            stmt.from_tables.append(self._parse_table_ref())
        while True:
            if self._kind() == TK_COMMA:
                self._advance()
                stmt.from_tables.append(self._parse_table_ref())
                stmt.joins.append(JoinClause(JK_CROSS, None))
            elif (
                self._is_kw("join") or self._is_kw("inner") or self._is_kw("cross")
                or self._is_kw("left") or self._is_kw("right") or self._is_kw("full")
                or self._is_kw("natural")
                or self._is_kw("semi") or self._is_kw("anti")
                or self._is_kw("asof") or self._is_kw("positional")
            ):
                # ⛔ ASOF / POSITIONAL: refused AT THE KEYWORD, before anything
                # else is consumed — see `_refuse_unserved_join_kind`.
                self._refuse_unserved_join_kind()
                var is_natural = False
                if self._is_kw("natural"):
                    self._advance()
                    is_natural = True
                    self._refuse_unserved_join_kind()
                var jkind = JK_CROSS
                if self._is_kw("semi"):
                    # ★ SEMI / ANTI. DuckDB spells them
                    # `[NATURAL] SEMI|ANTI JOIN r (ON ... | USING (...))`, with no
                    # OUTER / INNER / LEFT in between (all three are Parser
                    # Errors there, measured v1.5.3), so the keyword is followed
                    # by JOIN or it is a syntax error at `_expect_kw` below.
                    self._advance()
                    jkind = JK_SEMI
                elif self._is_kw("anti"):
                    self._advance()
                    jkind = JK_ANTI
                elif self._is_kw("inner"):
                    self._advance()
                elif self._is_kw("cross"):
                    self._advance()
                    if is_natural:
                        raise Error(
                            "SQL syntax error: NATURAL CROSS JOIN is not a join"
                            + " kind — NATURAL derives an equi-predicate from the"
                            + " shared column names and CROSS is the absence of"
                            + " one"
                        )
                elif self._is_kw("left"):
                    self._advance()
                    jkind = JK_LEFT
                    if self._is_kw("outer"):
                        self._advance()
                elif self._is_kw("right"):
                    self._advance()
                    jkind = JK_RIGHT
                    if self._is_kw("outer"):
                        self._advance()
                elif self._is_kw("full"):
                    self._advance()
                    jkind = JK_FULL
                    if self._is_kw("outer"):
                        self._advance()
                self._expect_kw("join")
                stmt.from_tables.append(self._parse_table_ref())
                var on_pred: Optional[SqlExpr] = None
                var using_cols = List[String]()
                if self._is_kw("on"):
                    if is_natural:
                        raise Error(
                            "SQL syntax error: NATURAL JOIN takes no ON condition"
                            + " — its join columns are every name the two"
                            + " relations share. Drop NATURAL to use this ON."
                        )
                    self._advance()
                    on_pred = self._parse_expr()
                elif self._is_kw("using"):
                    if is_natural:
                        raise Error(
                            "SQL syntax error: NATURAL JOIN takes no USING list"
                            + " — its join columns are every name the two"
                            + " relations share. Use one spelling or the other."
                        )
                    self._advance()
                    using_cols = self._parse_using_list()
                if jkind == JK_SEMI or jkind == JK_ANTI:
                    # ⛔ THIS ARM PRECEDES BOTH THE KEYED ONE AND THE JK_CROSS
                    # ONE, AND EITHER ORDER ERROR IS A WRONG ANSWER. The JK_CROSS
                    # arm FOLDS the ON into WHERE — an INNER join's predicate,
                    # i.e. the very `t AS semi JOIN u` answer this arm exists to
                    # remove — and the keyed arm hands the binder a clause whose
                    # key columns it COALESCES into the output, where a SEMI
                    # emits no right column at all. The whole clause (ON, or the
                    # USING list, or NATURAL) rides to the binder unfolded.
                    var kw = String("SEMI") if jkind == JK_SEMI else String("ANTI")
                    if not on_pred and not is_natural and len(using_cols) == 0:
                        raise Error(
                            "SQL syntax error: " + kw + " JOIN requires an ON"
                            + " condition or a USING (...) list — it keeps the"
                            + " left rows that have "
                            + ("a" if jkind == JK_SEMI else "no")
                            + " match, and without a condition there is"
                            + " nothing to match on"
                        )
                    stmt.joins.append(
                        JoinClause(jkind, on_pred^, is_natural, using_cols^)
                    )
                elif is_natural or len(using_cols) > 0:
                    # NATURAL / USING at ANY kind — a KEYED join. Nothing is
                    # folded into WHERE and nothing is carried as a predicate:
                    # the binder resolves the key NAMES against the two schemas
                    # and emits the coalescing projection. ⚠ This arm precedes
                    # the JK_CROSS one deliberately — routing `JOIN M USING (k)`
                    # through it would produce a JOIN_CROSS with no predicate,
                    # which is exactly the 3x3-for-2-rows defect.
                    stmt.joins.append(
                        JoinClause(jkind, None, is_natural, using_cols^)
                    )
                elif jkind == JK_CROSS:
                    # INNER / CROSS / bare JOIN — ON folds into WHERE (as before).
                    if on_pred:
                        where_acc = _and_into(where_acc^, on_pred.take())
                    stmt.joins.append(JoinClause(JK_CROSS, None))
                else:
                    # LEFT / RIGHT / FULL — the ON stays on the OUTER-join node.
                    if not on_pred:
                        raise Error("SQL syntax error: OUTER JOIN requires an ON condition")
                    stmt.joins.append(JoinClause(jkind, on_pred^))
            else:
                break

        if self._is_kw("where"):
            self._advance()
            where_acc = _and_into(where_acc^, self._parse_expr())
        stmt.where_pred = where_acc^

        if self._is_kw("group"):
            self._advance()
            self._expect_kw("by")
            stmt.group_by = self._parse_expr_list()

        if self._is_kw("having"):
            self._advance()
            stmt.having_pred = self._parse_expr()

        if self._is_kw("order"):
            self._advance()
            self._expect_kw("by")
            stmt.order_by = self._parse_order_list()

        # ---------------------------------------------------------------------
        # THE ROW-WINDOW CLAUSES: LIMIT / FETCH / OFFSET.
        #
        # ⚠ A LOOP, NOT A LADDER. DuckDB accepts `LIMIT n OFFSET m` AND
        # `OFFSET m LIMIT n` (measured, v1.5.3), so neither clause can be nested
        # inside the other's arm; each may appear at most once, in either order.
        # It does NOT accept MySQL's `LIMIT m, n` — that is a Parser Error there
        # (also measured), so the comma form falls out of the loop and dies at
        # `_finalize` as a trailing token, which is the right answer.
        #
        # ⛔ WITHOUT THE `offset` ARM the `offset` ident falls through to
        # `_finalize` and raises "unexpected trailing tokens after query" — a
        # message naming the symptom, not the clause. ClickBench Q38 Q39 Q40
        # Q41 Q42 each end in `LIMIT 10 OFFSET <m>`.
        # ---------------------------------------------------------------------
        var saw_limit = False
        var saw_offset = False
        while True:
            if self._is_kw("limit"):
                if saw_limit:
                    raise Error("SQL syntax error: duplicate LIMIT clause")
                saw_limit = True
                self._advance()
                if self._kind() != TK_INT:
                    raise Error("SQL syntax error: LIMIT expects an integer")
                stmt.limit = Int(self._small_int_tok("LIMIT"))
                self._advance()
            elif self._is_kw("fetch"):
                # TPC-H spec row-limit form: FETCH FIRST|NEXT <int> ROW[S] ONLY.
                if saw_limit:
                    raise Error(
                        "SQL syntax error: duplicate LIMIT/FETCH clause"
                    )
                saw_limit = True
                self._advance()  # fetch
                if self._is_kw("first") or self._is_kw("next"):
                    self._advance()
                if self._kind() != TK_INT:
                    raise Error(
                        "SQL syntax error: FETCH FIRST expects an integer"
                    )
                stmt.limit = Int(self._small_int_tok("FETCH FIRST count"))
                self._advance()
                if self._is_kw("rows") or self._is_kw("row"):
                    self._advance()
                if self._is_kw("only"):
                    self._advance()
            elif self._is_kw("offset"):
                if saw_offset:
                    raise Error("SQL syntax error: duplicate OFFSET clause")
                saw_offset = True
                self._advance()  # offset
                if self._kind() != TK_INT:
                    # Covers `OFFSET -1` too: the tokenizer emits `-` as its own
                    # token, so a negative literal never reaches TK_INT. DuckDB
                    # refuses the same input one tier later with
                    # "LIMIT/OFFSET cannot be negative"; refusing it here is the
                    # same fail-closed answer.
                    raise Error("SQL syntax error: OFFSET expects an integer")
                stmt.offset = Int(self._small_int_tok("OFFSET"))
                self._advance()
                # `OFFSET m ROW` / `OFFSET m ROWS` — the SQL-standard noise
                # words that pair with FETCH FIRST.
                if self._is_kw("rows") or self._is_kw("row"):
                    self._advance()
            else:
                break

        # A DuckDB clause keyword this grammar has no production for is NAMED
        # here rather than reported as "unexpected trailing tokens" (or as a
        # missing ')' one level up, in a nested SELECT).
        self._refuse_unsupported_clause()
        _refuse_ambiguous_derived_qualifier(stmt.from_tables)
        self.unnamed_derived = outer_unnamed
        # A nested SELECT body ends at ')' (CTE) or the top-level trailing
        # ';'/EOF — the caller (parse / _parse_with_clause) consumes those.
        return stmt^

    def _refuse_unserved_join_kind(self) raises:
        """⛔ `ASOF` / `POSITIONAL` JOIN — REFUSED BY NAME, at the keyword.

        Without the refusal both are SILENT WRONG ANSWERS: if neither word
        were structural, `L ASOF JOIN R ON lk >= rk` would bind as
        `L AS asof JOIN R` — an ordinary inequality join returning EVERY match
        instead of the nearest one — and `L POSITIONAL JOIN R` as a bare
        CROSS JOIN (30 rows where DuckDB v1.5.3 answers 6).

        ⚠ THE TWO REFUSALS ARE NOT THE SAME CLAIM. POSITIONAL has no operator
        anywhere in this engine. ASOF has a NODE — `PLAN_ASOF_JOIN`, a LEFT
        as-of join with an executor, built by the Mojo
        `PlanCarrier.asof_join` — and no SQL LOWERING (ON -> equi-keys + one
        inequality -> strategy; an INNER `ASOF JOIN` -> the LEFT node plus a
        matched-row filter). ⛔ DO NOT READ THAT AS "only the lowering is
        missing": `PlanCarrier.asof_join` is MEASURED raising
        at BOTH terminals over row-streaming (CSV) leaves, and which leaf
        shapes the node executes over is not established here. The message
        names the node and the missing lowering and claims nothing more.
        """
        if self._is_kw("asof"):
            raise Error(
                "SQL not supported: ASOF JOIN at the SQL door. An as-of join"
                " pairs each left row with the NEAREST right row satisfying its"
                " inequality (e.g. the latest price at or before each trade)."
                " The engine's as-of node (PLAN_ASOF_JOIN, built by the Mojo"
                " PlanCarrier.asof_join) has no SQL lowering yet, and binding"
                " the query as an ordinary join would return EVERY matching"
                " right row instead of the nearest one, under the same column"
                " names. It is refused rather than approximated."
            )
        if self._is_kw("positional"):
            raise Error(
                "SQL not supported: POSITIONAL JOIN. It pairs the n-th row of"
                " each side BY POSITION (padding the shorter side with NULLs);"
                " this engine has no positional-zip operator, and binding it as"
                " an ordinary join would return the CROSS product. It is refused"
                " rather than approximated."
            )

    def _refuse_unsupported_clause(self) raises:
        """Name the DuckDB clause keywords this grammar has NO production for.

        ⚠ EVERY WORD HERE IS ALSO IN `_is_structural_kw`, AND THAT IS WHAT
        MAKES THIS REACHABLE. Without the stop-list row the implicit-alias grab
        eats the keyword first (`FROM t QUALIFY ...` read as `FROM t AS qualify`)
        and the query dies one token later on a message that names neither the
        clause nor the grab. DuckDB v1.5.3 reserves every one of these words in
        the table-alias position (measured: `SELECT * FROM t qualify` is a
        Parser Error there), so the stop-list rows cost no query DuckDB accepts.
        """
        if self._kind() != TK_IDENT:
            return
        ref w = self.tokens[self.pos].text
        if w == "qualify":
            raise Error(
                "SQL not supported: the QUALIFY clause (a filter over window"
                " function results). Compute the window in a derived table and"
                " filter it from the outer query: `SELECT * FROM (SELECT ...,"
                " <window> AS w FROM t) d WHERE <predicate on w>`."
            )
        if w == "window":
            raise Error(
                "SQL not supported: a named WINDOW clause. Write the window"
                " specification inline in each OVER (...)."
            )
        if w == "pivot" or w == "unpivot":
            raise Error(
                "SQL not supported: " + String(w).upper() + " (reshaping a"
                " relation between long and wide form)."
            )
        if w == "tablesample" or (
            w == "using"
            and self.pos + 1 < len(self.tokens)
            and self.tokens[self.pos + 1].kind == TK_IDENT
            and self.tokens[self.pos + 1].text == "sample"
        ):
            raise Error(
                "SQL not supported: TABLESAMPLE / USING SAMPLE (row sampling)."
                " Silently scanning every row instead would answer a different"
                " question, so the sample clause is refused."
            )
        # An operator word a WHERE / HAVING expression stopped on
        # (`WHERE s GLOB 'a*'`) is named the same way the SELECT list names it.
        self._refuse_unserved_operator_word()

    def _parse_table_ref(mut self) raises -> FromRelation:
        """Parse one FROM relation: `ident [. ident] [AS ident]`, a
        `read_parquet('path')` table-valued function, OR a `(SELECT ...) alias`
        derived table. A schema qualifier (`s.t`) keeps the last component;
        the alias (`t AS a` / `t a`) is RECORDED on the `FromRelation` (it is
        load-bearing for correlated-subquery inner/outer column classification)."""
        # Derived table: `(SELECT ...) alias`. Parked in the subquery
        # side-table (SUBQ_DERIVED); the binder inlines it via the CTE scope.
        if self._kind() == TK_LPAREN:
            return self._parse_derived_table()
        if self._kind() == TK_STRING:
            return self._parse_replacement_scan()
        if self._kind() != TK_IDENT:
            raise Error("SQL syntax error: expected table name in FROM")
        var name = String(self.tokens[self.pos].text)
        # ⛔ `LATERAL (...)` — a subquery that may reference the relations to its
        # left. Without this arm `lateral` is read as a TABLE NAME and the
        # query dies one token later on "unexpected trailing tokens".
        if (
            name == "lateral"
            and self.pos + 1 < len(self.tokens)
            and self.tokens[self.pos + 1].kind == TK_LPAREN
        ):
            raise Error(
                "SQL not supported: LATERAL (a subquery that references columns"
                " of the relations before it in FROM). Express the correlation"
                " as a JOIN on the correlated columns, or as a correlated"
                " `WHERE [NOT] EXISTS (...)`."
            )
        # Table-valued function: read_parquet('path') / read_csv / read_json /
        # read_avro. The ident is lower-folded by the tokenizer, so compare
        # directly.
        #
        # ⭐ `read_avro` is the SQL spelling of an Avro file.
        # DuckDB's side resolves the same name once
        # `INSTALL avro; LOAD avro;` has run (verified: a bad path
        # fails at the PATH ARGUMENT, not at the function name — contrast
        # `read_arrow`, which fails at the NAME), so avro is the one non-native
        # format where an apples-to-apples parity arm is buildable.
        if (
            (name == "read_parquet" or name == "read_csv" or name == "read_json"
             or name == "read_ndjson" or name == "read_json_auto"
             or name == "read_csv_auto" or name == "read_avro")
            and self.pos + 1 < len(self.tokens)
            and self.tokens[self.pos + 1].kind == TK_LPAREN
        ):
            # ⚠ THE AVRO TEST MUST PRECEDE THE `!= "read_parquet"` CATCH-ALL.
            # That elif is a DEFAULT-TO-JSON, not a JSON test: adding a sixth
            # spelling to the clause above without a branch here would bind
            # `read_avro('f.avro')` as JSONL and hand the JSON prefix inferrer
            # an OCF container header.
            var kind: UInt8 = TVF_PARQUET
            if name == "read_csv" or name == "read_csv_auto":
                kind = TVF_CSV
            elif name == "read_avro":
                kind = TVF_AVRO
            elif name != "read_parquet":
                kind = TVF_JSON
            self._advance()  # func name -> now at '('
            self._expect(TK_LPAREN, "'('")
            if self._kind() != TK_STRING:
                raise Error(
                    "SQL syntax error: " + name + " expects a string path"
                )
            var path = String(self.tokens[self.pos].text)
            self._advance()  # the quoted path
            # `read_csv` / `read_json` take DuckDB's trailing `name=value`
            # option list. Every option that is a CSV/JSON DIALECT concept is
            # REFUSED BY NAME on the other kinds — see
            # `_refuse_option_for_kind`.
            #
            # ⛔ AN OPTION THE KIND DOES NOT READ MUST NOT PARSE CLEAN. A key in
            # `_parse_tvf_options`' allowlist (`header`, `delim`/`sep`,
            # `quote`, `escape`, `parallel`, `compression`, `auto_detect`)
            # that is accepted for ANY kind is recorded on a `TvfOptions` the
            # avro or parquet binder never reads, so
            # `read_avro('f.avro', delim='|')` or
            # `read_parquet('f.parquet', header=false, delim='|')` would PARSE
            # CLEAN and drop the option silently, which is the one outcome the
            # module note at `sql_ast.mojo` says is worse than raising.
            #
            # The blanket avro refusal below stands beside the per-key guards,
            # which would also catch it: it names the whole shape in one
            # sentence and fires before the first option is even read.
            if kind == TVF_AVRO and self._kind() == TK_COMMA:
                raise Error(
                    "SQL not supported: read_avro('" + path + "', ...) takes NO"
                    + " options — an Avro OCF carries its writer schema and its"
                    + " codec in the container header, so there is no dialect to"
                    + " steer and nothing an option could mean. It is REJECTED"
                    + " rather than ignored — an ignored option can change the"
                    + " result silently."
                )
            var opts = self._parse_tvf_options(name, kind)
            self._expect(TK_RPAREN, "')'")
            var tvf_alias = self._parse_optional_alias()
            # ⛔ EVERY KIND CARRIES ITS `opts`, PARQUET INCLUDED. An early
            # `return FromRelation.tvf(path, tvf_alias)` for parquet would drop
            # the parsed `TvfOptions` on the floor. The per-key kind guards in
            # `_parse_tvf_options` refuse every such option BY NAME, so a
            # parquet `opts` is always the default; routing it through
            # `tvf_of` anyway keeps the next option added without a guard from
            # being silently dropped instead of merely mis-honored. A DROP is
            # invisible; a wrong value is findable.
            return FromRelation.tvf_of(path, kind, opts^, tvf_alias)
        self._advance()
        if self._kind() == TK_DOT:
            self._advance()
            if self._kind() != TK_IDENT:
                raise Error("SQL syntax error: expected identifier after '.'")
            name = String(self.tokens[self.pos].text)
            self._advance()
        var tbl_alias = self._parse_optional_alias()
        return FromRelation.named(name, tbl_alias)

    def _parse_replacement_scan(mut self) raises -> FromRelation:
        """★ `FROM 'path/f.parquet'` — DuckDB's REPLACEMENT SCAN:
        a quoted FILE PATH in FROM reads the
        file, the reader chosen by its EXTENSION. MEASURED v1.5.3: `SELECT *
        FROM 'rs/t1.parquet'` answers the file, `SELECT t1.k FROM
        'rs/t1.parquet'` resolves — the relation is NAMED after the file STEM —
        and an alias replaces that name, as for any table.

        It is the SAME relation `read_parquet('path')` / `read_csv('path')` /
        `read_json('path')` builds (default options), so it answers what those
        answer.

        ⛔ AN EXTENSION THIS DOOR DOES NOT MAP IS REFUSED BY NAME, NOT GUESSED:
        `.parquet` -> parquet, `.csv` -> csv, `.json` / `.jsonl` / `.ndjson` ->
        json. DuckDB also sniffs `.tsv` (a TAB delimiter this reader does not
        auto-detect) and compressed suffixes (`.csv.gz`); reading either as a
        plain comma CSV would answer a different table."""
        var path = String(self.tokens[self.pos].text)
        var kind = _replacement_scan_kind(path)
        self._advance()  # the quoted path
        var rel_name = self._parse_optional_alias()
        if rel_name == "":
            rel_name = _file_stem(path)
        return FromRelation.tvf_of(path, kind, TvfOptions(), rel_name)

    def _tvf_bool_arg(mut self, fname: String, key: String) raises -> Bool:
        """Consume a `true` / `false` option value (the tokenizer lower-folds
        both to `TK_IDENT`)."""
        if self._kind() == TK_IDENT:
            var v = String(self.tokens[self.pos].text)
            if v == "true":
                self._advance()
                return True
            if v == "false":
                self._advance()
                return False
        raise Error(
            "SQL syntax error: " + fname + " option '" + key
            + "' expects TRUE or FALSE"
        )

    def _tvf_str_arg(mut self, fname: String, key: String) raises -> String:
        """Consume a single-quoted option value."""
        if self._kind() != TK_STRING:
            raise Error(
                "SQL syntax error: " + fname + " option '" + key
                + "' expects a quoted string"
            )
        var v = String(self.tokens[self.pos].text)
        self._advance()
        return v^

    def _refuse_option_for_kind(
        self, fname: String, key: String, kind: UInt8, belongs_to: String,
    ) raises:
        """Refuse a DIALECT option on a kind that has no dialect, BY NAME.

        ⛔ WITHOUT THIS GUARD AN OPTION IS A SILENT WRONG ANSWER. A key the
        kind does not read would be accepted and then never looked at, so
            SELECT * FROM read_parquet('f.parquet', header=false, delim='|')
        would parse CLEAN and ignore both options. DuckDB v1.5.3 rejects every
        one of them on `read_parquet` ("Invalid named parameter"), so this is
        not a dialect difference — accepting it would be an accept-and-ignore
        where the reference engine refuses.

        The same holds for `read_json`, one layer deeper: the parser DOES hand
        `opts` to the JSON arm, but the JSON schema binder takes a bare `path`
        and has no `TvfOptions` parameter at all.

        REFUSED, NOT PLUMBED, AND THE REASON IS THE FORMAT ITSELF. There is no
        meaning to plumb: a parquet file is SELF-DESCRIBING (its footer carries
        the column names, the physical types and the per-column-CHUNK codec)
        and JSONL records are SELF-DELIMITING (one JSON object per line, values
        tagged by the JSON grammar). Neither has a header line, a delimiter, a
        quote character or a type-inference pass for an option to steer."""
        var why = String("")
        if kind == TVF_PARQUET:
            why = (
                " A parquet file is SELF-DESCRIBING: its footer carries the"
                + " column names, the physical types and the per-column-chunk"
                + " codec, so there is no header line, delimiter, quote"
                + " character or type-inference pass for this option to steer"
                + " (and the codec is per chunk, not per file)."
            )
        elif kind == TVF_JSON:
            why = (
                " JSONL records are SELF-DELIMITING — one JSON object per"
                + " line, with every value tagged by the JSON grammar itself —"
                + " so there is no header line, delimiter or quote character"
                + " for this option to steer."
            )
        elif kind == TVF_AVRO:
            why = (
                " An Avro OCF carries its writer schema and its codec in the"
                + " container header, so there is no dialect to steer."
            )
        raise Error(
            "SQL not supported: " + fname + " option '" + key + "' is a "
            + belongs_to + " option and means nothing here." + why
            + " It is REJECTED rather than ignored — an ignored option can"
            + " change the result silently."
        )

    def _parse_tvf_options(
        mut self, fname: String, kind: UInt8,
    ) raises -> TvfOptions:
        """Parse the trailing `, name = value` option list of a `read_csv` /
        `read_json` call, positioned just after the path literal and returning
        with the cursor on the closing `')'`.

        THE ALLOWLIST IS THE POINT. Three classes, and every option is in exactly
        one of them:

          1. SEMANTIC — it changes what the result IS (`all_varchar`, `header`,
             `delim`). Recorded on `TvfOptions`; the binder honors it.
          2. NEUTRAL-BY-VALUE — it changes only HOW the engine gets there
             (`parallel`, `auto_detect=true`), or it restates something our
             reader derives for itself and AGREES with (`compression=` matching
             the path's own extension; `quote`/`escape` at their RFC-4180
             values; `format='newline_delimited'` for JSONL). Accepted, no field.
             ⚠ `parallel=false` is neutral for the VALUES and is NOT neutral for
             a benchmark: it scope-locks DuckDB to one thread while this engine
             reads with its whole pool. Accepting it here is correct for the
             SEMANTICS and must be stated wherever such a cell's ratio is
             reported — it is not an apples-to-apples wall.
          3. EVERYTHING ELSE — raises, naming the option. Silently dropping an
             unrecognized option is how a reader returns the right row count
             with the wrong values.

        ⛔ AND THE CLASSES ARE PER KIND, NOT GLOBAL. A key in
        class 1 or 2 for one kind can be MEANINGLESS for another, and a
        meaningless option is class 3 — `_refuse_option_for_kind` raises on it,
        naming the option and saying why the format has nothing for it to
        steer. Without the per-kind check `read_parquet('f.parquet',
        header=false)` would parse clean and change nothing.
        """
        var opts = TvfOptions()
        while self._kind() == TK_COMMA:
            self._advance()  # ','
            if self._kind() != TK_IDENT:
                raise Error(
                    "SQL syntax error: expected an option name inside " + fname
                    + "(...)"
                )
            var key = String(self.tokens[self.pos].text)
            self._advance()
            if self._kind() != TK_EQ:
                raise Error(
                    "SQL syntax error: " + fname + " option '" + key
                    + "' must be written name=value"
                )
            self._advance()  # '='

            if key == "all_varchar":
                if kind != TVF_CSV:
                    raise Error(
                        "SQL not supported: 'all_varchar' is a read_csv option"
                    )
                opts.all_varchar = self._tvf_bool_arg(fname, key)
            elif key == "header" or key == "has_header":
                if kind != TVF_CSV:
                    self._refuse_option_for_kind(fname, key, kind, "read_csv")
                opts.has_header = self._tvf_bool_arg(fname, key)
            elif key == "delim" or key == "sep" or key == "delimiter":
                if kind != TVF_CSV:
                    self._refuse_option_for_kind(fname, key, kind, "read_csv")
                var d = self._tvf_str_arg(fname, key)
                if len(d.as_bytes()) != 1:
                    raise Error(
                        "SQL not supported: " + fname + " '" + key + "'='" + d
                        + "' — only a SINGLE-byte delimiter is supported"
                    )
                opts.delimiter = d.as_bytes()[0]
            elif key == "quote":
                if kind != TVF_CSV:
                    self._refuse_option_for_kind(fname, key, kind, "read_csv")
                var q = self._tvf_str_arg(fname, key)
                if q != '"':
                    raise Error(
                        "SQL not supported: " + fname + " quote='" + q
                        + "' — this reader is RFC-4180 (quote='\"') only"
                    )
            elif key == "escape":
                if kind != TVF_CSV:
                    self._refuse_option_for_kind(fname, key, kind, "read_csv")
                var e = self._tvf_str_arg(fname, key)
                if e != '"':
                    raise Error(
                        "SQL not supported: " + fname + " escape='" + e
                        + "' — this reader is RFC-4180 (escape='\"',"
                        + " i.e. doubled quotes) only"
                    )
            elif key == "auto_detect" or key == "autodetect":
                # DuckDB v1.5.3 declares `auto_detect` on read_csv AND on
                # read_json (both infer a schema from a sample). A parquet /
                # avro read has nothing to auto-detect — the schema is in the
                # file — so the option is meaningless there, not merely
                # unimplemented.
                if kind != TVF_CSV and kind != TVF_JSON:
                    self._refuse_option_for_kind(
                        fname, key, kind, "read_csv / read_json"
                    )
                if not self._tvf_bool_arg(fname, key):
                    raise Error(
                        "SQL not supported: " + fname
                        + " auto_detect=false requires an explicit columns={...}"
                        + " list, which this binder does not implement"
                    )
            elif key == "parallel":
                # Class 2: an execution knob on DuckDB's side. See the docstring
                # — accepted for the VALUES, reportable for the WALL.
                #
                # ⚠ read_csv ONLY. DuckDB v1.5.3 declares `parallel` on
                # `read_csv` and NOT on `read_json` / `read_parquet`, so
                # accepting it elsewhere would accept a spelling the reference
                # engine itself rejects. Even where DuckDB has no opinion the
                # refusal is the right call: refusing a knob we do not
                # honor is a graded gap, accepting it is a lie.
                if kind != TVF_CSV:
                    self._refuse_option_for_kind(fname, key, kind, "read_csv")
                _ = self._tvf_bool_arg(fname, key)
            elif key == "compression":
                # ⚠ TEXT FORMATS ONLY. `compression` is a real DuckDB named
                # parameter on `read_csv` and `read_json`, where the WHOLE FILE
                # is wrapped in one codec our readers derive from the path
                # extension. Parquet's codec is per COLUMN CHUNK and lives in
                # the footer, so a file-level `compression=` cannot name it —
                # honoring it is impossible and accepting it is a silent lie.
                if kind != TVF_CSV and kind != TVF_JSON:
                    self._refuse_option_for_kind(
                        fname, key, kind, "read_csv / read_json"
                    )
                # Our readers derive the codec from the path extension. A stated
                # codec that AGREES is redundant; one that disagrees would make
                # two engines read different bytes, so it raises.
                var c = self._tvf_str_arg(fname, key).lower()
                if c != "auto" and c != "none" and c != "uncompressed" \
                        and c != "gzip" and c != "gz" and c != "zstd" \
                        and c != "zst":
                    raise Error(
                        "SQL not supported: " + fname + " compression='" + c
                        + "' — this reader derives the codec from the path"
                        + " extension and handles none / gzip / zstd"
                    )
            elif key == "format":
                if kind != TVF_JSON:
                    raise Error(
                        "SQL not supported: 'format' is a read_json option"
                    )
                var f = self._tvf_str_arg(fname, key).lower()
                if f != "newline_delimited" and f != "nd" and f != "auto":
                    raise Error(
                        "SQL not supported: read_json format='" + f
                        + "' — this reader is newline-delimited (JSONL) only"
                    )
            else:
                raise Error(
                    "SQL not supported: " + fname + " option '" + key
                    + "' is not implemented. It is REJECTED rather than ignored"
                    + " — an ignored option can change the result silently."
                )
        return opts^

    def _parse_derived_table(mut self) raises -> FromRelation:
        """Parse `(SELECT ...) alias [(c1, c2, ...)]` — a derived table (+the
        optional column-list rename). The body is a full nested SELECT parsed by
        the re-entrant `_parse_select_stmt` (so it gets the entire grammar). It is
        parked in the subquery side-table with kind `SUBQ_DERIVED`, its relation
        key (`<alias>#<subquery index>`, below), and any column-list rename; the
        parser emits a `named(key, alias)` relation, and `_bind_query` binds the
        body into the CTE scope under the key (applying the column-list rename to
        its output columns) so it resolves through the named-derived-relation
        path a CTE uses."""
        self._advance()  # '('
        if not self._is_kw("select"):
            raise Error("SQL syntax error: expected SELECT in a derived table")
        var body = self._parse_select_stmt()
        self._expect(TK_RPAREN, "')' to close the derived table")
        var d_alias = self._parse_optional_alias()
        # ★ AN UNALIASED DERIVED TABLE. DuckDB v1.5.3
        # accepts `FROM (SELECT ...)` and names it `unnamed_subquery`, then
        # `unnamed_subquery2`, ... — counting only the UNALIASED ones of one
        # FROM clause and restarting in every nested SELECT (measured:
        # `SELECT unnamed_subquery2.b FROM (SELECT 1 AS a), (SELECT 2 AS b)` is
        # 2; `... FROM (SELECT 1 AS a) x, (SELECT 2 AS b)` names the second
        # `unnamed_subquery`; `SELECT unnamed_subquery.a FROM (SELECT * FROM
        # (SELECT 1 AS a))` is 1).
        #
        # ⚠ TWO NAMES, ON PURPOSE, for EVERY derived table. The QUALIFIER is
        # the user's alias or DuckDB's synthetic name (`rel_alias`); the
        # RELATION NAME — the key the binder registers the body under in the
        # statement-wide derived-relation scope — is that plus `#<subquery
        # index>`. The scope is ONE per statement while aliases are scoped to
        # their own SELECT level (two nested unaliased tables are BOTH
        # `unnamed_subquery`; a derived `t` inside an IN body is not the `t`
        # of the top FROM), and `#` cannot occur in a lower-folded identifier,
        # so the key can neither collide with a twin at another level nor
        # SHADOW a catalog table or CTE outside the FROM entry that declares
        # it. A same-FROM relation that answers to the same qualifier is
        # refused by `_refuse_ambiguous_derived_qualifier`.
        var synthetic = d_alias == ""
        if synthetic:
            self.unnamed_derived += 1
            d_alias = String("unnamed_subquery")
            if self.unnamed_derived > 1:
                d_alias += String(self.unnamed_derived)
        var rel_name = d_alias + "#" + String(len(self.subqueries))
        # Optional column-list rename `(c1, c2, ...)` right after the alias
        # (`(SELECT ...) c_orders (c_custkey, c_count)`, TPC-H q13 shape). It is
        # distinguished from a fresh derived-table `(SELECT ...)` by the parser
        # position: a `(` here follows an alias IDENT, and its contents are bare
        # identifiers (not a SELECT). Applied positionally to the body's output
        # columns by the binder.
        var col_names = List[String]()
        # Only after an EXPLICIT alias: `(SELECT ...) (x)` is a Parser Error in
        # DuckDB v1.5.3 (measured), and here it falls out as a trailing token.
        if not synthetic and self._kind() == TK_LPAREN:
            self._advance()  # '('
            while True:
                if self._kind() != TK_IDENT:
                    raise Error("SQL syntax error: expected column name in a derived-table column list")
                col_names.append(String(self.tokens[self.pos].text))
                self._advance()
                if self._kind() == TK_COMMA:
                    self._advance()
                    continue
                break
            self._expect(TK_RPAREN, "')' to close the derived-table column list")
        self.subqueries.append(SubqueryDef(body^, SUBQ_DERIVED, String(""), rel_name, col_names^))
        return FromRelation.named(rel_name, d_alias)

    def _parse_using_list(mut self) raises -> List[String]:
        """Consume `( col [, col]* )` after USING and RETURN the column names.

        ⛔ `USING ()` IS REFUSED, not accepted as "no keys". A keyless join that
        still returns a table is the 9-rows-for-2 Cartesian this production
        exists to prevent, and an empty list would reintroduce it through a
        spelling that LOOKS like it named keys.

        ⚠ Only bare identifiers are accepted. `USING (t.k)` is not legal SQL --
        a USING column is by definition unqualified, since it names a column on
        BOTH sides -- and it refuses here rather than resolving one side."""
        self._expect(TK_LPAREN, "'(' after USING")
        var cols = List[String]()
        while True:
            if self._kind() != TK_IDENT:
                raise Error(
                    "SQL syntax error: expected an unqualified column name in"
                    + " USING (...)"
                )
            cols.append(String(self.tokens[self.pos].text))
            self._advance()
            if self._kind() == TK_COMMA:
                self._advance()
                continue
            break
        self._expect(TK_RPAREN, "')' to close USING (...)")
        return cols^

    def _parse_optional_alias(mut self) raises -> String:
        """Consume an optional table alias (`AS ident` / a bare non-keyword
        ident) and RETURN it ("" if none)."""
        if self._is_kw("as"):
            self._advance()
            if self._kind() != TK_IDENT:
                raise Error("SQL syntax error: expected alias after AS")
            var a = String(self.tokens[self.pos].text)
            self._advance()
            return a
        elif self._kind() == TK_IDENT and not self._is_structural_kw():
            var a = String(self.tokens[self.pos].text)
            self._advance()
            return a
        return String("")

    def _parse_select_list(mut self) raises -> Slab[SelectItem]:
        var items = Slab[SelectItem]()
        while True:
            if self._kind() == TK_STAR:
                self._advance()
                items.append(SelectItem(SqlExpr.star(), Optional[String](), True))
            else:
                var e = self._parse_expr()
                var out_alias: Optional[String] = None
                if self._is_kw("as"):
                    self._advance()
                    if self._kind() != TK_IDENT:
                        raise Error("SQL syntax error: expected alias after AS")
                    out_alias = String(self.tokens[self.pos].text)
                    self._advance()
                elif self._kind() == TK_IDENT and not self._is_structural_kw():
                    # implicit alias (`expr alias`) — unless the word is a
                    # DuckDB OPERATOR this grammar has no production for.
                    # A call's name rides into the message so two refusals
                    # of one modifier over different aggregates read apart.
                    var after = String("")
                    if e.tag == SX_AGG or e.tag == SX_CALL:
                        after = String(e.text)
                    self._refuse_unserved_operator_word(after)
                    out_alias = String(self.tokens[self.pos].text)
                    self._advance()
                items.append(SelectItem(e^, out_alias^, False))
            if self._kind() == TK_COMMA:
                self._advance()
                continue
            break
        return items^

    def _refuse_unserved_operator_word(self, after: String = String("")) raises:
        """⛔ Refuse, BY NAME, a word DuckDB reads as an OPERATOR on the
        expression before it, when it reaches an implicit-alias position here.

        The SELECT list takes `expr <word>` as `expr AS <word>`. DuckDB v1.5.3
        takes only a plain, non-keyword identifier there (measured:
        `SELECT 1 name` and `SELECT 1 year` are Parser Errors), so for these
        words the alias reading is never DuckDB's reading:

        * `EXPORT_STATE` without this check is a SILENT WRONG ANSWER.
          `SELECT count(*) EXPORT_STATE FROM t` is an AGGREGATE_STATE blob in
          DuckDB (measured); read as an alias it would answer the COUNT under
          the name `export_state`.

        * The rest would fail LOUDLY but one token later, on "expected keyword
          'from'" (or a trailing token), naming neither the operator nor the
          grab: `COLLATE`, `GLOB`, `ESCAPE` after a LIKE pattern, `AT TIME
          ZONE`, an aggregate's `FILTER (WHERE ...)` and an ordered-set
          aggregate's `WITHIN GROUP (...)`. (`ILIKE` and `SIMILAR TO` are not
          on this list: both are productions of `_parse_cmp`, so an expression
          consumes them before any alias position is reached.)

        ⚠ NOT A RESERVED-WORD LIST. A word is refused only where DuckDB would
        read it as the operator (`filter` only before `(`, `at` only before
        `time`, `within` only before `group`), so a column or alias with one of
        these names elsewhere is untouched. `_refuse_unsupported_clause` asks the
        same question of the word a statement stops on.
        """
        if self._kind() != TK_IDENT:
            return
        # `after` names the aggregate / function the word follows (the SELECT
        # list passes it); "" where the caller cannot know it.
        var on = String("")
        if after != "":
            on = " on `" + after + "(...)`"
        var w = String(self.tokens[self.pos].text)
        var nxt = String("")
        if (
            self.pos + 1 < len(self.tokens)
            and self.tokens[self.pos + 1].kind == TK_IDENT
        ):
            nxt = String(self.tokens[self.pos + 1].text)
        var nxt_lparen = (
            self.pos + 1 < len(self.tokens)
            and self.tokens[self.pos + 1].kind == TK_LPAREN
        )
        # `x NOT GLOB p` stops on `not`: the postfix NOT arm admits only IN /
        # LIKE / ILIKE / SIMILAR TO / BETWEEN / NULL after it.
        if w == "not" and nxt == "glob":
            w = nxt
        var what = String("")
        if w == "export_state":
            what = (
                "EXPORT_STATE" + on + " (an aggregate's internal STATE instead"
                " of its value). Taking the word as the column alias would"
                " answer the aggregate's VALUE under the name `export_state`"
            )
        elif w == "collate":
            what = "COLLATE (a collation on the expression before it)"
        elif w == "glob":
            what = "the GLOB pattern operator"
        elif w == "escape":
            what = "a LIKE pattern's ESCAPE character"
        elif w == "filter" and nxt_lparen:
            what = (
                "an aggregate's FILTER (WHERE ...) clause" + on + " (TPC-H's"
                " spelling, an aggregate over `CASE WHEN <cond> THEN <x> ELSE"
                " 0 END`, is served)"
            )
        elif w == "at" and nxt == "time":
            what = "AT TIME ZONE"
        elif w == "within" and nxt == "group":
            what = (
                "an ordered-set aggregate's WITHIN GROUP (ORDER BY ...)" + on
            )
        if what != "":
            raise Error(
                "SQL not supported: " + what + ". `" + w.upper() + "` is an"
                + " operator on the expression before it, and this frontend has"
                + " no production for it (it is refused rather than read as a"
                + " column alias or dropped)."
            )

    @always_inline
    def _is_structural_kw(self) -> Bool:
        """True if the current IDENT is a clause keyword (so it is NOT an
        implicit alias).

        ⚠ `offset` IS LOAD-BEARING HERE, NOT TIDINESS. Without it
        `SELECT * FROM t OFFSET 5` reads `offset` as the table alias of `t` and
        then dies at `5` with the SAME "unexpected trailing tokens after query"
        the OFFSET arm exists to remove — so the clause would look unsupported
        even though the parser has an arm for it. (DuckDB also reserves
        `OFFSET`: `FROM (VALUES (1)) offset(v)` is an error there — measured.)

        ⚠ `natural` / `using` are here for the SAME reason as `offset`: without
    them `FROM K NATURAL JOIN M` reads `natural` as K's alias and answers a 3x3
    CROSS JOIN -- 9 rows where DuckDB v1.5.3 returns 2 -- while `JOIN M USING
    (k)` reads `using` as M's alias and dies at `(k)` with "unexpected trailing
    tokens after query". Both are ANSI reserved words, so neither is usable as
    a bare alias anyway.

    ⚠ `union` / `intersect` / `except` are the same case: without them
    `SELECT k, g, v FROM t UNION ALL SELECT k, g, v FROM t` dies with
    "unexpected trailing tokens after query" even though the set-operator tail
    (`_parse_set_operator_tail`) exists, because `union` is eaten as `t`'s
    implicit ALIAS and the tail never sees its own keyword. Only a branch
    ending in a structural keyword (a `WHERE`) would get through: the
    production would be correct and UNREACHABLE.

    ⭐ SO A NEW STATEMENT-TAIL KEYWORD NEEDS A ROW HERE AS WELL AS A
    PRODUCTION. The alias grab runs FIRST and silently wins; the symptom is
    always this same trailing-token message, which names neither.

    ⛔⛔ `semi` / `anti` / `asof` / `positional` are the worst case, because
    without them the result is a SILENT WRONG ANSWER rather than a refusal:
    `FROM L SEMI JOIN R ON lk = rk` would parse as `FROM L AS semi JOIN R`, an
    INNER join answering 5 fanned-out rows plus R's columns where DuckDB
    v1.5.3 answers 3 rows of L's; `L POSITIONAL JOIN R` would answer a CROSS
    JOIN; `L ASOF [LEFT|RIGHT|INNER] JOIN R ON lk >= rk` would answer an
    ordinary inequality join of that kind. The ALIASED form `L AS a SEMI JOIN
    ...` fails the other way — the alias slot is full, so `semi` falls out of
    the FROM loop as a trailing token. ⚠ THE TWO FAILURES ARE WHY THESE WORDS
    ARE TESTED IN BOTH SPELLINGS: a test of only the aliased form goes RED for
    the right keyword and the wrong reason (a refusal), and hides the bare
    form's wrong answer.

    ⚠ `fetch` is here because its FETCH FIRST arm is otherwise UNREACHABLE
    without an explicit alias (`FROM t FETCH FIRST 1 ROWS ONLY` would eat
    `fetch` as t's alias). `qualify` / `window` / `pivot` / `unpivot` /
    `tablesample` are here so `_refuse_unsupported_clause` can NAME them
    instead of dying on the token after. `isnull` / `notnull` are here so the
    SELECT-list grab never takes them as an alias (they are postfix NULL tests
    — `_parse_null_test_suffix`). DuckDB reserves every one of these words in
    the table-alias position (measured: `SELECT * FROM t semi` is a Parser
    Error there), so none of them costs a query DuckDB accepts.

    ★ THE LIST COVERS THE CLASS, NOT A SAMPLE. Every one of DuckDB v1.5.3's 489
    `duckdb_keywords()`, put after a table, after a derived table, after a
    JOIN's right table and after a SELECT expression, each followed by 18
    continuations and graded by DuckDB's own `json_serialize_sql` against this
    parser, finds 82 words this parser takes as a bare table alias that DuckDB
    reserves there; only the rows above have a continuation DuckDB ACCEPTS —
    every other word dies on its next token here. The SELECT-expression
    position is `_refuse_unserved_operator_word`'s.
        """
        if self._kind() != TK_IDENT:
            return False
        ref w = self.tokens[self.pos].text
        return (
            w == "from" or w == "where" or w == "group" or w == "order"
            or w == "limit" or w == "offset" or w == "having" or w == "as"
            or w == "and" or w == "or"
            or w == "join" or w == "inner" or w == "cross" or w == "on"
            or w == "left" or w == "right" or w == "full" or w == "outer"
            or w == "natural" or w == "using"
            or w == "union" or w == "intersect" or w == "except"
            or w == "semi" or w == "anti" or w == "asof" or w == "positional"
            or w == "fetch" or w == "qualify" or w == "window"
            or w == "pivot" or w == "unpivot" or w == "tablesample"
            or w == "isnull" or w == "notnull"
        )

    def _parse_expr_list(mut self) raises -> Slab[SqlExpr]:
        var lst = Slab[SqlExpr]()
        while True:
            lst.append(self._parse_expr())
            if self._kind() == TK_COMMA:
                self._advance()
                continue
            break
        return lst^

    def _parse_order_list(mut self) raises -> Slab[OrderKey]:
        var lst = Slab[OrderKey]()
        while True:
            var e = self._parse_expr()
            var desc = False
            if self._is_kw("asc"):
                self._advance()
            elif self._is_kw("desc"):
                self._advance()
                desc = True
            # NULLS FIRST / NULLS LAST:
            # `NULLS FIRST` / `NULLS LAST`, standard SQL and DuckDB-accepted.
            #
            # ⚠ ABSENT IS NOT `LAST`, AND THAT IS WHY THIS IS AN `Optional`.
            # Omitting the clause leaves the plan free to DERIVE the placement
            # from the direction, which is what a query without the clause
            # relies on; spelling it out pins it. The two are the same value on
            # an ascending key and OPPOSITE ones on a descending key.
            #
            # ⛔ `NULLS` ALONE IS A SYNTAX ERROR, NOT A SILENT SKIP. The word
            # only ever appears here followed by FIRST or LAST, so consuming it
            # and shrugging would accept `ORDER BY v NULLS` and answer with a
            # placement the writer did not choose.
            var nf = Optional[Bool](None)
            if self._is_kw("nulls"):
                self._advance()
                if self._is_kw("first"):
                    self._advance()
                    nf = Optional[Bool](True)
                elif self._is_kw("last"):
                    self._advance()
                    nf = Optional[Bool](False)
                else:
                    raise Error(
                        "SQL syntax error: ORDER BY ... NULLS expects FIRST or"
                        " LAST"
                    )
            lst.append(OrderKey(e^, desc, nf^))
            if self._kind() == TK_COMMA:
                self._advance()
                continue
            break
        return lst^

    # -------------------------------------------------------------------------
    # Expression grammar (precedence climbing)
    # -------------------------------------------------------------------------
    def _parse_expr(mut self) raises -> SqlExpr:
        return self._parse_or()

    def _parse_or(mut self) raises -> SqlExpr:
        var left = self._parse_and()
        while self._is_kw("or"):
            self._advance()
            var right = self._parse_and()
            left = SqlExpr.binary(SXOP_OR, left^, right^)
        return left^

    def _parse_and(mut self) raises -> SqlExpr:
        var left = self._parse_not()
        while self._is_kw("and"):
            self._advance()
            var right = self._parse_not()
            left = SqlExpr.binary(SXOP_AND, left^, right^)
        return left^

    def _parse_not(mut self) raises -> SqlExpr:
        """Prefix `NOT <predicate>`, at SQL's precedence: tighter than AND/OR
        and looser than a comparison — so `NOT a = b` is `NOT (a = b)` and
        `NOT a AND b` is `(NOT a) AND b`.

        ⚠ IT MUST NOT SWALLOW `NOT EXISTS`. That form is parsed one level down
        (`_parse_cmp`) into a SUBQ_NOT_EXISTS side-table entry the binder lowers
        to a real ANTI JOIN. Taking it here would instead produce
        `UN_NOT(<semi-join predicate>)` — the same truth value obtained by
        materialising the semi-join and negating it, which is a different and
        much worse plan. The `exists` lookahead is load-bearing, not defensive.

        `x NOT IN (...)` / `x NOT LIKE p` keep their postfix arm in `_parse_cmp`
        (the NOT follows a left operand, so it never reaches here). The PREFIX
        spelling `NOT x IN (...)` does reach here and negates the whole
        predicate, which is what SQL says it means.
        """
        if self._is_kw("not") and self.pos + 1 < len(self.tokens):
            ref nx = self.tokens[self.pos + 1]
            if not (nx.kind == TK_IDENT and nx.text == "exists"):
                self._advance()  # consume NOT
                var operand = self._parse_not()  # right-associative: NOT NOT x
                # `NOT (x IN (...))` is DuckDB's NOT IN:
                # re-mark the IN list's comparisons so the binder keeps a cast.
                _mark_in_list_negated(operand)
                return SqlExpr.unary(SXUN_NOT, operand^)
        return self._parse_cmp()

    def _parse_cmp(mut self) raises -> SqlExpr:
        # Prefix predicate: [NOT] EXISTS (SELECT ...) — no left operand.
        # Parked in the subquery side-table (SUBQ_EXISTS / SUBQ_NOT_EXISTS); the
        # binder lowers it to a correlated subquery Expr (SEMI / ANTI). Checked
        # BEFORE `_parse_add` so the `EXISTS`/`NOT EXISTS` keyword is not mis-read
        # as a column reference.
        if self._is_kw("exists"):
            return self._parse_exists_subquery(False)
        if self._is_kw("not") and self.pos + 1 < len(self.tokens):
            ref nx0 = self.tokens[self.pos + 1]
            if nx0.kind == TK_IDENT and nx0.text == "exists":
                self._advance()  # consume NOT
                return self._parse_exists_subquery(True)
        var left = self._parse_op()
        # ★ A NULL TEST DIRECTLY ON THE OPERAND (`x IS NULL`, `x + 1 ISNULL`).
        # Returned as-is: `x IS NULL = y` is not a shape this
        # grammar serves, and it falls out as a trailing token.
        var at = self.pos
        left = self._parse_null_test_suffix(left^)
        if self.pos != at:
            return left^
        # Postfix keyword predicates: [NOT] IN (...), [NOT] LIKE pat,
        # [NOT] ILIKE pat, [NOT] SIMILAR TO pat, [NOT] BETWEEN a AND b. A
        # leading NOT that prefixes one of those is handled here; a bare prefix
        # `NOT` is `_parse_not`'s, one level up. A NULL test AFTER one tests the
        # whole predicate (see the helper).
        if (
            self._is_kw("in") or self._is_kw("like") or self._is_kw("between")
            or self._is_kw("ilike") or self._is_similar_to_at(self.pos)
        ):
            return self._parse_null_test_suffix(
                self._parse_postfix_pred(left^, False)
            )
        # ★ THE SYMBOL SPELLINGS: `~~` / `!~~` /
        # `~~*` / `!~~*` ARE [NOT] LIKE / [NOT] ILIKE — the same node, the
        # same string-literal pattern rule — and `~` / `!~` are [NOT]
        # SIMILAR TO, i.e. `regexp_full_match` (DuckDB v1.5.3 prints exactly
        # those names for them, MEASURED).
        if self._kind() == TK_LIKE_SYM:
            var code = Int(self.tokens[self.pos].int_val)
            self._advance()
            var sym = String("~~")
            if code == 1:
                sym = String("!~~")
            elif code == 2:
                sym = String("~~*")
            elif code == 3:
                sym = String("!~~*")
            if self._kind() != TK_STRING:
                raise Error("SQL syntax error: " + sym + " expects a string pattern")
            var spat = String(self.tokens[self.pos].text)
            self._advance()
            var sflav = SXLIKE_ILIKE if code >= 2 else SXLIKE_LIKE
            return self._parse_null_test_suffix(
                SqlExpr.like(left^, spat, code == 1 or code == 3, sflav)
            )
        if self._kind() == TK_TILDE or self._kind() == TK_NTILDE:
            var tneg = self._kind() == TK_NTILDE
            self._advance()
            var tpat = self._parse_op()
            var targs = Slab[SqlExpr]()
            targs.append(left^)
            targs.append(tpat^)
            var tm = SqlExpr.call(String("regexp_full_match"), targs^)
            if tneg:
                return self._parse_null_test_suffix(SqlExpr.unary(SXUN_NOT, tm^))
            return self._parse_null_test_suffix(tm^)
        if self._is_kw("not") and self.pos + 1 < len(self.tokens):
            ref nx = self.tokens[self.pos + 1]
            if nx.kind == TK_IDENT and (
                nx.text == "in" or nx.text == "like" or nx.text == "between"
                or nx.text == "ilike" or self._is_similar_to_at(self.pos + 1)
            ):
                self._advance()  # consume NOT
                return self._parse_null_test_suffix(
                    self._parse_postfix_pred(left^, True)
                )
        var k = self._kind()
        var op: UInt8
        if k == TK_EQ:
            op = SXOP_EQ
        elif k == TK_NE:
            op = SXOP_NE
        elif k == TK_LT:
            op = SXOP_LT
        elif k == TK_LE:
            op = SXOP_LE
        elif k == TK_GT:
            op = SXOP_GT
        elif k == TK_GE:
            op = SXOP_GE
        else:
            return left^
        self._advance()
        var right = self._parse_op()
        # ⚠ A NULL TEST AFTER A COMPARISON TESTS THE **COMPARISON**, at DuckDB's
        # (PostgreSQL's) precedence, where IS / ISNULL / NOTNULL bind LOOSER
        # than `=`. Measured v1.5.3: `SELECT NULL = 1 IS NULL` and
        # `SELECT NULL = 1 ISNULL` are both TRUE, i.e. `(NULL = 1) IS NULL`.
        return self._parse_null_test_suffix(SqlExpr.binary(op, left^, right^))

    def _parse_null_test_suffix(mut self, var operand: SqlExpr) raises -> SqlExpr:
        """Apply every postfix NULL test that follows `operand`: `IS NULL`,
        `IS NOT NULL`, `ISNULL`, `NOTNULL`, `NOT NULL`. Returns `operand`
        unchanged when none follows. Chains (`x ISNULL IS NULL`), as DuckDB's
        grammar does.

        ★ `IS [NOT] NULL` is how a user asks for missing data, and the only
        reader of a column's VALIDITY. `UN_IS_NULL` / `UN_IS_NOT_NULL` are the
        plan IR nodes it builds.

        ⚠ `IS` IS NOT MADE A RESERVED WORD. The tokenizer lower-folds every
        identifier and the parser classifies by text, so a column named `is`
        keeps working: this arm fires only on `IS` FOLLOWED BY `NULL` or `NOT
        NULL`, and anything else after `IS` is a syntax error naming what was
        expected rather than a silently mis-parsed column.

        ⛔ `ISNULL` / `NOTNULL` / `x NOT NULL` — the PostgreSQL /
        SQLite spellings of the same two tests, all three accepted by DuckDB
        v1.5.3 (measured: `SELECT 2 NOT NULL, NULL NOT NULL` is `true, false`).
        WITHOUT THIS HELPER `ISNULL` / `NOTNULL` ARE A SILENT WRONG ANSWER, NOT
        A REFUSAL: in the SELECT list the word falls through to the implicit-
        alias grab, so `SELECT k ISNULL FROM t` would answer the column `k`
        itself under the name `isnull` — the right row count and a plausible
        column, holding values instead of booleans — and `SELECT k = 2 ISNULL`
        the COMPARISON under that name. Both words are also in
        `_is_structural_kw`, so a position this helper does not reach
        refuses instead of aliasing.
        """
        var e = operand^
        while True:
            if self._is_kw("is"):
                self._advance()  # consume IS
                var negate = False
                if self._is_kw("not"):
                    self._advance()
                    negate = True
                if not self._is_kw("null"):
                    raise Error(
                        "SQL syntax error: expected NULL after IS"
                        + (" NOT" if negate else "")
                        + " (only `IS [NOT] NULL` is supported; `IS TRUE` /"
                        + " `IS DISTINCT FROM` are not)"
                    )
                self._advance()  # consume NULL
                e = SqlExpr.unary(
                    SXUN_IS_NOT_NULL if negate else SXUN_IS_NULL, e^
                )
            elif self._is_kw("isnull"):
                self._advance()
                e = SqlExpr.unary(SXUN_IS_NULL, e^)
            elif self._is_kw("notnull"):
                self._advance()
                e = SqlExpr.unary(SXUN_IS_NOT_NULL, e^)
            elif (
                self._is_kw("not")
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_IDENT
                and self.tokens[self.pos + 1].text == "null"
            ):
                self._advance()  # NOT
                self._advance()  # NULL
                e = SqlExpr.unary(SXUN_IS_NOT_NULL, e^)
            else:
                return e^

    def _parse_postfix_pred(mut self, var left: SqlExpr, negate: Bool) raises -> SqlExpr:
        """Parse `[NOT] IN (...)`, `[NOT] LIKE pat`, or `[NOT] BETWEEN a AND b`
        following an already-parsed `left`. IN and BETWEEN are DESUGARED into
        existing binary ops (no new AST node); LIKE builds an SX_LIKE node."""
        if self._is_kw("in"):
            self._advance()
            self._expect(TK_LPAREN, "'('")
            # `x [NOT] IN (SELECT ...)` — a subquery membership test. Parked
            # in the subquery side-table (SUBQ_IN / SUBQ_NOT_IN) with the LHS
            # column name; the binder rewrites it to an EXISTS / NOT-EXISTS
            # correlated subquery (SEMI / ANTI) with a synthesized
            # `inner_proj = x` equi-key. The LHS must be a column.
            if self._is_kw("select"):
                var sq_body = self._parse_select_stmt()
                self._expect(TK_RPAREN, "')' to close IN subquery")
                if left.tag != SX_COLUMN:
                    raise Error("SQL not supported: `IN (subquery)` requires a column on the left")
                var in_kind = SUBQ_NOT_IN if negate else SUBQ_IN
                var idx = len(self.subqueries)
                self.subqueries.append(SubqueryDef(sq_body^, in_kind, String(left.text), String(""), in_lhs_qualifier=String(left.qualifier)))
                return SqlExpr.subquery(idx)
            # IN -> OR-of-EQ ; NOT IN -> AND-of-NE. `left` is reused per element
            # via `.copy()`; the original is dropped when this scope ends.
            var acc: Optional[SqlExpr] = None
            while True:
                var v = self._parse_expr()
                var cmp: SqlExpr
                # ⛔ THE DESUGARED COMPARISON REMEMBERS IT CAME FROM AN IN LIST.
                # DuckDB 1.5.3 unwraps
                # `CAST(col AS <int>) IN (...)` but NOT `... NOT IN (...)` nor
                # `NOT (... IN (...))` -- those keep the cast and RAISE its
                # Conversion Error -- so the binder's int-cast unwrap must be
                # able to tell a NOT-IN `<>` from a written one. `text` is unused
                # on SX_BINARY; the space keeps it out of every identifier.
                if negate:
                    cmp = SqlExpr.binary(SXOP_NE, left.copy(), v^)
                    cmp.text = String("not in")
                else:
                    cmp = SqlExpr.binary(SXOP_EQ, left.copy(), v^)
                    cmp.text = String("in")
                if acc:
                    var joiner = SXOP_AND if negate else SXOP_OR
                    var j = SqlExpr.binary(joiner, acc.take(), cmp^)
                    # The desugar's own joiner carries the mark too, so a NOT
                    # can tell ONE IN list from a user-written OR of them.
                    j.text = String("not in") if negate else String("in")
                    acc = Optional(j^)
                else:
                    acc = Optional(cmp^)
                if self._kind() == TK_COMMA:
                    self._advance()
                    continue
                break
            self._expect(TK_RPAREN, "')'")
            if not acc:
                raise Error("SQL syntax error: empty IN list")
            return acc.take()
        if self._is_kw("between"):
            self._advance()
            var lo = self._parse_op()
            self._expect_kw("and")
            var hi = self._parse_op()
            if negate:
                # NOT BETWEEN -> (left < lo) OR (left > hi)
                var lt = SqlExpr.binary(SXOP_LT, left.copy(), lo^)
                var gt = SqlExpr.binary(SXOP_GT, left^, hi^)
                return SqlExpr.binary(SXOP_OR, lt^, gt^)
            # BETWEEN -> (left >= lo) AND (left <= hi)
            var ge = SqlExpr.binary(SXOP_GE, left.copy(), lo^)
            var le = SqlExpr.binary(SXOP_LE, left^, hi^)
            return SqlExpr.binary(SXOP_AND, ge^, le^)
        if self._is_similar_to_at(self.pos):
            # ★ `x [NOT] SIMILAR TO p`. DuckDB v1.5.3
            # does NOT translate the SQL-standard SIMILAR TO syntax (`%` / `_`
            # wildcards): it binds the operator to `regexp_full_match(x, p)`,
            # and so does this — MEASURED: `'abc' SIMILAR TO 'a%'` is FALSE
            # there, `'a%c' SIMILAR TO 'a%c'` TRUE, and the column it prints is
            # `regexp_full_match(s, 'a.*')`. NOT SIMILAR TO prints
            # `(NOT regexp_full_match(...))` — the `SXUN_NOT` wrapper below.
            # The pattern is an ordinary operand here and the regexp binder
            # refuses a non-literal one BY NAME (`_regexp_literal_string`).
            self._advance()  # 'similar'
            self._advance()  # 'to'
            var spat = self._parse_op()
            var sargs = Slab[SqlExpr]()
            sargs.append(left^)
            sargs.append(spat^)
            var sm = SqlExpr.call(String("regexp_full_match"), sargs^)
            if negate:
                return SqlExpr.unary(SXUN_NOT, sm^)
            return sm^
        # LIKE / ILIKE
        var flavour = SXLIKE_LIKE
        var spelled = String("LIKE")
        if self._is_kw("ilike"):
            # ★ `x [NOT] ILIKE 'p'` — the SAME node as
            # LIKE with the case-insensitive flavour; the binder folds BOTH
            # sides with the engine's own `lower()` (see `_bind_like`).
            self._advance()
            flavour = SXLIKE_ILIKE
            spelled = String("ILIKE")
        else:
            self._expect_kw("like")
        if self._kind() != TK_STRING:
            raise Error("SQL syntax error: " + spelled + " expects a string pattern")
        var pat = String(self.tokens[self.pos].text)
        self._advance()
        return SqlExpr.like(left^, pat, negate, flavour)

    def _position_in_form(self, lparen: Int) -> Bool:
        """The parenthesised list opening at `lparen` holds a TOP-LEVEL `IN`
        before its first top-level `,` or its closing `)` — i.e. it is
        `POSITION(x IN y)` and not the call `position(a, b)`. A nested `IN`
        (`position(x IN (1, 2))` would still be the grammar form, as in DuckDB,
        whose parser commits on the keyword) is inside parentheses and so is
        not what makes the decision; only depth 1 counts."""
        var depth = 0
        var i = lparen
        while i < len(self.tokens):
            ref t = self.tokens[i]
            if t.kind == TK_LPAREN:
                depth += 1
            elif t.kind == TK_RPAREN:
                depth -= 1
                if depth == 0:
                    return False
            elif depth == 1 and t.kind == TK_COMMA:
                return False
            elif depth == 1 and t.kind == TK_IDENT and t.text == "in":
                return True
            elif t.kind == TK_EOF:
                return False
            i += 1
        return False

    def _is_similar_to_at(self, at: Int) -> Bool:
        """The tokens at `at` are `SIMILAR TO`. ⚠ BOTH WORDS: `similar` alone
        is an ordinary identifier (a column may be called `similar`), and only
        the pair is the operator."""
        return (
            at + 1 < len(self.tokens)
            and self.tokens[at].kind == TK_IDENT
            and self.tokens[at].text == "similar"
            and self.tokens[at + 1].kind == TK_IDENT
            and self.tokens[at + 1].text == "to"
        )

    def _parse_exists_subquery(mut self, negate: Bool) raises -> SqlExpr:
        """Parse `[NOT] EXISTS (SELECT ...)` — the `EXISTS`/`NOT` keyword is
        already consumed by the caller. Parks the body in the subquery side-table
        (SUBQ_EXISTS / SUBQ_NOT_EXISTS) and returns a SX_SUBQUERY reference node."""
        self._expect_kw("exists")
        self._expect(TK_LPAREN, "'(' after EXISTS")
        if not self._is_kw("select"):
            raise Error("SQL syntax error: EXISTS expects a subquery `(SELECT ...)`")
        var body = self._parse_select_stmt()
        self._expect(TK_RPAREN, "')' to close EXISTS subquery")
        var kind = SUBQ_NOT_EXISTS if negate else SUBQ_EXISTS
        var idx = len(self.subqueries)
        self.subqueries.append(SubqueryDef(body^, kind, String(""), String("")))
        return SqlExpr.subquery(idx)

    def _parse_case(mut self) raises -> SqlExpr:
        """Parse a `CASE ... END` expression — the leading `case` keyword is already
        consumed by `_parse_primary`. Two forms:
          searched:  CASE WHEN cond THEN res [WHEN ...]* [ELSE d] END
          simple:    CASE operand WHEN val THEN res [WHEN ...]* [ELSE d] END
        A SIMPLE CASE is DESUGARED here into the searched form: each branch's
        condition becomes the synthesized `operand = val` comparison (the operand
        is `.copy()`-ed per branch, exactly as the desugared IN list reuses its
        LHS), so the AST + binder only ever see the searched shape. Requires at
        least one WHEN. The optional ELSE default is parked in a 0/1-entry Slab —
        an omitted ELSE binds to SQL NULL at the binder."""
        # A leading token that is NOT `when` is the simple-CASE operand.
        var operand: Optional[SqlExpr] = None
        if not self._is_kw("when"):
            operand = self._parse_expr()
        if not self._is_kw("when"):
            raise Error("SQL syntax error: CASE requires at least one WHEN clause")
        var conds = Slab[SqlExpr]()
        var results = Slab[SqlExpr]()
        while self._is_kw("when"):
            self._advance()  # when
            # The WHEN operand: a full boolean condition (searched) or a match
            # value (simple). Parsing stops at `then` (not an operator token).
            var branch = self._parse_expr()
            self._expect_kw("then")
            var res = self._parse_expr()
            if operand:
                # simple CASE -> `operand = branch`
                conds.append(SqlExpr.binary(SXOP_EQ, operand.value().copy(), branch^))
            else:
                conds.append(branch^)
            results.append(res^)
        var otherwise = Slab[SqlExpr]()
        if self._is_kw("else"):
            self._advance()
            otherwise.append(self._parse_expr())
        self._expect_kw("end")
        return SqlExpr.case(conds^, results^, otherwise^)

    def _parse_op(mut self) raises -> SqlExpr:
        """`||` and `^@` — DuckDB's "any other operator" precedence level
        (`%left Op` in its grammar): LOOSER than `+`/`-`, TIGHTER than a
        comparison, left-associative. MEASURED v1.5.3 (the column names are
        DuckDB's own parenthesisation):

            'a' || 1 + 2        -> ('a' || (1 + 2))            'a3'
            1 + 2 || 'x'        -> ((1 + 2) || 'x')            '3x'
            'a' || 'b' = 'ab'   -> (('a' || 'b') = 'ab')       TRUE
            'a' || 'b' ^@ 'a'   -> (('a' || 'b') ^@ 'a')       TRUE

        What each operator MEANS is the binder's (`_bind_sql_operator`)."""
        var left = self._parse_add()
        while self._kind() == TK_DPIPE or self._kind() == TK_CARET_AT:
            var op = SXOP_CONCAT if self._kind() == TK_DPIPE else SXOP_STARTS_WITH
            self._advance()
            var right = self._parse_add()
            left = SqlExpr.binary(op, left^, right^)
        return left^

    def _parse_add(mut self) raises -> SqlExpr:
        var left = self._parse_mul()
        while self._kind() == TK_PLUS or self._kind() == TK_MINUS:
            var op = SXOP_ADD if self._kind() == TK_PLUS else SXOP_SUB
            self._advance()
            var right = self._parse_mul()
            left = SqlExpr.binary(op, left^, right^)
        return left^

    def _parse_mul(mut self) raises -> SqlExpr:
        """`*`, `/`, `//`, `%` — one precedence level, left-associative, as in
        DuckDB v1.5.3 (MEASURED: `7 + 5 // 2` = 9, `2 * 7 % 4` = 2,
        `7 % 4 * 2` = 6, `8 / 2 // 3` prints `((8 / 2) // 3)`). The operands
        are `_parse_pow`'s: `^` binds tighter (`2 * 3 ^ 2` = 18.0).

        ⚠ `/` AND `//` ARE DIFFERENT OPERATORS: `7 / 2` = 3.5 (DOUBLE) and
        `7 // 2` = 3 (INTEGER); the binder decides what each MEANS
        (`_bind_sql_division`). `%` is `mod()` exactly."""
        var left = self._parse_pow()
        while (
            self._kind() == TK_STAR
            or self._kind() == TK_SLASH
            or self._kind() == TK_DSLASH
            or self._kind() == TK_PERCENT
        ):
            var k = self._kind()
            var op = SXOP_MUL
            if k == TK_SLASH:
                op = SXOP_DIV
            elif k == TK_DSLASH:
                op = SXOP_IDIV
            elif k == TK_PERCENT:
                op = SXOP_MOD
            self._advance()
            var right = self._parse_pow()
            left = SqlExpr.binary(op, left^, right^)
        return left^

    def _parse_pow(mut self) raises -> SqlExpr:
        """`^` — power, one level TIGHTER than `*` and LOOSER than unary minus,
        LEFT-associative. MEASURED DuckDB v1.5.3:

            2 ^ 3 ^ 2   -> ((2 ^ 3) ^ 2)   64.0   (left-assoc, NOT PostgreSQL-style right)
            -2 ^ 2      -> 4.0                    (unary minus binds tighter)
            2 * 3 ^ 2   -> (2 * (3 ^ 2))   18.0
            2 ^ 10      -> DOUBLE 1024.0          (`pow()`, even over integers)
        """
        var left = self._parse_unary()
        while self._kind() == TK_CARET:
            self._advance()
            var right = self._parse_unary()
            left = SqlExpr.binary(SXOP_POW, left^, right^)
        return left^

    def _parse_unary(mut self) raises -> SqlExpr:
        if self._kind() == TK_MINUS:
            self._advance()
            # A negative LITERAL stays a literal (`-3` is the constant DuckDB
            # prints as `-3`, and `-1::DOUBLE` is `(-1)::DOUBLE` there).
            if self._kind() == TK_INT:
                var v = self.tokens[self.pos].int_val
                var big = String(self.tokens[self.pos].text)
                self._advance()
                if big.byte_length() > 0 and big != "9223372036854775808":
                    # A literal past BIGINT negated: still past it (DuckDB:
                    # HUGEINT). Kept as a NEGATE over the big literal so the
                    # binder refuses it by name rather than folding its
                    # wrapped bits. `-9223372036854775808` IS BIGINT's minimum
                    # and its wrapped bits are exactly Int64.MIN.
                    var lit = SqlExpr.int_lit(v)
                    lit.text = big^
                    return self._parse_cast_suffix(
                        SqlExpr.unary(SXUN_NEGATE, lit^)
                    )
                return self._parse_cast_suffix(SqlExpr.int_lit(-v))
            elif self._kind() == TK_FLOAT:
                var f = self.tokens[self.pos].float_val
                self._advance()
                return self._parse_cast_suffix(SqlExpr.float_lit(-f))
            # ★ UNARY MINUS ON AN EXPRESSION
            # — `-a`, `-(a + 1)`, `ORDER BY -k`. It binds TIGHTER than
            # `^` and `*` (DuckDB: `- a * 2` is `(-(a) * 2)`, `-2 ^ 2` is
            # 4.0), so its operand is another unary, which also serves `- -a`.
            # ⭐ A negated LITERAL folds, as DuckDB's printer does: `- -3`
            # prints `3` there, and the literal arm above cannot see it because
            # the second `-` is not a number token.
            var operand = self._parse_unary()
            if (
                operand.tag == SX_INT
                and operand.int_val != Int64.MIN
                and operand.text.byte_length() == 0
            ):
                return SqlExpr.int_lit(-operand.int_val)
            if operand.tag == SX_FLOAT:
                return SqlExpr.float_lit(-operand.float_val)
            return SqlExpr.unary(SXUN_NEGATE, operand^)
        if self._kind() == TK_AT:
            # ★ PREFIX `@` — absolute value. ⚠ ITS
            # OPERAND IS A WHOLE ARITHMETIC EXPRESSION, NOT ONE FACTOR: DuckDB
            # gives prefix operators the LOW "Op" precedence, so MEASURED
            # v1.5.3 `@ -3 + 1` is `@((-3 + 1))` = 2, `@ -2 * 3` is 6, and
            # `@ a || b` is `(@(a) || b)` (the `||` is the same level, so it
            # does not join the operand).
            self._advance()
            var aoperand = self._parse_add()
            return SqlExpr.unary(SXUN_ABS, aoperand^)
        var base = self._parse_primary()
        return self._parse_cast_suffix(base^)

    def _parse_cast_suffix(mut self, var base: SqlExpr) raises -> SqlExpr:
        """`<expr>::<type>` — the POSTFIX cast operator.

        ⭐ IT BINDS TIGHTER THAN EVERYTHING, INCLUDING UNARY MINUS, which is
        why the two negative-literal arms above route through it as well
        instead of returning directly. DuckDB v1.5.3 parses `-1::DOUBLE` as
        `(-1)::DOUBLE` and this engine folds a negated literal into a
        literal, so the two readings cannot differ in VALUE here — but a `::`
        that simply did not apply after a negative literal would raise
        `expected ')'` from two levels up, which is the wrong layer telling a
        user the wrong thing.

        ⚠ IT LOOPS. `x::BIGINT::DOUBLE` is legal in DuckDB and is two casts;
        a single `if` would parse the first and leave the second to blow up in
        the caller.

        ⛔ IT DESUGARS TO THE SAME CALL NODE THE `CAST(x AS T)` ARM BUILDS, and
        that is the whole reason there is one binder arm. The two spellings ARE
        the same operation in the dialect being copied; giving them two
        lowerings lets one spelling be supported while the other is not, as
        `EXTRACT(DOW FROM x)` and `date_part('dow', x)` could be.
        """
        var e = base^
        while self._kind() == TK_DCOLON:
            self._advance()  # '::'
            var ty = self._parse_sql_type_name(String("the '::' cast operator"))
            var cargs = Slab[SqlExpr]()
            cargs.append(e^)
            cargs.append(SqlExpr.string_lit(ty))
            e = SqlExpr.call(String(_CAST_DESUGAR_NAME), cargs^)
        return e^

    def _parse_sql_type_name(mut self, ctx: String) raises -> String:
        """The TARGET TYPE of a cast, as written, lower-folded by the lexer.

        ⛔ THE PARSER VALIDATES NO TYPE NAME AND THAT IS DELIBERATE — the same
        division of labour the `EXTRACT` arm states one screen up. This knows
        the SHAPE (a word, optionally two words, optionally parameterised);
        WHICH types this engine can convert to is the binder's table, and
        duplicating it here would give an unsupported target two different
        error messages depending on which file noticed first.

        ⭐ THE PARAMETERS TRAVEL **INSIDE** THE TOKEN — `decimal(18,4)`, not
        `decimal` — so the binder's refusal can name the type the user
        actually wrote. A refusal that says DECIMAL when the query said
        DECIMAL(18,4) invites the reader to try a different precision.
        """
        if self._kind() != TK_IDENT:
            raise Error(
                "SQL syntax error: " + ctx + " expects a type name, as in"
                + " CAST(<expr> AS BIGINT) or <expr>::BIGINT"
            )
        var ty = String(self.tokens[self.pos].text)
        self._advance()
        # `DOUBLE PRECISION` is TWO words in the standard and one type. Taken
        # only when the second word is exactly `precision`, so a select list
        # like `CAST(v AS DOUBLE) precision` — an alias that happens to be
        # spelled that way — is not silently swallowed... which it would be,
        # were this not inside the parentheses. Inside them there is no alias
        # position, so the reading is unambiguous.
        if (
            ty == "double"
            and self._kind() == TK_IDENT
            and self.tokens[self.pos].text == "precision"
        ):
            self._advance()
            ty = String("double precision")
        if self._kind() == TK_LPAREN:
            self._advance()  # '('
            ty += "("
            var first = True
            while self._kind() == TK_INT:
                if not first:
                    ty += ","
                # DuckDB 1.5.3 refuses a type parameter past BIGINT too, but
                # NOT with a Conversion Error (MEASURED: `DECIMAL(<big>, 2)` is
                # a Binder Error on the width, `VARCHAR(<big>)` a Parser Error).
                ty += String(self._small_int_tok(
                    "type parameter",
                    "DuckDB v1.5.3 refuses it too, as a Binder or Parser Error",
                ))
                first = False
                self._advance()
                if self._kind() == TK_COMMA:
                    self._advance()
                else:
                    break
            self._expect(TK_RPAREN, "')' to close the type parameters")
            ty += ")"
        return ty^

    def _parse_primary(mut self) raises -> SqlExpr:
        var k = self._kind()
        if k == TK_INT:
            var v = self.tokens[self.pos].int_val
            var big = String(self.tokens[self.pos].text)
            self._advance()
            var lit = SqlExpr.int_lit(v)
            # Past BIGINT: the digits ride in `text` (see `tokenize`).
            lit.text = big^
            return lit^
        if k == TK_FLOAT:
            var f = self.tokens[self.pos].float_val
            self._advance()
            return SqlExpr.float_lit(f)
        if k == TK_STRING:
            var s = String(self.tokens[self.pos].text)
            self._advance()
            return SqlExpr.string_lit(s)
        if k == TK_STAR:
            self._advance()
            return SqlExpr.star()
        if k == TK_LPAREN:
            self._advance()
            # A parenthesized SELECT is a scalar subquery operand — reuses
            # the SAME re-entrant nested-SELECT primitive the CTE bodies use, so
            # the subquery gets the entire grammar. The binder lowers it to an
            # uncorrelated `CORR_KIND_SCALAR` subquery -> broadcast cross-join.
            if self._is_kw("select"):
                var body = self._parse_select_stmt()
                self._expect(TK_RPAREN, "')' to close subquery")
                # Park the body in the flat side-table; the node carries only
                # its index. A NESTED subquery inside `body` was appended by the
                # recursive `_parse_select_stmt` above, so its index is lower —
                # the append order is inner-before-outer, which the binder walks
                # by index (no dependence on ordering).
                var idx = len(self.subqueries)
                self.subqueries.append(SubqueryDef(body^, SUBQ_SCALAR, String(""), String("")))
                return SqlExpr.subquery(idx)
            var inner = self._parse_expr()
            self._expect(TK_RPAREN, "')'")
            return inner^
        if k == TK_IDENT:
            var name = String(self.tokens[self.pos].text)
            # CASE expression:  CASE [operand] WHEN c THEN r ... [ELSE d] END.
            # `case` is a reserved word here — the tokenizer lower-folds it, and the
            # corpus never uses `case` as a column name.
            if name == "case":
                self._advance()  # consume 'case'
                return self._parse_case()
            # ★ boolean literal: TRUE / FALSE.
            #
            # ⚠ ONLY WHEN THE NEXT TOKEN CANNOT MAKE IT A COLUMN. A table is
            # allowed a column called `true`, and without this arm the
            # tokenizer's lower-folded ident binds as exactly that
            # (`WHERE flag = true` raises "unknown column 'true'"). So the
            # keyword reading is taken only where a column reference cannot
            # continue — a `.` would make it a qualifier (`true.x`) and a `(`
            # a function call — and everywhere else the identifier reading
            # survives.
            if name == "true" or name == "false":
                var nk = (
                    self.tokens[self.pos + 1].kind
                    if self.pos + 1 < len(self.tokens)
                    else TK_EOF
                )
                if nk != TK_DOT and nk != TK_LPAREN:
                    self._advance()
                    return SqlExpr.bool_lit(name == "true")
            # ★ the NULL literal (SX_NULL) — the same guard as
            # TRUE / FALSE above, for the same reason: `null.x` and `null(...)`
            # keep their column / call readings.
            if name == "null":
                var nk2 = (
                    self.tokens[self.pos + 1].kind
                    if self.pos + 1 < len(self.tokens)
                    else TK_EOF
                )
                if nk2 != TK_DOT and nk2 != TK_LPAREN:
                    self._advance()
                    return SqlExpr.null_lit()
            # date literal:  date 'YYYY-MM-DD'
            if name == "date" and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].kind == TK_STRING:
                self._advance()  # 'date'
                var ds = String(self.tokens[self.pos].text)
                self._advance()  # the quoted date string
                return SqlExpr.date_lit(ds)
            # ★ timestamp literal: `timestamp '...'` / `timestamptz '...'`.
            # THE SAME SHAPE AS THE DATE
            # ARM ABOVE and gated the same way — the keyword reading is taken
            # only when a quoted string follows, so a table with a column
            # called `timestamp` still binds as a column reference everywhere
            # else. Which of the two keywords was written rides the node: see
            # `SX_TIMESTAMP` for the measurement that makes them two
            # questions rather than two spellings.
            if (
                (name == "timestamp" or name == "timestamptz")
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_STRING
            ):
                var aware = name == "timestamptz"
                self._advance()  # 'timestamp' / 'timestamptz'
                var ts = String(self.tokens[self.pos].text)
                self._advance()  # the quoted timestamp string
                return SqlExpr.timestamp_lit(ts, aware)
            # ★★ `EXTRACT(<field> FROM <expr>)`.
            #
            # A SEPARATE GRAMMAR ARM AND NOT A FUNCTION NAME, because `FROM`
            # inside the parentheses is not an argument separator: the general
            # call branch below would parse `YEAR` as a column reference and
            # then choke on the `FROM`. SQL's EXTRACT is spelled this way in
            # the standard and in every corpus query that uses it.
            #
            # IT LOWERS TO `date_part('<field>', <expr>)` AND THAT IS
            # DELIBERATE — the two ARE the same function in DuckDB v1.5.3
            # (`EXTRACT(YEAR FROM ts)` and `date_part('year', ts)` both answer
            # 2026 :: BIGINT over the same value), so rewriting here means the
            # binder needs ONE arm and the two spellings cannot drift apart.
            # A second binder arm is how `EXTRACT(DOW FROM x)` ends up
            # supported while `date_part('dow', x)` is not.
            #
            # THE FIELD IS TAKEN VERBATIM AND VALIDATED BY THE BINDER, never
            # here. This arm knows the SHAPE; which field names exist is the
            # binder's name table, and duplicating that list in the parser
            # would give an unsupported field two different error messages.
            if (
                name == "extract"
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_LPAREN
            ):
                self._advance()  # 'extract'
                self._advance()  # '('
                # The field is a bare identifier in the standard spelling
                # (`EXTRACT(YEAR FROM ...)`); a quoted string is accepted too
                # so `EXTRACT('year' FROM ...)` does not have to be rewritten
                # by hand. Both reach the binder as the same string.
                var field = String("")
                if self._kind() == TK_IDENT or self._kind() == TK_STRING:
                    field = String(self.tokens[self.pos].text)
                    self._advance()
                else:
                    raise Error(
                        "SQL syntax error: EXTRACT expects a field name, as in"
                        + " EXTRACT(YEAR FROM <expr>)"
                    )
                if not self._is_kw("from"):
                    raise Error(
                        "SQL syntax error: EXTRACT(" + field
                        + " ...) is missing the FROM keyword — the spelling is"
                        + " EXTRACT(" + field + " FROM <expr>)"
                    )
                self._advance()  # 'from'
                var src = self._parse_expr()
                self._expect(TK_RPAREN, "')' to close EXTRACT(...)")
                var ex_args = Slab[SqlExpr]()
                ex_args.append(SqlExpr.string_lit(field))
                ex_args.append(src^)
                return SqlExpr.call(String("date_part"), ex_args^)
            # ★ `POSITION(<needle> IN <haystack>)` — the SQL-standard GRAMMAR
            # form. DuckDB v1.5.3
            # has no CALLABLE `position`: `position('b', 'abc')` is a Parser
            # Error there, and the IN form binds `position(haystack, needle)`
            # = `strpos` (MEASURED: `POSITION('b' IN 'abc')` = 2, `POSITION(''
            # IN 'abc')` = 1, `POSITION(NULL IN 'abc')` NULL, `POSITION('ß' IN
            # 'Straße')` = 5 — a CODEPOINT index). It lowers to the
            # `STRFNN_STRPOS` node under an UNLEXABLE desugar name
            # (`POSITION_IN_DESUGAR_NAME`), exactly as CAST does below.
            #
            # ⚠ IT FIRES ONLY WHEN AN `IN` SITS AT THE TOP LEVEL OF THE
            # PARENTHESES (`_position_in_form`). `position(a, b)` and
            # `position(a)` stay ordinary CALLS, so the fn table's `_R_POSITION`
            # row keeps refusing the comma form with its measured reason, and a
            # UDF declared as `position` is still reached by `position(x)` —
            # this arm takes no name away from the `<name>(<one arg>)` shape
            # `sql_name_claimed_by_grammar` answers for.
            if (
                name == "position"
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_LPAREN
                and self._position_in_form(self.pos + 1)
            ):
                self._advance()  # 'position'
                self._advance()  # '('
                var needle = self._parse_op()
                self._expect_kw("in")
                var hay = self._parse_op()
                self._expect(TK_RPAREN, "')' to close POSITION(... IN ...)")
                var pargs = Slab[SqlExpr]()
                pargs.append(hay^)
                pargs.append(needle^)
                return SqlExpr.call(String(_POSITION_IN_DESUGAR_NAME), pargs^)
            # ★★ `CAST(<expr> AS <type>)` / `TRY_CAST(<expr> AS <type>)`.
            #
            # A SEPARATE GRAMMAR ARM FOR THE SAME REASON `EXTRACT` HAS ONE:
            # `AS` inside the parentheses is not an argument separator, so the
            # general call branch below would parse `<expr>` and then die on
            # the bare identifier `AS` with `expected ')'`. That would be a
            # PARSER fact, not a capability one: the IR carries `EXPR_CAST` and
            # the wire carries `WireCast`.
            #
            # ⚠ IT FIRES ON THE NAME + `(` ONLY, so a column called `cast` is
            # still a column — the same guard the `true`/`false` arm above
            # states in full.
            #
            # ⛔ A MISSING `AS` IS ITS OWN SYNTAX ERROR AND NOT A FALL-THROUGH.
            # `cast(x)` refuses HERE, naming the keyword it is missing, rather
            # than reaching the BINDER as an unknown scalar function. That is a
            # DIFFERENT message from `nosuchfn(x)`'s — a parser that refuses
            # everything with one sentence proves nothing about any of them.
            if (
                (name == "cast" or name == "try_cast")
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_LPAREN
            ):
                var is_try = name == "try_cast"
                var spelled = String("TRY_CAST") if is_try else String("CAST")
                self._advance()  # 'cast' / 'try_cast'
                self._advance()  # '('
                var csrc = self._parse_expr()
                if not self._is_kw("as"):
                    raise Error(
                        "SQL syntax error: " + spelled + " is missing the AS"
                        + " keyword — the spelling is " + spelled
                        + "(<expr> AS <type>)"
                    )
                self._advance()  # 'as'
                var cty = self._parse_sql_type_name(spelled)
                self._expect(TK_RPAREN, "')' to close " + spelled + "(...)")
                var cargs2 = Slab[SqlExpr]()
                cargs2.append(csrc^)
                cargs2.append(SqlExpr.string_lit(cty))
                return SqlExpr.call(
                    String(_TRY_CAST_DESUGAR_NAME) if is_try
                    else String(_CAST_DESUGAR_NAME),
                    cargs2^,
                )
            # aggregate call?  `sum(...)` / `count(*)` / `avg(...)` ...
            var agg = self._agg_code(name)
            if agg >= 0 and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].kind == TK_LPAREN:
                self._advance()  # func name
                self._advance()  # '('
                # COUNT(DISTINCT col) — the DISTINCT keyword precedes the arg.
                var is_distinct = False
                if self._is_kw("distinct"):
                    self._advance()
                    is_distinct = True
                var arg: SqlExpr
                if self._kind() == TK_STAR:
                    self._advance()  # COUNT(*) — sentinel STAR argument
                    arg = SqlExpr.star()
                else:
                    arg = self._parse_expr()
                self._expect(TK_RPAREN, "')'")
                # `<agg>(...) OVER (...)` — a WINDOWED aggregate. The OVER
                # keyword right after the closing `)` flips this from a plain
                # aggregate (SX_AGG -> GROUP BY) to a window function (SX_WINDOW ->
                # PARTITION BY node). win-running `SUM(value) OVER (...)`,
                # win-rolling `AVG(value) OVER (... ROWS ...)`.
                if self._is_kw("over"):
                    return self._parse_window_agg(UInt8(agg), arg^, is_distinct)
                # ⭐ `name` — THE SOURCE TOKEN, lower-folded by the tokenizer,
                # carried onto the node. `SXAGG_*` is a CODE and several names
                # reach one (`avg` and `mean` are both SXAGG_AVG), so the
                # unaliased output-column name cannot be re-derived from `op`
                # without answering `avg(v)` for a query that says `mean(v)`.
                # See `SqlExpr.agg` and `sql_bind_names._duckdb_agg_text`.
                return SqlExpr.agg(UInt8(agg), arg^, is_distinct, name)
            # ranking window function `RANK() / ROW_NUMBER() / DENSE_RANK()` — these
            # are NOT aggregates (no `_agg_code` entry) and are only valid with an
            # OVER clause. Detected BEFORE the general scalar-call branch so the
            # empty `()` + OVER is not mis-read as an unknown zero-arg function.
            var wrank = self._win_ranking_code(name)
            if wrank >= 0 and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].kind == TK_LPAREN:
                self._advance()  # func name
                self._expect(TK_LPAREN, "'('")
                self._expect(TK_RPAREN, "')' (ranking window functions take no arguments)")
                if not self._is_kw("over"):
                    raise Error(
                        "SQL syntax error: the ranking window function '" + name
                        + "' requires an OVER (...) clause"
                    )
                var wr = self._parse_over_clause(UInt8(wrank), String(""))
                return SqlExpr.window(wr^)
            # VALUE window functions `LAG / LEAD / FIRST_VALUE / LAST_VALUE /
            # NTH_VALUE (col [, k [, default]]) OVER (...)`.
            # ⚠ ONLY WHEN `OVER` FOLLOWS THE ARGUMENT LIST: without
            # it `lag(x)` stays the ordinary scalar call below, which
            # `sql_fn_table` refuses with the `_R_AGGWINVALUE` family reason --
            # so the name is not taken away from the `<name>(<arg>)` shape.
            var wval = sql_win_value_code(name)
            if (
                wval >= 0
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_LPAREN
                and self._over_follows_call(self.pos + 1)
            ):
                var wv = self._parse_value_window(UInt8(wval), name)
                return SqlExpr.window(wv^)
            # DISTRIBUTION window functions `PERCENT_RANK() / CUME_DIST() /
            # NTILE(k) OVER (...)` -- the same OVER
            # lookahead as the value windows above, for the same reason.
            var wdist = sql_win_dist_code(name)
            if (
                wdist >= 0
                and self.pos + 1 < len(self.tokens)
                and self.tokens[self.pos + 1].kind == TK_LPAREN
                and self._over_follows_call(self.pos + 1)
            ):
                var wd = self._parse_dist_window(UInt8(wdist), name)
                return SqlExpr.window(wd^)
            # general scalar function call `name(arg, ...)` — reached only when
            # `name` is NOT a date-literal keyword or an aggregate name, so it
            # cleanly captures date_diff(...), sqrt(x), year(x), etc. The binder
            # dispatches on the (lower-folded) name and raises a clean Error for
            # any function it does not support (negative-corpus contract).
            if self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].kind == TK_LPAREN:
                self._advance()  # func name
                self._advance()  # '('
                # ⭐ `f(DISTINCT x)` — REFUSED BY NAME RATHER THAN AS A SYNTAX
                # ACCIDENT. This branch parses arguments with `_parse_expr`, and
                # `distinct` is an ordinary `TK_IDENT` to the tokenizer — so
                # without this arm `median(DISTINCT q)` would parse `DISTINCT`
                # as a COLUMN REFERENCE, find `q` where it wants `,` or `)`, and
                # refuse with "SQL syntax error: expected ')'". That message is TRUE about
                # the token stream and USELESS to the user: it describes
                # where the parser gave up, not what is unsupported, and it
                # names a construct (`)`) the query already had.
                #
                # ⚠ THE SIX STATISTICAL NAMES RIDE THIS BRANCH, not the
                # `_agg_code` one above, which is the whole reason they land
                # here: `count`/`sum`/`avg`/`min`/`max`/`mean` have an
                # `_agg_code` entry and parse DISTINCT explicitly; `median` /
                # `stddev` / `stddev_samp` / `var_samp` / `variance` / `corr`
                # do not. So this arm gives the SX_CALL half the same ANSWER the
                # SX_AGG half already gives from the binder ("DISTINCT is only
                # supported on COUNT") instead of a parser artifact.
                #
                # ⛔ IT REFUSES; IT DOES NOT IMPLEMENT DISTINCT. The kernels have
                # no per-group distinct set for these statistics, and a parser
                # that ACCEPTED the keyword and dropped it would answer the
                # NON-distinct value — a wrong number wearing a supported
                # query's clothes, which is strictly worse than the artifact.
                #
                # ⚠ AND IT REJECTS NO CALL THAT IS OTHERWISE LEGAL. The guard is
                # `distinct` FOLLOWED BY SOMETHING THAT IS NOT `,` OR `)`, so a
                # (bizarre, but legal in this dialect — there is no quoted
                # identifier syntax) column named `distinct` still parses as
                # `f(distinct)` / `f(distinct, x)`. Only `DISTINCT <expr>`, the
                # SQL quantifier form, is intercepted, and that form has no
                # other parse.
                if self._is_kw("distinct"):
                    var _dk = self.tokens[self.pos + 1].kind if self.pos + 1 < len(self.tokens) else TK_EOF
                    if _dk != TK_COMMA and _dk != TK_RPAREN:
                        if sql_call_is_aggregate(name):
                            raise Error(
                                "SQL not supported: DISTINCT inside '" + name
                                + "(...)'. DISTINCT is only supported on COUNT"
                                + " on this surface (`count(DISTINCT x)`); the"
                                + " statistical aggregates have no per-group"
                                + " distinct set, and dropping the keyword"
                                + " would answer the NON-distinct value"
                            )
                        raise Error(
                            "SQL syntax error: DISTINCT is not valid inside the"
                            + " scalar function '" + name + "(...)' — the"
                            + " DISTINCT quantifier belongs to an aggregate"
                            + " call, and on this surface only COUNT takes it"
                        )
                var call_args = Slab[SqlExpr]()
                if self._kind() != TK_RPAREN:
                    while True:
                        call_args.append(self._parse_expr())
                        if self._kind() == TK_COMMA:
                            self._advance()
                            continue
                        break
                self._expect(TK_RPAREN, "')'")
                return SqlExpr.call(name, call_args^)
            # plain column ref (optionally `t.col`). The qualifier `t` is
            # PRESERVED (load-bearing for correlated-subquery inner/outer column
            # classification; the ordinary binder ignores it).
            self._advance()
            var qualifier = String("")
            if self._kind() == TK_DOT:
                self._advance()
                if self._kind() != TK_IDENT:
                    raise Error("SQL syntax error: expected column after '.'")
                qualifier = name
                name = String(self.tokens[self.pos].text)
                self._advance()
            return SqlExpr.column(name, qualifier)
        if self._kind() == TK_TILDE:
            # PREFIX `~` is DuckDB's BITWISE NOT (`~5` = -6, MEASURED v1.5.3);
            # the infix `~` above is the regex match. No bitwise operator here.
            raise Error(
                "SQL not supported: the bitwise NOT operator `~` (DuckDB answers"
                " `~5` = -6). This engine has no bitwise operator; an INFIX"
                " `x ~ 'pattern'` is the regular-expression match, which is served"
            )
        raise Error("SQL syntax error: unexpected token in expression")

    @always_inline
    def _agg_code(self, name: String) -> Int:
        """Return the SXAGG_* code for an aggregate function name, or -1.

        ⛔ THE SET LIVES IN `sql_ast.sql_agg_code` AND THIS DELEGATES. Spelled
        here, privately, the only component that could ask "does the grammar
        already claim this name" would be the parser — and the UDF declare
        door, which has to ask exactly that, could not, so those names would be
        declarable and then silently replaced; see
        `sql_name_claimed_by_grammar`."""
        return sql_agg_code(name)

    @always_inline
    def _win_ranking_code(self, name: String) -> Int:
        """Return the SXWIN_* code for a RANKING window function name (which takes
        no argument and is valid only with OVER), or -1. The aggregate window
        functions (SUM/COUNT/MIN/MAX/AVG) are NOT here — they ride the `_agg_code`
        parse path and gain OVER after their argument list.

        ⛔ Delegates to `sql_ast.sql_win_ranking_code` for the reason
        `_agg_code` above states."""
        return sql_win_ranking_code(name)

    @always_inline
    def _agg_to_win_code(self, agg: UInt8) raises -> UInt8:
        """Map an SXAGG_* code to its SXWIN_* window-aggregate counterpart."""
        if agg == SXAGG_SUM:
            return SXWIN_SUM
        if agg == SXAGG_COUNT:
            return SXWIN_COUNT
        if agg == SXAGG_MIN:
            return SXWIN_MIN
        if agg == SXAGG_MAX:
            return SXWIN_MAX
        if agg == SXAGG_AVG:
            return SXWIN_AVG
        raise Error("SQL bind error: unsupported aggregate in an OVER clause")

    def _parse_window_agg(mut self, agg: UInt8, var arg: SqlExpr, is_distinct: Bool) raises -> SqlExpr:
        """Finalize a `<agg>(<arg>) OVER (...)` windowed aggregate — the `over`
        keyword is at the current position. The argument must be a bare column
        (`SUM(value)`) or `*` (`COUNT(*)`); a complex aggregate argument in an OVER
        clause is not in the corpus and raises cleanly. DISTINCT is not supported in
        a window aggregate."""
        if is_distinct:
            raise Error("SQL not supported: DISTINCT inside an OVER (window) aggregate")
        var win_func = self._agg_to_win_code(agg)
        var arg_col: String
        if arg.tag == SX_STAR:
            arg_col = String("")  # COUNT(*) OVER — no argument column
        elif arg.tag == SX_COLUMN:
            arg_col = String(arg.text)
        else:
            raise Error(
                "SQL not supported: a window aggregate argument must be a plain"
                + " column reference (e.g. `SUM(value) OVER ...`) or `*`"
            )
        var w = self._parse_over_clause(win_func, arg_col)
        if arg.tag == SX_COLUMN:
            w.arg_qual = String(arg.qualifier)
        return SqlExpr.window(w^)

    def _parse_dist_window(mut self, func: UInt8, fname: String) raises -> SqlWindowData:
        """`percent_rank() OVER (...)`, `cume_dist() OVER (...)`, `ntile(k)
        OVER (...)` — the name is at the current position and `OVER` is known
        to follow the argument list.

        ⚠ `ntile`'s bucket count is a POSITIVE INTEGER LITERAL here. DuckDB
        v1.5.3 also takes a column (a per-row bucket count) and raises
        `Argument for ntile must be greater than zero` at run time for 0 or a
        negative literal; both are refused at parse time here, BY NAME, rather
        than handed to a kernel that reads one plan-time count."""
        self._advance()  # function name
        self._expect(TK_LPAREN, "'('")
        var buckets: Int64 = 0
        if func == SXWIN_NTILE:
            if self._kind() != TK_INT:
                raise Error(
                    "SQL not supported: ntile(...)'s bucket count must be a"
                    " positive integer literal here, e.g. `ntile(4) OVER (ORDER"
                    " BY k)` (a column-valued count is a per-row bucket count"
                    " this window node cannot carry)"
                )
            buckets = self._small_int_tok("ntile bucket count")
            self._advance()
            if buckets <= 0:
                raise Error(
                    "SQL bind error: ntile(" + String(buckets) + ") — the bucket"
                    " count must be greater than zero (DuckDB v1.5.3: `Argument"
                    " for ntile must be greater than zero`)"
                )
            self._expect(TK_RPAREN, "')' after ntile's bucket count")
        else:
            self._expect(
                TK_RPAREN, "')' (" + fname + "() takes no arguments)"
            )
        var w = self._parse_over_clause(func, String(""))
        w.value_offset = buckets
        return w^

    def _over_follows_call(self, lparen: Int) -> Bool:
        """True iff the argument list opening at token `lparen` is closed by a
        `)` that is followed by the keyword OVER. Pure lookahead -- no token is
        consumed -- so a value-window NAME without OVER falls through to the
        scalar-call branch like any other name."""
        var depth = 0
        var j = lparen
        while j < len(self.tokens):
            var k = self.tokens[j].kind
            if k == TK_EOF:
                return False
            if k == TK_LPAREN:
                depth += 1
            elif k == TK_RPAREN:
                depth -= 1
                if depth == 0:
                    return (
                        j + 1 < len(self.tokens)
                        and self.tokens[j + 1].kind == TK_IDENT
                        and self.tokens[j + 1].text == "over"
                    )
            j += 1
        return False

    def _parse_value_window_int(mut self, fname: String, what: String) raises -> Int64:
        """A SIGNED integer literal argument (LAG / LEAD offset, NTH_VALUE n).

        ⚠ ONLY A LITERAL, AND ONLY AN INTEGER. DuckDB v1.5.3 also accepts
        `lag(v, 1.5)` (it rounds to 2) and `lag(v, NULL)` (every row NULL); the
        window IR carries an `Int` offset and no cast, so those REFUSE by name
        rather than truncate."""
        var neg = False
        if self._kind() == TK_MINUS:
            neg = True
            self._advance()
        if self._kind() != TK_INT:
            raise Error(
                "SQL not supported: the " + what + " of " + fname + "(...) OVER"
                + " must be an INTEGER literal (e.g. `" + fname + "(v, 2)`) --"
                + " an expression, a NULL or a fractional offset is not lowered to"
                + " the window operator"
            )
        var v = self._small_int_tok(what + " of " + fname + "()")
        self._advance()
        return -v if neg else v

    def _parse_value_window(mut self, func: UInt8, fname: String) raises -> SqlWindowData:
        """`LAG / LEAD (col [, offset [, default]])`, `FIRST_VALUE / LAST_VALUE
        (col)`, `NTH_VALUE (col, n)`, then the OVER clause -- the name token is
        at the current position and `_over_follows_call` has already seen the
        OVER.

        The argument must be a plain column (the window IR names its input by
        column, as for the aggregate windows); the DEFAULT must be a literal --
        INT, FLOAT, STRING, `DATE '...'` or NULL (a NULL default is no default:
        `LAG(x, 1, NULL)` is `LAG(x, 1)` in SQL). `RESPECT NULLS` is the SQL
        default and is accepted; `IGNORE NULLS` refuses by name."""
        self._advance()  # function name
        self._expect(TK_LPAREN, "'('")
        if self._kind() != TK_IDENT:
            raise Error(
                "SQL not supported: the argument of " + fname + "(...) OVER must"
                + " be a plain column reference (e.g. `" + fname + "(v) OVER"
                + " (...)`) -- an expression argument is not lowered to the window"
                + " operator"
            )
        var col = String(self.tokens[self.pos].text)
        var col_qual = String("")
        self._advance()
        if self._kind() == TK_DOT:
            self._advance()
            if self._kind() != TK_IDENT:
                raise Error("SQL syntax error: expected column after '.' in " + fname + "(...)")
            col_qual = col^
            col = String(self.tokens[self.pos].text)
            self._advance()
        if not (
            self._kind() == TK_COMMA
            or self._kind() == TK_RPAREN
            or self._is_kw("ignore")
            or self._is_kw("respect")
        ):
            raise Error(
                "SQL not supported: the argument of " + fname + "(...) OVER must"
                + " be a plain column reference (e.g. `" + fname + "(v) OVER"
                + " (...)`) -- an expression argument is not lowered to the window"
                + " operator"
            )
        var is_shift = func == SXWIN_LAG or func == SXWIN_LEAD
        var offset: Int64 = 1 if is_shift else 0
        var has_default = False
        var dkind = SX_INT
        var dint: Int64 = 0
        var dfloat: Float64 = 0.0
        var dtext = String("")
        if self._kind() == TK_COMMA:
            if func == SXWIN_FIRST_VALUE or func == SXWIN_LAST_VALUE:
                raise Error(
                    "SQL syntax error: " + fname + "() takes exactly ONE argument,"
                    + " the column (DuckDB v1.5.3: 'Incorrect number of parameters')"
                )
            self._advance()
            var what = String("offset") if is_shift else String("n")
            offset = self._parse_value_window_int(fname, what)
            if self._kind() == TK_COMMA:
                if not is_shift:
                    raise Error(
                        "SQL syntax error: " + fname + "() takes two arguments,"
                        + " the column and n"
                    )
                self._advance()
                var neg = False
                if self._kind() == TK_MINUS:
                    neg = True
                    self._advance()
                if self._kind() == TK_INT:
                    has_default = True
                    dkind = SX_INT
                    if neg and self.tokens[self.pos].text == "9223372036854775808":
                        # `-9223372036854775808` IS a BIGINT (Int64.MIN): its
                        # magnitude alone is past BIGINT, so it must not reach
                        # the out-of-range refusal below.
                        dint = Int64.MIN
                    else:
                        dint = self._small_int_tok("default of " + fname + "()")
                        if neg:
                            dint = -dint
                    self._advance()
                elif self._kind() == TK_FLOAT:
                    has_default = True
                    dkind = SX_FLOAT
                    dfloat = self.tokens[self.pos].float_val
                    if neg:
                        dfloat = -dfloat
                    self._advance()
                elif not neg and self._kind() == TK_STRING:
                    has_default = True
                    dkind = SX_STRING
                    dtext = String(self.tokens[self.pos].text)
                    self._advance()
                elif (
                    not neg
                    and self._is_kw("date")
                    and self.pos + 1 < len(self.tokens)
                    and self.tokens[self.pos + 1].kind == TK_STRING
                ):
                    self._advance()
                    has_default = True
                    dkind = SX_DATE
                    dtext = String(self.tokens[self.pos].text)
                    self._advance()
                elif not neg and self._is_kw("null"):
                    self._advance()  # a NULL default IS no default
                else:
                    raise Error(
                        "SQL not supported: the DEFAULT of " + fname + "(col, k,"
                        + " default) OVER must be a literal -- an INTEGER, a FLOAT,"
                        + " a STRING, DATE '...' or NULL; an expression default is"
                        + " not lowered to the window operator"
                    )
        elif func == SXWIN_NTH_VALUE:
            raise Error(
                "SQL syntax error: NTH_VALUE needs 2 parameters, the column and n"
                + " (e.g. `nth_value(v, 2) OVER (...)`)"
            )
        if self._is_kw("ignore"):
            raise Error(
                "SQL not supported: " + fname + "(... IGNORE NULLS) -- the window"
                + " operator copies a NULL cell as NULL (RESPECT NULLS, the SQL"
                + " default) and has no arm that skips it"
            )
        if self._is_kw("respect"):
            self._advance()
            self._expect_kw("nulls")
        self._expect(TK_RPAREN, "')' to close " + fname + "(...)")
        var w = self._parse_over_clause(func, col)
        w.arg_qual = col_qual^
        w.value_offset = offset
        w.has_default = has_default
        w.default_kind = dkind
        w.default_int = dint
        w.default_float = dfloat
        w.default_text = dtext^
        return w^

    def _parse_over_clause(mut self, func: UInt8, arg_col: String) raises -> SqlWindowData:
        """Parse `OVER ( [PARTITION BY col, ...] [ORDER BY col [ASC|DESC], ...]
        [ROWS|RANGE <frame>] )` — the `over` keyword is at the current position.
        Returns the fully-populated `SqlWindowData` (function + arg + keys + frame).
        Partition / order operands are column names only (the corpus never orders a
        window by an expression)."""
        self._expect_kw("over")
        # ⛔ A NAMED WINDOW IS USED BEFORE IT IS DEFINED, so the `WINDOW`
        # clause refusal in `_refuse_unserved_clause_word` cannot see the
        # spelling a user actually writes: `sum(v) OVER w ... WINDOW w AS (...)`
        # would die HERE on "expected '(' after OVER", and `OVER (w ORDER BY k)`
        # on "expected ')' to close the OVER clause" -- paren messages for queries
        # DuckDB v1.5.3 answers. Nothing but `(` may follow OVER in this
        # grammar, and inside the parentheses only PARTITION / ORDER / a frame
        # unit may open the specification, so any other identifier IS a window
        # name. `groups` is excluded on purpose: it is an (unserved) frame UNIT
        # and keeps its own message rather than being misnamed as a window.
        if self._kind() == TK_IDENT:
            self._refuse_named_window_ref(self.tokens[self.pos].text, False)
        self._expect(TK_LPAREN, "'(' after OVER")
        if self._kind() == TK_IDENT and not (
            self._is_kw("partition")
            or self._is_kw("order")
            or self._is_kw("rows")
            or self._is_kw("range")
            or self._is_kw("groups")
        ):
            self._refuse_named_window_ref(self.tokens[self.pos].text, True)
        var pby = List[String]()
        var oby = List[String]()
        var desc = List[Bool]()
        var pqual = List[String]()
        var oqual = List[String]()
        if self._is_kw("partition"):
            self._advance()
            self._expect_kw("by")
            while True:
                var pq = String("")
                pby.append(self._parse_window_col(String("PARTITION BY"), pq))
                pqual.append(pq^)
                if self._kind() == TK_COMMA:
                    self._advance()
                    continue
                break
        if self._is_kw("order"):
            self._advance()
            self._expect_kw("by")
            while True:
                var oq = String("")
                var c = self._parse_window_col(String("ORDER BY"), oq)
                oqual.append(oq^)
                var d = False
                if self._is_kw("asc"):
                    self._advance()
                elif self._is_kw("desc"):
                    self._advance()
                    d = True
                oby.append(c)
                desc.append(d)
                if self._kind() == TK_COMMA:
                    self._advance()
                    continue
                break
        var w = SqlWindowData(func, arg_col, pby^, oby^, desc^)
        w.partition_qual = pqual^
        w.order_qual = oqual^
        if self._is_kw("rows") or self._is_kw("range"):
            self._parse_frame(w)
        self._expect(TK_RPAREN, "')' to close the OVER clause")
        return w^

    def _refuse_named_window_ref(self, name: String, in_parens: Bool) raises:
        """Refuse `OVER <name>` / `OVER (<name> ...)` BY NAME. Serving it is a
        frontend substitution (every inline specification it can name is
        served), but the reference precedes the `WINDOW` clause that defines
        it, so it needs the specification resolved after the SELECT is parsed;
        until then it is refused rather than guessed."""
        var spelled = String("OVER ") + name
        if in_parens:
            spelled = String("OVER (") + name + " ...)"
        raise Error(
            "SQL not supported: a named window reference `" + spelled + "` (a"
            " window defined by a WINDOW clause). Write the window specification"
            " inline in each OVER (...), e.g. `OVER (PARTITION BY k ORDER BY t)`."
        )

    def _parse_window_col(mut self, clause: String, mut qual: String) raises -> String:
        """Parse a column reference `ident [. ident]` inside an OVER clause and
        return its (last-component) name; its qualifier goes to `qual` ("" when
        none was written). ⛔ Dropping the qualifier here would make
        `PARTITION BY Q.k`, over a join whose sides share a column name, read
        the LEFT `k` — a silent wrong answer (see `SqlWindowData.partition_qual`). `clause`
        is "PARTITION BY" or "ORDER BY", and exists ONLY so the refusal below can
        name the clause the reader actually wrote.

        ⛔⛔ THE `(` CHECK IS A SEMANTIC REFUSAL, NOT A TOKEN EXPECTATION, AND
        THAT IS THE WHOLE POINT. Without it `OVER (PARTITION BY affine(g))` would
        consume `affine` as the key, find `(` where it wants `,`/ORDER/ROWS/`)`,
        and die in `_parse_over_clause` with "SQL syntax error: expected ')' to
        close the OVER clause" — a message about PARENTHESES for a query whose
        parentheses are perfectly balanced. `OVER (PARTITION BY g)` parses and
        answers, so the reader would be sent hunting a typo that does not
        exist.

        ⚠ IT IS RAISED HERE, IN THE PARSER, BECAUSE NOTHING DOWNSTREAM CAN SEE
        IT. `SqlWindowData` carries partition / order keys as plain `String`
        column names and holds no `SqlExpr` at all — deliberately, so the AST
        stays acyclic through SX_WINDOW — so a computed key has no representation
        to hand the binder. Giving one is a CAPABILITY change; this is only the
        message. A `(` after an identifier is unambiguous here: the token after a
        window key is always `,`, ORDER, ROWS, RANGE or `)`.
        """
        if self._kind() != TK_IDENT:
            raise Error("SQL syntax error: expected a column name in the OVER clause")
        var nm = String(self.tokens[self.pos].text)
        self._advance()
        if self._kind() == TK_DOT:
            self._advance()
            if self._kind() != TK_IDENT:
                raise Error("SQL syntax error: expected column after '.' in OVER clause")
            qual = nm^
            nm = String(self.tokens[self.pos].text)
            self._advance()
        if self._kind() == TK_LPAREN:
            raise Error(
                "SQL not supported: a window " + clause + " key must be a plain"
                + " column reference (e.g. `OVER (" + clause + " g)`) — `" + nm
                + "(...)` computes the key, which this engine cannot lower yet"
            )
        return nm

    def _parse_frame(mut self, mut w: SqlWindowData) raises:
        """Parse a `ROWS|RANGE (BETWEEN <start> AND <end> | <start>)` frame and set
        it on `w`. The single-bound shorthand `ROWS <start>` means
        `BETWEEN <start> AND CURRENT ROW`."""
        var units = SXFRAME_ROWS if self._is_kw("rows") else SXFRAME_RANGE
        self._advance()  # rows / range
        var start_tag: UInt8
        var start_off: Int64
        var end_tag: UInt8
        var end_off: Int64
        if self._is_kw("between"):
            self._advance()
            var s = self._parse_frame_bound(units)
            start_tag = s[0]
            start_off = s[1]
            self._expect_kw("and")
            var e = self._parse_frame_bound(units)
            end_tag = e[0]
            end_off = e[1]
        else:
            var s = self._parse_frame_bound(units)
            start_tag = s[0]
            start_off = s[1]
            end_tag = SXFRAME_CURRENT_ROW
            end_off = Int64(0)
        w.set_frame(units, start_tag, start_off, end_tag, end_off)

    def _parse_frame_bound(mut self, units: UInt8) raises -> Tuple[UInt8, Int64]:
        """Parse one frame bound -> (bound_tag, offset). Forms: `UNBOUNDED
        PRECEDING`, `UNBOUNDED FOLLOWING`, `CURRENT ROW`, `<n> PRECEDING`,
        `<n> FOLLOWING`."""
        if self._is_kw("unbounded"):
            self._advance()
            if self._is_kw("preceding"):
                self._advance()
                return (SXFRAME_UNBOUNDED_PRECEDING, Int64(0))
            if self._is_kw("following"):
                self._advance()
                return (SXFRAME_UNBOUNDED_FOLLOWING, Int64(0))
            raise Error("SQL syntax error: expected PRECEDING / FOLLOWING after UNBOUNDED")
        if self._is_kw("current"):
            self._advance()
            self._expect_kw("row")
            return (SXFRAME_CURRENT_ROW, Int64(0))
        if self._kind() == TK_INT:
            if units == SXFRAME_RANGE and self.tokens[self.pos].text.byte_length() > 0:
                # ⛔ NOT `_small_int_tok`'s sentence:
                # DuckDB 1.5.3 ANSWERS a RANGE offset past BIGINT
                # (MEASURED: `sum(k) OVER (ORDER BY k RANGE BETWEEN
                # 18446744073709551617 PRECEDING AND CURRENT ROW)` is the
                # running sum), so "DuckDB raises" would be false here. The
                # ROWS offset DOES raise in DuckDB and keeps that sentence.
                raise Error(
                    "SQL not supported: the RANGE frame offset "
                    + self.tokens[self.pos].text
                    + " is past BIGINT, and this engine's frame offsets are"
                    + " BIGINT. DuckDB v1.5.3 answers it (it compares a RANGE"
                    + " offset with the ORDER BY key widened to HUGEINT). An"
                    + " offset at least as wide as the ORDER BY key's range is"
                    + " the same frame as UNBOUNDED PRECEDING / FOLLOWING,"
                    + " which is served."
                )
            var n = self._small_int_tok("window frame offset")
            self._advance()
            if self._is_kw("preceding"):
                self._advance()
                return (SXFRAME_PRECEDING, n)
            if self._is_kw("following"):
                self._advance()
                return (SXFRAME_FOLLOWING, n)
            raise Error("SQL syntax error: expected PRECEDING / FOLLOWING after a frame offset")
        raise Error(
            "SQL syntax error: expected a frame bound (UNBOUNDED PRECEDING/FOLLOWING,"
            + " CURRENT ROW, or `<n> PRECEDING/FOLLOWING`)"
        )


def _refuse_ambiguous_derived_qualifier(from_tables: List[FromRelation]) raises:
    """⛔ Refuse a derived table whose qualifier (its alias, or the synthetic
    `unnamed_subquery[N]` of an unaliased one, see
    `_Parser._parse_derived_table`) is ALSO the name or alias of another
    relation in the same FROM clause (`FROM t, (SELECT ...) AS t`,
    `FROM (SELECT ...) AS d, u AS d`, `FROM (SELECT 1 AS a), unnamed_subquery`).

    This binder's qualifier resolution takes the first relation that answers
    to a qualifier, so it could pick the other one and answer from the wrong
    relation under a plausible column. (For the synthetic name DuckDB v1.5.3
    accepts it and resolves each qualified column by name — with a table that
    is itself called `unnamed_subquery`, `unnamed_subquery.z` reaches the
    TABLE and `unnamed_subquery.a` the SUBQUERY, measured.) Refused, naming the
    collision and the remedy.

    A derived relation is recognised by the `#` in its relation NAME, which no
    lower-folded identifier can contain. One with no `rel_alias` (a shape the
    parser never builds) is skipped: an empty qualifier names nothing."""
    for i in range(len(from_tables)):
        ref s = from_tables[i]
        if s.name.find("#") < 0 or s.rel_alias == "":
            continue
        var q = s.rel_alias.lower()
        for j in range(len(from_tables)):
            if j == i:
                continue
            ref o = from_tables[j]
            if o.name.lower() == q or o.rel_alias.lower() == q:
                raise Error(
                    "SQL not supported: a derived table `(SELECT ...)` is"
                    + " named `" + q + "`, and another relation in the same"
                    + " FROM clause also answers to `" + q + "`, so a column"
                    + " qualified by that name is ambiguous. Give the"
                    + " relations distinct aliases (an unaliased derived table"
                    + " is named `unnamed_subquery`, `unnamed_subquery2`, ...)."
                )


def _replacement_scan_kind(path: String) raises -> UInt8:
    """The TVF kind a `FROM '<path>'` replacement scan reads, by extension —
    or a refusal naming the extension. See `_Parser._parse_replacement_scan`."""
    var low = path.lower()
    if low.endswith(".parquet"):
        return TVF_PARQUET
    if low.endswith(".csv"):
        return TVF_CSV
    if low.endswith(".json") or low.endswith(".jsonl") or low.endswith(".ndjson"):
        return TVF_JSON
    raise Error(
        "SQL not supported: a replacement scan of `'" + path + "'` — this door"
        " maps a FROM-clause file path by its extension (.parquet, .csv, .json,"
        " .jsonl, .ndjson) and this one is none of them. Spell the reader"
        " explicitly (`read_parquet(...)` / `read_csv(...)` / `read_json(...)`)."
        " (DuckDB also sniffs `.tsv` and compressed suffixes; reading those as a"
        " plain comma-separated file would answer a different table.)"
    )


def _file_stem(path: String) -> String:
    """`dir/t1.parquet` -> `t1`: the name DuckDB gives a replacement-scan
    relation (MEASURED v1.5.3, `SELECT t1.k FROM 'rs/t1.parquet'`). Byte
    scan: `/` and `.` are ASCII, so a byte index is a character boundary."""
    var b = path.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(ord("/")):
            start = i + 1
    var stop = len(b)
    for i in range(start + 1, len(b)):
        if b[i] == UInt8(ord(".")):
            stop = i
    return String(unsafe_from_utf8=b[start:stop]).lower()


def _and_into(var acc: Optional[SqlExpr], var p: SqlExpr) -> Optional[SqlExpr]:
    """Conjoin `p` into `acc` (`acc AND p`), or seed `acc` with `p` if empty."""
    if acc:
        return Optional(SqlExpr.binary(SXOP_AND, acc.take(), p^))
    return Optional(p^)


def _select_star_from(name: String) raises -> SelectStmt:
    """Synthesize the `SELECT * FROM <name>` source for a bare-table `COPY <table>
    TO ...` — so a COPY of a catalog/CTAS table binds through the SAME `_bind_select`
    path a `COPY (SELECT * FROM <table>) TO ...` subquery source would."""
    var stmt = SelectStmt()
    stmt.select_items.append(SelectItem(SqlExpr.star(), Optional[String](), True))
    stmt.from_tables.append(FromRelation.named(name, String("")))
    return stmt^


def _format_word(w: String) raises -> UInt8:
    """Map a COPY `FORMAT <word>` to a WFMT_* code (raises on a format with no
    wired sink — negative-corpus contract). DuckDB spells newline-delimited JSON
    `FORMAT 'json'` + `ARRAY false`; `jsonl`/`ndjson` are accepted as the same
    thing because that is what the sink writes."""
    if w == "parquet":
        return WFMT_PARQUET
    if w == "csv":
        return WFMT_CSV
    if w == "json" or w == "jsonl" or w == "ndjson":
        return WFMT_JSONL
    raise Error(
        "SQL not supported: COPY ... (FORMAT '" + w + "') — wired write sinks are"
        " parquet / csv / json"
    )


def _codec_word(w: String) raises -> UInt8:
    """Map a COPY `COMPRESSION <word>` to a WCOMP_* code (raises on an unknown
    codec — negative-corpus contract). Whether the codec is legal for the chosen
    FORMAT is a SEPARATE check (`write_target_supported`): snappy is a Parquet
    page codec and has no whole-file CSV/JSONL arm."""
    if w == "uncompressed" or w == "none":
        return WCOMP_UNCOMPRESSED
    if w == "snappy":
        return WCOMP_SNAPPY
    if w == "zstd":
        return WCOMP_ZSTD
    if w == "gzip" or w == "gz":
        return WCOMP_GZIP
    # `lz4_raw` is the Parquet codec id 7 spelling; `lz4` is what DuckDB's CSV /
    # JSONL COPY calls the same whole-file wrapper. One WCOMP code, because the
    # sink arm each one resolves to is chosen by the FORMAT.
    if w == "lz4" or w == "lz4_raw":
        return WCOMP_LZ4
    raise Error(
        "SQL not supported: COPY compression '" + w + "' (uncompressed / snappy /"
        " zstd / gzip / lz4_raw)"
    )


def _codec_fixed_level(codec: UInt8) -> Int:
    """The compression LEVEL the wired sink for `codec` is parameterized on, or
    -1 for a codec that takes no level. `COMPRESSION_LEVEL` is honoured only by
    AGREEING with it — see `_parse_copy_options`."""
    if codec == WCOMP_ZSTD:
        return 3      # WholeFileCompressed[..., Zstd[3]] / Parquet[Zstd[3]]
    if codec == WCOMP_GZIP:
        return 6      # Gzip[6] — zlib's default level
    return -1


def parse_sql(var tokens: List[Token]) raises -> SqlStatement:
    """Parse a tokenized analytical statement (SELECT / COPY / CREATE ... AS) into
    a `SqlStatement`."""
    var p = _Parser(tokens^)
    return p.parse()


def _mark_in_list_negated(mut e: SqlExpr):
    """`e` is the operand of a prefix NOT. When it is ONE desugared `x IN (...)`
    (an `in`-marked EQ, or an `in`-marked OR joiner over them), re-mark the
    whole list `not in` -- DuckDB binds `NOT (x IN (...))` as NOT IN. A
    user-written OR (unmarked) is NOT descended: DuckDB keeps each IN inside
    `NOT (a IN (5) OR a = 7)` an IN, and unwraps it (MEASURED 1.5.3)."""
    if e.tag != SX_BINARY or e.text != "in":
        return
    e.text = String("not in")
    if e.op == SXOP_OR and e._binary:
        _mark_in_list_negated(e._binary.value().left[])
        _mark_in_list_negated(e._binary.value().right[])
