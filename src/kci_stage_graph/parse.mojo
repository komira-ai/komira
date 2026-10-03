# =============================================================================
# src/kci_stage_graph/parse.mojo -- read a machine file (format
#   `kci.machine`, kci_contract's format table).
# =============================================================================
#
#   schema_version: 1
#   stage {
#     name: "build"
#     step {
#       name: "build"
#       kind: BUILD
#       platform: "linux-x86_64"
#       declarations: "release/artifacts.textproto"
#     }
#   }
#   stage {
#     name: "prod"
#     after: "build"
#     step {
#       name: "publish"
#       kind: PUBLISH
#       platform: "linux-x86_64"
#       declarations: "release/artifacts.textproto"
#       channels: "release/channels.textproto"
#       channel: "komira"
#     }
#   }
#
# `schema_version` is read FIRST (kci_contract's `authored_schema_version`):
# missing, set twice, not an integer, or a major this kci does not read is
# refused, so a file written for a newer kci says "needs a newer kci" rather
# than naming a field the newer major added. `machine_schema_version` does
# that check alone, so a caller can tell a version refusal from any other.
#
# The field names are the contract (`machine_field_names`, pinned by a
# welded golden test). Top level: `schema_version`, `stage`. A stage: `name`,
# `after` (at most once), `step` (repeated). A step: `name`, `kind`,
# `platform`, `declarations`, `channels`, `channel`, each at most once. A
# `:` before a `{` is optional; a scalar may be quoted or bare.
#
# RESERVED: `step.validation` (a block). It is in the golden list so its
# name is taken, and the parser refuses it as "needs a newer kci", the same
# treatment as `kind: DEPLOY` (graph.mojo).
#
# Every refusal starts `<source>: line N:`. The parser refuses an unknown
# field at any level, a scalar set twice, and a block never closed; every
# other rule is graph.mojo's `validate_stage_graph`, run before the graph is
# returned.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_textproto import (
    TOKEN_COLON,
    TOKEN_LBRACE,
    TOKEN_NUMBER,
    TOKEN_RBRACE,
    TOKEN_STRING,
    TOKEN_WORD,
    TokenCursor,
    lex,
)

from kci_contract import FORMAT_MACHINE, authored_schema_version, skip_schema_version

from .graph import Stage, StageGraph, StageStep, validate_stage_graph


def machine_field_names() -> List[String]:
    """Every field name a machine file may use, as `<block>.<field>`, in the
    order of the file header. The welded golden test pins this list: a
    rename is a visible edit of that test."""
    var out = List[String]()
    out.append(String("schema_version"))
    out.append(String("stage"))
    out.append(String("stage.name"))
    out.append(String("stage.after"))
    out.append(String("stage.step"))
    out.append(String("step.name"))
    out.append(String("step.kind"))
    out.append(String("step.platform"))
    out.append(String("step.declarations"))
    out.append(String("step.channels"))
    out.append(String("step.channel"))
    out.append(String("step.validation"))
    return out^


def _at(source: String, line: Int) -> String:
    return source + String(": line ") + String(line) + String(": ")


def _open_block(mut c: TokenCursor) raises -> Int:
    if c.is_kind(TOKEN_COLON):
        _ = c.expect(TOKEN_COLON)
    return c.expect(TOKEN_LBRACE).line


def _scalar(mut c: TokenCursor, field: String, source: String) raises -> String:
    _ = c.expect(TOKEN_COLON)
    var v = c.next(String("a value for '") + field + String("'"))
    if v.kind != TOKEN_STRING and v.kind != TOKEN_WORD and v.kind != TOKEN_NUMBER:
        raise Error(
            _at(source, v.line) + String("expected a value for '") + field + String("' but got ") + v.describe()
        )
    return v.text.copy()


def _twice(source: String, line: Int, field: String, where: String) raises:
    raise Error(_at(source, line) + String("field '") + field + String("' is set twice in ") + where)


def _parse_step(mut c: TokenCursor, source: String, stage_name: String, open_line: Int) raises -> StageStep:
    var s = StageStep(open_line)
    var seen = List[String]()
    var where = String("a step of stage '") + stage_name + String("'")
    while True:
        if c.at_end():
            raise Error(_at(source, open_line) + where + String(" is not closed (expected '}')"))
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        var f = c.expect(TOKEN_WORD)
        for i in range(len(seen)):
            if seen[i] == f.text:
                _twice(source, f.line, f.text, where)
        if f.text == "name":
            s.name = _scalar(c, f.text, source)
        elif f.text == "kind":
            s.kind = _scalar(c, f.text, source)
        elif f.text == "platform":
            s.platform = _scalar(c, f.text, source)
        elif f.text == "declarations":
            s.declarations = _scalar(c, f.text, source)
        elif f.text == "channels":
            s.channels = _scalar(c, f.text, source)
        elif f.text == "channel":
            s.channel = _scalar(c, f.text, source)
        elif f.text == "validation":
            var named = where
            if s.name.byte_length() > 0:
                named = String("step '") + s.name + String("' of stage '") + stage_name + String("'")
            raise Error(
                _at(source, f.line) + named
                + String(" declares a validation: validations need a newer kci (this kci runs BUILD and PUBLISH steps)")
            )
        else:
            raise Error(
                _at(source, f.line) + String("unknown field '") + f.text + String("' in ") + where
                + String(" (expected name, kind, platform, declarations, channels, channel)")
            )
        seen.append(f.text.copy())
    return s^


def _parse_stage(mut c: TokenCursor, source: String, ordinal: Int, open_line: Int) raises -> Stage:
    var st = Stage(open_line)
    var seen_name = False
    var seen_after = False
    while True:
        var where: String
        if st.name.byte_length() > 0:
            where = String("stage '") + st.name + String("'")
        else:
            where = String("stage #") + String(ordinal)
        if c.at_end():
            raise Error(_at(source, open_line) + where + String(" is not closed (expected '}')"))
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        var f = c.expect(TOKEN_WORD)
        if f.text == "name":
            if seen_name:
                _twice(source, f.line, f.text, where)
            st.name = _scalar(c, f.text, source)
            seen_name = True
        elif f.text == "after":
            if seen_after:
                _twice(source, f.line, f.text, where)
            st.after = _scalar(c, f.text, source)
            seen_after = True
        elif f.text == "step":
            var line = _open_block(c)
            st.steps.append(_parse_step(c, source, st.name, line))
        else:
            raise Error(
                _at(source, f.line) + String("unknown field '") + f.text + String("' in ") + where
                + String(" (expected name, after, step)")
            )
    return st^


def machine_schema_version(text: String, source: String) raises -> Int:
    """The checked major of a machine file, and nothing else (file
    header)."""
    var tokens = lex(text, source)
    return authored_schema_version(tokens, String(FORMAT_MACHINE), source)


def parse_machine_file(text: String, source: String) raises -> StageGraph:
    """Parse and validate a machine file; `source` names it in every
    refusal. Raises on the first refusal."""
    var tokens = lex(text, source)
    var major = authored_schema_version(tokens, String(FORMAT_MACHINE), source)
    var c = TokenCursor(tokens^, source)
    var g = StageGraph(major)
    while not c.at_end():
        var f = c.expect(TOKEN_WORD)
        if f.text == "schema_version":
            skip_schema_version(c)
            continue
        if f.text != "stage":
            raise Error(
                _at(source, f.line) + String("unknown top-level field '") + f.text
                + String("' (expected schema_version, stage)")
            )
        var line = _open_block(c)
        g.stages.append(_parse_stage(c, source, len(g.stages) + 1, line))
    validate_stage_graph(g, source)
    return g^
