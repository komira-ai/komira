# =============================================================================
# formula_parser.mojo — the =FORMULA(...) parser (entry point v1, §4.2 step 1)
# =============================================================================
#
#   expr    := compare
#   compare := concat  ( (= | <> | < | <= | > | >=) concat)*
#   concat  := add     ( & add)*
#   add     := mul     ( (+ | -) mul)*
#   mul     := unary   ( (* | /) unary)*
#   unary   := ('-' | '+')? primary
#   primary := number | string | bool | error-lit | name | call | '(' expr ')'
#   call    := ident '(' [ expr (',' expr)* ] ')'
#
# Precedence (low->high, Excel order): comparison < & < +/- < */ < unary-.
# Produces a `FormulaAst` (arena, index children). The sheet/grid A1-addressing
# layer is OUT of scope (contract §0) — a bare identifier is a BINDING name, not
# a cell reference.
#
# Totality note (contract §4.1): the spine parser RAISES on malformed syntax;
# the "return a #NAME?/#ERROR! node instead of raising" totality refinement is a
# w1 follow-in. Golden tests exercise well-formed formulas + semantic (data)
# errors, not syntax errors.
#
# Encapsulation rule: value semantics; no UnsafePointer. Byte-level scanning
# reads `String.as_bytes()` (a safe Span) — ASCII operators/keywords; multibyte
# UTF-8 is preserved verbatim inside string literals + identifiers.
# =============================================================================

from .formula_ast import (
    FormulaAst,
    node_number,
    node_string,
    node_bool,
    node_error,
    node_name,
    node_call,
    node_binop,
    node_unary,
    OP_ADD,
    OP_SUB,
    OP_MUL,
    OP_DIV,
    OP_CONCAT,
    OP_EQ,
    OP_NE,
    OP_LT,
    OP_LE,
    OP_GT,
    OP_GE,
    OP_NEG,
)
from komira_core.plan.excel_error_code import excel_error_code_from_literal


# --- Token kinds. ---
comptime TOK_EOF: UInt8 = 0
comptime TOK_NUMBER: UInt8 = 1
comptime TOK_STRING: UInt8 = 2
comptime TOK_IDENT: UInt8 = 3
comptime TOK_ERROR: UInt8 = 4
comptime TOK_LPAREN: UInt8 = 5
comptime TOK_RPAREN: UInt8 = 6
comptime TOK_COMMA: UInt8 = 7
comptime TOK_OP: UInt8 = 8


@fieldwise_init
struct Token(Copyable, Movable):
    var kind: UInt8
    var num: Float64
    var text: String
    var op: UInt8
    var error_code: UInt8


# --- Byte classifiers (ASCII). ---
@always_inline
def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(0x30) and c <= UInt8(0x39)


@always_inline
def _is_alpha(c: UInt8) -> Bool:
    return (
        (c >= UInt8(0x41) and c <= UInt8(0x5A))
        or (c >= UInt8(0x61) and c <= UInt8(0x7A))
        or c == UInt8(0x5F)  # underscore
    )


@always_inline
def _is_ident_cont(c: UInt8) -> Bool:
    return _is_alpha(c) or _is_digit(c) or c == UInt8(0x2E)  # '.'


@always_inline
def _is_space(c: UInt8) -> Bool:
    return (
        c == UInt8(0x20)
        or c == UInt8(0x09)
        or c == UInt8(0x0A)
        or c == UInt8(0x0D)
    )


@always_inline
def _is_err_cont(c: UInt8) -> Bool:
    # error-literal continuation bytes: alnum, '/', '!', '?'
    return (
        _is_alpha(c)
        or _is_digit(c)
        or c == UInt8(0x2F)
        or c == UInt8(0x21)
        or c == UInt8(0x3F)
    )


def _slice_str(s: String, start: Int, end: Int) -> String:
    """Materialize bytes [start, end) of `s` as a String (UTF-8 preserved)."""
    var bs = s.as_bytes()
    var buf = List[UInt8]()
    for k in range(start, end):
        buf.append(bs[k])
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def tokenize(formula: String) raises -> List[Token]:
    """Lex a formula string into tokens (terminated by TOK_EOF)."""
    var bs = formula.as_bytes()
    var n = len(bs)
    var toks = List[Token]()
    var i = 0
    while i < n:
        var c = bs[i]
        if _is_space(c):
            i += 1
            continue

        # --- number: digits with optional fraction ---
        if _is_digit(c) or (c == UInt8(0x2E) and i + 1 < n and _is_digit(bs[i + 1])):
            var start = i
            while i < n and _is_digit(bs[i]):
                i += 1
            if i < n and bs[i] == UInt8(0x2E):
                i += 1
                while i < n and _is_digit(bs[i]):
                    i += 1
            var numstr = _slice_str(formula, start, i)
            toks.append(Token(TOK_NUMBER, Float64(numstr), String(""), 0, 0))
            continue

        # --- string literal: "..." with "" as an escaped quote ---
        if c == UInt8(0x22):  # "
            i += 1
            var sbuf = List[UInt8]()
            var closed = False
            while i < n:
                var ch = bs[i]
                if ch == UInt8(0x22):
                    if i + 1 < n and bs[i + 1] == UInt8(0x22):
                        sbuf.append(UInt8(0x22))
                        i += 2
                        continue
                    i += 1
                    closed = True
                    break
                sbuf.append(ch)
                i += 1
            if not closed:
                raise Error("xlfn parse error: unterminated string literal")
            toks.append(
                Token(
                    TOK_STRING,
                    0.0,
                    String(StringSlice(unsafe_from_utf8=Span(sbuf))),
                    0,
                    0,
                )
            )
            continue

        # --- error literal: #DIV/0! #N/A #VALUE! #REF! #NAME? #NUM! #NULL! ---
        if c == UInt8(0x23):  # #
            var estart = i
            i += 1
            while i < n and _is_err_cont(bs[i]):
                i += 1
            var etext = _slice_str(formula, estart, i)
            toks.append(Token(TOK_ERROR, 0.0, String(""), 0, excel_error_code_from_literal(etext)))
            continue

        # --- identifier / function name (TRUE/FALSE resolved at parse time) ---
        if _is_alpha(c):
            var istart = i
            i += 1
            while i < n and _is_ident_cont(bs[i]):
                i += 1
            toks.append(Token(TOK_IDENT, 0.0, _slice_str(formula, istart, i), 0, 0))
            continue

        # --- punctuation + operators ---
        if c == UInt8(0x28):  # (
            toks.append(Token(TOK_LPAREN, 0.0, String(""), 0, 0)); i += 1; continue
        if c == UInt8(0x29):  #)
            toks.append(Token(TOK_RPAREN, 0.0, String(""), 0, 0)); i += 1; continue
        if c == UInt8(0x2C):  #,
            toks.append(Token(TOK_COMMA, 0.0, String(""), 0, 0)); i += 1; continue
        if c == UInt8(0x2B):  # +
            toks.append(Token(TOK_OP, 0.0, String(""), OP_ADD, 0)); i += 1; continue
        if c == UInt8(0x2D):  # -
            toks.append(Token(TOK_OP, 0.0, String(""), OP_SUB, 0)); i += 1; continue
        if c == UInt8(0x2A):  # *
            toks.append(Token(TOK_OP, 0.0, String(""), OP_MUL, 0)); i += 1; continue
        if c == UInt8(0x2F):  # /
            toks.append(Token(TOK_OP, 0.0, String(""), OP_DIV, 0)); i += 1; continue
        if c == UInt8(0x26):  # &
            toks.append(Token(TOK_OP, 0.0, String(""), OP_CONCAT, 0)); i += 1; continue
        if c == UInt8(0x3D):  # =
            toks.append(Token(TOK_OP, 0.0, String(""), OP_EQ, 0)); i += 1; continue
        if c == UInt8(0x3C):  # <
            if i + 1 < n and bs[i + 1] == UInt8(0x3E):  # <>
                toks.append(Token(TOK_OP, 0.0, String(""), OP_NE, 0)); i += 2; continue
            if i + 1 < n and bs[i + 1] == UInt8(0x3D):  # <=
                toks.append(Token(TOK_OP, 0.0, String(""), OP_LE, 0)); i += 2; continue
            toks.append(Token(TOK_OP, 0.0, String(""), OP_LT, 0)); i += 1; continue
        if c == UInt8(0x3E):  # >
            if i + 1 < n and bs[i + 1] == UInt8(0x3D):  # >=
                toks.append(Token(TOK_OP, 0.0, String(""), OP_GE, 0)); i += 2; continue
            toks.append(Token(TOK_OP, 0.0, String(""), OP_GT, 0)); i += 1; continue

        if c == UInt8(0x40):  # @
            raise Error(
                "xlfn parse error: the '@' implicit-intersection operator is not"
                " supported (a deferred sheet-layer feature)"
            )

        raise Error("xlfn parse error: unexpected character")

    toks.append(Token(TOK_EOF, 0.0, String(""), 0, 0))
    return toks^


@always_inline
def _binop_prec(op: UInt8) -> Int:
    """Binary-operator precedence (0 = not a binary operator). Higher binds
    tighter. Unary minus is handled in `parse_unary`, not here."""
    if op == OP_EQ or op == OP_NE or op == OP_LT or op == OP_LE or op == OP_GT or op == OP_GE:
        return 1
    if op == OP_CONCAT:
        return 2
    if op == OP_ADD or op == OP_SUB:
        return 3
    if op == OP_MUL or op == OP_DIV:
        return 4
    return 0


struct Parser:
    """Precedence-climbing parser over a token list, building a FormulaAst."""
    var toks: List[Token]
    var pos: Int
    var ast: FormulaAst

    def __init__(out self, var toks: List[Token]):
        self.toks = toks^
        self.pos = 0
        self.ast = FormulaAst()

    @always_inline
    def _peek(self) -> Token:
        return self.toks[self.pos].copy()

    @always_inline
    def _advance(mut self):
        self.pos += 1

    def _expect(mut self, kind: UInt8) raises:
        if self.toks[self.pos].kind != kind:
            raise Error("xlfn parse error: unexpected token, expected kind")
        self.pos += 1

    def parse_expr(mut self, min_prec: Int) raises -> Int:
        var left = self.parse_unary()
        while True:
            var t = self._peek()
            if t.kind != TOK_OP:
                break
            var prec = _binop_prec(t.op)
            if prec == 0 or prec < min_prec:
                break
            self._advance()
            var right = self.parse_expr(prec + 1)  # left-associative
            left = self.ast.add(node_binop(t.op, left, right))
        return left

    def parse_unary(mut self) raises -> Int:
        var t = self._peek()
        if t.kind == TOK_OP and t.op == OP_SUB:
            self._advance()
            var child = self.parse_unary()
            return self.ast.add(node_unary(OP_NEG, child))
        if t.kind == TOK_OP and t.op == OP_ADD:
            self._advance()
            return self.parse_unary()
        return self.parse_primary()

    def parse_primary(mut self) raises -> Int:
        var t = self._peek()
        if t.kind == TOK_NUMBER:
            self._advance()
            return self.ast.add(node_number(t.num))
        if t.kind == TOK_STRING:
            self._advance()
            return self.ast.add(node_string(t.text))
        if t.kind == TOK_ERROR:
            self._advance()
            return self.ast.add(node_error(t.error_code))
        if t.kind == TOK_LPAREN:
            self._advance()
            var e = self.parse_expr(0)
            self._expect(TOK_RPAREN)
            return e
        if t.kind == TOK_IDENT:
            self._advance()
            var up = t.text.upper()
            if self._peek().kind != TOK_LPAREN:
                if up == String("TRUE"):
                    return self.ast.add(node_bool(True))
                if up == String("FALSE"):
                    return self.ast.add(node_bool(False))
            # function call?
            if self._peek().kind == TOK_LPAREN:
                self._advance()  # consume '('
                var args = List[Int]()
                if self._peek().kind != TOK_RPAREN:
                    args.append(self.parse_expr(0))
                    while self._peek().kind == TOK_COMMA:
                        self._advance()
                        args.append(self.parse_expr(0))
                self._expect(TOK_RPAREN)
                return self.ast.add(node_call(t.text, args^))
            # bare binding name
            return self.ast.add(node_name(t.text))
        raise Error("xlfn parse error: unexpected token in primary")


def parse_formula(formula: String) raises -> FormulaAst:
    """Parse a formula string (with or without a leading '=') into a
    FormulaAst. The result's `root` is the top-level expression node index."""
    var body = formula
    if formula.byte_length() > 0 and formula.as_bytes()[0] == UInt8(0x3D):  # strip leading '='
        body = _slice_str(formula, 1, formula.byte_length())
    var toks = tokenize(body)
    var p = Parser(toks^)
    var root = p.parse_expr(0)
    if p._peek().kind != TOK_EOF:
        raise Error("xlfn parse error: trailing tokens after expression")
    var ast = p.ast.copy()
    ast.root = root
    return ast^
