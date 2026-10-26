# =============================================================================
# The route ledger and the scan-binding wiring that is checked against it
# =============================================================================
#
# `plan_validation_routes` is the list of terminal execution routes and what
# the plan validation gate does about each; `scan_binding_gate_wiring` runs the
# scan-binding gate at a route and refuses a route the ledger does not name.
# Nothing else in this package drives them directly, so this file does.
#
#   1. `ledger_self_check` accepts the shipped ledger, and
#      `ledger_self_check_rows` refuses each way a ledger can contradict
#      itself: empty, an unknown status, a row with no note, an UNCOVERED row
#      that carries a token or does not say what closes it, a wired row with no
#      token, a duplicate token, and a COVERED row that names no guard test.
#   2. Every token a wiring site passes finds its own row, each in a distinct
#      row; an unknown token, an empty token and a retired route's token find
#      none.
#   3. An UNCOVERED row carries no entry token and says what closes it, so an
#      unwired route cannot present a token and pass as wired.
#   4. `pv_status_name` names every status and an unknown one by its number.
#   5. The wiring raises on an unregistered entry token before it looks at the
#      plan, counts a bound leaf under a registered token, and refuses a
#      handle from another registry's epoch on both entry points.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_SCAN
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_HANDLE_UNBOUND,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import (
    UnboundScanResolver,
    SCAN_BINDING_EPOCH_MISMATCH,
)
from komira_scan_source.source_variant import SourceVariant

from komira_sdk_exec.plan_validation_routes import (
    PV_ENTRY_INMEM_AGG_PLAN,
    PV_ENTRY_INMEM_PLAN,
    PV_ENTRY_OPTIMIZE_FULL,
    PV_ENTRY_OPTIMIZE_FULL_CTE,
    PV_ENTRY_PREPARE_PLAN,
    PV_ENTRY_ROW_PLAN,
    PV_ENTRY_SINGLE_FS_CLOUD_PLAN,
    PV_ENTRY_TEST_HARNESS,
    PV_ROUTE_COVERED,
    PV_ROUTE_TEST_HARNESS,
    PV_ROUTE_UNCOVERED,
    PV_ROUTE_WIRED_UNPROVEN,
    PlanValidationRoute,
    ledger_self_check,
    ledger_self_check_rows,
    plan_validation_routes,
    pv_status_name,
    route_index_for_entry,
)
from komira_sdk_exec.scan_binding_gate_wiring import (
    check_scan_bindings_at_entry,
    check_scan_bindings_at_entry_unbound,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    return sb.build()


def _bound_leaf(handle: Int) raises -> LogicalPlan:
    """A binding-backed scan leaf holding `handle`, minted under epoch 9."""
    var binding = ScanBinding(
        kind_id=scan_kind_id(String("example.ledger.kind")),
        kind_name=String("example.ledger.kind"),
        name=String("leaf"),
        params=ScanParams(),
        schema=_schema(),
        fingerprint=UInt64(1),
        structural_id=UInt64(1),
        gate=PushdownGate.reject_all(),
        handle=handle,
        registry_epoch=UInt64(9),
    )
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(binding^), _schema()
    )


def _wired_tokens() -> List[String]:
    var out = List[String]()
    out.append(String(PV_ENTRY_PREPARE_PLAN))
    out.append(String(PV_ENTRY_OPTIMIZE_FULL))
    out.append(String(PV_ENTRY_OPTIMIZE_FULL_CTE))
    out.append(String(PV_ENTRY_ROW_PLAN))
    out.append(String(PV_ENTRY_SINGLE_FS_CLOUD_PLAN))
    out.append(String(PV_ENTRY_INMEM_PLAN))
    out.append(String(PV_ENTRY_INMEM_AGG_PLAN))
    out.append(String(PV_ENTRY_TEST_HARNESS))
    return out^


def test_the_shipped_ledger_passes_its_self_check() raises:
    ledger_self_check()


def _row(
    entry: String, status: UInt8, note: String, guard: String
) -> PlanValidationRoute:
    return PlanValidationRoute(String("a route"), entry, status, note, guard)


def _good_rows() -> List[PlanValidationRoute]:
    var rows = List[PlanValidationRoute]()
    rows.append(
        _row(String("tok-a"), PV_ROUTE_COVERED, String("why"), String("a test"))
    )
    rows.append(
        _row(String("tok-b"), PV_ROUTE_WIRED_UNPROVEN, String("why"), String(""))
    )
    rows.append(
        _row(
            String(""),
            PV_ROUTE_UNCOVERED,
            String("not wired. Closes when: it is."),
            String(""),
        )
    )
    return rows^


def test_a_well_formed_ledger_passes_the_rows_check() raises:
    ledger_self_check_rows(_good_rows())


def test_an_empty_ledger_is_refused() raises:
    with assert_raises(contains="empty"):
        ledger_self_check_rows(List[PlanValidationRoute]())


def test_an_unknown_status_is_refused() raises:
    var rows = _good_rows()
    rows.append(_row(String("tok-c"), UInt8(77), String("why"), String("")))
    with assert_raises(contains="unknown status 77"):
        ledger_self_check_rows(rows)


def test_a_row_with_no_note_is_refused() raises:
    var rows = _good_rows()
    rows.append(
        _row(String("tok-c"), PV_ROUTE_WIRED_UNPROVEN, String(""), String(""))
    )
    with assert_raises(contains="must say WHY"):
        ledger_self_check_rows(rows)


def test_an_uncovered_row_with_a_token_is_refused() raises:
    var rows = _good_rows()
    rows.append(
        _row(
            String("tok-c"),
            PV_ROUTE_UNCOVERED,
            String("Closes when: x"),
            String(""),
        )
    )
    with assert_raises(contains="must not carry an entry token"):
        ledger_self_check_rows(rows)


def test_an_uncovered_row_that_does_not_say_what_closes_it_is_refused() raises:
    var rows = _good_rows()
    rows.append(
        _row(String(""), PV_ROUTE_UNCOVERED, String("later"), String(""))
    )
    with assert_raises(contains="must say what will close it"):
        ledger_self_check_rows(rows)


def test_a_wired_row_with_no_token_is_refused() raises:
    var rows = _good_rows()
    rows.append(
        _row(String(""), PV_ROUTE_WIRED_UNPROVEN, String("why"), String(""))
    )
    with assert_raises(contains="must carry the entry token"):
        ledger_self_check_rows(rows)


def test_a_duplicate_token_is_refused() raises:
    var rows = _good_rows()
    rows.append(
        _row(String("tok-a"), PV_ROUTE_WIRED_UNPROVEN, String("why"), String(""))
    )
    with assert_raises(contains="duplicate entry token 'tok-a'"):
        ledger_self_check_rows(rows)


def test_a_covered_row_with_no_guard_is_refused() raises:
    var rows = _good_rows()
    rows.append(
        _row(String("tok-c"), PV_ROUTE_COVERED, String("why"), String(""))
    )
    with assert_raises(contains="must name the test"):
        ledger_self_check_rows(rows)


def test_every_wired_token_finds_its_own_distinct_row() raises:
    var rows = plan_validation_routes()
    var tokens = _wired_tokens()
    var seen = List[Int]()
    for i in range(len(tokens)):
        var idx = route_index_for_entry(tokens[i])
        assert_true(idx >= 0, "no row for " + tokens[i])
        assert_equal(rows[idx].entry, tokens[i])
        for j in range(len(seen)):
            assert_true(seen[j] != idx, "two tokens share a row: " + tokens[i])
        seen.append(idx)


def test_unknown_empty_and_retired_tokens_find_no_row() raises:
    assert_equal(route_index_for_entry(String("no-such-route")), -1)
    assert_equal(route_index_for_entry(String("")), -1)
    # A route the ledger does not carry: its token must not resolve.
    assert_equal(
        route_index_for_entry(String("EngineContext.materialize_cloud_plan")),
        -1,
    )
    # A token is matched whole, not by prefix.
    assert_equal(
        route_index_for_entry(String("EngineContext.optimize_full(")), -1
    )


def test_an_uncovered_row_has_no_token_and_says_what_closes_it() raises:
    var rows = plan_validation_routes()
    var uncovered = 0
    for i in range(len(rows)):
        if rows[i].status == PV_ROUTE_UNCOVERED:
            uncovered += 1
            assert_equal(rows[i].entry.byte_length(), 0)
            assert_true(rows[i].note.find(String("Closes when:")) >= 0)
        else:
            assert_true(rows[i].entry.byte_length() > 0)
        if rows[i].status == PV_ROUTE_COVERED:
            assert_true(rows[i].guard.byte_length() > 0)
    assert_true(uncovered > 0)


def test_status_names() raises:
    assert_equal(pv_status_name(PV_ROUTE_COVERED), String("COVERED"))
    assert_equal(
        pv_status_name(PV_ROUTE_WIRED_UNPROVEN), String("WIRED_UNPROVEN")
    )
    assert_equal(pv_status_name(PV_ROUTE_UNCOVERED), String("UNCOVERED"))
    assert_equal(
        pv_status_name(PV_ROUTE_TEST_HARNESS), String("TEST_HARNESS")
    )
    assert_equal(pv_status_name(UInt8(9)), String("UNKNOWN(9)"))


def test_the_wiring_refuses_an_unregistered_token_before_the_plan() raises:
    var plan = _bound_leaf(3)
    with assert_raises(
        contains="unregistered entry token 'no-such-route'"
    ):
        _ = check_scan_bindings_at_entry(
            UnboundScanResolver(), plan, "no-such-route"
        )
    with assert_raises(contains="unregistered entry token ''"):
        _ = check_scan_bindings_at_entry_unbound(plan, "")


def test_the_wiring_counts_a_bound_leaf_under_a_registered_token() raises:
    var unbound_handle = _bound_leaf(SCAN_HANDLE_UNBOUND)
    assert_equal(
        check_scan_bindings_at_entry(
            UnboundScanResolver(), unbound_handle, PV_ENTRY_OPTIMIZE_FULL
        ),
        1,
    )
    assert_equal(
        check_scan_bindings_at_entry_unbound(
            unbound_handle, PV_ENTRY_INMEM_PLAN
        ),
        1,
    )
    var empty = LogicalPlan(PLAN_SCAN, _schema())
    assert_equal(
        check_scan_bindings_at_entry_unbound(empty, PV_ENTRY_TEST_HARNESS), 0
    )


def test_the_wiring_refuses_a_handle_from_another_epoch() raises:
    var minted_elsewhere = _bound_leaf(3)
    with assert_raises(contains=String(SCAN_BINDING_EPOCH_MISMATCH)):
        _ = check_scan_bindings_at_entry(
            UnboundScanResolver(), minted_elsewhere, PV_ENTRY_PREPARE_PLAN
        )
    with assert_raises(contains=String(SCAN_BINDING_EPOCH_MISMATCH)):
        _ = check_scan_bindings_at_entry_unbound(
            minted_elsewhere, PV_ENTRY_INMEM_AGG_PLAN
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
