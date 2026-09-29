# A mojo_test (run by `buck2 test` through the gate runner) with a dict `data`
# entry and an env value.
from std.os import getenv
from std.os.path import exists
from std.testing import assert_equal, assert_false


def main() raises:
    with open("staged/as.txt", "r") as f:
        assert_equal(f.read(), "declared bytes\n")
    assert_false(exists("negative/test_data/fixtures/undeclared.txt"))
    assert_false(exists("negative/test_data/fixtures/declared.txt"))
    assert_equal(getenv("TD_MODE"), "mojo_test")
    print("test_mojo_test_data: PASS")
