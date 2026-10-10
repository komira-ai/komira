# A library source importing its own test-support package, which reaches
# the tests only: the compile fails.
from tdhelper import helper_answer


def value() -> Int:
    return helper_answer()
