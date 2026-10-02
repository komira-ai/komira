"""fx_optout_user: a library with one dependency, a fixture of tests//negative/conda."""

from fx_optout import fx_optout_value


def fx_optout_user_value() -> Int:
    return fx_optout_value() + 1
