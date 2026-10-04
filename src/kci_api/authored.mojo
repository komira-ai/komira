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
# line: the field set twice, a value that is not a decimal integer; then the
# format table's checks (formats.mojo): missing, too new, too old. The
# file's parser then skips the field (`skip_schema_version`).
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_textproto import TOKEN_COLON, TOKEN_LBRACE, TOKEN_NUMBER, TOKEN_RBRACE, TOKEN_WORD, Token, TokenCursor

from kci_api.formats import SCHEMA_VERSION_KEY, check_authored_version


def _decimal(text: String) -> Int:
    """`text` as a non-negative decimal without a sign or a leading zero, or
    -1."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 9:
        return -1
    if len(b) > 1 and Int(b[0]) == 48:
        return -1
    var n = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return -1
        n = n * 10 + (c - 48)
    return n


def authored_schema_version(tokens: List[Token], format: String, source: String) raises -> Int:
    """The checked major of an authored file (file header)."""
    var depth = 0
    var present = False
    var found = 0
    var line_seen = 0
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
        if n < 0:
            raise Error(
                source + String(": line ") + String(t.line)
                + String(": schema_version is not a decimal integer (expected `schema_version: <major>`)")
            )
        present = True
        found = n
        line_seen = t.line
    check_authored_version(format, source, present, found)
    return found


def skip_schema_version(mut c: TokenCursor) raises:
    """Consume `: <number>` after a top-level `schema_version` field name,
    which `authored_schema_version` has already checked."""
    _ = c.expect(TOKEN_COLON)
    _ = c.expect(TOKEN_NUMBER)
