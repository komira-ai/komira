# Calls a function of a written source (plain.mojo) and one of a generated
# source (gen.mojo): the coverage run's report has the first and not the
# second (test 43).
from covgen import half, twice
from std.testing import assert_equal


def main() raises:
    assert_equal(half(8), 4, "half of 8")
    assert_equal(twice(4), 8, "twice 4")
