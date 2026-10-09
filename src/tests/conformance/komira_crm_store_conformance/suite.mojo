# =============================================================================
# komira_crm_store_conformance/suite.mojo -- run every check, then one
#   verdict.
# =============================================================================
#
# Every check runs even when an earlier one fails, so one log names every
# failure: each as `FAIL <check> on <target>: <error>`, and the suite raises
# with all of them. `feed_sequence` runs only on a transactional target.
# =============================================================================

from komira_crm_store_conformance.checks import (
    check_dataset_init,
    check_external_id_per_kind,
    check_org_card_not_unique,
    check_version_cas,
    check_orphan_row_hidden,
    check_field_key_per_kind,
    check_system_activity,
    check_account_links,
    check_archive_hides,
    check_money_refused,
    check_erasure,
    check_feed_sequence,
)
from komira_crm_store_conformance.targets import CrmTarget


def _fail(mut failures: String, check: StaticString, target: String, e: Error):
    failures += String("FAIL ") + String(check) + String(" on ") + target + String(": ") + String(e) + String("\n")


def run_crm_suite[T: CrmTarget](mut t: T) raises:
    var who = t.name()
    var failures = String()
    var passed = 0
    try:
        check_dataset_init[T](t)
        passed += 1
    except e:
        _fail(failures, "dataset_init", who, e)
    try:
        check_external_id_per_kind[T](t)
        passed += 1
    except e:
        _fail(failures, "external_id_per_kind", who, e)
    try:
        check_org_card_not_unique[T](t)
        passed += 1
    except e:
        _fail(failures, "org_card_not_unique", who, e)
    try:
        check_version_cas[T](t)
        passed += 1
    except e:
        _fail(failures, "version_cas", who, e)
    try:
        check_orphan_row_hidden[T](t)
        passed += 1
    except e:
        _fail(failures, "orphan_row_hidden", who, e)
    try:
        check_field_key_per_kind[T](t)
        passed += 1
    except e:
        _fail(failures, "field_key_per_kind", who, e)
    try:
        check_system_activity[T](t)
        passed += 1
    except e:
        _fail(failures, "system_activity", who, e)
    try:
        check_account_links[T](t)
        passed += 1
    except e:
        _fail(failures, "account_links", who, e)
    try:
        check_archive_hides[T](t)
        passed += 1
    except e:
        _fail(failures, "archive_hides", who, e)
    try:
        check_money_refused[T](t)
        passed += 1
    except e:
        _fail(failures, "money_refused", who, e)
    try:
        check_erasure[T](t)
        passed += 1
    except e:
        _fail(failures, "erasure", who, e)
    if t.transactional():
        try:
            check_feed_sequence[T](t)
            passed += 1
        except e:
            _fail(failures, "feed_sequence", who, e)
    if failures.byte_length() > 0:
        raise Error(failures)
    print(String("komira_crm_store_conformance: ") + String(passed) + String(" checks passed on ") + who)
