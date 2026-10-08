# Test 47: assert_equal on two known equal values. Its failure path, which
# writes both (for a Tag, branchlib's Tag.write_to), is a branch the
# compiler folds to never taken, so the instrumented link drops what only
# that path calls, Tag.write_to among them, with their counters, and the
# run's profile holds no record of them.
from branchlib import Tag
from std.testing import assert_equal

comptime SEVEN: UInt8 = 7


def main() raises:
    assert_equal(Tag(SEVEN), Tag(7))
    assert_equal(Int(SEVEN), 7)
