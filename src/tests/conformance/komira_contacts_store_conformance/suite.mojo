# =============================================================================
# komira_contacts_store_conformance/suite.mojo -- run every check, then one
#   verdict.
# =============================================================================
#
# Every check runs even when an earlier one fails, so one log names every
# failure: each as `FAIL <check> on <target>: <error>`, and the suite raises
# with all of them.
# =============================================================================

from komira_contacts_store_conformance.checks import (
    check_card_round_trip,
    check_changes_feed,
    check_default_book,
    check_idor_personal_book,
    check_refused_write_moves_nothing,
    check_shared_book_rules,
    check_stale_default_claim,
    check_stale_uid_key,
    check_uid_unique_per_book,
    check_version_cas,
)
from komira_contacts_store_conformance.targets import ContactsTarget


def _fail(mut failures: String, check: StaticString, target: String, e: Error):
    failures += String("FAIL ") + String(check) + String(" on ") + target + String(": ") + String(e) + String("\n")


def run_contacts_suite[T: ContactsTarget](mut t: T) raises:
    var who = t.name()
    var failures = String()
    var passed = 0
    try:
        check_uid_unique_per_book[T](t)
        passed += 1
    except e:
        _fail(failures, "uid_unique_per_book", who, e)
    try:
        check_version_cas[T](t)
        passed += 1
    except e:
        _fail(failures, "version_cas", who, e)
    try:
        check_changes_feed[T](t)
        passed += 1
    except e:
        _fail(failures, "changes_feed", who, e)
    try:
        check_refused_write_moves_nothing[T](t)
        passed += 1
    except e:
        _fail(failures, "refused_write_moves_nothing", who, e)
    try:
        check_idor_personal_book[T](t)
        passed += 1
    except e:
        _fail(failures, "idor_personal_book", who, e)
    try:
        check_shared_book_rules[T](t)
        passed += 1
    except e:
        _fail(failures, "shared_book_rules", who, e)
    try:
        check_default_book[T](t)
        passed += 1
    except e:
        _fail(failures, "default_book", who, e)
    try:
        check_card_round_trip[T](t)
        passed += 1
    except e:
        _fail(failures, "card_round_trip", who, e)
    try:
        check_stale_uid_key[T](t)
        passed += 1
    except e:
        _fail(failures, "stale_uid_key", who, e)
    try:
        check_stale_default_claim[T](t)
        passed += 1
    except e:
        _fail(failures, "stale_default_claim", who, e)
    if failures.byte_length() > 0:
        raise Error(failures)
    print(String("komira_contacts_store_conformance: ") + String(passed) + String(" checks passed on ") + who)
