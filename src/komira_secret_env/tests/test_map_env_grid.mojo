# =============================================================================
# tests/test_map_env_grid.mojo: MapEnv and EnvSecretStore[MapEnv] over a grid
#   of variable states, each answer exact.
# =============================================================================
#
# Every fixture (unset; set to 0, 1, 2, MAX_SECRET_LEN and MAX_SECRET_LEN + 1
# bytes) goes through every checker (`MapEnv.lookup`, `EnvSecretStore.resolve`)
# with its exact expected result: the whole `SecretValue` (length and every
# byte) for a value, the whole message for a refusal, and the lookup count
# after each call. Pinned besides:
#   * `set` overwrites and copies bytes exactly (non-ASCII included);
#   * `unset` of an absent name is a no-op, and of a present one removes it
#     without touching its neighbours;
#   * the lookup count counts misses and refusals of the value, never a
#     handle refused by the grammar;
#   * a grammar refusal through the store carries the grammar's exact
#     message behind the store's prefix.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_secret_store import MAX_SECRET_LEN, SecretValue

from komira_secret_env import EnvSecretStore, MapEnv


def _value_equals(v: SecretValue, want: String) -> Bool:
    """Whole-object equality: the length and every byte."""
    var got = v.revealed_bytes()
    var w = want.as_bytes()
    if v.len() != len(w) or len(got) != len(w):
        return False
    for i in range(len(w)):
        if got[i] != w[i]:
            return False
    return True


def _lookup(mut env: MapEnv, name: String) -> String:
    """`env.lookup(name)` as text: "<none>", "=<bytes>" or "!<message>"."""
    try:
        var got = env.lookup(name)
        if not got:
            return String("<none>")
        var v = got.take()
        var b = v.revealed_bytes()
        return String("=") + String(unsafe_from_utf8=b)
    except e:
        return String("!") + String(e)


def _resolve(mut store: EnvSecretStore[MapEnv], name: String) -> String:
    """`store.resolve(name)` as text: "=<bytes>" or "!<message>"."""
    try:
        var v = store.resolve(name)
        var b = v.revealed_bytes()
        return String("=") + String(unsafe_from_utf8=b)
    except e:
        return String("!") + String(e)


def test_grid_every_fixture_through_every_checker() raises:
    var long_value = String("q") * (MAX_SECRET_LEN + 1)
    var max_value = String("q") * MAX_SECRET_LEN
    var names: List[String] = ["V_UNSET", "V_0", "V_1", "V_2", "V_MAX", "V_LONG"]
    var values: List[String] = ["", "", "a", "b2", max_value, long_value]
    var too_long = String("SecretValue: value exceeds MAX_SECRET_LEN (got ") + String(
        MAX_SECRET_LEN + 1
    ) + " bytes)"
    var want_lookup: List[String] = [
        "<none>",
        "=",
        "=a",
        "=b2",
        String("=") + max_value,
        String("!") + too_long,
    ]
    var want_resolve: List[String] = [
        "!EnvSecretStore: environment variable V_UNSET is not set",
        "!EnvSecretStore: environment variable V_0 is set but empty",
        "=a",
        "=b2",
        String("=") + max_value,
        String("!EnvSecretStore: environment variable V_LONG: ") + too_long,
    ]

    var env = MapEnv()
    for i in range(1, len(names)):
        env.set(names[i], values[i])
    var probe = env.share()
    var store = EnvSecretStore[MapEnv](env^)

    var calls = 0
    for i in range(len(names)):
        assert_equal(_lookup(probe, names[i]), want_lookup[i], names[i])
        calls += 1
        assert_equal(probe.lookup_count(), calls, names[i])
        assert_equal(_resolve(store, names[i]), want_resolve[i], names[i])
        calls += 1
        assert_equal(probe.lookup_count(), calls, names[i])


def test_whole_value_is_returned() raises:
    var env = MapEnv()
    env.set("K", "données=1")
    var store = EnvSecretStore[MapEnv](env^)
    var v = store.resolve("K")
    assert_equal(v.len(), 10)
    assert_true(_value_equals(v, "données=1"))
    assert_false(_value_equals(v, "données=2"))
    assert_false(_value_equals(v, "données="))


def test_set_overwrites() raises:
    var env = MapEnv()
    env.set("K", "first-longer")
    env.set("K", "2nd")
    assert_equal(_lookup(env, "K"), "=2nd")
    env.set("K", "")
    assert_equal(_lookup(env, "K"), "=")


def test_unset_absent_is_a_noop_and_present_removes_only_it() raises:
    var env = MapEnv()
    env.set("KEEP", "k")
    env.set("DROP", "d")
    env.unset("NEVER_SET")
    assert_equal(_lookup(env, "KEEP"), "=k")
    assert_equal(_lookup(env, "DROP"), "=d")
    env.unset("DROP")
    assert_equal(_lookup(env, "DROP"), "<none>")
    assert_equal(_lookup(env, "KEEP"), "=k")
    env.unset("DROP")
    assert_equal(_lookup(env, "DROP"), "<none>")
    assert_equal(env.lookup_count(), 5)


def test_a_fresh_map_is_empty_and_independent() raises:
    var a = MapEnv()
    var b = MapEnv()
    a.set("X", "1")
    assert_equal(a.lookup_count(), 0)
    assert_equal(_lookup(b, "X"), "<none>")
    assert_equal(a.lookup_count(), 0, "b's lookup is not counted on a")
    assert_equal(b.lookup_count(), 1)


def test_grammar_refusal_message_through_the_store() raises:
    var env = MapEnv()
    var probe = env.share()
    var store = EnvSecretStore[MapEnv](env^)
    assert_equal(
        _resolve(store, ""), "!EnvSecretStore: secret env name is empty"
    )
    assert_equal(
        _resolve(store, "A=B"),
        "!EnvSecretStore: secret env name (3 bytes) is not an environment"
        " variable name: byte 1 is outside [A-Za-z_][A-Za-z0-9_]*",
    )
    assert_equal(
        _resolve(store, String("A") * 129),
        "!EnvSecretStore: secret env name is 129 bytes; the limit is 128"
        " (a handle names a variable, it is not a value)",
    )
    assert_equal(probe.lookup_count(), 0)


def main() raises:
    test_grid_every_fixture_through_every_checker()
    test_whole_value_is_returned()
    test_set_overwrites()
    test_unset_absent_is_a_noop_and_present_removes_only_it()
    test_a_fresh_map_is_empty_and_independent()
    test_grammar_refusal_message_through_the_store()
    print("PASS test_map_env_grid")
