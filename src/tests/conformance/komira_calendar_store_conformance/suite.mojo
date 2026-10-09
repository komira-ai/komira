# =============================================================================
# komira_calendar_store_conformance/suite.mojo -- run every check, then one
#   verdict.
# =============================================================================
#
# Every check runs even when an earlier one fails, so one log names every
# failure: each as `FAIL <check> on <target>: <error>`, and the suite raises
# with all of them.
# =============================================================================

from .checks import (
    check_erasure_closed_world,
    check_feed,
    check_if_match,
    check_override_window,
    check_restart,
    check_uid_unique,
    check_window_open_series,
)
from .targets import CalendarTarget


def _fail(mut failures: String, check: StaticString, target: String, e: Error):
    failures += "FAIL " + String(check) + " on " + target + ": " + String(e) + "\n"


def run_calendar_suite[T: CalendarTarget](mut t: T) raises:
    var who = t.name()
    var failures = String()
    var passed = 0
    try:
        check_erasure_closed_world[T](t)
        passed += 1
    except e:
        _fail(failures, "erasure_closed_world", who, e)
    try:
        check_window_open_series[T](t)
        passed += 1
    except e:
        _fail(failures, "window_open_series", who, e)
    try:
        check_override_window[T](t)
        passed += 1
    except e:
        _fail(failures, "override_window", who, e)
    try:
        check_feed[T](t)
        passed += 1
    except e:
        _fail(failures, "feed", who, e)
    try:
        check_if_match[T](t)
        passed += 1
    except e:
        _fail(failures, "if_match", who, e)
    try:
        check_uid_unique[T](t)
        passed += 1
    except e:
        _fail(failures, "uid_unique", who, e)
    try:
        check_restart[T](t)
        passed += 1
    except e:
        _fail(failures, "restart", who, e)
    if failures.byte_length() > 0:
        raise Error(failures)
    print("komira_calendar_store_conformance: " + String(passed) + " checks passed on " + who)
