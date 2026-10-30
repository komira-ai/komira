# =============================================================================
# src/kci_api/authored.mojo -- `schema_version` of an authored
#   (textproto) file, read before anything else in it.
# =============================================================================
#
# Every authored file states its major at the top level:
#
#   schema_version: 1
#
# `authored_schema_version(tokens, format, source)` scans the lexed file's
# TOP LEVEL (brace depth 0) for that field before the file's own parser runs,
# so a file written for a newer kci is refused as "needs a newer kci" rather
# than as an unknown field the newer major added. It refuses, naming the
# line: the field set twice, a value that is not a decimal integer (a sign,
# a leading zero, a fraction, a string); then the format table's checks
# (formats.mojo): missing, too new, too old. A major of up to 9 digits is
# read as a number; a longer one is still a decimal integer, above every
# supported major, and gets the same "needs a newer kci" refusal with its
# digits as written (it is never read into an Int, so it cannot wrap). The
# file's parser then skips the field (`skip_schema_version`).
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_textproto import TOKEN_COLON, TOKEN_LBRACE, TOKEN_NUMBER, TOKEN_RBRACE, TOKEN_WORD, Token, TokenCursor

from kci_api.formats import SCHEMA_VERSION_KEY, check_authored_version, refuse_authored_major_beyond_int

comptime _MAX_READ_DIGITS = 9
"""The longest major read as a number (fits an Int without overflow)."""
comptime _TOO_LONG = -2
"""`_decimal`: a well-formed decimal longer than `_MAX_READ_DIGITS`."""


def _decimal(text: String) -> Int:
    """`text` as a non-negative decimal without a sign or a leading zero;
    `_TOO_LONG` for such a decimal of more than `_MAX_READ_DIGITS` digits;
    -1 for anything else."""
    var b = text.as_bytes()
    if len(b) == 0 or (len(b) > 1 and Int(b[0]) == 48):
        return -1
    var n = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return -1
        if i < _MAX_READ_DIGITS:
            n = n * 10 + (c - 48)
    if len(b) > _MAX_READ_DIGITS:
        return _TOO_LONG
    return n


def authored_schema_version(tokens: List[Token], format: String, source: String) raises -> Int:
    """The checked major of an authored file (file header)."""
    var depth = 0
    var present = False
    var found = 0
    var line_seen = 0
    var too_long = String()  # the digits of a major longer than _MAX_READ_DIGITS
    for i in range(len(tokens)):
        ref t = tokens[i]
        if t.kind == TOKEN_LBRACE:
            depth += 1
            continue
        if t.kind == TOKEN_RBRACE:
            depth -= 1
            continue
        if depth != 0 or t.kind != TOKEN_WORD or t.text != SCHEMA_VERSION_KEY:
            continue
        if i > 0 and tokens[i - 1].kind == TOKEN_COLON:
            continue  # a value, not a field name
        if present:
            raise Error(
                source + String(": line ") + String(t.line)
                + String(": field 'schema_version' is set twice (first on line ")
                + String(line_seen) + String(")")
            )
        var ok = (
            i + 2 < len(tokens)
            and tokens[i + 1].kind == TOKEN_COLON
            and tokens[i + 2].kind == TOKEN_NUMBER
        )
        var n = -1
        if ok:
            n = _decimal(tokens[i + 2].text)
        if n == _TOO_LONG:
            too_long = tokens[i + 2].text
            n = 0
        elif n < 0:
            raise Error(
                source + String(": line ") + String(t.line)
                + String(": schema_version is not a decimal integer (expected `schema_version: <major>`)")
            )
        present = True
        found = n
        line_seen = t.line
    if too_long.byte_length() > 0:
        refuse_authored_major_beyond_int(format, source, too_long)
    check_authored_version(format, source, present, found)
    return found


def skip_schema_version(mut c: TokenCursor) raises:
    """Consume `: <number>` after a top-level `schema_version` field name,
    which `authored_schema_version` has already checked."""
    _ = c.expect(TOKEN_COLON)
    _ = c.expect(TOKEN_NUMBER)
