from kflib import answer


def main() raises:
    if answer() == 42:
        raise Error("test_fails_too: DELIBERATE FAILURE (a tests_known_failing fixture)")
