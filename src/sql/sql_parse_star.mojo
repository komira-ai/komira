# =============================================================================
# sql/sql_parse_star.mojo
#   The tail of a star in the SELECT list: `* EXCLUDE (a, b)`.
# =============================================================================
#
# DuckDB reads a star with an EXCLUDE list as every column the star expands to
# but the named ones (`SELECT * EXCLUDE (note) FROM orders`), and takes one
# name without parentheses too (`* EXCLUDE note`). A table-qualified star
# takes it the same way (`o.* EXCLUDE (note)`). This module parses the list
# after the star the parser has already consumed; the binder expands it
# (`_star_out_names` of `sql_bind_scope`).
#
# What it refuses, each by name:
#   * a name written twice (DuckDB: `Parser Error: Duplicate entry "b"
#     in EXCLUDE list`), compared case-insensitively, as column names are;
#   * an empty list `EXCLUDE ()` (a syntax error in DuckDB too);
#   * a qualified name `EXCLUDE (c.k)`, which this grammar does not take;
#   * DuckDB's other star modifiers, `REPLACE (...)` and `RENAME (...)`, which
#     would otherwise stop at "expected keyword 'from'" naming neither.

from .sql_token import TK_COMMA, TK_DOT, TK_IDENT, TK_LPAREN, TK_RPAREN, Token


# Every `pos += 1` below steps off a token that is not the last one (an
# identifier, `(`, `,`, `)` or `.`; the EOF token is always last), so it never
# runs past the list.


def _star_is_word(tokens: List[Token], pos: Int, word: String) -> Bool:
    return tokens[pos].kind == TK_IDENT and tokens[pos].text == word


def _star_exclude_name(
    tokens: List[Token], mut pos: Int, names: List[String]
) raises -> String:
    """The column name at `pos` of an EXCLUDE list, consumed; refuses a
    missing name, a qualified one and a repeat of one of `names`."""
    if tokens[pos].kind != TK_IDENT:
        raise Error("SQL syntax error: expected a column name in EXCLUDE")
    var name = String(tokens[pos].text)
    pos += 1
    if tokens[pos].kind == TK_DOT:
        pos += 1
        if tokens[pos].kind != TK_IDENT:
            raise Error(
                "SQL syntax error: expected a column name after '.' in EXCLUDE"
            )
        var col = String(tokens[pos].text)
        raise Error(
            "SQL not supported: a qualified name in EXCLUDE (`" + name + "."
            + col + "`). Name the column alone, `EXCLUDE (" + col + ")`, which"
            " drops every column of that name the star expands to, or name"
            " the relation's star, `" + name + ".* EXCLUDE (" + col + ")`."
        )
    var lowered = name.lower()
    for i in range(len(names)):
        if names[i].lower() == lowered:
            raise Error(
                "SQL syntax error: duplicate entry \"" + name
                + "\" in EXCLUDE list"
            )
    return name^


def _parse_star_tail(tokens: List[Token], mut pos: Int) raises -> List[String]:
    """The EXCLUDE list after a star (empty when there is none), consumed
    from `pos`; then refuses a REPLACE or RENAME list by name."""
    var names = List[String]()
    if _star_is_word(tokens, pos, "exclude"):
        pos += 1
        if tokens[pos].kind == TK_LPAREN:
            pos += 1
            while True:
                names.append(_star_exclude_name(tokens, pos, names))
                if tokens[pos].kind == TK_COMMA:
                    pos += 1
                    continue
                break
            if tokens[pos].kind != TK_RPAREN:
                raise Error(
                    "SQL syntax error: expected ')' to close EXCLUDE (...)"
                )
            pos += 1
        else:
            names.append(_star_exclude_name(tokens, pos, names))
    var next_is_list = (
        pos + 1 < len(tokens) and tokens[pos + 1].kind == TK_LPAREN
    )
    if next_is_list and _star_is_word(tokens, pos, "replace"):
        raise Error(
            "SQL not supported: SELECT * REPLACE (...). Select the columns by"
            " name and write the replacing expression in place of its column"
            " (`SELECT a, b + 1 AS b FROM t`)."
        )
    if next_is_list and _star_is_word(tokens, pos, "rename"):
        raise Error(
            "SQL not supported: SELECT * RENAME (...). Select the columns by"
            " name and rename with AS (`SELECT a, b AS c FROM t`)."
        )
    return names^
