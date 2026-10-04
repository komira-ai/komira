# =============================================================================
# src/kci_publish/tests/test_publish_actions_env.mojo -- `ActionsOidcEnv`
#   reads the runner's two OIDC handshake variables through komira_libc's
#   `_read_env`, the one `getenv` declaration of a binary.
# =============================================================================
#
# This test links both: komira_libc's `getenv` (through `_read_env`, as
# kci_pkg_upload and kci_cli read the platform variables) and
# `ActionsOidcEnv.from_process`. A second declaration of `getenv` in the same
# binary (std.os.getenv) is a conflicting-signature error at LLVM lowering, so
# this file does not compile while `from_process` reads through std.os. That
# is the error bin/kci hit.
#
# The test runner sets neither handshake variable, so the read is "not under
# CI".
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_libc.posix import _read_env

from kci_publish import ActionsOidcEnv


def test_from_process_links_beside_komira_libc() raises:
    assert_equal(_read_env("ACTIONS_ID_TOKEN_REQUEST_URL"), String(""))
    assert_equal(_read_env("ACTIONS_ID_TOKEN_REQUEST_TOKEN"), String(""))
    var env = ActionsOidcEnv.from_process()
    assert_true(env.is_absent())
    assert_equal(
        env.missing(), String("ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
