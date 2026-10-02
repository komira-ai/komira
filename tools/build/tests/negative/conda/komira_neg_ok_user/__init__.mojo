"""komira_neg_ok_user: a library with one dependency, a fixture of tests//negative/conda."""

from komira_neg_listed import komira_neg_listed_value


def komira_neg_ok_user_value() -> Int:
    return komira_neg_listed_value() + 1
