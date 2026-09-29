# Always red: the env fixtures (env_held, env_bin) must stay red whatever the
# test's declared environment names.


def main() raises:
    raise Error("test_red: DELIBERATE FAILURE (a test runtime contract fixture)")
