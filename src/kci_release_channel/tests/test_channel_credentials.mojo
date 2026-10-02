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
    ChannelCredential,
    ChannelDeclaration,
    ChannelRepository,
    find_channel,
    is_known_credential_kind,
    is_valid_secret_name,
    oidc_exchange_implemented,
    parse_channels_file,
    validate_channel_declarations,
)


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
        _ = parse_channels_file(text)
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
    var decls = parse_channels_file(
        _file(
            String("OCI"),
            String("    credential { kind: API_TOKEN secret_name: \"OCI_TOKEN\" }\n"),
        )
    )
    var c = find_channel(decls, String("beta")).repository_for(
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
        var decls = parse_channels_file(_file(types[i], block))
        var c = decls[0].repositories[0].declared_credential()
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
            "channels file: line 8: unknown field 'token' in the credential of a"
            " repository of channel 'beta' (expected kind, secret_name)"
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
            "channel 'beta' declares unknown credential kind 'PASSWORD'"
            " (expected API_TOKEN, OIDC_TRUSTED_PUBLISHING) for its OCI"
            " repository"
        ),
    )


def test_kind_is_case_sensitive() raises:
    _assert_refused(
        _file(
            String("OCI"),
            String("    credential { kind: api_token secret_name: \"A\" }\n"),
        ),
        String("declares unknown credential kind 'api_token'"),
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
    var decls = List[ChannelDeclaration]()
    decls.append(ChannelDeclaration(String("edge"), String("PUBLIC"), repos^))
    var msg = String("")
    try:
        validate_channel_declarations(decls)
    except e:
        msg = String(e)
    if "channel 'edge' declares no credential" not in msg:
        raise Error(String("unexpected: ") + msg)
    msg = String("")
    try:
        _ = decls[0].repositories[0].declared_credential()
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
