# Declared as a list entry, so staged at its path from the cell root; the
# current directory is share/, so that path opens as written.
from std.testing import assert_equal
from tdlib import answer


def main() raises:
    with open("functional/test_data/fixtures/declared.txt", "r") as f:
        assert_equal(f.read(), "declared bytes\n")
    assert_equal(answer(), 7)
    print("test_reads_declared: PASS")
