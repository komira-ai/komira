# =============================================================================
# test_suite_failures.mojo -- run_crm_suite on a target that fails every
#   check.
# =============================================================================
#
# The other tests show the suite passing on a working backend; this one shows
# it can fail. `BrokenTarget.fresh()` raises, so every check fails at its
# first step: the suite must still run all twelve (the target says it is
# transactional, so the feed check runs too), raise, and name each one as
# `FAIL <check> on <target>: <error>`. Catches a check whose failure is
# dropped, a check name copied from its neighbour, and a suite that passes
# with failures recorded.
# =============================================================================

from std.testing import assert_equal

from komira_db_sqlite import SqliteDatabase

from komira_crm_store_conformance import CrmTarget, run_crm_suite


struct BrokenTarget(CrmTarget):
    comptime DB = SqliteDatabase

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("broken")

    def transactional(self) -> Bool:
        return True

    def fresh(mut self) raises -> SqliteDatabase:
        raise Error("no database")


def _line(check: StaticString) -> String:
    return String("FAIL ") + String(check) + String(" on broken: no database\n")


def main() raises:
    var want = String()
    want += _line("dataset_init")
    want += _line("external_id_per_kind")
    want += _line("org_card_not_unique")
    want += _line("version_cas")
    want += _line("orphan_row_hidden")
    want += _line("field_key_per_kind")
    want += _line("system_activity")
    want += _line("account_links")
    want += _line("archive_hides")
    want += _line("money_refused")
    want += _line("erasure")
    want += _line("feed_sequence")
    var got = String("the suite passed")
    var target = BrokenTarget()
    try:
        run_crm_suite(target)
    except e:
        got = String(e)
    assert_equal(got, want, "every check fails, each named once, in order")
    print("PASS komira_crm_store_conformance suite failures")
