# =============================================================================
# kci_cell/parse.mojo -- read a cells file.
# =============================================================================
#
# The cells file is textproto, every cell defined once, under its format's
# major (kci_api's format table, `kci.cells`):
#
#   schema_version: 1
#   cell {
#     name: "staging"
#     cloud: "gcp"
#     setting { key: "project" value: "example-staging" }
#     setting { key: "region" value: "europe-west1" }
#     bootstrap_level: 1
#   }
#
# `schema_version` is read FIRST, before any other field (kci_api's
# `authored_schema_version`): missing, set twice, not an integer, or a major
# this kci does not read is refused, so a file written for a newer kci says
# "needs a newer kci" rather than naming a field the newer major added.
#
# `schema_version` and `cell` are the only top-level fields; `name`, `cloud`,
# `setting` (repeated) and `bootstrap_level` the only cell fields; `key` and
# `value` the only setting fields. A `:` before a `{` is optional, as in
# textproto. A scalar may be quoted or bare; `bootstrap_level` is a bare
# integer.
#
# Every refusal from this file starts `cells file: line N:`, lexer and
# token-cursor refusals included; a `schema_version` refusal that kci_api
# words without a line is given the line of the field (line 1 when it is
# missing). The parser refuses:
#
#   * an unknown field at any level;
#   * a scalar field set twice;
#   * a duplicate cell name, and a setting key set twice in one cell (keys
#     compare byte for byte: `Project` and `project` are two keys);
#   * a setting with no key;
#   * an empty (or whitespace-only) or missing `cloud` (any other value is
#     kept as written: its form is checked where the step runs);
#   * a cell name outside the step-name grammar (kci_api's `is_step_name`),
#     a missing name included;
#   * a `bootstrap_level` other than the integer 1, a missing one included;
#   * a `cell` or `setting` block that is never closed;
#   * a file declaring no cell;
#   * a `schema_version` that is missing or of another major.
#
# Every check runs here, on the line it names, so a parsed list is always a
# valid one. Whether the cell's cloud is built into this kci, and which
# settings it needs, is the cloud's business (kci_cloud), never this
# package's: it depends on the lexer and kci_api only.
# =============================================================================

from komira_textproto import (
    TOKEN_COLON,
    TOKEN_LBRACE,
    TOKEN_NUMBER,
    TOKEN_RBRACE,
    TOKEN_STRING,
    TOKEN_WORD,
    Token,
    TokenCursor,
    lex,
)

from kci_api import (
    FORMAT_CELLS,
    SCHEMA_VERSION_KEY,
    STEP_NAME_MAX_BYTES,
    authored_schema_version,
    is_step_name,
    skip_schema_version,
)

from .cell import BOOTSTRAP_LEVEL_V1, Cell, CellSetting


comptime _SOURCE: String = "cells file"


def _at(line: Int) -> String:
    return String(_SOURCE) + String(": line ") + String(line) + String(": ")


def _open_block(mut c: TokenCursor) raises -> Int:
    """Consume an optional `:` then the `{` of a message field; return the
    line of the `{`."""
    if c.is_kind(TOKEN_COLON):
        _ = c.expect(TOKEN_COLON)
    return c.expect(TOKEN_LBRACE).line


def _refuse_unclosed(open_line: Int, what: String) raises:
    raise Error(_at(open_line) + what + String(" is not closed (expected '}')"))


def _scalar_token(mut c: TokenCursor, field: String) raises -> Token:
    """Consume `: <value>` and return the value's token."""
    _ = c.expect(TOKEN_COLON)
    var v = c.next(String("a value for '") + field + String("'"))
    if v.kind != TOKEN_STRING and v.kind != TOKEN_WORD and v.kind != TOKEN_NUMBER:
        raise Error(
            _at(v.line)
            + String("expected a value for '")
            + field
            + String("' but got ")
            + v.describe()
        )
    return v^


def _scalar(mut c: TokenCursor, field: String) raises -> String:
    """Consume `: <value>` and return the value's text."""
    return _scalar_token(c, field).text.copy()


def _refuse_twice(line: Int, field: String, where: String) raises:
    raise Error(
        _at(line) + String("field '") + field + String("' is set twice in ") + where
    )


def _cell_label(name: String, ordinal: Int) -> String:
    if name.byte_length() > 0:
        return String("cell '") + name + String("'")
    return String("cell #") + String(ordinal)


def _is_blank(value: String) -> Bool:
    """True for an empty or whitespace-only value."""
    var b = value.as_bytes()
    for i in range(len(b)):
        var ch = Int(b[i])
        if ch != 32 and ch != 9 and ch != 10 and ch != 13:
            return False
    return True


def _parse_setting(
    mut c: TokenCursor, where: String, open_line: Int, mut key_line: Int
) raises -> CellSetting:
    """One `setting { key: ... value: ... }`; `key_line` is set to the line
    of its `key` field."""
    var key = String("")
    var value = String("")
    var seen_key = False
    var seen_value = False
    var label = String("a setting of ") + where
    while True:
        if c.at_end():
            _refuse_unclosed(open_line, label)
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        var f = c.expect(TOKEN_WORD)
        if f.text == "key":
            if seen_key:
                _refuse_twice(f.line, f.text, label)
            key = _scalar(c, f.text)
            seen_key = True
            key_line = f.line
        elif f.text == "value":
            if seen_value:
                _refuse_twice(f.line, f.text, label)
            value = _scalar(c, f.text)
            seen_value = True
        else:
            raise Error(
                _at(f.line)
                + String("unknown field '")
                + f.text
                + String("' in ")
                + label
                + String(" (expected key, value)")
            )
    if not seen_key or key.byte_length() == 0:
        raise Error(_at(open_line) + label + String(" has no key"))
    return CellSetting(key^, value^)


def _parse_cell(
    mut c: TokenCursor, ordinal: Int, open_line: Int, mut name_line: Int
) raises -> Cell:
    """One `cell { ... }`, every per-cell rule checked; `name_line` is set to
    the line of its `name` field (the `{` when it has none)."""
    var name = String("")
    var cloud = String("")
    var level_text = String("")
    var level_is_number = False
    var seen_name = False
    var seen_cloud = False
    var seen_level = False
    var cloud_line = open_line
    var level_line = open_line
    name_line = open_line
    var settings = List[CellSetting]()
    var setting_lines = List[Int]()
    while True:
        if c.at_end():
            _refuse_unclosed(open_line, _cell_label(name, ordinal))
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        var f = c.expect(TOKEN_WORD)
        if f.text == "name":
            if seen_name:
                _refuse_twice(f.line, f.text, _cell_label(name, ordinal))
            name = _scalar(c, f.text)
            seen_name = True
            name_line = f.line
        elif f.text == "cloud":
            if seen_cloud:
                _refuse_twice(f.line, f.text, _cell_label(name, ordinal))
            cloud = _scalar(c, f.text)
            seen_cloud = True
            cloud_line = f.line
        elif f.text == "bootstrap_level":
            if seen_level:
                _refuse_twice(f.line, f.text, _cell_label(name, ordinal))
            var v = _scalar_token(c, f.text)
            level_is_number = v.kind == TOKEN_NUMBER
            level_text = v.text.copy()
            seen_level = True
            level_line = f.line
        elif f.text == "setting":
            var where = _cell_label(name, ordinal)
            var setting_line = _open_block(c)
            var key_line = setting_line
            var s = _parse_setting(c, where, setting_line, key_line)
            for k in range(len(settings)):
                if settings[k].key == s.key:
                    raise Error(
                        _at(key_line)
                        + String("setting '")
                        + s.key
                        + String("' is set twice in ")
                        + where
                        + String(" (first on line ")
                        + String(setting_lines[k])
                        + String(")")
                    )
            settings.append(s^)
            setting_lines.append(key_line)
        else:
            raise Error(
                _at(f.line)
                + String("unknown field '")
                + f.text
                + String("' in ")
                + _cell_label(name, ordinal)
                + String(" (expected name, cloud, setting, bootstrap_level)")
            )
    if not is_step_name(name):
        raise Error(
            _at(name_line)
            + _cell_label(name, ordinal)
            + String(" has name '")
            + name
            + String("'; a cell name is [a-z][a-z0-9-]*, at most ")
            + String(STEP_NAME_MAX_BYTES)
            + String(" bytes, not ending in '-'")
        )
    if _is_blank(cloud):
        raise Error(
            _at(cloud_line)
            + String("cell '")
            + name
            + String("' has an empty cloud (a cloud id such as \"gcp\" is required)")
        )
    if not (seen_level and level_is_number and level_text == String(BOOTSTRAP_LEVEL_V1)):
        var got = String("none")
        if seen_level:
            got = String("'") + level_text + String("'")
        raise Error(
            _at(level_line)
            + String("cell '")
            + name
            + String("' has bootstrap_level ")
            + got
            + String("; this kci accepts only the integer ")
            + String(BOOTSTRAP_LEVEL_V1)
        )
    return Cell(name^, cloud^, settings^, BOOTSTRAP_LEVEL_V1, open_line)


def _schema_version_line(tokens: List[Token]) -> Int:
    """The line of the first top-level `schema_version` field, or 1 when
    there is none (where the field is to be added)."""
    var depth = 0
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
        return t.line
    return 1


def _check_schema_version(tokens: List[Token]) raises:
    """kci_api's `authored_schema_version`, each refusal starting
    `cells file: line N:`."""
    var refusal = String("")
    var failed = False
    try:
        _ = authored_schema_version(tokens, String(FORMAT_CELLS), String(_SOURCE))
    except e:
        refusal = String(e)
        failed = True
    if not failed:
        return
    if refusal.startswith(String(_SOURCE) + String(": line ")):
        raise Error(refusal)
    var head = String(_SOURCE) + String(": ")
    var rest = refusal.copy()
    if refusal.startswith(head):
        rest = String(refusal[byte = head.byte_length():])
    raise Error(_at(_schema_version_line(tokens)) + rest)


def parse_cells_file(text: String) raises -> List[Cell]:
    """Parse and validate a cells file. Raises on the first refusal, by a
    message starting `cells file: line N:` and naming the offending field or
    cell."""
    var tokens = lex(text, String(_SOURCE))
    _check_schema_version(tokens)
    var c = TokenCursor(tokens^, String(_SOURCE))
    var out = List[Cell]()
    var name_lines = List[Int]()
    while not c.at_end():
        var f = c.expect(TOKEN_WORD)
        if f.text == "schema_version":
            skip_schema_version(c)
            continue
        if f.text != "cell":
            raise Error(
                _at(f.line)
                + String("unknown top-level field '")
                + f.text
                + String("' (expected schema_version, cell)")
            )
        var open_line = _open_block(c)
        var name_line = open_line
        var cell = _parse_cell(c, len(out) + 1, open_line, name_line)
        for k in range(len(out)):
            if out[k].name == cell.name:
                raise Error(
                    _at(name_line)
                    + String("cell '")
                    + cell.name
                    + String("' is declared twice (first on line ")
                    + String(name_lines[k])
                    + String(")")
                )
        out.append(cell^)
        name_lines.append(name_line)
    if len(out) == 0:
        raise Error(
            _at(c.last_line())
            + String("the file declares no cell (expected at least one `cell { ... }`)")
        )
    return out^
