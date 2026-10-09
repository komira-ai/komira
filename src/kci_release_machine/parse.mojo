# =============================================================================
# src/kci_release_machine/parse.mojo -- read a machine file (format
#   `kci.machine`, kci_api's format table).
# =============================================================================
#
#   schema_version: 1
#   name: "shop"
#   stage {
#     name: "build"
#     farm_connected: true
#     step {
#       name: "build"
#       kind: BUILD
#       platform: "linux-x86_64"
#       artifacts: "release/artifacts.textproto"
#     }
#   }
#   stage {
#     name: "gamma"
#     after: "build"
#     step {
#       name: "publish"
#       kind: PUBLISH
#       platform: "linux-x86_64"
#       artifacts: "release/artifacts.textproto"
#       channels: "release/channels.textproto"
#       channel: "gamma"
#       validation {
#         name: "install"
#         kind: CONDA_INSTALL_SMOKE
#         image: "<reference>@sha256:<64 hex>"
#         install: "komira_encoding"
#         install: "komira_all"
#         compiler_channel: "https://conda.modular.com/max"
#         extra_channel: "conda-forge"
#         program: "release/smoke/smoke_komira_encoding.mojo"
#         wait_for_index_seconds: 1800
#       }
#     }
#   }
#   stage {
#     name: "prod"
#     after: "gamma"
#     step { ... channel: "prod" }
#   }
#
# `schema_version` is read FIRST (kci_api's `authored_schema_version`):
# missing, set twice, not an integer, or a major this kci does not read is
# refused, so a file written for a newer kci says "needs a newer kci" rather
# than naming a field the newer major added. `machine_schema_version` does
# that check alone, so a caller can tell a version refusal from any other.
#
# The field names are the contract (`machine_field_names`, pinned by a
# welded golden test). Top level: `schema_version`, `name` (the machine's
# name: the step-name grammar, at most once, before the first `stage`; it is
# required only when a step writes into a cell, deploy.mojo's rule), `stage`.
# A stage: `name`,
# `after`, `environment` (default: the stage's name; none on a PULL_REQUEST
# stage), `farm_connected` (`true` or `false`, default false), `trigger`
# (`PUSH` or `PULL_REQUEST`, default PUSH; graph.mojo's header),
# `break_glass` (`true` or `false`, default false: graph.mojo's header),
# `break_glass_environment` (graph.mojo's header), each
# at most once, and `step` (repeated). A step: `name`, `kind`, `platform`, `artifacts`, `channels`,
# `channel`, `cells`, `cell`, `resources`, each at most once, and
# `definitions` and `validation` (a block), each repeated. A
# validation: `name`, `kind`, `image`, `compiler_channel`, `program`,
# `wait_for_index_seconds` (an integer), each at most once, and `install` and
# `extra_channel` (each repeated). A `:` before a `{` is optional; a scalar may
# be quoted or bare.
#
# Every refusal starts `<source>: line N:`. The parser refuses an unknown
# field at any level, a scalar set twice, a block never closed, and a
# machine `name` set twice, after a `stage` or outside the grammar; every
# other rule is graph.mojo's `validate_release_machine`, then deploy.mojo's
# `validate_cell_steps`, run before the graph is returned.
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

from kci_api import FORMAT_MACHINE, authored_schema_version, is_step_name, skip_schema_version

from .deploy import validate_cell_steps
from .graph import NAME_MAX_BYTES, ReleaseMachine, Stage, StageStep, StageValidation, validate_release_machine


def machine_field_names() -> List[String]:
    """Every field name a machine file may use, as `<block>.<field>`, in the
    order of the file header. The welded golden test pins this list: a
    rename is a visible edit of that test."""
    var out = List[String]()
    out.append(String("schema_version"))
    out.append(String("name"))
    out.append(String("stage"))
    out.append(String("stage.name"))
    out.append(String("stage.after"))
    out.append(String("stage.environment"))
    out.append(String("stage.farm_connected"))
    out.append(String("stage.trigger"))
    out.append(String("stage.break_glass"))
    out.append(String("stage.break_glass_environment"))
    out.append(String("stage.step"))
    out.append(String("step.name"))
    out.append(String("step.kind"))
    out.append(String("step.platform"))
    out.append(String("step.artifacts"))
    out.append(String("step.channels"))
    out.append(String("step.channel"))
    out.append(String("step.cells"))
    out.append(String("step.cell"))
    out.append(String("step.resources"))
    out.append(String("step.definitions"))
    out.append(String("step.validation"))
    out.append(String("validation.name"))
    out.append(String("validation.kind"))
    out.append(String("validation.image"))
    out.append(String("validation.install"))
    out.append(String("validation.compiler_channel"))
    out.append(String("validation.extra_channel"))
    out.append(String("validation.program"))
    out.append(String("validation.smoke"))
    out.append(String("validation.wait_for_index_seconds"))
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


def _seconds(mut c: TokenCursor, field: String, source: String, where: String) raises -> Int:
    """A non-negative decimal integer of at most 6 digits (the range is
    graph.mojo's rule)."""
    _ = c.expect(TOKEN_COLON)
    var v = c.next(String("a value for '") + field + String("'"))
    var b = v.text.as_bytes()
    var ok = v.kind == TOKEN_NUMBER and len(b) > 0 and len(b) <= 6
    var n = 0
    for i in range(len(b)):
        var d = Int(b[i])
        if d < 48 or d > 57:
            ok = False
        else:
            n = n * 10 + (d - 48)
    if not ok:
        raise Error(
            _at(source, v.line) + String("field '") + field + String("' of ") + where + String(" is '") + v.text
            + String("'; it is a whole number of seconds")
        )
    return n


def _twice(source: String, line: Int, field: String, where: String) raises:
    raise Error(_at(source, line) + String("field '") + field + String("' is set twice in ") + where)


def _parse_validation(mut c: TokenCursor, source: String, step_where: String, open_line: Int) raises -> StageValidation:
    var v = StageValidation(open_line)
    var seen = List[String]()
    while True:
        var where: String
        if v.name.byte_length() > 0:
            where = String("validation '") + v.name + String("'")
        else:
            where = String("a validation of ") + step_where
        if c.at_end():
            raise Error(_at(source, open_line) + where + String(" is not closed (expected '}')"))
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        var f = c.expect(TOKEN_WORD)
        if f.text != "extra_channel" and f.text != "install":
            for i in range(len(seen)):
                if seen[i] == f.text:
                    _twice(source, f.line, f.text, where)
        if f.text == "name":
            v.name = _scalar(c, f.text, source)
        elif f.text == "kind":
            v.kind = _scalar(c, f.text, source)
        elif f.text == "image":
            v.image = _scalar(c, f.text, source)
        elif f.text == "install":
            v.installs.append(_scalar(c, f.text, source))
        elif f.text == "compiler_channel":
            v.compiler_channel = _scalar(c, f.text, source)
        elif f.text == "extra_channel":
            v.extra_channels.append(_scalar(c, f.text, source))
        elif f.text == "program":
            v.program = _scalar(c, f.text, source)
        elif f.text == "smoke":
            v.smoke = _scalar(c, f.text, source)
        elif f.text == "wait_for_index_seconds":
            v.wait_for_index_seconds = _seconds(c, f.text, source, where)
        else:
            raise Error(
                _at(source, f.line) + String("unknown field '") + f.text + String("' in ") + where
                + String(" (expected name, kind, image, install, compiler_channel, extra_channel, program,")
                + String(" smoke, wait_for_index_seconds)")
            )
        seen.append(f.text.copy())
    return v^


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
        if f.text != "validation" and f.text != "definitions":
            for i in range(len(seen)):
                if seen[i] == f.text:
                    _twice(source, f.line, f.text, where)
        if f.text == "name":
            s.name = _scalar(c, f.text, source)
        elif f.text == "kind":
            s.kind = _scalar(c, f.text, source)
        elif f.text == "platform":
            s.platform = _scalar(c, f.text, source)
        elif f.text == "artifacts":
            s.artifacts = _scalar(c, f.text, source)
        elif f.text == "channels":
            s.channels = _scalar(c, f.text, source)
        elif f.text == "channel":
            s.channel = _scalar(c, f.text, source)
        elif f.text == "cells":
            s.cells = _scalar(c, f.text, source)
        elif f.text == "cell":
            s.cell = _scalar(c, f.text, source)
        elif f.text == "resources":
            s.resources = _scalar(c, f.text, source)
        elif f.text == "definitions":
            s.definitions.append(_scalar(c, f.text, source))
        elif f.text == "validation":
            var named = where
            if s.name.byte_length() > 0:
                named = String("step '") + s.name + String("' of stage '") + stage_name + String("'")
            var line = _open_block(c)
            s.validations.append(_parse_validation(c, source, named, line))
        else:
            raise Error(
                _at(source, f.line) + String("unknown field '") + f.text + String("' in ") + where
                + String(" (expected name, kind, platform, artifacts, channels, channel, cells, cell, resources,")
                + String(" definitions, validation)")
            )
        seen.append(f.text.copy())
    return s^


def _parse_stage(mut c: TokenCursor, source: String, ordinal: Int, open_line: Int) raises -> Stage:
    var st = Stage(open_line)
    var seen_name = False
    var seen_after = False
    var seen_environment = False
    var seen_farm = False
    var seen_trigger = False
    var seen_break_glass = False
    var seen_break_glass_environment = False
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
        elif f.text == "environment":
            if seen_environment:
                _twice(source, f.line, f.text, where)
            st.environment = _scalar(c, f.text, source)
            seen_environment = True
        elif f.text == "farm_connected":
            if seen_farm:
                _twice(source, f.line, f.text, where)
            var word = _scalar(c, f.text, source)
            if word == "true":
                st.farm_connected = True
            elif word == "false":
                st.farm_connected = False
            else:
                raise Error(
                    _at(source, f.line) + String("field 'farm_connected' of ") + where + String(" is '") + word
                    + String("'; it is true or false")
                )
            seen_farm = True
        elif f.text == "trigger":
            if seen_trigger:
                _twice(source, f.line, f.text, where)
            st.trigger = _scalar(c, f.text, source)
            seen_trigger = True
        elif f.text == "break_glass":
            if seen_break_glass:
                _twice(source, f.line, f.text, where)
            var word = _scalar(c, f.text, source)
            if word == "true":
                st.break_glass = True
            elif word == "false":
                st.break_glass = False
            else:
                raise Error(
                    _at(source, f.line) + String("field 'break_glass' of ") + where + String(" is '") + word
                    + String("'; it is true or false")
                )
            seen_break_glass = True
        elif f.text == "break_glass_environment":
            if seen_break_glass_environment:
                _twice(source, f.line, f.text, where)
            st.break_glass_environment = _scalar(c, f.text, source)
            seen_break_glass_environment = True
        elif f.text == "step":
            var line = _open_block(c)
            st.steps.append(_parse_step(c, source, st.name, line))
        else:
            raise Error(
                _at(source, f.line) + String("unknown field '") + f.text + String("' in ") + where
                + String(" (expected name, after, environment, farm_connected, trigger, break_glass, break_glass_environment, step)")
            )
    if not seen_environment and not st.is_pull_request():
        st.environment = st.name.copy()
    return st^


def _machine_name(mut c: TokenCursor, source: String, line: Int, mut g: ReleaseMachine) raises:
    """The top-level `name` (file header): once, before the first stage, in
    the step-name grammar."""
    if len(g.stages) > 0:
        raise Error(
            _at(source, line) + String("the machine's name comes after a stage; it is written before the first")
            + String(" stage")
        )
    if g.name_line > 0:
        raise Error(
            _at(source, line) + String("the machine's name is set twice (first on line ") + String(g.name_line)
            + String(")")
        )
    var name = _scalar(c, String("name"), source)
    if not is_step_name(name):
        raise Error(
            _at(source, line) + String("the machine's name '") + name
            + String("' is not [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
            + String(" bytes, not ending in '-' (it is written verbatim as a label value)")
        )
    g.name = name^
    g.name_line = line


def machine_schema_version(text: String, source: String) raises -> Int:
    """The checked major of a machine file, and nothing else (file
    header)."""
    var tokens = lex(text, source)
    return authored_schema_version(tokens, String(FORMAT_MACHINE), source)


def parse_machine_file(text: String, source: String) raises -> ReleaseMachine:
    """Parse and validate a machine file; `source` names it in every
    refusal. Raises on the first refusal."""
    var tokens = lex(text, source)
    var major = authored_schema_version(tokens, String(FORMAT_MACHINE), source)
    var c = TokenCursor(tokens^, source)
    var g = ReleaseMachine(major)
    while not c.at_end():
        var f = c.expect(TOKEN_WORD)
        if f.text == "schema_version":
            skip_schema_version(c)
            continue
        if f.text == "name":
            _machine_name(c, source, f.line, g)
            continue
        if f.text != "stage":
            raise Error(
                _at(source, f.line) + String("unknown top-level field '") + f.text
                + String("' (expected schema_version, name, stage)")
            )
        var line = _open_block(c)
        g.stages.append(_parse_stage(c, source, len(g.stages) + 1, line))
    validate_release_machine(g, source)
    validate_cell_steps(g, source)
    return g^
