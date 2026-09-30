# Reads a file that exists in the repository next to the declared one but is
# not declared. The staged tree does not hold it, so the open raises and the
# gate goes red (tests//negative/test_data:undeclared must FAIL).
from std.testing import assert_equal


def main() raises:
    with open("negative/test_data/fixtures/declared.txt", "r") as f:
        assert_equal(f.read(), "declared bytes\n")
    with open("negative/test_data/fixtures/undeclared.txt", "r") as f:
        print("UNDECLARED FILE WAS READABLE:", f.read())
