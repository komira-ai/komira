# =============================================================================
# sql/sql_parse_text.mojo
#   Tokenize and parse a SQL text, and say where it stopped when it is refused.
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
from sql.sql_position import SqlPosition, position_of
from sql.sql_token import Token, tokenize


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
