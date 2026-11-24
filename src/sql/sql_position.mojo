# =============================================================================
# sql/sql_position.mojo
#   Where in a SQL text the tokenizer or the parser stopped.
# =============================================================================
#
#   var stopped_at = SqlPosition(0, 0)
#   try:
#       _ = parse_sql_text("SELECT a FROM t GROUP a", stopped_at)
#   except e:
#       # String(e)      == "SQL syntax error: expected keyword 'by'"
#       # String(stopped_at) == "line 1, column 23"
#       pass
#
# `parse_sql_text` is `parse_sql(tokenize(text))` that also says where it
# stopped; the error it raises is the tokenizer's or parser's own, unchanged.

from sql.sql_ast import SqlStatement
from sql.sql_parser import _Parser
from sql.sql_token import Token, tokenize


@fieldwise_init
struct SqlPosition(Copyable, Movable, Writable):
    """A place in a SQL text: `line` and `column`, both counted from 1. The
    column counts characters (UTF-8 code points), not bytes. Written as
    `line <L>, column <C>`."""

    var line: Int
    var column: Int

    def write_to[W: Writer](self, mut writer: W):
        writer.write("line ", self.line, ", column ", self.column)


def position_of(text: String, offset: Int) -> SqlPosition:
    """The position of the byte `offset` in `text`: the line is 1 plus the
    newlines before `offset`; the column is 1 plus the characters between the
    last newline before `offset` and `offset`. A byte that continues a
    multi-byte UTF-8 character (`0b10xxxxxx`) is not counted."""
    var src = text.as_bytes()
    var end = min(max(offset, 0), len(src))
    var line = 1
    var column = 1
    for i in range(end):
        var b = src[i]
        if b == UInt8(ord("\n")):
            line += 1
            column = 1
        elif (b & UInt8(0xC0)) != UInt8(0x80):
            column += 1
    return SqlPosition(line, column)


def parse_sql_text(
    text: String, mut stopped_at: SqlPosition
) raises -> SqlStatement:
    """Tokenize and parse `text` into a `SqlStatement`.

    Raises the tokenizer's or the parser's own `Error`, unchanged, and first
    sets `stopped_at`: for a tokenizer error to the start of the token it was
    lexing (an unterminated string literal's opening quote, the unexpected
    character); for a parser error to the start of the token the parser was
    looking at (the end of the text when it wanted more). `stopped_at` is left
    as given when `text` parses.
    """
    var starts = List[Int]()
    var tokens: List[Token]
    try:
        tokens = tokenize(text, starts)
    except e:
        stopped_at = position_of(text, starts[len(starts) - 1])
        raise e^
    # `parse_sql` is `_Parser(tokens).parse()`; the parser's token index, which
    # it keeps in `pos`, is what maps an error to a place in the text, and
    # `parse_sql` does not give the parser back.
    var parser = _Parser(tokens^)
    try:
        return parser.parse()
    except e:
        stopped_at = position_of(text, starts[parser.pos])
        raise e^
