# =============================================================================
# src/kci_cli/tests/test_kci_platform_env_non_ascii.mojo — `platform_env`
#   returns an environment value's bytes exactly. KCI_CLI_TEST_NON_ASCII is
#   set by `test_env` to a value with a byte at or above 0x80 (U+00E9, bytes
#   C3 A9), and the value comes back byte for byte.
# =============================================================================

from std.testing import TestSuite, assert_equal

from kci_cli import LibrarySteps


def test_platform_env_keeps_non_ascii_bytes() raises:
    var steps = LibrarySteps()
    var got = steps.platform_env(String("KCI_CLI_TEST_NON_ASCII"))
    var want = String("/work/café")
    assert_equal(got.byte_length(), want.byte_length())
    assert_equal(got, want)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
