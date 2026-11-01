# Calls a function of a written source (plain.mojo) and one of a source in the
# generated parts directory (_parts/part.mojo): the coverage run's report has
# the first and not the second.
from covparts import half, triple
from std.testing import assert_equal


def main() raises:
    assert_equal(half(8), 4, "half of 8")
    assert_equal(triple(4), 12, "triple 4")
