# =============================================================================
# kci_artifact_declaration/parse.mojo -- read a declarations file.
# =============================================================================
#
# A declarations file is textproto for `kci.release.v1.ArtifactDeclarations`
# (//src/kci_artifact_declaration_proto), one `artifact` block per artifact:
#
#   artifact {
#     name: "komira_json"
#     allowed_channels: "public"
#     conda_package {
#       build { buck2 { label: "//src/komira_json:komira_json_conda" } }
#       subdirs: "linux-64"
#       depends_on: "komira_encoding"
#       member_of: "komira"
#     }
#   }
#
# The kind is one block of `conda_package`, `conda_metapackage`,
# `python_wheel`, `oci_image`; any other block there is an unknown field, so
# a kind this schema does not have is refused by name. Every value is a
# quoted string (the schema has no enum and no number). A `:` before a `{` is
# optional, as in textproto; `#` starts a comment.
#
# Refused here, each starting `<source>: line N:` (lexer refusals included):
# an unknown field at any level, a non-repeated field set twice, a second
# kind in one artifact, a second build system in one build rule, an unquoted
# value, a block never closed, any top-level field but `artifact`.
# Everything else (names, labels, references, cycles, channels) is
# `validate_artifact_declarations`, run on the parsed value before it is
# returned, so a parsed value is always a valid one.
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

from kci_artifact_declaration_proto.artifact_declaration import (
    ArtifactDeclaration,
    ArtifactDeclarations,
    Buck2Target,
    BuildRule,
    CondaMetapackage,
    CondaPackage,
    OciImage,
    PythonWheel,
)

from .validate import (
    KIND_CONDA_METAPACKAGE,
    KIND_CONDA_PACKAGE,
    KIND_OCI_IMAGE,
    KIND_PYTHON_WHEEL,
    known_kinds,
    validate_artifact_declarations,
)


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


def _parse_buck2(mut x: _Ctx, where: String, open_line: Int) raises -> Buck2Target:
    var label = String("")
    var seen = False
    var me = String("the buck2 target of ") + where
    while True:
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "label":
            if seen:
                _twice(x, t.line, t.text, me)
            label = _string(x, t.text)
            seen = True
        else:
            _unknown(x, t.line, t.text, me, String("label"))
    return Buck2Target(label^)


def _parse_build_rule(
    mut x: _Ctx, field: String, where: String, open_line: Int
) raises -> BuildRule:
    var arm = 0
    var buck2 = Optional[Buck2Target](None)
    var me = String("the ") + field + String(" of ") + where
    while True:
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "buck2":
            if arm != 0:
                raise Error(
                    x.at(t.line)
                    + me
                    + String(" names a second build system 'buck2'")
                )
            var line = _open_block(x)
            buck2 = Optional(_parse_buck2(x, me, line))
            arm = 1
        else:
            _unknown(x, t.line, t.text, me, String("buck2"))
    return BuildRule(arm, buck2^)


def _parse_conda_package(mut x: _Ctx, where: String, open_line: Int) raises -> CondaPackage:
    var build = Optional[BuildRule](None)
    var subdirs = List[String]()
    var depends_on = List[String]()
    var member_of = String("")
    var seen_member = False
    var me = String("the conda_package of ") + where
    while True:
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "build":
            if build:
                _twice(x, t.line, t.text, me)
            var line = _open_block(x)
            build = Optional(_parse_build_rule(x, t.text, where, line))
        elif t.text == "subdirs":
            subdirs.append(_string(x, t.text))
        elif t.text == "depends_on":
            depends_on.append(_string(x, t.text))
        elif t.text == "member_of":
            if seen_member:
                _twice(x, t.line, t.text, me)
            member_of = _string(x, t.text)
            seen_member = True
        else:
            _unknown(x, t.line, t.text, me, String("build, subdirs, depends_on, member_of"))
    return CondaPackage(build^, subdirs^, depends_on^, member_of^)


def _parse_conda_metapackage(
    mut x: _Ctx, where: String, open_line: Int
) raises -> CondaMetapackage:
    var packer = Optional[BuildRule](None)
    var subdirs = List[String]()
    var me = String("the conda_metapackage of ") + where
    while True:
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "packer":
            if packer:
                _twice(x, t.line, t.text, me)
            var line = _open_block(x)
            packer = Optional(_parse_build_rule(x, t.text, where, line))
        elif t.text == "subdirs":
            subdirs.append(_string(x, t.text))
        else:
            _unknown(x, t.line, t.text, me, String("packer, subdirs"))
    return CondaMetapackage(packer^, subdirs^)


def _parse_python_wheel(mut x: _Ctx, where: String, open_line: Int) raises -> PythonWheel:
    var build = Optional[BuildRule](None)
    var depends_on = List[String]()
    var me = String("the python_wheel of ") + where
    while True:
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "build":
            if build:
                _twice(x, t.line, t.text, me)
            var line = _open_block(x)
            build = Optional(_parse_build_rule(x, t.text, where, line))
        elif t.text == "depends_on":
            depends_on.append(_string(x, t.text))
        else:
            _unknown(x, t.line, t.text, me, String("build, depends_on"))
    return PythonWheel(build^, depends_on^)


def _parse_oci_image(mut x: _Ctx, where: String, open_line: Int) raises -> OciImage:
    var build = Optional[BuildRule](None)
    var me = String("the oci_image of ") + where
    while True:
        var f = _field(x, open_line, me)
        if not f:
            break
        var t = f.value().copy()
        if t.text == "build":
            if build:
                _twice(x, t.line, t.text, me)
            var line = _open_block(x)
            build = Optional(_parse_build_rule(x, t.text, where, line))
        else:
            _unknown(x, t.line, t.text, me, String("build"))
    return OciImage(build^)


def _label(name: String, ordinal: Int) -> String:
    if name.byte_length() > 0:
        return String("artifact '") + name + String("'")
    return String("artifact #") + String(ordinal)


def _parse_artifact(mut x: _Ctx, ordinal: Int, open_line: Int) raises -> ArtifactDeclaration:
    var name = String("")
    var seen_name = False
    var channels = List[String]()
    var arm = 0
    var kind_text = String("")
    var conda_package = Optional[CondaPackage](None)
    var conda_metapackage = Optional[CondaMetapackage](None)
    var python_wheel = Optional[PythonWheel](None)
    var oci_image = Optional[OciImage](None)
    while True:
        var f = _field(x, open_line, _label(name, ordinal))
        if not f:
            break
        var t = f.value().copy()
        var me = _label(name, ordinal)
        if t.text == "name":
            if seen_name:
                _twice(x, t.line, t.text, me)
            name = _string(x, t.text)
            seen_name = True
            continue
        if t.text == "allowed_channels":
            channels.append(_string(x, t.text))
            continue
        var kind = 0
        if t.text == "conda_package":
            kind = KIND_CONDA_PACKAGE
        elif t.text == "conda_metapackage":
            kind = KIND_CONDA_METAPACKAGE
        elif t.text == "python_wheel":
            kind = KIND_PYTHON_WHEEL
        elif t.text == "oci_image":
            kind = KIND_OCI_IMAGE
        else:
            _unknown(
                x,
                t.line,
                t.text,
                me,
                String("name, allowed_channels, ") + known_kinds(),
            )
        if arm != 0:
            raise Error(
                x.at(t.line)
                + me
                + String(" sets a second kind '")
                + t.text
                + String("' (it is already '")
                + kind_text
                + String("'); an artifact is exactly one kind")
            )
        var line = _open_block(x)
        if kind == KIND_CONDA_PACKAGE:
            conda_package = Optional(_parse_conda_package(x, me, line))
        elif kind == KIND_CONDA_METAPACKAGE:
            conda_metapackage = Optional(_parse_conda_metapackage(x, me, line))
        elif kind == KIND_PYTHON_WHEEL:
            python_wheel = Optional(_parse_python_wheel(x, me, line))
        else:
            oci_image = Optional(_parse_oci_image(x, me, line))
        arm = kind
        kind_text = t.text.copy()
    return ArtifactDeclaration(
        name^,
        channels^,
        arm,
        conda_package^,
        conda_metapackage^,
        python_wheel^,
        oci_image^,
    )


def parse_artifact_declarations(
    text: String, source: String
) raises -> ArtifactDeclarations:
    """Parse and validate a declarations file. `source` (its path) starts
    every refusal. Raises on the first refusal."""
    var x = _Ctx(TokenCursor(lex(text, source), source.copy()), source.copy())
    var out = List[ArtifactDeclaration]()
    while not x.c.at_end():
        var t = x.c.expect(TOKEN_WORD)
        if t.text != "artifact":
            raise Error(
                x.at(t.line)
                + String("unknown top-level field '")
                + t.text
                + String("' (expected artifact)")
            )
        var line = _open_block(x)
        out.append(_parse_artifact(x, len(out) + 1, line))
    var decls = ArtifactDeclarations(out^)
    validate_artifact_declarations(decls, source)
    return decls^


def read_artifact_declarations(path: String) raises -> ArtifactDeclarations:
    """Read, parse and validate the declarations file at `path`."""
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(
            String("declarations file '")
            + path
            + String("' cannot be read: ")
            + String(e)
        )
    return parse_artifact_declarations(text, path)
