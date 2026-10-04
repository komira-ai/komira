# =============================================================================
# src/kci_release_channel/tests/test_release_channels_file.mojo
#   The repository's own channels file, release/channels.textproto, read
#   through the real parser: exactly two channels, `gamma` and `prod`, the
#   public prefix.dev conda channels komira-ai/gamma and komira-ai/prod, each
#   pushed to by trusted publishing from its own GitHub environment only.
# =============================================================================
#
# The file is staged as test data at `channels.textproto` (BUCK). A typo in
# it, a token credential, a third channel, a channel without its namespace or
# a push identity naming another environment fails this test, and with it
# `./buck2 build //...`.
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


def test_the_two_channels_are_gamma_and_prod() raises:
    var channels = parse_channels_file(_read())
    assert_equal(len(channels), 2)
    assert_equal(channels[0].name, String("gamma"))
    assert_equal(channels[1].name, String("prod"))
    for i in range(len(channels)):
        assert_true(channels[i].is_public())
        assert_equal(len(channels[i].repositories), 1)


def _check(name: String) raises:
    var ch = find_channel(parse_channels_file(_read()), name)
    var repo = ch.repository_for(String(ARTIFACT_TYPE_CONDA))
    # the namespaced prefix.dev repository URL: https://prefix.dev/<namespace>/<channel>
    assert_equal(repo.location, String("https://prefix.dev/komira-ai/") + name)
    assert_equal(repo.push_identity, String("repo:komira-ai/komira:environment:") + name)
    var cred = repo.declared_credential()
    assert_equal(cred.kind, String(CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING))
    assert_equal(cred.secret_name, String(""))
    # The Trusted Publisher names one GitHub environment: only the kci.yml job
    # in that environment can push here.
    assert_equal(push_identity_environment(repo), name)


def test_gamma_is_komira_ai_gamma_by_trusted_publishing_from_environment_gamma() raises:
    _check(String("gamma"))


def test_prod_is_komira_ai_prod_by_trusted_publishing_from_environment_prod() raises:
    _check(String("prod"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
