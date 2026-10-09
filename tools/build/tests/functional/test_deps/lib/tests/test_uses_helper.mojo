# A welded test of tdlib that imports the test-support package tdhelper,
# which reaches it only through tdlib's `test_deps`.
from std.testing import assert_equal

from tdhelper import helper_answer
from tdlib import lib_value


def main() raises:
    assert_equal(lib_value() * 6, helper_answer())
    print("OK")
