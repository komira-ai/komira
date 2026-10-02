"""fx_notests_user: a library with one dependency, a fixture of tests//negative/conda."""

from fx_notests import fx_notests_value


def fx_notests_user_value() -> Int:
    return fx_notests_value() + 1
