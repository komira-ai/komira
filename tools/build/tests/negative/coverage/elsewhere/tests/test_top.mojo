# A welded test in a tests/ directory that is not the package's own (as
# src/komira_db_postgres/wire/tests/): the gate names it to covcheck
# (--test-source), so its lines are not covtop's (test 46).
from covtop import top
from std.testing import assert_equal


def main() raises:
    var got = top()
    assert_equal(got, "top", "top")
