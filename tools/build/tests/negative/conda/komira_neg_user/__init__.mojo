"""komira_neg_user: a library with one dependency, a fixture of tests//negative/conda."""

from komira_neg_dep import komira_neg_dep_value


def komira_neg_user_value() -> Int:
    return komira_neg_dep_value() + 1
