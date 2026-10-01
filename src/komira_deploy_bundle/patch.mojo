# =============================================================================
# komira_deploy_bundle/patch.mojo — the comment-preserving textproto patcher.
# =============================================================================
#
# The MINIMAL-DIFF patcher: `set-field` (replace one
# scalar's value) and `append-block` (add a repeated message block) applied
# DIRECTLY to the textproto TEXT — never a parse -> canonical re-serialize, which
# "would destroy the `#` prose that justifies the file". It shares the parser's
# tokenizer (`tokenizer.mojo`): the token byte-spans locate the exact bytes to
# splice, and EVERY other byte — comments, blank lines, field order, indentation
# — is passed through untouched. This is the "use this new image for my service"
# one-field-edit path and the LLM's structured-edit surface.
#
# set-field targets a scalar reached by a dotted path of SINGULAR message blocks
# (`spec.port`, `spec.image.from_build`, `name`); the first match at each level
# wins. append-block inserts a fully-rendered `field { ... }` block at end-of-file
# (top-level parent) or just before a named parent block's closing `}`.
#
# ENCAPSULATION: value-typed token walk + `String` splice. No UnsafePointer, no
# wildcard origin. Mojo 1.0.0b2.
# =============================================================================

from komira_deploy_bundle.tokenizer import (
    Token,
    tokenize,
    TOK_IDENT,
    TOK_STRING,
    TOK_NUMBER,
    TOK_LBRACE,
    TOK_RBRACE,
    TOK_COLON,
    TOK_EOF,
)
from komira_deploy_bundle.emit import quote
from komira_deploy_bundle.parser import resolve_enum_token


def _join_path(path: List[String]) -> String:
    var out = String("")
    for i in range(len(path)):
        if i > 0:
            out += String(".")
        out += path[i]
    return out^


def _splice(text: String, start: Int, end: Int, replacement: String) -> String:
    """Return `text` with bytes [start, end) replaced by `replacement`; every
    other byte is preserved VERBATIM (byte-exact — non-ASCII comment/prose bytes
    survive intact, the whole point of the comment-preserving patcher)."""
    var b = text.as_bytes()
    var prefix = String(unsafe_from_utf8=b[0:start])
    var suffix = String(unsafe_from_utf8=b[end : len(b)])
    return prefix + replacement + suffix


def _skip_block(toks: List[Token], i: Int) -> Int:
    """`toks[i]` is a `{`; return the token index just AFTER the matching `}`."""
    var depth = 0
    var j = i
    while j < len(toks):
        if toks[j].kind == TOK_LBRACE:
            depth += 1
        elif toks[j].kind == TOK_RBRACE:
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return j


def _find_value_token(
    toks: List[Token], start: Int, path: List[String], pidx: Int
) raises -> Int:
    """Scan the block whose fields begin at token index `start` (0 at top level;
    just-after-`{` for a nested block). Descend singular message blocks matching
    the path; return the VALUE token index of the terminal scalar."""
    var i = start
    while i < len(toks):
        var kind = toks[i].kind
        if kind == TOK_RBRACE or kind == TOK_EOF:
            break
        if kind != TOK_IDENT:
            i += 1
            continue
        var field = String(toks[i].text)
        var j = i + 1
        if j < len(toks) and toks[j].kind == TOK_COLON:
            j += 1
        if j < len(toks) and toks[j].kind == TOK_LBRACE:
            # a nested message block
            if field == path[pidx] and pidx + 1 < len(path):
                return _find_value_token(toks, j + 1, path, pidx + 1)
            i = _skip_block(toks, j)
            continue
        else:
            # a scalar field: value token at j
            if field == path[pidx] and pidx + 1 == len(path):
                return j
            i = j + 1
            continue
    raise Error(
        String("patch: scalar field path '")
        + _join_path(path)
        + String("' not found")
    )


def _find_block_open(
    toks: List[Token], start: Int, path: List[String], pidx: Int
) raises -> Int:
    """Return the `{` token index of the message block reached by `path` from the
    fields beginning at token index `start`."""
    var i = start
    while i < len(toks):
        var kind = toks[i].kind
        if kind == TOK_RBRACE or kind == TOK_EOF:
            break
        if kind != TOK_IDENT:
            i += 1
            continue
        var field = String(toks[i].text)
        var j = i + 1
        if j < len(toks) and toks[j].kind == TOK_COLON:
            j += 1
        if j < len(toks) and toks[j].kind == TOK_LBRACE:
            if field == path[pidx]:
                if pidx + 1 == len(path):
                    return j
                return _find_block_open(toks, j + 1, path, pidx + 1)
            i = _skip_block(toks, j)
            continue
        else:
            i = j + 1
            continue
    raise Error(
        String("patch: block path '")
        + _join_path(path)
        + String("' not found")
    )


def _indent_block(block: String, level: Int) -> String:
    """Prefix each non-empty line of `block` with `level` * 2 spaces; guarantee a
    trailing newline (so the parent's closing `}` lands on its own line). Byte-
    exact for the copied content (non-ASCII survives)."""
    var b = block.as_bytes()
    var out = List[UInt8]()
    var at_line_start = True
    for i in range(len(b)):
        var c = b[i]
        if at_line_start and c != UInt8(ord("\n")):
            for _ in range(level * 2):
                out.append(UInt8(ord(" ")))
        out.append(c)
        at_line_start = c == UInt8(ord("\n"))
    if len(out) == 0 or out[len(out) - 1] != UInt8(ord("\n")):
        out.append(UInt8(ord("\n")))
    return String(unsafe_from_utf8=out)


# ─── the two public patch ops ────────────────────────────────────────────────
def patch_set_field(
    text: String, path: List[String], new_value: String, quote_value: Bool
) raises -> String:
    """Replace the value of the scalar at the dotted `path` with `new_value`
    (quoted as a string literal when `quote_value`, else spliced raw for a
    number/enum). Comments, ordering, and all other bytes are preserved. Raises a
    path-not-found error the caller can surface for self-correction."""
    var toks = tokenize(text)
    var vi = _find_value_token(toks, 0, path, 0)
    var vstart = toks[vi].start
    var vend = toks[vi].end
    var rendered = quote(new_value) if quote_value else new_value
    return _splice(text, vstart, vend, rendered)


def patch_set_enum(
    text: String, path: List[String], value: String, legal: List[String]
) raises -> String:
    """Set-field for an ENUM scalar: `value` is resolved to its CANONICAL full
    declared name (accepting the same short suffix alias the parser accepts — e.g.
    `API` -> `APP_KIND_API`) and spliced RAW (unquoted). Honors "friendly input,
    one canonical output": a patched enum line always emits the canonical full
    value even when the author typed a short alias, while every UNTOUCHED enum
    line keeps the author's original spelling (byte-preserved). `legal` is the
    field's enum value set (e.g. parser.app_kind_values())."""
    var canonical = resolve_enum_token(value, legal)
    return patch_set_field(text, path, canonical, False)


def patch_append_block(
    text: String, parent_path: List[String], block: String
) raises -> String:
    """Append the fully-rendered `block` (e.g. a `waves { ... }` message) under
    `parent_path`. An EMPTY parent_path appends at end-of-file (a top-level
    repeated field, preceded by a blank line); a non-empty parent_path inserts
    the block, indented one level, just before that parent block's closing `}`.
    Comments and existing content are preserved."""
    if len(parent_path) == 0:
        var out = String(text)
        if out.byte_length() > 0 and not out.endswith(String("\n")):
            out += String("\n")
        # a blank separator line, then the block (guaranteed newline-terminated)
        out += String("\n") + _indent_block(block, 0)
        return out^
    var toks = tokenize(text)
    var open_idx = _find_block_open(toks, 0, parent_path, 0)
    var after = _skip_block(toks, open_idx)  # token index just past '}'
    var close_start = toks[after - 1].start  # byte offset of the '}' token
    var insertion = _indent_block(block, 1)
    return _splice(text, close_start, close_start, insertion)
