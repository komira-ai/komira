# =============================================================================
# tests/test_env_secret_store.mojo: EnvSecretStore over the MapEnv double.
# =============================================================================
#
# Hermetic: no process environment is read. Pinned here:
#   * a set variable resolves to exactly its bytes, through a generic
#     `[S: SecretStore]` (the store conforms to the seam);
#   * unset and set-but-empty are both refused, with different messages that
#     name the handle;
#   * a handle outside the grammar is refused BEFORE any lookup, and the
#     refusal does not quote it (it may be a pasted secret);
#   * an over-length value is refused naming the handle, never the value;
#   * the resolved value's Display is redacted;
#   * every resolve that passes the grammar makes exactly one lookup.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_secret_store import MAX_SECRET_LEN, SecretStore, SecretValue

from komira_secret_env import (
    MAX_SECRET_NAME_LEN,
    EnvSecretStore,
    MapEnv,
    is_secret_env_name,
)


def _resolve_through[S: SecretStore](mut store: S, handle: String) raises -> SecretValue:
    return store.resolve(handle)


def _refusal(mut store: EnvSecretStore[MapEnv], handle: String) -> String:
    """The message `resolve(handle)` raises, or "<resolved>" if it does not."""
    try:
        _ = store.resolve(handle)
    except e:
        return String(e)
    return String("<resolved>")


def _bytes_equal(v: SecretValue, want: String) -> Bool:
    var got = v.revealed_bytes()
    var w = want.as_bytes()
    if len(got) != len(w):
        return False
    for i in range(len(w)):
        if got[i] != w[i]:
            return False
    return True


def test_set_variable_resolves_to_its_bytes() raises:
    var env = MapEnv()
    env.set("PYPI_TOKEN", "pypi-s3cr3t")
    var probe = env.share()
    var store = EnvSecretStore[MapEnv](env^)
    var v = _resolve_through(store, "PYPI_TOKEN")
    assert_true(_bytes_equal(v, "pypi-s3cr3t"), "the variable's bytes, exactly")
    assert_equal(probe.lookup_count(), 1)


def test_unset_is_refused_naming_the_handle() raises:
    var store = EnvSecretStore[MapEnv](MapEnv())
    var msg = _refusal(store, "PYPI_TOKEN")
    assert_equal(msg, "EnvSecretStore: environment variable PYPI_TOKEN is not set")


def test_empty_is_refused_with_its_own_message() raises:
    var env = MapEnv()
    env.set("PYPI_TOKEN", "")
    var store = EnvSecretStore[MapEnv](env^)
    var msg = _refusal(store, "PYPI_TOKEN")
    assert_equal(
        msg, "EnvSecretStore: environment variable PYPI_TOKEN is set but empty"
    )


def test_unset_after_set_stops_resolving() raises:
    var env = MapEnv()
    env.set("A_TOKEN", "v")
    var handle = env.share()
    var store = EnvSecretStore[MapEnv](env^)
    _ = store.resolve("A_TOKEN")
    handle.unset("A_TOKEN")
    assert_true(_refusal(store, "A_TOKEN").find("is not set") >= 0)


def test_bad_names_are_refused_before_lookup_and_not_quoted() raises:
    var env = MapEnv()
    var probe = env.share()
    var store = EnvSecretStore[MapEnv](env^)
    var long_name = String("A") * (MAX_SECRET_NAME_LEN + 1)
    var bad: List[String] = [
        "",
        "1ABC",
        "has-dash",
        "ghp_pasted.token/value",
        "NUL\x00INSIDE",
        long_name,
    ]
    for i in range(len(bad)):
        var msg = _refusal(store, bad[i])
        assert_true(msg.startswith("EnvSecretStore: secret env name"), msg)
        if bad[i].byte_length() > 3:
            assert_equal(msg.find(bad[i]), -1, "the refused handle is not quoted")
    assert_equal(probe.lookup_count(), 0, "no lookup for a refused handle")


def test_grammar_accepts_shell_names() raises:
    assert_true(is_secret_env_name("_X"))
    assert_true(is_secret_env_name("PYPI_TOKEN_2"))
    assert_true(is_secret_env_name(String("A") * MAX_SECRET_NAME_LEN))
    assert_false(is_secret_env_name("A B"))
    assert_false(is_secret_env_name("ÄRGER"))


def test_over_length_value_is_refused_naming_the_handle_only() raises:
    var env = MapEnv()
    var value = String("q") * (MAX_SECRET_LEN + 1)
    env.set("BIG_TOKEN", value)
    var store = EnvSecretStore[MapEnv](env^)
    var msg = _refusal(store, "BIG_TOKEN")
    assert_true(msg.startswith("EnvSecretStore: environment variable BIG_TOKEN: "), msg)
    assert_equal(msg.find("qqqq"), -1, "the value never appears in the refusal")

    var at_limit = MapEnv()
    at_limit.set("MAX_TOKEN", String("q") * MAX_SECRET_LEN)
    var store2 = EnvSecretStore[MapEnv](at_limit^)
    assert_equal(store2.resolve("MAX_TOKEN").len(), MAX_SECRET_LEN)


def test_display_is_redacted() raises:
    var env = MapEnv()
    env.set("API_TOKEN", "hunter2-xyz")
    var store = EnvSecretStore[MapEnv](env^)
    var v = store.resolve("API_TOKEN")
    var shown = String(v)
    assert_equal(shown, "SecretValue(<redacted:11B>)")
    assert_equal(shown.find("hunter2"), -1)


def test_each_resolve_is_one_lookup() raises:
    var env = MapEnv()
    env.set("T1", "a")
    env.set("T2", "")
    var probe = env.share()
    var store = EnvSecretStore[MapEnv](env^)
    _ = store.resolve("T1")
    _ = _refusal(store, "T2")
    _ = _refusal(store, "T3")
    _ = _refusal(store, "bad-name")
    _ = store.resolve("T1")
    assert_equal(probe.lookup_count(), 4, "4 valid handles, 4 lookups")


def main() raises:
    test_set_variable_resolves_to_its_bytes()
    test_unset_is_refused_naming_the_handle()
    test_empty_is_refused_with_its_own_message()
    test_unset_after_set_stops_resolving()
    test_bad_names_are_refused_before_lookup_and_not_quoted()
    test_grammar_accepts_shell_names()
    test_over_length_value_is_refused_naming_the_handle_only()
    test_display_is_redacted()
    test_each_resolve_is_one_lookup()
    print("PASS test_env_secret_store")
