# =============================================================================
# test_suite_failures.mojo -- run_contacts_suite on a target that fails every
#   check.
# =============================================================================
#
# The other tests show the suite passing on a working backend; this one shows
# it can fail. `BrokenTarget.fresh()` raises, so every check fails at its
# first step: the suite must still run all ten, raise, and name each one as
# `FAIL <check> on <target>: <error>`. Catches a check whose failure is
# dropped (a missing `_fail`), a check name copied from its neighbour, and a
# suite that passes with failures recorded.
# =============================================================================

from std.testing import assert_equal

from komira_db_sqlite import SqliteDatabase

from komira_contacts_store_conformance import ContactsTarget, run_contacts_suite


struct BrokenTarget(ContactsTarget):
    comptime DB = SqliteDatabase

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("broken")

    def fresh(mut self) raises -> SqliteDatabase:
        raise Error("no database")


def _line(check: StaticString) -> String:
    return String("FAIL ") + String(check) + String(" on broken: no database\n")


def main() raises:
    var want = String()
    want += _line("uid_unique_per_book")
    want += _line("version_cas")
    want += _line("changes_feed")
    want += _line("refused_write_moves_nothing")
    want += _line("idor_personal_book")
    want += _line("shared_book_rules")
    want += _line("default_book")
    want += _line("card_round_trip")
    want += _line("stale_uid_key")
    want += _line("stale_default_claim")
    var got = String("the suite passed")
    var target = BrokenTarget()
    try:
        run_contacts_suite(target)
    except e:
        got = String(e)
    assert_equal(got, want, "every check fails, each named once, in order")
    print("PASS komira_contacts_store_conformance suite failures")
