# =============================================================================
# src/kci_release_channel/tests/test_channels.mojo
#   A channels file parses into channels, and the lookups read them back.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_channel import (
    ARTIFACT_TYPE_CONDA,
    ARTIFACT_TYPE_NPM,
    ARTIFACT_TYPE_OCI,
    ARTIFACT_TYPE_PYTHON,
    CREDENTIAL_KIND_API_TOKEN,
    CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING,
    VISIBILITY_PRIVATE,
    VISIBILITY_PUBLIC,
    ChannelCredential,
    Channel,
    ChannelRepository,
    channel_names,
    find_channel,
    is_known_artifact_type,
    is_valid_channel_name,
    parse_channels_file,
    validate_channels,
)

comptime _FILE = """
# Two synthetic channels.
channel {
  name: "beta"
  visibility: PRIVATE
  repository {
    artifact_type: OCI
    location: "registry.example.invalid/beta"
    push_identity: "publisher@example.invalid"
    credential { kind: API_TOKEN secret_name: "BETA_REGISTRY_TOKEN" }
  }
}
channel: {
  name: stable
  visibility: PUBLIC
  repository {
    artifact_type: OCI
    location: "registry.example.invalid/stable"
    push_identity: "publisher@example.invalid"
    credential: { kind: "API_TOKEN" secret_name: STABLE_REGISTRY_TOKEN }
  }
  repository: {
    artifact_type: PYTHON
    location: "https://packages.example.invalid/stable/simple"
    push_identity: "wheel-publisher@example.invalid"
    credential { kind: OIDC_TRUSTED_PUBLISHING }
  }
}
"""

# The two release channels: prefix.dev's namespaced channels, each with a
# trusted publisher bound to one GitHub environment.
comptime _RELEASE = """
channel {
  name: "gamma"
  visibility: PUBLIC
  repository {
    artifact_type: CONDA
    location: "https://prefix.dev/komira-ai/gamma"
    push_identity: "repo:komira-ai/komira:environment:gamma"
    credential { kind: OIDC_TRUSTED_PUBLISHING }
  }
}
channel {
  name: "prod"
  visibility: PUBLIC
  repository {
    artifact_type: CONDA
    location: "https://prefix.dev/komira-ai/prod"
    push_identity: "repo:komira-ai/komira:environment:prod"
    credential { kind: OIDC_TRUSTED_PUBLISHING }
  }
}
"""


def _parse(text: String) raises -> List[Channel]:
    """`parse_channels_file` over `text` with `schema_version: 1` prepended on
    its FIRST line, so no line number a refusal names moves."""
    return parse_channels_file(String("schema_version: 1 ") + text)


def _assert_contains(haystack: String, needle: String) raises:
    if needle not in haystack:
        raise Error(String("expected '") + needle + String("' in: ") + haystack)


def test_a_channels_file_parses_in_order() raises:
    var channels = _parse(String(_FILE))
    assert_equal(len(channels), 2)
    var names = channel_names(channels)
    assert_equal(names[0], String("beta"))
    assert_equal(names[1], String("stable"))
    assert_equal(channels[0].visibility, String(VISIBILITY_PRIVATE))
    assert_equal(channels[1].visibility, String(VISIBILITY_PUBLIC))
    assert_equal(len(channels[0].repositories), 1)
    assert_equal(len(channels[1].repositories), 2)


def test_visibility_reads_back() raises:
    var channels = _parse(String(_FILE))
    assert_false(find_channel(channels, String("beta")).is_public())
    assert_true(find_channel(channels, String("stable")).is_public())


def test_repository_for_reads_every_field() raises:
    var channels = _parse(String(_FILE))
    var r = find_channel(channels, String("stable")).repository_for(
        String(ARTIFACT_TYPE_PYTHON)
    )
    assert_equal(r.artifact_type, String(ARTIFACT_TYPE_PYTHON))
    assert_equal(
        r.location, String("https://packages.example.invalid/stable/simple")
    )
    assert_equal(r.push_identity, String("wheel-publisher@example.invalid"))
    var rc = r.declared_credential()
    assert_true(rc.is_oidc_trusted_publishing())
    assert_equal(rc.secret_name, String(""))
    var o = find_channel(channels, String("beta")).repository_for(
        String(ARTIFACT_TYPE_OCI)
    )
    assert_equal(o.location, String("registry.example.invalid/beta"))
    var oc = o.declared_credential()
    assert_true(oc.is_api_token())
    assert_equal(oc.kind, String(CREDENTIAL_KIND_API_TOKEN))
    assert_equal(oc.secret_name, String("BETA_REGISTRY_TOKEN"))
    var so = find_channel(channels, String("stable")).repository_for(
        String(ARTIFACT_TYPE_OCI)
    )
    assert_equal(
        so.declared_credential().secret_name, String("STABLE_REGISTRY_TOKEN")
    )


def test_a_missing_repository_is_refused_not_defaulted() raises:
    var channels = _parse(String(_FILE))
    var msg = String("")
    try:
        _ = find_channel(channels, String("beta")).repository_for(
            String(ARTIFACT_TYPE_PYTHON)
        )
    except e:
        msg = String(e)
    _assert_contains(msg, String("channel 'beta' declares no PYTHON repository"))


def test_an_unknown_channel_is_refused_naming_the_declared_ones() raises:
    var channels = _parse(String(_FILE))
    var msg = String("")
    try:
        _ = find_channel(channels, String("nightly"))
    except e:
        msg = String(e)
    _assert_contains(
        msg, String("unknown release channel 'nightly' (declared: beta, stable)")
    )


def test_constructed_channels_validate() raises:
    var repos = List[ChannelRepository]()
    repos.append(
        ChannelRepository(
            String(ARTIFACT_TYPE_NPM),
            String("https://npm.example.invalid/edge"),
            String("publisher@example.invalid"),
            Optional(
                ChannelCredential(
                    String(CREDENTIAL_KIND_API_TOKEN), String("NPM_TOKEN")
                )
            ),
        )
    )
    repos.append(
        ChannelRepository(
            String(ARTIFACT_TYPE_CONDA),
            String("https://conda.example.invalid/edge"),
            String("publisher@example.invalid"),
            Optional(
                ChannelCredential(
                    String(CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING), String("")
                )
            ),
        )
    )
    var channels = List[Channel]()
    channels.append(
        Channel(String("edge-2"), String(VISIBILITY_PRIVATE), repos^)
    )
    validate_channels(channels)
    assert_equal(
        find_channel(channels, String("edge-2"))
        .repository_for(String(ARTIFACT_TYPE_CONDA))
        .location,
        String("https://conda.example.invalid/edge"),
    )


def test_artifact_types_are_a_closed_set() raises:
    assert_true(is_known_artifact_type(String(ARTIFACT_TYPE_OCI)))
    assert_true(is_known_artifact_type(String(ARTIFACT_TYPE_PYTHON)))
    assert_true(is_known_artifact_type(String(ARTIFACT_TYPE_NPM)))
    assert_true(is_known_artifact_type(String(ARTIFACT_TYPE_CONDA)))
    assert_false(is_known_artifact_type(String("oci")))
    assert_false(is_known_artifact_type(String("")))


def test_channel_name_charset() raises:
    assert_true(is_valid_channel_name(String("beta")))
    assert_true(is_valid_channel_name(String("a")))
    assert_true(is_valid_channel_name(String("rc-2")))
    assert_false(is_valid_channel_name(String("")))
    assert_false(is_valid_channel_name(String("Beta")))
    assert_false(is_valid_channel_name(String("2beta")))
    assert_false(is_valid_channel_name(String("beta-")))
    assert_false(is_valid_channel_name(String("be_ta")))
    assert_false(is_valid_channel_name(String("be.ta")))
    var long = String("")
    for _ in range(64):
        long += "a"
    assert_false(is_valid_channel_name(long))
    assert_true(is_valid_channel_name(String(long[byte=0:63])))


def test_the_gamma_and_prod_channels() raises:
    var channels = _parse(String(_RELEASE))
    assert_equal(len(channels), 2)
    var names = channel_names(channels)
    assert_equal(names[0], String("gamma"))
    assert_equal(names[1], String("prod"))
    var g = find_channel(channels, String("gamma"))
    assert_true(g.is_public())
    var gr = g.repository_for(String(ARTIFACT_TYPE_CONDA))
    assert_equal(gr.location, String("https://prefix.dev/komira-ai/gamma"))
    assert_equal(gr.push_identity, String("repo:komira-ai/komira:environment:gamma"))
    assert_true(gr.declared_credential().is_oidc_trusted_publishing())
    var p = find_channel(channels, String("prod"))
    assert_true(p.is_public())
    var pr = p.repository_for(String(ARTIFACT_TYPE_CONDA))
    assert_equal(pr.location, String("https://prefix.dev/komira-ai/prod"))
    assert_equal(pr.push_identity, String("repo:komira-ai/komira:environment:prod"))
    assert_true(pr.declared_credential().is_oidc_trusted_publishing())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
