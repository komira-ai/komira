# =============================================================================
# src/kci_release_channel/tests/test_channel_parse_refusals.mojo
#   Every refusal of `parse_channels_file`, one case per message.
# =============================================================================
#
# Each case builds a small synthetic channels file that is valid except for one
# thing, and asserts the message names that thing. A control case shows the
# unbroken fixture parses, so each refusal is caused by its one change.
# =============================================================================

from std.testing import TestSuite, assert_equal

from kci_release_channel import Channel, parse_channels_file

comptime _ID = "publisher@example.invalid"


def _parse(text: String) raises -> List[Channel]:
    """`parse_channels_file` over `text` with `schema_version: 1` prepended on
    its FIRST line, so no line number a refusal names moves."""
    return parse_channels_file(String("schema_version: 1 ") + text)


def _repo(artifact_type: String, location: String, identity: String) -> String:
    return (
        String("  repository {\n    artifact_type: ")
        + artifact_type
        + String("\n    location: \"")
        + location
        + String("\"\n    push_identity: \"")
        + identity
        + String("\"\n    credential { kind: API_TOKEN secret_name: \"TOKEN\" }\n  }\n")
    )


def _oci(location: String) -> String:
    return _repo(String("OCI"), location, String(_ID))


def _channel(name: String, visibility: String, body: String) -> String:
    var out = String("channel {\n")
    if name.byte_length() > 0:
        out += String("  name: \"") + name + String("\"\n")
    if visibility.byte_length() > 0:
        out += String("  visibility: ") + visibility + String("\n")
    out += body
    out += String("}\n")
    return out^


def _refusal(text: String) -> String:
    try:
        _ = _parse(text)
    except e:
        return String(e)
    return String("<no refusal>")


def _assert_refused(text: String, needle: String) raises:
    var msg = _refusal(text)
    if needle not in msg:
        raise Error(String("expected '") + needle + String("' in: ") + msg)


def test_control_the_fixture_parses() raises:
    var text = _channel(
        String("beta"), String("PRIVATE"), _oci(String("registry.example.invalid/beta"))
    ) + _channel(
        String("stable"), String("PUBLIC"), _oci(String("registry.example.invalid/stable"))
    )
    assert_equal(len(_parse(text)), 2)


def test_duplicate_channel_name() raises:
    var text = _channel(
        String("beta"), String("PRIVATE"), _oci(String("registry.example.invalid/a"))
    ) + _channel(
        String("beta"), String("PUBLIC"), _oci(String("registry.example.invalid/b"))
    )
    _assert_refused(text, String("channel 'beta' is declared twice"))


def test_two_channels_sharing_a_location() raises:
    var text = _channel(
        String("beta"), String("PRIVATE"), _oci(String("registry.example.invalid/shared"))
    ) + _channel(
        String("stable"), String("PUBLIC"), _oci(String("registry.example.invalid/shared"))
    )
    _assert_refused(
        text,
        String(
            "location 'registry.example.invalid/shared' is declared by both"
            " channel 'beta' and channel 'stable'"
        ),
    )


def test_two_repositories_of_one_artifact_type() raises:
    var text = _channel(
        String("beta"),
        String("PRIVATE"),
        _oci(String("registry.example.invalid/a"))
        + _oci(String("registry.example.invalid/b")),
    )
    _assert_refused(
        text, String("channel 'beta' declares more than one OCI repository")
    )


def test_empty_push_identity() raises:
    var text = _channel(
        String("beta"),
        String("PRIVATE"),
        _repo(String("OCI"), String("registry.example.invalid/beta"), String("")),
    )
    _assert_refused(
        text,
        String(
            "channel 'beta' declares an empty push_identity for its OCI repository"
        ),
    )


def test_empty_location() raises:
    var text = _channel(
        String("beta"), String("PRIVATE"), _repo(String("NPM"), String(""), String(_ID))
    )
    _assert_refused(
        text, String("channel 'beta' declares an empty location for its NPM repository")
    )


def test_missing_name() raises:
    var text = _channel(
        String(""), String("PRIVATE"), _oci(String("registry.example.invalid/beta"))
    )
    _assert_refused(text, String("channel #1 has no name"))


def test_invalid_name_charset() raises:
    var text = _channel(
        String("Beta_1"), String("PRIVATE"), _oci(String("registry.example.invalid/beta"))
    )
    _assert_refused(text, String("channel name 'Beta_1' is invalid"))


def test_missing_visibility() raises:
    var text = _channel(
        String("beta"), String(""), _oci(String("registry.example.invalid/beta"))
    )
    _assert_refused(text, String("channel 'beta' declares no visibility"))


def test_unknown_visibility() raises:
    var text = _channel(
        String("beta"), String("INTERNAL"), _oci(String("registry.example.invalid/beta"))
    )
    _assert_refused(
        text, String("channel 'beta' declares unknown visibility 'INTERNAL'")
    )


def test_a_channel_with_no_repository() raises:
    var text = _channel(String("beta"), String("PRIVATE"), String(""))
    _assert_refused(text, String("channel 'beta' declares no repository"))


def test_unknown_artifact_type() raises:
    var text = _channel(
        String("beta"),
        String("PRIVATE"),
        _repo(String("TARBALL"), String("registry.example.invalid/beta"), String(_ID)),
    )
    _assert_refused(
        text,
        String("channel 'beta' declares a repository of unknown artifact type 'TARBALL'"),
    )


def test_unknown_field_in_a_channel() raises:
    var text = _channel(
        String("beta"),
        String("PRIVATE"),
        String("  color: \"blue\"\n")
        + _oci(String("registry.example.invalid/beta")),
    )
    _assert_refused(
        text, String("line 4: unknown field 'color' in channel 'beta'")
    )


def test_unknown_field_in_a_repository() raises:
    var text = _channel(
        String("beta"),
        String("PRIVATE"),
        String("  repository {\n    artifact_type: OCI\n    reader: \"x\"\n  }\n"),
    )
    _assert_refused(
        text,
        String("unknown field 'reader' in a repository of channel 'beta'"),
    )


def test_unknown_top_level_field() raises:
    _assert_refused(
        String("environment { name: \"beta\" }\n"),
        String("line 1: unknown top-level field 'environment' (expected schema_version, channel)"),
    )


def test_a_field_set_twice() raises:
    var text = _channel(
        String("beta"),
        String("PRIVATE"),
        String("  visibility: PUBLIC\n") + _oci(String("registry.example.invalid/beta")),
    )
    _assert_refused(
        text, String("field 'visibility' is set twice in channel 'beta'")
    )


def test_a_file_with_no_channel() raises:
    _assert_refused(
        String("# nothing declared\n"), String("channels file declares no channel")
    )


def test_a_lexer_refusal_surfaces() raises:
    _assert_refused(
        String("channel {\n  name: \"beta\n}\n"),
        String("channels file: line 2: unterminated string"),
    )


def test_an_unclosed_channel() raises:
    _assert_refused(
        String("# one channel\nchannel {\n  name: \"beta\"\n"),
        String("channels file: line 2: channel 'beta' is not closed (expected '}')"),
    )


def test_an_unclosed_repository() raises:
    _assert_refused(
        String(
            "channel {\n  name: \"beta\"\n  repository {\n    artifact_type: OCI\n"
        ),
        String(
            "channels file: line 3: a repository of channel 'beta' is not closed"
            " (expected '}')"
        ),
    )


def test_a_structural_refusal_names_the_channels_file() raises:
    _assert_refused(
        String("channel {\n  name \"beta\"\n}\n"),
        String("channels file: line 2: expected ':' but got string \"beta\""),
    )


def test_each_scalar_field_set_twice() raises:
    _assert_refused(
        _channel(
            String("beta"),
            String("PRIVATE"),
            String("  name: \"stable\"\n") + _oci(String("registry.example.invalid/beta")),
        ),
        String("line 4: field 'name' is set twice in channel 'beta'"),
    )
    var fields = List[String]()
    fields.append(String("artifact_type: NPM"))
    fields.append(String("location: \"registry.example.invalid/other\""))
    fields.append(String("push_identity: \"other@example.invalid\""))
    var names = List[String]()
    names.append(String("artifact_type"))
    names.append(String("location"))
    names.append(String("push_identity"))
    for i in range(len(fields)):
        var repo = (
            String("  repository {\n    artifact_type: OCI\n    location: ")
            + String("\"registry.example.invalid/beta\"\n    push_identity: ")
            + String("\"publisher@example.invalid\"\n    ")
            + fields[i]
            + String("\n  }\n")
        )
        _assert_refused(
            _channel(String("beta"), String("PRIVATE"), repo),
            String("line 8: field '")
            + names[i]
            + String("' is set twice in a repository of channel 'beta'"),
        )


def test_two_repositories_of_one_channel_sharing_a_location() raises:
    var text = _channel(
        String("beta"),
        String("PRIVATE"),
        _oci(String("registry.example.invalid/shared"))
        + _repo(String("NPM"), String("registry.example.invalid/shared"), String(_ID)),
    )
    _assert_refused(
        text,
        String(
            "channel 'beta' declares location 'registry.example.invalid/shared'"
            " for both its OCI and its NPM repository"
        ),
    )


def test_a_whitespace_only_location_or_identity_is_empty() raises:
    _assert_refused(
        _channel(
            String("beta"), String("PRIVATE"), _repo(String("OCI"), String(" \t"), String(_ID))
        ),
        String("channel 'beta' declares an empty location for its OCI repository"),
    )
    _assert_refused(
        _channel(
            String("beta"),
            String("PRIVATE"),
            _repo(String("OCI"), String("registry.example.invalid/beta"), String("  ")),
        ),
        String("channel 'beta' declares an empty push_identity for its OCI repository"),
    )



# ── schema_version: read before any other field. ─────────────────────────────


def _raw_refusal(text: String) -> String:
    try:
        _ = parse_channels_file(text)
    except e:
        return String(e)
    return String("<no refusal>")


def _one_channel() -> String:
    return _channel(String("beta"), String("PRIVATE"), _oci(String("registry.example.invalid/beta")))


def test_schema_version_missing() raises:
    assert_equal(
        _raw_refusal(_one_channel()),
        String("channels file: no schema_version; add `schema_version: 1` (this kci reads kci.channels up to major 1)"),
    )


def test_schema_version_of_a_newer_kci_wins_over_its_new_fields() raises:
    # A major-2 file may use a field this kci does not know; the refusal
    # names the version, not the field.
    assert_equal(
        _raw_refusal(String("schema_version: 2\nchannel { name: \"beta\" retention_days: 30 }\n")),
        String("channels file: schema_version 2 needs a newer kci (this kci reads kci.channels up to major 1)"),
    )


def test_schema_version_set_twice() raises:
    assert_equal(
        _raw_refusal(String("schema_version: 1\n") + _one_channel() + String("schema_version: 1\n")),
        String("channels file: line 12: field 'schema_version' is set twice (first on line 1)"),
    )


def test_schema_version_not_an_integer() raises:
    assert_equal(
        _raw_refusal(String("schema_version: \"1\"\n") + _one_channel()),
        String("channels file: line 1: schema_version is not a decimal integer (expected `schema_version: <major>`)"),
    )


def test_schema_version_inside_a_channel_is_unknown() raises:
    _assert_refused(
        _channel(String("beta"), String("PRIVATE"), String("  schema_version: 1\n") + _oci(String("registry.example.invalid/beta"))),
        String("unknown field 'schema_version' in channel 'beta'"),
    )


def test_schema_version_anywhere_at_the_top_level() raises:
    var channels = parse_channels_file(_one_channel() + String("schema_version: 1\n"))
    assert_equal(len(channels), 1)

# ── A scalar field's value: a string, a word or a number, nothing else. ─────


def test_a_structural_token_is_not_a_value() raises:
    # the line named is the offending token's, not the field's
    assert_equal(
        _refusal(String("channel {\n  name: }\n}\n")),
        String("channels file: line 2: expected a value for 'name' but got '}'"),
    )
    assert_equal(
        _refusal(String("channel {\n  name: \"beta\"\n  visibility:\n\n  {\n}\n")),
        String("channels file: line 5: expected a value for 'visibility' but got '{'"),
    )
    assert_equal(
        _refusal(
            String("channel {\n  name: \"beta\"\n  repository {\n    location: :\n  }\n}\n")
        ),
        String("channels file: line 4: expected a value for 'location' but got ':'"),
    )


def test_a_word_and_a_number_are_values() raises:
    # a number passes the value check and is refused for its meaning
    var number = _channel(
        String("beta"), String("7"), _oci(String("registry.example.invalid/beta"))
    )
    _assert_refused(number, String("channel 'beta' declares unknown visibility '7'"))
    # a bare word is a value too: an unquoted name parses
    var word = String("channel {\n  name: beta\n  visibility: PRIVATE\n") + _oci(
        String("registry.example.invalid/beta")
    ) + String("}\n")
    var channels = _parse(word)
    assert_equal(channels[0].name, String("beta"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
