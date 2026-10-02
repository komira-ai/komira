"""fx_renamed_user: a library with one dependency, a fixture of tests//negative/conda."""

from fx_renamed import fx_renamed_value


def fx_renamed_user_value() -> Int:
    return fx_renamed_value() + 1
