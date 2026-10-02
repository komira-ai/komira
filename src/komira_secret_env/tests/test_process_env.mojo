# =============================================================================
# tests/test_process_env.mojo: ProcessEnv and EnvSecretStore[ProcessEnv] over
#   the real process environment.
# =============================================================================
#
# The variables come from the library's `test_env` (BUCK), which the gate
# runner exports for this test: nothing is set in-process and nothing is read
# from the host. Pinned here: set, empty and unset are three different
# answers from `ProcessEnv.lookup`, a value is copied byte for byte (a
# non-ASCII byte is not re-encoded), and the store's refusals hold over the
# real reader.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_secret_store import SecretValue

from komira_secret_env import EnvSecretStore, ProcessEnv


def _bytes_equal(v: SecretValue, want: String) -> Bool:
    var got = v.revealed_bytes()
    var w = want.as_bytes()
    if len(got) != len(w):
        return False
    for i in range(len(w)):
        if got[i] != w[i]:
            return False
    return True


def _refusal(mut store: EnvSecretStore[ProcessEnv], handle: String) -> String:
    try:
        _ = store.resolve(handle)
    except e:
        return String(e)
    return String("<resolved>")


def test_lookup_distinguishes_set_empty_and_unset() raises:
    var env = ProcessEnv()
    var set_ = env.lookup("KOMIRA_SECRET_ENV_TEST_SET")
    assert_true(Bool(set_), "a set variable is found")
    assert_true(_bytes_equal(set_.take(), "s3cr3t-value"))

    var empty = env.lookup("KOMIRA_SECRET_ENV_TEST_EMPTY")
    assert_true(Bool(empty), "a set-but-empty variable is found")
    assert_equal(empty.take().len(), 0)

    var unset = env.lookup("KOMIRA_SECRET_ENV_TEST_NEVER_SET")
    assert_false(Bool(unset), "an unset variable is None")


def test_value_is_copied_byte_for_byte() raises:
    var env = ProcessEnv()
    var got = env.lookup("KOMIRA_SECRET_ENV_TEST_UTF8")
    assert_true(Bool(got))
    var v = got.take()
    assert_true(_bytes_equal(v, "données=1"), "non-ASCII bytes are not re-encoded")
    assert_equal(v.len(), 10)


def test_lookup_refuses_a_bad_name() raises:
    var env = ProcessEnv()
    var refused = False
    try:
        _ = env.lookup("A=B")
    except:
        refused = True
    assert_true(refused, "a name with '=' never reaches getenv")


def test_store_over_the_process_env() raises:
    var store = EnvSecretStore[ProcessEnv](ProcessEnv())
    var v = store.resolve("KOMIRA_SECRET_ENV_TEST_SET")
    assert_true(_bytes_equal(v, "s3cr3t-value"))
    assert_equal(String(v), "SecretValue(<redacted:12B>)")
    assert_equal(
        _refusal(store, "KOMIRA_SECRET_ENV_TEST_EMPTY"),
        "EnvSecretStore: environment variable KOMIRA_SECRET_ENV_TEST_EMPTY is set but empty",
    )
    assert_equal(
        _refusal(store, "KOMIRA_SECRET_ENV_TEST_NEVER_SET"),
        "EnvSecretStore: environment variable KOMIRA_SECRET_ENV_TEST_NEVER_SET is not set",
    )


def main() raises:
    test_lookup_distinguishes_set_empty_and_unset()
    test_value_is_copied_byte_for_byte()
    test_lookup_refuses_a_bad_name()
    test_store_over_the_process_env()
    print("PASS test_process_env")
