# =============================================================================
# kci_release_channel/parse.mojo -- read a channels file.
# =============================================================================
#
# The channels file is textproto, every channel defined once:
#
#   channel {
#     name: "beta"
#     visibility: PRIVATE
#     repository {
#       artifact_type: OCI
#       location: "registry.example.invalid/beta"
#       push_identity: "publisher@example.invalid"
#       credential { kind: API_TOKEN  secret_name: "BETA_REGISTRY_TOKEN" }
#     }
#   }
#
# `channel` is the only top-level field; `name`, `visibility` and `repository`
# (repeated) the only channel fields; `artifact_type`, `location`,
# `push_identity` and `credential` (at most once) the only repository fields;
# `kind` and `secret_name` the only credential fields. A `:` before a `{` is optional,
# as in textproto. A scalar may be quoted or bare.
#
# Every refusal from this file starts `channels file: line N:` (lexer and
# token-cursor refusals included). The parser refuses: an unknown field at
# any level, a scalar field set twice, a `credential` block set twice, a
# `channel`, `repository` or `credential` block that is never closed, and a
# file declaring no channel.
# Inside a `credential` block no refusal quotes a token: a secret pasted where
# a field name, a colon or a value was expected would otherwise be echoed by
# the token cursor into the error text and from there into a CI log. Those
# refusals name the field and the line and say the value is not quoted.
# Everything else (names, visibility, artifact types, empty values, sharing)
# is `validate_channel_declarations`, which runs on the parsed list before it
# is returned, so a parsed list is always a valid one.
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

from .channel_credential import ChannelCredential
from .channel_declaration import (
    ChannelDeclaration,
    ChannelRepository,
    validate_channel_declarations,
)


comptime _SOURCE: String = "channels file"


def _at(line: Int) -> String:
    return String(_SOURCE) + String(": line ") + String(line) + String(": ")


def _open_block(mut c: TokenCursor) raises -> Int:
    """Consume an optional `:` then the `{` of a message field; return the
    line of the `{`."""
    if c.is_kind(TOKEN_COLON):
        _ = c.expect(TOKEN_COLON)
    return c.expect(TOKEN_LBRACE).line


def _refuse_unclosed(open_line: Int, what: String) raises:
    raise Error(
        _at(open_line) + what + String(" is not closed (expected '}')")
    )


def _scalar(mut c: TokenCursor, field: String) raises -> String:
    """Consume `: <value>` and return the value's text."""
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
    return v.text.copy()


def _refuse_twice(line: Int, field: String, where: String) raises:
    raise Error(
        _at(line)
        + String("field '")
        + field
        + String("' is set twice in ")
        + where
    )


def _channel_label(name: String, ordinal: Int) -> String:
    if name.byte_length() > 0:
        return String("channel '") + name + String("'")
    return String("channel #") + String(ordinal)


def _credential_scalar(
    mut c: TokenCursor, field: String, line: Int, label: String
) raises -> String:
    """`_scalar` for a credential field, with its refusal reworded so it never
    quotes the token it got: the cursor's own refusal echoes that token, and
    in a credential block that token may be a pasted secret."""
    var value = String("")
    var failed = False
    try:
        value = _scalar(c, field)
    except:
        failed = True
    if failed:
        raise Error(
            _at(line)
            + String("malformed ")
            + field
            + String(" in ")
            + label
            + String(" (expected `")
            + field
            + String(": <value>`; value not quoted)")
        )
    return value^


def _parse_credential(
    mut c: TokenCursor, where: String, open_line: Int
) raises -> ChannelCredential:
    var kind = String("")
    var secret_name = String("")
    var seen_kind = False
    var seen_secret = False
    var label = String("the credential of ") + where
    while True:
        if c.at_end():
            _refuse_unclosed(open_line, label)
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        if not c.is_kind(TOKEN_WORD):
            var bad_line = c.next(String("a field name")).line
            raise Error(
                _at(bad_line)
                + String("expected a field name in ")
                + label
                + String(" (expected kind, secret_name; token not quoted)")
            )
        var f = c.expect(TOKEN_WORD)
        if f.text == "kind":
            if seen_kind:
                _refuse_twice(f.line, f.text, label)
            kind = _credential_scalar(c, f.text, f.line, label)
            seen_kind = True
        elif f.text == "secret_name":
            if seen_secret:
                _refuse_twice(f.line, f.text, label)
            secret_name = _credential_scalar(c, f.text, f.line, label)
            seen_secret = True
        else:
            raise Error(
                _at(f.line)
                + String("unknown field in ")
                + label
                + String(" (expected kind, secret_name; field not quoted)")
            )
    return ChannelCredential(kind^, secret_name^)


def _parse_repository(
    mut c: TokenCursor, where: String, open_line: Int
) raises -> ChannelRepository:
    var artifact_type = String("")
    var location = String("")
    var push_identity = String("")
    var seen_type = False
    var seen_location = False
    var seen_identity = False
    var credential = Optional[ChannelCredential](None)
    var label = String("a repository of ") + where
    while True:
        if c.at_end():
            _refuse_unclosed(open_line, label)
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        var f = c.expect(TOKEN_WORD)
        if f.text == "artifact_type":
            if seen_type:
                _refuse_twice(f.line, f.text, label)
            artifact_type = _scalar(c, f.text)
            seen_type = True
        elif f.text == "location":
            if seen_location:
                _refuse_twice(f.line, f.text, label)
            location = _scalar(c, f.text)
            seen_location = True
        elif f.text == "push_identity":
            if seen_identity:
                _refuse_twice(f.line, f.text, label)
            push_identity = _scalar(c, f.text)
            seen_identity = True
        elif f.text == "credential":
            if credential:
                _refuse_twice(f.line, f.text, label)
            var cred_line = _open_block(c)
            credential = Optional(_parse_credential(c, label, cred_line))
        else:
            raise Error(
                _at(f.line)
                + String("unknown field '")
                + f.text
                + String("' in ")
                + label
                + String(" (expected artifact_type, location, push_identity,")
                + String(" credential)")
            )
    return ChannelRepository(
        artifact_type^, location^, push_identity^, credential^
    )


def _parse_channel(
    mut c: TokenCursor, ordinal: Int, open_line: Int
) raises -> ChannelDeclaration:
    var name = String("")
    var visibility = String("")
    var seen_name = False
    var seen_visibility = False
    var repos = List[ChannelRepository]()
    while True:
        if c.at_end():
            _refuse_unclosed(open_line, _channel_label(name, ordinal))
        if c.is_kind(TOKEN_RBRACE):
            _ = c.expect(TOKEN_RBRACE)
            break
        var f = c.expect(TOKEN_WORD)
        if f.text == "name":
            if seen_name:
                _refuse_twice(f.line, f.text, _channel_label(name, ordinal))
            name = _scalar(c, f.text)
            seen_name = True
        elif f.text == "visibility":
            if seen_visibility:
                _refuse_twice(f.line, f.text, _channel_label(name, ordinal))
            visibility = _scalar(c, f.text)
            seen_visibility = True
        elif f.text == "repository":
            var repo_line = _open_block(c)
            repos.append(
                _parse_repository(c, _channel_label(name, ordinal), repo_line)
            )
        else:
            raise Error(
                _at(f.line)
                + String("unknown field '")
                + f.text
                + String("' in ")
                + _channel_label(name, ordinal)
                + String(" (expected name, visibility, repository)")
            )
    return ChannelDeclaration(name^, visibility^, repos^)


def parse_channels_file(text: String) raises -> List[ChannelDeclaration]:
    """Parse and validate a channels file. Raises on the first refusal, by a
    message naming the offending field, channel, repository or location."""
    var c = TokenCursor(lex(text, String(_SOURCE)), String(_SOURCE))
    var out = List[ChannelDeclaration]()
    while not c.at_end():
        var f = c.expect(TOKEN_WORD)
        if f.text != "channel":
            raise Error(
                _at(f.line)
                + String("unknown top-level field '")
                + f.text
                + String("' (expected channel)")
            )
        var open_line = _open_block(c)
        out.append(_parse_channel(c, len(out) + 1, open_line))
    if len(out) == 0:
        raise Error(String(_SOURCE) + String(" declares no channel"))
    validate_channel_declarations(out)
    return out^
