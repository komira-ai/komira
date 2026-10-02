# =============================================================================
# tests/getenv_link_probe.mojo: ProcessEnv's own `getenv` declaration links
#   beside komira_core_ffi's and the standard library's.
# =============================================================================
#
# Mojo refuses, at LINK, a binary in which two packages declare one C symbol
# with different signatures. process_env.mojo declares `getenv` with
# komira_core_ffi's signature; this binary links both, so building it is the
# check. Running it (`buck2 test`) also compares the two readers' answers.
#
# `std.os.getenv` is deliberately absent: its declaration differs from
# komira_core_ffi's (measured 2026-10-01: a binary linking std.os.getenv and
# komira_core_ffi's `_read_env` fails with "existing function with
# conflicting signature"), so no binary holding either can call it.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core_ffi.posix import _read_env

from komira_secret_env import ProcessEnv


def main() raises:
    var want = String("probe-value")
    assert_equal(_read_env("KOMIRA_SECRET_ENV_PROBE"), want)
    var env = ProcessEnv()
    var got = env.lookup("KOMIRA_SECRET_ENV_PROBE")
    assert_true(Bool(got))
    assert_equal(got.take().len(), want.byte_length())
    print("PASS getenv_link_probe")
