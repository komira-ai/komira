# =============================================================================
# src/kci_release_channels/tests/test_channel_declarations.mojo
#   A channels file parses into declarations, and the lookups read them back.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_channels import (
    ARTIFACT_TYPE_CONDA,
    ARTIFACT_TYPE_NPM,
    ARTIFACT_TYPE_OCI,
    ARTIFACT_TYPE_PYTHON,
    VISIBILITY_PRIVATE,
    VISIBILITY_PUBLIC,
    ChannelDeclaration,
    ChannelRepository,
    channel_names,
    find_channel,
    is_known_artifact_type,
    is_valid_channel_name,
    parse_channels_file,
    validate_channel_declarations,
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
  }
}
channel: {
  name: stable
  visibility: PUBLIC
  repository {
    artifact_type: OCI
    location: "registry.example.invalid/stable"
    push_identity: "publisher@example.invalid"
  }
  repository: {
    artifact_type: PYTHON
    location: "https://packages.example.invalid/stable/simple"
    push_identity: "wheel-publisher@example.invalid"
  }
}
"""


def _assert_contains(haystack: String, needle: String) raises:
    if needle not in haystack:
        raise Error(String("expected '") + needle + String("' in: ") + haystack)


def test_a_channels_file_parses_in_order() raises:
    var decls = parse_channels_file(String(_FILE))
    assert_equal(len(decls), 2)
    var names = channel_names(decls)
    assert_equal(names[0], String("beta"))
    assert_equal(names[1], String("stable"))
    assert_equal(decls[0].visibility, String(VISIBILITY_PRIVATE))
    assert_equal(decls[1].visibility, String(VISIBILITY_PUBLIC))
    assert_equal(len(decls[0].repositories), 1)
    assert_equal(len(decls[1].repositories), 2)


def test_visibility_reads_back() raises:
    var decls = parse_channels_file(String(_FILE))
    assert_false(find_channel(decls, String("beta")).is_public())
    assert_true(find_channel(decls, String("stable")).is_public())


def test_repository_for_reads_every_field() raises:
    var decls = parse_channels_file(String(_FILE))
    var r = find_channel(decls, String("stable")).repository_for(
        String(ARTIFACT_TYPE_PYTHON)
    )
    assert_equal(r.artifact_type, String(ARTIFACT_TYPE_PYTHON))
    assert_equal(
        r.location, String("https://packages.example.invalid/stable/simple")
    )
    assert_equal(r.push_identity, String("wheel-publisher@example.invalid"))
    var o = find_channel(decls, String("beta")).repository_for(
        String(ARTIFACT_TYPE_OCI)
    )
    assert_equal(o.location, String("registry.example.invalid/beta"))


def test_a_missing_repository_is_refused_not_defaulted() raises:
    var decls = parse_channels_file(String(_FILE))
    var msg = String("")
    try:
        _ = find_channel(decls, String("beta")).repository_for(
            String(ARTIFACT_TYPE_PYTHON)
        )
    except e:
        msg = String(e)
    _assert_contains(msg, String("channel 'beta' declares no PYTHON repository"))


def test_an_unknown_channel_is_refused_naming_the_declared_ones() raises:
    var decls = parse_channels_file(String(_FILE))
    var msg = String("")
    try:
        _ = find_channel(decls, String("nightly"))
    except e:
        msg = String(e)
    _assert_contains(
        msg, String("unknown release channel 'nightly' (declared: beta, stable)")
    )


def test_constructed_declarations_validate() raises:
    var repos = List[ChannelRepository]()
    repos.append(
        ChannelRepository(
            String(ARTIFACT_TYPE_NPM),
            String("https://npm.example.invalid/edge"),
            String("publisher@example.invalid"),
        )
    )
    repos.append(
        ChannelRepository(
            String(ARTIFACT_TYPE_CONDA),
            String("https://conda.example.invalid/edge"),
            String("publisher@example.invalid"),
        )
    )
    var decls = List[ChannelDeclaration]()
    decls.append(
        ChannelDeclaration(String("edge-2"), String(VISIBILITY_PRIVATE), repos^)
    )
    validate_channel_declarations(decls)
    assert_equal(
        find_channel(decls, String("edge-2"))
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
