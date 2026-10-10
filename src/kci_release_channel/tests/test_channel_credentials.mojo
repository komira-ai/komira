# =============================================================================
# src/kci_release_channel/tests/test_channel_credentials.mojo
#   The per-repository `credential`: what parses, and every refusal by name.
# =============================================================================
#
# Each case is one channel whose single repository is valid except for its
# credential block, so each refusal is caused by that block alone. The
# controls show both kinds parse.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_channel import (
    ARTIFACT_TYPE_CONDA,
    ARTIFACT_TYPE_NPM,
    ARTIFACT_TYPE_OCI,
    ARTIFACT_TYPE_PYTHON,
    CREDENTIAL_KIND_API_TOKEN,
    CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING,
    ChannelCredential,
    Channel,
    ChannelRepository,
    find_channel,
    is_known_credential_kind,
    is_valid_secret_name,
    oidc_exchange_implemented,
    parse_channels_file,
    break_glass_push_identity_environment,
    push_identity_environment,
    validate_channels,
)


def _parse(text: String) raises -> List[Channel]:
    """`parse_channels_file` over `text` with `schema_version: 1` prepended on
    its FIRST line, so no line number a refusal names moves."""
    return parse_channels_file(String("schema_version: 1 ") + text)


def _file(artifact_type: String, credential_lines: String) -> String:
    """One channel `beta`, one repository whose body ends with
    `credential_lines` (already indented, newline-terminated)."""
    return (
        String("channel {\n  name: \"beta\"\n  visibility: PRIVATE\n")
        + String("  repository {\n    artifact_type: ")
        + artifact_type
        + String("\n    location: \"registry.example.invalid/beta\"\n")
        + String("    push_identity: \"publisher@example.invalid\"\n")
        + credential_lines
        + String("  }\n}\n")
    )


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


def _assert_not_quoted(text: String, secret: String) raises:
    var msg = _refusal(text)
    if secret in msg:
        raise Error(String("refusal quotes the secret_name: ") + msg)


# ── Controls. ────────────────────────────────────────────────────────────────


def test_control_api_token_parses() raises:
    var channels = _parse(
        _file(
            String("OCI"),
            String("    credential { kind: API_TOKEN secret_name: \"OCI_TOKEN\" }\n"),
        )
    )
    var c = find_channel(channels, String("beta")).repository_for(
        String(ARTIFACT_TYPE_OCI)
    ).declared_credential()
    assert_true(c.is_api_token())
    assert_false(c.is_oidc_trusted_publishing())
    assert_equal(c.secret_name, String("OCI_TOKEN"))


def test_control_oidc_parses_on_conda_and_python() raises:
    var block = String("    credential: {\n      kind: OIDC_TRUSTED_PUBLISHING\n    }\n")
    var types = List[String]()
    types.append(String("CONDA"))
    types.append(String("PYTHON"))
    for i in range(len(types)):
        var channels = _parse(_file(types[i], block))
        var c = channels[0].repositories[0].declared_credential()
        assert_true(c.is_oidc_trusted_publishing())
        assert_equal(c.secret_name, String(""))


# ── Parse refusals (`channels file: line N:`). ───────────────────────────────


def test_credential_set_twice() raises:
    _assert_refused(
        _file(
            String("OCI"),
            String("    credential { kind: API_TOKEN secret_name: \"A\" }\n")
            + String("    credential { kind: API_TOKEN secret_name: \"B\" }\n"),
        ),
        String(
            "channels file: line 9: field 'credential' is set twice in a"
            " repository of channel 'beta'"
        ),
    )


def test_unclosed_credential() raises:
    _assert_refused(
        String("channel {\n  name: \"beta\"\n  repository {\n")
        + String("    credential {\n      kind: API_TOKEN\n"),
        String(
            "channels file: line 4: the credential of a repository of channel"
            " 'beta' is not closed (expected '}')"
        ),
    )


def test_unknown_credential_field() raises:
    _assert_refused(
        _file(
            String("OCI"),
            String("    credential { kind: API_TOKEN token: \"x\" }\n"),
        ),
        String(
            "channels file: line 8: unknown field in the credential of a"
            " repository of channel 'beta' (expected kind, secret_name; field"
            " not quoted)"
        ),
    )


def test_each_credential_field_set_twice() raises:
    _assert_refused(
        _file(
            String("OCI"),
            String("    credential { kind: API_TOKEN kind: API_TOKEN }\n"),
        ),
        String(
            "line 8: field 'kind' is set twice in the credential of a repository"
            " of channel 'beta'"
        ),
    )
    _assert_refused(
        _file(
            String("OCI"),
            String("    credential {\n      kind: API_TOKEN\n")
            + String("      secret_name: \"A\"\n      secret_name: \"B\"\n    }\n"),
        ),
        String(
            "line 11: field 'secret_name' is set twice in the credential of a"
            " repository of channel 'beta'"
        ),
    )


# ── Validation refusals (naming channel + repository). ───────────────────────


def test_no_credential_is_refused_not_defaulted() raises:
    _assert_refused(
        _file(String("OCI"), String("")),
        String(
            "channel 'beta' declares no credential (a credential is never"
            " defaulted) for its OCI repository"
        ),
    )


def test_missing_kind() raises:
    _assert_refused(
        _file(String("OCI"), String("    credential { secret_name: \"A\" }\n")),
        String(
            "channel 'beta' declares a credential with no kind (expected"
            " API_TOKEN, OIDC_TRUSTED_PUBLISHING) for its OCI repository"
        ),
    )


def test_unknown_kind() raises:
    _assert_refused(
        _file(
            String("OCI"),
            String("    credential { kind: PASSWORD secret_name: \"A\" }\n"),
        ),
        String(
            "channel 'beta' declares an unknown credential kind (not quoted: it"
            " may be a pasted secret; expected API_TOKEN,"
            " OIDC_TRUSTED_PUBLISHING) for its OCI repository"
        ),
    )


def test_kind_is_case_sensitive() raises:
    _assert_refused(
        _file(
            String("OCI"),
            String("    credential { kind: api_token secret_name: \"A\" }\n"),
        ),
        String("declares an unknown credential kind"),
    )


def test_api_token_without_secret_name() raises:
    _assert_refused(
        _file(String("NPM"), String("    credential { kind: API_TOKEN }\n")),
        String(
            "channel 'beta' declares an API_TOKEN credential with no"
            " secret_name for its NPM repository"
        ),
    )


def test_oidc_with_a_secret_name() raises:
    _assert_refused(
        _file(
            String("PYTHON"),
            String(
                "    credential { kind: OIDC_TRUSTED_PUBLISHING secret_name:"
                " \"PYPI_TOKEN\" }\n"
            ),
        ),
        String(
            "channel 'beta' declares an OIDC_TRUSTED_PUBLISHING credential with"
            " a secret_name (trusted publishing stores no secret) for its"
            " PYTHON repository"
        ),
    )


def test_oidc_on_a_type_with_no_exchange() raises:
    var types = List[String]()
    types.append(String("OCI"))
    types.append(String("NPM"))
    for i in range(len(types)):
        var t = types[i].copy()
        _assert_refused(
            _file(t, String("    credential { kind: OIDC_TRUSTED_PUBLISHING }\n")),
            String("channel 'beta' declares an OIDC_TRUSTED_PUBLISHING")
            + String(" credential, which has no implemented exchange for ")
            + t
            + String(" (implemented: CONDA, PYTHON) for its ")
            + t
            + String(" repository"),
        )


def test_invalid_secret_name_is_refused_without_quoting_it() raises:
    var pasted = List[String]()
    pasted.append(String("pypi-AgEIcHlwaS5vcmcCJGFiY2Q"))
    pasted.append(String("ghp_abc.def"))
    pasted.append(String("1TOKEN"))
    pasted.append(String("TOKEN NAME"))
    pasted.append(String("tok/en+="))
    var long = String("")
    for _ in range(129):
        long += "A"
    pasted.append(long)
    for i in range(len(pasted)):
        var text = _file(
            String("CONDA"),
            String("    credential { kind: API_TOKEN secret_name: \"")
            + pasted[i]
            + String("\" }\n"),
        )
        _assert_refused(
            text,
            String(
                "channel 'beta' declares an invalid secret_name (not quoted: it"
                " may be a pasted secret; expected a handle matching"
                " [A-Za-z_][A-Za-z0-9_]*, at most 128 bytes) for its CONDA"
                " repository"
            ),
        )
        _assert_not_quoted(text, pasted[i])


def _pasted_secrets() -> List[String]:
    """The same six pasted shapes the invalid-secret_name test uses."""
    var pasted = List[String]()
    pasted.append(String("pypi-AgEIcHlwaS5vcmcCJGFiY2Q"))
    pasted.append(String("ghp_abc.def"))
    pasted.append(String("1TOKEN"))
    pasted.append(String("TOKEN NAME"))
    pasted.append(String("tok/en+="))
    var long = String("")
    for _ in range(129):
        long += "A"
    pasted.append(long^)
    return pasted^


def test_malformed_secret_name_is_refused_without_quoting_it() raises:
    """A parse-time refusal must not quote the value either: with the colon
    missing, the token cursor's own refusal would echo the pasted secret."""
    var pasted = _pasted_secrets()
    for i in range(len(pasted)):
        var text = _file(
            String("CONDA"),
            String("    credential { kind: API_TOKEN secret_name \"")
            + pasted[i]
            + String("\" }\n"),
        )
        _assert_refused(
            text,
            String(
                "channels file: line 8: malformed secret_name in the credential"
                " of a repository of channel 'beta' (expected `secret_name:"
                " <value>`; value not quoted)"
            ),
        )
        _assert_not_quoted(text, pasted[i])


def test_a_pasted_kind_is_refused_without_quoting_it() raises:
    """A secret pasted into `kind`: malformed (missing colon) at parse time,
    and well-formed but unknown at validation. Neither refusal quotes it."""
    var pasted = _pasted_secrets()
    for i in range(len(pasted)):
        var missing_colon = _file(
            String("OCI"),
            String("    credential { kind \"") + pasted[i] + String("\" }\n"),
        )
        _assert_refused(
            missing_colon,
            String(
                "channels file: line 8: malformed kind in the credential of a"
                " repository of channel 'beta'"
            ),
        )
        _assert_not_quoted(missing_colon, pasted[i])
        var unknown = _file(
            String("OCI"),
            String("    credential { kind: \"") + pasted[i] + String("\" }\n"),
        )
        _assert_refused(
            unknown,
            String("channel 'beta' declares an unknown credential kind (not quoted"),
        )
        _assert_not_quoted(unknown, pasted[i])


def test_a_pasted_field_name_is_refused_without_quoting_it() raises:
    """A secret where a credential field NAME was expected: as a string it is
    not a field name, and as a bare word it is an unknown field. Neither
    refusal quotes it."""
    var pasted = _pasted_secrets()
    for i in range(len(pasted)):
        var as_string = _file(
            String("OCI"),
            String("    credential { kind: API_TOKEN \"")
            + pasted[i]
            + String("\" }\n"),
        )
        _assert_refused(
            as_string,
            String(
                "channels file: line 8: expected a field name in the credential"
                " of a repository of channel 'beta'"
            ),
        )
        _assert_not_quoted(as_string, pasted[i])
    var as_word = _file(
        String("OCI"),
        String("    credential { kind: API_TOKEN ghp_abc123: \"A\" }\n"),
    )
    _assert_refused(
        as_word,
        String(
            "channels file: line 8: unknown field in the credential of a"
            " repository of channel 'beta' (expected kind, secret_name; field"
            " not quoted)"
        ),
    )
    _assert_not_quoted(as_word, String("ghp_abc123"))


def test_a_constructed_repository_without_credential_is_refused() raises:
    var repos = List[ChannelRepository]()
    repos.append(
        ChannelRepository(
            String(ARTIFACT_TYPE_OCI),
            String("registry.example.invalid/edge"),
            String("publisher@example.invalid"),
            None,
        )
    )
    var channels = List[Channel]()
    channels.append(Channel(String("edge"), String("PUBLIC"), repos^))
    var msg = String("")
    try:
        validate_channels(channels)
    except e:
        msg = String(e)
    if "channel 'edge' declares no credential" not in msg:
        raise Error(String("unexpected: ") + msg)
    msg = String("")
    try:
        _ = channels[0].repositories[0].declared_credential()
    except e:
        msg = String(e)
    assert_equal(msg, String("the OCI repository declares no credential"))


# ── The predicates. ──────────────────────────────────────────────────────────


def test_credential_kinds_are_a_closed_set() raises:
    assert_true(is_known_credential_kind(String("API_TOKEN")))
    assert_true(is_known_credential_kind(String("OIDC_TRUSTED_PUBLISHING")))
    assert_false(is_known_credential_kind(String("OIDC")))
    assert_false(is_known_credential_kind(String("")))


def test_secret_name_grammar() raises:
    assert_true(is_valid_secret_name(String("PYPI_TOKEN")))
    assert_true(is_valid_secret_name(String("_x")))
    assert_true(is_valid_secret_name(String("a1")))
    assert_false(is_valid_secret_name(String("")))
    assert_false(is_valid_secret_name(String("9A")))
    assert_false(is_valid_secret_name(String("A-B")))
    assert_false(is_valid_secret_name(String("A.B")))
    var name = String("")
    for _ in range(128):
        name += "A"
    assert_true(is_valid_secret_name(name))
    name += "A"
    assert_false(is_valid_secret_name(name))


def test_oidc_exchange_table() raises:
    assert_true(oidc_exchange_implemented(String(ARTIFACT_TYPE_CONDA)))
    assert_true(oidc_exchange_implemented(String(ARTIFACT_TYPE_PYTHON)))
    assert_false(oidc_exchange_implemented(String(ARTIFACT_TYPE_OCI)))
    assert_false(oidc_exchange_implemented(String(ARTIFACT_TYPE_NPM)))


def test_a_credential_value_reads_back() raises:
    var c = ChannelCredential(String(CREDENTIAL_KIND_API_TOKEN), String("X"))
    assert_true(c.is_api_token())
    assert_equal(c.copy().secret_name, String("X"))



# ── push_identity_environment: the stage a trusted publisher names. ─────────


def _identity_env(kind_block: String, identity: String) raises -> String:
    var text = (
        String("channel {\n  name: \"beta\"\n  visibility: PRIVATE\n")
        + String("  repository {\n    artifact_type: CONDA\n")
        + String("    location: \"registry.example.invalid/beta\"\n")
        + String("    push_identity: \"") + identity + String("\"\n")
        + kind_block
        + String("  }\n}\n")
    )
    return push_identity_environment(_parse(text)[0].repositories[0])


def test_push_identity_environment() raises:
    var oidc = String("    credential { kind: OIDC_TRUSTED_PUBLISHING }\n")
    var token = String("    credential { kind: API_TOKEN secret_name: \"T\" }\n")
    # the two release channels' trusted publishers: environments staging and stable
    assert_equal(_identity_env(oidc, String("repo:example-org/example-repo:environment:staging")), String("staging"))
    assert_equal(_identity_env(oidc, String("repo:example-org/example-repo:environment:stable")), String("stable"))
    assert_equal(_identity_env(oidc, String("repo:o/r:environment:build-2")), String("build-2"))
    # no environment, an empty one, or a further claim after it: none
    assert_equal(_identity_env(oidc, String("repo:o/r:ref:refs/heads/main")), String(""))
    assert_equal(_identity_env(oidc, String("repo:o/r:environment:")), String(""))
    assert_equal(_identity_env(oidc, String("repo:o/r:environment:stable:x")), String(""))
    # an API token's push identity is a principal, not a token subject
    assert_equal(_identity_env(token, String("repo:o/r:environment:stable")), String(""))


# ── break_glass_push_identity: a second trusted publisher. ──────────────────


def _bg(kind_block: String, identity: String, break_glass: String) -> String:
    return (
        String("channel {\n  name: \"beta\"\n  visibility: PRIVATE\n")
        + String("  repository {\n    artifact_type: CONDA\n")
        + String("    location: \"registry.example.invalid/beta\"\n")
        + String("    push_identity: \"") + identity + String("\"\n")
        + String("    break_glass_push_identity: \"") + break_glass + String("\"\n")
        + kind_block
        + String("  }\n}\n")
    )


def test_break_glass_push_identity() raises:
    var oidc = String("    credential { kind: OIDC_TRUSTED_PUBLISHING }\n")
    var token = String("    credential { kind: API_TOKEN secret_name: \"T\" }\n")
    var main = String("repo:o/r:environment:gamma")
    var r = _parse(_bg(oidc, main, String("repo:o/r:environment:gamma-breakglass")))[0].repositories[0].copy()
    assert_equal(break_glass_push_identity_environment(r), String("gamma-breakglass"))
    assert_equal(push_identity_environment(r), String("gamma"))
    # none declared: none
    var plain = (
        String("channel {\n  name: \"beta\"\n  visibility: PRIVATE\n  repository {\n    artifact_type: CONDA\n")
        + String("    location: \"registry.example.invalid/beta\"\n    push_identity: \"") + main + String("\"\n") + oidc
        + String("  }\n}\n")
    )
    assert_equal(break_glass_push_identity_environment(_parse(plain)[0].repositories[0]), String(""))
    assert_equal(
        break_glass_push_identity_environment(
            _parse(_bg(oidc, main, String("repo:o/r:environment:g2")))[0].repositories[0]
        ),
        String("g2"),
    )
    # refusals: an API token; no environment; the same environment; another
    # repository or workflow; set twice
    _assert_refused(
        _bg(token, String("repo:o/r:environment:gamma"), String("repo:o/r:environment:gamma-bg")),
        String("which does not publish by OIDC trusted publishing"),
    )
    _assert_refused(_bg(oidc, main, String("repo:o/r:ref:refs/heads/x")), String("it names no environment"))
    _assert_refused(_bg(oidc, main, String("repo:o/r:environment:gamma")), String("it names the push_identity's own environment 'gamma'"))
    _assert_refused(
        _bg(oidc, main, String("repo:o/other:environment:gamma-bg")),
        String("it is not push_identity 'repo:o/r:environment:gamma' with another environment"),
    )
    var twice = _bg(oidc, main, String("repo:o/r:environment:a")).replace(
        String("    credential"), String("    break_glass_push_identity: \"repo:o/r:environment:b\"\n    credential")
    )
    _assert_refused(twice, String("break_glass_push_identity"))


# ── Both environment readers need an OIDC credential. ───────────────────────


def _constructed(var credential: Optional[ChannelCredential]) -> ChannelRepository:
    """A repository built without the parser (which refuses a break-glass
    identity on an API token and a missing credential), whose push and
    break-glass identities each name an environment."""
    var r = ChannelRepository(
        String(ARTIFACT_TYPE_CONDA),
        String("registry.example.invalid/beta"),
        String("repo:o/r:environment:stable"),
        credential^,
    )
    r.break_glass_push_identity = String("repo:o/r:environment:stable-bg")
    return r^


def test_identity_environments_need_an_oidc_credential() raises:
    # control: with an OIDC credential the same identities name environments
    var oidc = _constructed(
        ChannelCredential(String(CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING), String(""))
    )
    assert_equal(push_identity_environment(oidc), String("stable"))
    assert_equal(break_glass_push_identity_environment(oidc), String("stable-bg"))
    # no credential: neither identity is a token subject
    var none = _constructed(None)
    assert_equal(push_identity_environment(none), String(""))
    assert_equal(break_glass_push_identity_environment(none), String(""))
    # an API token: the break-glass identity is not a token subject either
    var token = _constructed(
        ChannelCredential(String(CREDENTIAL_KIND_API_TOKEN), String("T"))
    )
    assert_equal(push_identity_environment(token), String(""))
    assert_equal(break_glass_push_identity_environment(token), String(""))


def test_a_structural_token_as_a_credential_value() raises:
    """A `{`, `}` or `:` where a credential value belongs is malformed, and
    the reworded refusal still names the field and its line."""
    var kinds = List[String]()
    kinds.append(String("{"))
    kinds.append(String("}"))
    kinds.append(String(":"))
    for i in range(len(kinds)):
        var text = _file(
            String("CONDA"),
            String("    credential {\n      kind: ") + kinds[i] + String(" }\n"),
        )
        assert_equal(
            _refusal(text),
            String(
                "channels file: line 9: malformed kind in the credential"
                " of a repository of channel 'beta' (expected `kind:"
                " <value>`; value not quoted)"
            ),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
