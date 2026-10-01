"""`komira_textproto` -- a zero-dependency textproto lexer.

`lex(text)` turns textproto text into a list of typed `Token`s; every token
keeps its kind, so a quoted "{" never compares equal to a brace.
`TokenCursor` is a small reader over a token list
for hand-written parsers. See `lexer.mojo`.
"""

from .lexer import (
    TOKEN_COLON,
    TOKEN_LBRACE,
    TOKEN_NUMBER,
    TOKEN_RBRACE,
    TOKEN_STRING,
    TOKEN_WORD,
    Token,
    TokenCursor,
    lex,
    token_kind_name,
)
