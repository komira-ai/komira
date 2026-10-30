# =============================================================================
# kci_artifact/parse.mojo -- read an artifacts file.
# =============================================================================
#
# An artifacts file is textproto for `kci.release.v1.Artifacts`
# (//src/kci_artifact_proto), under its format's major
# (kci_api's format table, `kci.artifacts`):
#
#   schema_version: 1
#   build_systems {
#     name: "buck2"
#     executable: "buck2"
#     args: "build"
#   }
#   artifacts {
#     name: "komira_json"
#     build_system: "buck2"
#     args: "//src/komira_json:komira_json_conda[release]"
#     args: "--out"
#     args: "{out_dir}"
#     targets: "//src/komira_json:komira_json_conda"
#   }
#   checks {
#     name: "lints"
#     build_system: "buck2"
#     targets: "//:docs"
#   }
#
# A build system may also hold the per-change commands, each a block:
# `affected { executable: "..." args: "..." }`, `build_targets { ... }` and
# `derive_checks { ... }` (the .proto's header).
#
# which kci renders as `buck2 build
# //src/komira_json:komira_json_conda[release] --out <dir>`. `build` belongs in
# the build system's args: they come first. The farm is not named here: it is
# a buckconfig buck2 reads at daemon start (`/etc/buckconfig.d/` or
# `~/.buckconfig.d/`); `--config-file` and `-c` in these args never reach
# `[buck2_re_client]` (see example.textproto).
#
# Every value but `schema_version` is a quoted string. A `:` before a `{` is
# optional, as in textproto; `#` starts a comment.
#
# `schema_version` is read FIRST, before any other field (kci_api's
# `authored_schema_version`): missing, set twice, not an integer, or a major
# this kci does not read is refused, so a file written for a newer kci says
# "needs a newer kci" rather than naming a field the newer major added.
#
# Refused here, each starting `<source>: line N:` (lexer refusals included):
# an unknown field at any level, a non-repeated field set twice, an unquoted
# value, a block never closed, any top-level field but `schema_version`,
# `build_systems`, `artifacts` and `checks`. Everything else is `validate_artifacts`, run on the
# parsed value before it is returned, so a parsed value is always a valid one.
#
# Owned values only; no pointer.
# =============================================================================

from std.pathlib import Path

from komira_textproto import (
    TOKEN_COLON,
    TOKEN_LBRACE,
    TOKEN_RBRACE,
    TOKEN_STRING,
    TOKEN_WORD,
    Token,
    TokenCursor,
    lex,
)

from kci_api import FORMAT_ARTIFACTS, authored_schema_version, skip_schema_version

from kci_artifact_proto.artifact import (
    Artifact,
    Artifacts,
    BuildSystem,
    Check,
    Command,
)

from .validate import validate_artifacts


struct _Ctx(Movable):
    """The token cursor and the source name every refusal starts with."""

    var c: TokenCursor
    var source: String

    def __init__(out self, var c: TokenCursor, var source: String):
        self.c = c^
        self.source = source^

    def at(self, line: Int) -> String:
        return self.source + String(": line ") + String(line) + String(": ")


def _open_block(mut x: _Ctx) raises -> Int:
    """Consume an optional `:` then a `{`; return the `{`'s line."""
    if x.c.is_kind(TOKEN_COLON):
        _ = x.c.expect(TOKEN_COLON)
    return x.c.expect(TOKEN_LBRACE).line


def _string(mut x: _Ctx, field: String) raises -> String:
    """Consume `: "<value>"` and return the value."""
    _ = x.c.expect(TOKEN_COLON)
    var v = x.c.next(String("a value for '") + field + String("'"))
    if v.kind != TOKEN_STRING:
        raise Error(
            x.at(v.line)
            + String("expected a quoted string for '")
            + field
            + String("' but got ")
            + v.describe()
        )
    return v.text.copy()


def _twice(x: _Ctx, line: Int, field: String, where: String) raises:
    raise Error(
        x.at(line) + String("field '") + field + String("' is set twice in ") + where
    )


def _unknown(x: _Ctx, line: Int, field: String, where: String, expected: String) raises:
    raise Error(
        x.at(line)
        + String("unknown field '")
        + field
        + String("' in ")
        + where
        + String(" (expected ")
        + expected
        + String(")")
    )


def _field(mut x: _Ctx, open_line: Int, where: String) raises -> Optional[Token]:
    """The next field name of the block opened at `open_line`, or None at its
    closing `}` (consumed)."""
    if x.c.at_end():
        raise Error(x.at(open_line) + where + String(" is not closed (expected '}')"))
    if x.c.is_kind(TOKEN_RBRACE):
        _ = x.c.expect(TOKEN_RBRACE)
        return None
    return x.c.expect(TOKEN_WORD)


def _label(kind: String, name: String, ordinal: Int) -> String:
    if name.byte_length() > 0:
        return kind + String(" '") + name + String("'")
    return kind + String(" #") + String(ordinal)


def _parse_command(mut x: _Ctx, open_line: Int, where: String) raises -> Command:
    """The body of an `affected` or `build_targets` block."""
    var executable = String("")
    var seen_executable = False
    var args = List[String]()
    while True:
        var f = _field(x, open_line, where)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "executable":
            if seen_executable:
                _twice(x, t.line, t.text, where)
            executable = _string(x, t.text)
            seen_executable = True
        elif t.text == "args":
            args.append(_string(x, t.text))
        else:
            _unknown(x, t.line, t.text, where, String("executable, args"))
    return Command(executable^, args^)


def _parse_build_system(mut x: _Ctx, ordinal: Int, open_line: Int) raises -> BuildSystem:
    var name = String("")
    var seen_name = False
    var executable = String("")
    var seen_executable = False
    var args = List[String]()
    var affected = Optional[Command](None)
    var build_targets = Optional[Command](None)
    var derive_checks = Optional[Command](None)
    while True:
        var me = _label(String("build system"), name, ordinal)
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "name":
            if seen_name:
                _twice(x, t.line, t.text, me)
            name = _string(x, t.text)
            seen_name = True
        elif t.text == "executable":
            if seen_executable:
                _twice(x, t.line, t.text, me)
            executable = _string(x, t.text)
            seen_executable = True
        elif t.text == "args":
            args.append(_string(x, t.text))
        elif t.text == "affected":
            if affected:
                _twice(x, t.line, t.text, me)
            var line = _open_block(x)
            affected = _parse_command(x, line, String("the affected command of ") + me)
        elif t.text == "build_targets":
            if build_targets:
                _twice(x, t.line, t.text, me)
            var line = _open_block(x)
            build_targets = _parse_command(x, line, String("the build_targets command of ") + me)
        elif t.text == "derive_checks":
            if derive_checks:
                _twice(x, t.line, t.text, me)
            var line = _open_block(x)
            derive_checks = _parse_command(x, line, String("the derive_checks command of ") + me)
        else:
            _unknown(x, t.line, t.text, me, String("name, executable, args, affected, build_targets, derive_checks"))
    return BuildSystem(name^, executable^, args^, affected^, build_targets^, derive_checks^)


def _parse_artifact(mut x: _Ctx, ordinal: Int, open_line: Int) raises -> Artifact:
    var name = String("")
    var seen_name = False
    var build_system = String("")
    var seen_build_system = False
    var args = List[String]()
    var targets = List[String]()
    while True:
        var me = _label(String("artifact"), name, ordinal)
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "name":
            if seen_name:
                _twice(x, t.line, t.text, me)
            name = _string(x, t.text)
            seen_name = True
        elif t.text == "build_system":
            if seen_build_system:
                _twice(x, t.line, t.text, me)
            build_system = _string(x, t.text)
            seen_build_system = True
        elif t.text == "args":
            args.append(_string(x, t.text))
        elif t.text == "targets":
            targets.append(_string(x, t.text))
        else:
            _unknown(x, t.line, t.text, me, String("name, build_system, args, targets"))
    return Artifact(name^, build_system^, args^, targets^)


def _parse_check(mut x: _Ctx, ordinal: Int, open_line: Int) raises -> Check:
    var name = String("")
    var seen_name = False
    var build_system = String("")
    var seen_build_system = False
    var targets = List[String]()
    while True:
        var me = _label(String("check"), name, ordinal)
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "name":
            if seen_name:
                _twice(x, t.line, t.text, me)
            name = _string(x, t.text)
            seen_name = True
        elif t.text == "build_system":
            if seen_build_system:
                _twice(x, t.line, t.text, me)
            build_system = _string(x, t.text)
            seen_build_system = True
        elif t.text == "targets":
            targets.append(_string(x, t.text))
        else:
            _unknown(x, t.line, t.text, me, String("name, build_system, targets"))
    return Check(name^, build_system^, targets^)


def parse_artifacts(
    text: String, source: String
) raises -> Artifacts:
    """Parse and validate an artifacts file. `source` (its path) starts
    every refusal. Raises on the first refusal."""
    var tokens = lex(text, source)
    var major = authored_schema_version(tokens, String(FORMAT_ARTIFACTS), source)
    var x = _Ctx(TokenCursor(tokens^, source.copy()), source.copy())
    var systems = List[BuildSystem]()
    var artifacts = List[Artifact]()
    var checks = List[Check]()
    while not x.c.at_end():
        var t = x.c.expect(TOKEN_WORD)
        if t.text == "schema_version":
            skip_schema_version(x.c)
        elif t.text == "build_systems":
            var line = _open_block(x)
            systems.append(_parse_build_system(x, len(systems) + 1, line))
        elif t.text == "artifacts":
            var line = _open_block(x)
            artifacts.append(_parse_artifact(x, len(artifacts) + 1, line))
        elif t.text == "checks":
            var line = _open_block(x)
            checks.append(_parse_check(x, len(checks) + 1, line))
        else:
            raise Error(
                x.at(t.line)
                + String("unknown top-level field '")
                + t.text
                + String("' (expected schema_version, build_systems, artifacts, checks)")
            )
    var arts = Artifacts(systems^, artifacts^, Int32(major), checks^)
    validate_artifacts(arts, source)
    return arts^


def read_artifacts(path: String) raises -> Artifacts:
    """Read, parse and validate the artifacts file at `path`."""
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(
            String("artifacts file '")
            + path
            + String("' cannot be read: ")
            + String(e)
        )
    return parse_artifacts(text, path)
