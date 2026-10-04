# =============================================================================
# src/kci_release_channel/tests/test_release_channels_file.mojo
#   The repository's own channels file, release/channels.textproto, read
#   through the real parser: the one channel `komira` (the name
#   .github/workflows/kci.yml publishes to) is the public prefix.dev conda
#   channel, pushed to by trusted publishing from the prod environment only.
# =============================================================================
#
# The file is staged as test data at `channels.textproto` (BUCK). A typo in
# it, a token credential, a second channel or a different location fails
# this test, and with it `./buck2 build //...`.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from kci_release_channel import (
    ARTIFACT_TYPE_CONDA,
    CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING,
    find_channel,
    parse_channels_file,
    push_identity_environment,
)


def _read() raises -> String:
    return Path(String("channels.textproto")).read_text()


def test_the_one_channel_is_komira() raises:
    var channels = parse_channels_file(_read())
    assert_equal(len(channels), 1)
    assert_equal(channels[0].name, String("komira"))
    assert_true(channels[0].is_public())
    assert_equal(len(channels[0].repositories), 1)


def test_komira_is_the_prefix_dev_conda_channel_by_trusted_publishing() raises:
    var channels = parse_channels_file(_read())
    var ch = find_channel(channels, String("komira"))
    var repo = ch.repository_for(String(ARTIFACT_TYPE_CONDA))
    assert_equal(repo.location, String("https://prefix.dev/komira"))
    assert_equal(repo.push_identity, String("repo:komira-ai/komira:environment:prod"))
    var cred = repo.declared_credential()
    assert_equal(cred.kind, String(CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING))
    assert_equal(cred.secret_name, String(""))
    # The Trusted Publisher names the GitHub environment `prod`: only the
    # kci.yml job in that environment (the publish stage) can push here.
    assert_equal(push_identity_environment(repo), String("prod"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
