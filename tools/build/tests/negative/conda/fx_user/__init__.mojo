"""fx_user: a library with one dependency, a fixture of tests//negative/conda."""

from fx_plain import fx_plain_value


def fx_user_value() -> Int:
    return fx_plain_value() + 1
