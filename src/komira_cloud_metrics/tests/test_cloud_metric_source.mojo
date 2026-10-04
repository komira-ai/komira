# =============================================================================
# tests/test_cloud_metric_source.mojo — ★ THE CLOUD-METRIC READ SEAM, made
#   falsifiable, on BOTH cloud arms, with ZERO network.
# =============================================================================
#
# ── ⛔ WHY A FALSIFIER FOR A PACKAGE NOTHING CALLS ──────────────────────────
# Precisely BECAUSE nothing calls it. A library with a consumer is exercised by
# that consumer's tests; a library without one is exercised by nothing at all,
# and the parts most worth pinning here are the parts a future consumer will
# assume rather than check — the EXACT BYTES of each request and the refusals
# that stop a query reading someone else's numbers.
#
# ⛔ AND THIS FILE DOES NOT PRETEND THERE IS A CONSUMER. It asserts shapes and
# refusals; it does not assert a gate verdict, because there is no gate. The
# argued case for that is `komira_cloud_metrics/__init__.mojo` §3.
#
# ── WHAT IS SILENT WHEN WRONG HERE (the five) ───────────────────────────────
#   1. ★★ GCP SENDS `int64Value` AS A JSON **STRING**. A parser that read only
#      `doubleValue`, or that scanned for a bare number, returns ZERO POINTS for
#      every INT64 metric — including `run.googleapis.com/request_count`, the
#      metric these tests use. ⛔ And "zero points" is ALSO the legitimate
#      answer for a fresh deploy, so the failure looks exactly like the thing
#      being measured. §3.
#   2. ★★ CLOUDWATCH SENDS `Timestamps` AND `Values` AS PARALLEL ARRAYS. Zipping
#      `min(n, m)` silently drops the tail AND keeps pairing the rest, so every
#      surviving point looks right. §6.
#   3. AN UNSCOPED FILTER. `metric.type="…"` with no service is syntactically
#      fine and returns EVERY service in the project — rendered under this
#      workload's name. §2.
#   4. A PARTIALLY-DIMENSIONED CLOUDWATCH QUERY. One dimension matches every
#      service of that name in every cluster. §5.
#   5. `StatusCode: "PartialData"` — a TRUNCATED computation inside an HTTP 200.
#      Taken at face value it says "the rate was fine" about a window nobody
#      measured. §7.
#
# Hermetic: pure functions + the in-library scripted double. No socket, no
# cloud, no sleep, no clock.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_cloud_metrics import (
    DEFAULT_METRIC_ALIGNER,
    DEFAULT_METRIC_ALIGNMENT_PERIOD,
    MONITORING_HOST,
    MetricPage,
    MetricPoint,
    MetricSeries,
    MetricWindow,
    NoCloudMetricSource,
    ScriptedCloudMetricSource,
    cloudwatch_metrics_host,
    ecs_service_cluster,
    ecs_service_name,
    get_metric_data_body,
    parse_get_metric_data_body,
    parse_timeseries_body,
    run_service_metric_filter,
    service_leaf,
    service_project,
    timeseries_path,
    timeseries_query,
)


comptime _SVC: String = (
    "projects/example-project/locations/us-south1/services/example-run-svc"
)
comptime _ECS_SVC: String = (
    "arn:aws:ecs:us-east-1:123456789012:service/example-cluster/example-ecs-svc"
)
comptime _METRIC: String = "run.googleapis.com/request_count"


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def _window() -> MetricWindow:
    return MetricWindow(
        String("2026-09-11T10:00:00Z"), String("2026-09-12T10:00:00Z")
    )


# =============================================================================
# §1 — THE HANDLE IS SELF-ADDRESSING (both clouds).
# =============================================================================
def test_the_handle_is_self_addressing_on_both_clouds() raises:
    """⭐ THE PROPERTY THE WHOLE SEAM RESTS ON, and `CloudLogSource`'s rule
    restated: a conformer DERIVES what it needs from the handle, so it cannot be
    configured with a project/region that DISAGREES with it. On a metric that
    matters more than on a log line — a wrong log line usually looks wrong, and
    a wrong number never does."""
    assert_equal(service_project(_SVC), String("example-project"))
    assert_equal(service_leaf(_SVC), String("example-run-svc"))
    assert_equal(
        timeseries_path(_SVC),
        String("/v3/projects/example-project/timeSeries"),
        "the path carries the project OUT OF THE HANDLE",
    )
    assert_equal(ecs_service_cluster(_ECS_SVC), String("example-cluster"))
    assert_equal(ecs_service_name(_ECS_SVC), String("example-ecs-svc"))
    assert_equal(
        MONITORING_HOST,
        String("monitoring.googleapis.com"),
        "GCP's monitoring host is GLOBAL…",
    )
    assert_equal(
        cloudwatch_metrics_host(String("us-east-1")),
        String("monitoring.us-east-1.amazonaws.com"),
        "…and AWS's is REGIONAL",
    )


def test_a_handle_that_is_not_one_yields_EMPTY_never_a_guess() raises:
    """⛔ EVERY REFUSAL IS EMPTY, NEVER A DEFAULT. A partially-derived query is
    SYNTACTICALLY FINE and returns somebody else's numbers.

    MUTATION: return the input, or a constant project, from any of these."""
    assert_equal(service_project(String("example-run-svc")), String(""))
    assert_equal(service_leaf(String("projects/p/locations/r")), String(""))
    assert_equal(timeseries_path(String("not-a-resource-name")), String(""))
    assert_equal(
        cloudwatch_metrics_host(String("")),
        String(""),
        "⛔ an empty region is an empty host, never `monitoring..amazonaws.com`",
    )


# =============================================================================
# §2 — THE GCP REQUEST: scoped, aggregated, and both are load-bearing.
# =============================================================================
def test_the_gcp_filter_is_SCOPED_to_one_service() raises:
    """⛔ AN UNSCOPED FILTER RETURNS EVERY SERVICE IN THE PROJECT, inside a 200,
    and the caller renders it under THIS workload's name.

    MUTATION: drop the `AND resource.labels.service_name=` clause."""
    var f = run_service_metric_filter(String(_METRIC), _SVC)
    assert_true(
        _contains(f, String('metric.type="run.googleapis.com/request_count"')),
        "the metric: " + f,
    )
    assert_true(
        _contains(f, String('resource.labels.service_name="example-run-svc"')),
        "⛔ and the SERVICE — without this it is every service: " + f,
    )
    assert_equal(
        run_service_metric_filter(String(_METRIC), String("bogus")),
        String(""),
        "⛔ a handle that names no service REFUSES rather than un-scoping",
    )
    assert_equal(
        run_service_metric_filter(String(""), _SVC),
        String(""),
        "⛔ and so does an unnamed metric",
    )


def test_the_gcp_query_is_SERVER_AGGREGATED_and_that_is_MEASURED() raises:
    """⛔⛔ THE AGGREGATION PARAMETERS ARE A MEASURED MITIGATION, NOT A SIZE
    PREFERENCE.

    MEASURED on Cloud Run: an unaggregated
    `timeSeries.list` over 24h returned 2,546,731 bytes and FAILED after ~279s
    inside a Cloud Run Job; the same code passed 12/12 under ~1.1 MB. Hourly
    ALIGN_SUM over the same window: the SAME 16 series, 53,772 bytes.

    MUTATION: drop either `aggregation.*` parameter. Nothing fails locally; the
    read fails in cloud, on a fixed budget, in the one environment an in-cloud
    validate step runs in."""
    var q = timeseries_query(run_service_metric_filter(String(_METRIC), _SVC), _window())
    assert_true(
        _contains(q, String("aggregation.alignmentPeriod=3600s")),
        "the alignment period rides: " + q,
    )
    assert_true(
        _contains(q, String("aggregation.perSeriesAligner=ALIGN_SUM")),
        "and the aligner: " + q,
    )
    assert_equal(
        DEFAULT_METRIC_ALIGNMENT_PERIOD, String("3600s"), "the pinned default"
    )
    assert_equal(DEFAULT_METRIC_ALIGNER, String("ALIGN_SUM"), "and the aligner")
    assert_true(
        _contains(q, String("interval.startTime=2026-09-11T10%3A00%3A00Z")),
        (
            "⛔ the window is PERCENT-ENCODED — an RFC3339 colon in a raw query"
            " string is a different parse: "
            + q
        ),
    )
    assert_true(
        _contains(q, String("metric.type%3D%22")),
        "…and so is the filter's own punctuation: " + q,
    )


def test_an_UNBOUNDED_window_is_REFUSED_at_the_query() raises:
    """⛔ EMPTY, NOT AN OPEN-ENDED READ. An unbounded `timeSeries.list` is
    precisely the request that returned 2.5 MB and stalled.

    MUTATION: drop the `window.ok()` guard."""
    assert_equal(
        timeseries_query(
            run_service_metric_filter(String(_METRIC), _SVC),
            MetricWindow(String(""), String("2026-09-12T10:00:00Z")),
        ),
        String(""),
        "no start",
    )
    assert_equal(
        timeseries_query(String(""), _window()),
        String(""),
        "⛔ and an EMPTY FILTER is refused too — it would read the whole project",
    )


# =============================================================================
# §3 — ★★ THE GCP PARSE: `int64Value` IS A JSON STRING.
# =============================================================================
def test_an_int64_metric_parses_even_though_its_value_is_QUOTED() raises:
    """★★ THE HEADLINE OF THIS FILE.

    `int64Value` is a JSON STRING — the proto3-JSON mapping for int64, not a
    quirk of one metric. A parser that read only `doubleValue`, or that scanned
    for a bare number, returns ZERO POINTS for `request_count` — and zero points
    is ALSO the legitimate answer for a freshly deployed service, so the bug
    looks exactly like the thing it is measuring.

    MUTATION: drop the `int64Value` arm from `_parse_value`."""
    var body = String(
        '{"timeSeries":[{"metric":{"type":"run.googleapis.com/request_count",'
        '"labels":{"response_code":"200"}},'
        '"resource":{"type":"cloud_run_revision","labels":{"project_id":"p"}},'
        '"points":[{"interval":{"startTime":"2026-09-12T09:00:00Z",'
        '"endTime":"2026-09-12T10:00:00Z"},"value":{"int64Value":"42"}}]}]}'
    )
    var page = parse_timeseries_body(body)
    assert_true(page.ok(), "a well-formed body parses: " + page.fault)
    assert_equal(len(page.series), 1, "one series")
    assert_equal(page.point_count(), 1, "⛔ carrying ONE point, not zero")
    assert_equal(
        page.series[0].points[0].value,
        Float64(42),
        "⛔ and the QUOTED int64 became the value",
    )
    assert_equal(
        page.series[0].points[0].end_time,
        String("2026-09-12T10:00:00Z"),
        "the bucket END, verbatim as the provider spelled it",
    )


def test_a_double_valued_metric_parses_too_and_keeps_its_fraction() raises:
    """The other half of the same arm. ⚠ `json_scan_number` (the log package's)
    stops at a `.`, which is why this package has its own scalar scanner: a
    latency metric read through the integer scanner is `0` for every value under
    one second."""
    var body = String(
        '{"timeSeries":[{"metric":{"type":"run.googleapis.com/request_latencies"},'
        '"points":[{"interval":{"endTime":"2026-09-12T10:00:00Z"},'
        '"value":{"doubleValue":0.125}}]}]}'
    )
    var page = parse_timeseries_body(body)
    assert_true(page.ok(), "parses: " + page.fault)
    assert_equal(
        page.series[0].points[0].value,
        Float64(0.125),
        "⛔ the FRACTION survived — an integer scanner returns 0 here",
    )


def test_a_field_nobody_listed_cannot_reach_the_page() raises:
    """⛔ THE ALLOW-LIST IS THE SECURITY BOUNDARY. `resource.labels` is a
    free-form map the emitting service controls; it is OFF the list, so nothing
    in it can be rendered by any consumer of this page.

    MUTATION: add a `resource` arm to `_parse_series`."""
    var body = String(
        '{"timeSeries":[{"metric":{"type":"m","labels":{"response_code":"500"}},'
        '"resource":{"type":"cloud_run_revision","labels":'
        '{"project_id":"secret-project","revision_name":"ya29-looking-thing"}},'
        '"points":[{"interval":{"endTime":"T"},"value":{"int64Value":"1"}}]}]}'
    )
    var page = parse_timeseries_body(body)
    assert_true(page.ok(), "parses: " + page.fault)
    assert_false(
        _contains(page.series[0].label_summary, String("secret-project")),
        "⛔ a resource label cannot print itself: " + page.series[0].label_summary,
    )
    assert_false(
        _contains(page.series[0].label_summary, String("ya29-looking-thing")),
        "⛔ nor can a revision name: " + page.series[0].label_summary,
    )
    assert_true(
        _contains(page.series[0].label_summary, String("response_code=500")),
        "…while the METRIC label, which IS listed, survives: "
        + page.series[0].label_summary,
    )


def test_an_EMPTY_window_is_an_ANSWER_not_a_fault() raises:
    """⛔⛔ THE ASSERTION THAT KEEPS A FUTURE CONSUMER HONEST. An empty result
    means "no points have ARRIVED YET", which on Cloud Run is the NORMAL state
    for ~26 minutes after a deploy (measured on Cloud Run). A caller that
    reads it as unhealthy has built a clock, not a gate."""
    var page = parse_timeseries_body(String('{"timeSeries":[]}'))
    assert_true(page.ok(), "⛔ empty is an ANSWER: " + page.fault)
    assert_equal(page.point_count(), 0, "with nothing in it")
    var absent = parse_timeseries_body(String("{}"))
    assert_true(absent.ok(), "…and so is an ABSENT key")


def test_a_malformed_gcp_body_is_reported_WITHOUT_echoing_it() raises:
    """⛔ A 4xx/malformed body from an auth-adjacent API is exactly the body that
    carries material. Byte count and position; never bytes the server chose."""
    var page = parse_timeseries_body(
        String('{"timeSeries":{"not":"an array"},"token":"ya29.SECRET"}')
    )
    assert_false(page.ok(), "a non-array `timeSeries` is a FAULT")
    assert_false(
        _contains(page.fault, String("ya29.SECRET")),
        "⛔ and the body is NOT echoed: " + page.fault,
    )
    assert_true(
        _contains(page.fault, String("NOT echoed")), "…and it says so"
    )


# =============================================================================
# §4 — THE NOT-CONFIGURED DEFAULT + THE DOUBLE.
# =============================================================================
def test_the_not_configured_source_REFUSES_rather_than_answering_empty() raises:
    """⛔ AN EMPTY PAGE AND A MISSING WIRING ARE DIFFERENT FACTS, and on this
    seam collapsing them is worse than on the log one: empty is the normal state
    of a fresh deploy, so a wiring gap would be indistinguishable from the most
    common real answer."""
    var src = NoCloudMetricSource()
    var page = src.read_series(_SVC, _window())
    assert_false(page.ok(), "⛔ it REFUSES")
    assert_true(
        _contains(page.fault, String("no cloud metric source is configured")),
        "…naming the WIRING, not the workload: " + page.fault,
    )


def test_the_double_records_the_WINDOW_as_well_as_the_handle() raises:
    """⭐ THE ANTI-VACUITY CHECK A FUTURE CONSUMER WILL NEED. The defect this
    seam is most likely to have is a consumer that reads the right handle over
    the WRONG WINDOW — every value plausible, every one about the wrong day. A
    double that discarded the window could not catch it."""
    var src = ScriptedCloudMetricSource()
    var page = MetricPage.empty(200)
    var pts = List[MetricPoint]()
    pts.append(MetricPoint(String("T1"), Float64(7)))
    page.series.append(MetricSeries(String("m response_code=200"), pts^))
    src.script_page(_SVC, page^)
    var observer = src.share()
    assert_equal(observer.call_count(), 0, "nothing read yet")
    var got = src.read_series(_SVC, _window())
    assert_equal(got.point_count(), 1, "the scripted page came back")
    assert_equal(observer.call_count(), 1, "exactly one read")
    assert_equal(observer.last_handle(), _SVC, "of THIS handle")
    assert_equal(
        observer.last_window(),
        String("2026-09-11T10:00:00Z..2026-09-12T10:00:00Z"),
        "⛔ and over THIS window",
    )
    var unknown = src.read_series(String("projects/x/locations/y/services/z"), _window())
    assert_true(
        unknown.ok(),
        "an unscripted handle is a reached-and-found-nothing ANSWER",
    )
    assert_equal(unknown.point_count(), 0, "with nothing in it")


# =============================================================================
# §5 — THE AWS REQUEST: fully dimensioned, oldest-first.
# =============================================================================
def test_the_aws_body_is_FULLY_DIMENSIONED_or_REFUSED() raises:
    """⛔ ONE DIMENSION MATCHES EVERY SERVICE OF THAT NAME IN EVERY CLUSTER.

    MUTATION: emit only the `ServiceName` dimension, or accept the legacy
    cluster-less ARN shape."""
    var body = get_metric_data_body(
        String("AWS/ECS"),
        String("CPUUtilization"),
        String("Average"),
        3600,
        _ECS_SVC,
        MetricWindow(String("1789120800"), String("1789207200")),
    )
    assert_true(
        _contains(body, String('{"Name":"ClusterName","Value":"example-cluster"}')),
        "the CLUSTER dimension: " + body,
    )
    assert_true(
        _contains(body, String('{"Name":"ServiceName","Value":"example-ecs-svc"}')),
        "and the SERVICE dimension: " + body,
    )
    assert_equal(
        get_metric_data_body(
            String("AWS/ECS"),
            String("CPUUtilization"),
            String("Average"),
            3600,
            String("arn:aws:ecs:us-east-1:123456789012:service/example-ecs-svc"),
            MetricWindow(String("1789120800"), String("1789207200")),
        ),
        String(""),
        (
            "⛔ the LEGACY cluster-less ARN is REFUSED — a partially dimensioned"
            " query returns somebody else's numbers"
        ),
    )


def test_the_aws_body_asks_for_OLDEST_first_and_that_is_not_cosmetic() raises:
    """⚠ `ScanBy` DEFAULTS TO `TimestampDescending` ON THIS API, so omitting it
    is NOT the same as stating it. `MetricSeries.points` promises oldest ->
    newest — the `startFromHead: true` rule of the log arm, for its reason.

    MUTATION: drop the `ScanBy` field."""
    var body = get_metric_data_body(
        String("AWS/ECS"),
        String("CPUUtilization"),
        String("Average"),
        3600,
        _ECS_SVC,
        MetricWindow(String("1789120800"), String("1789207200")),
    )
    assert_true(
        _contains(body, String('"ScanBy":"TimestampAscending"')),
        "⛔ oldest first, STATED: " + body,
    )
    assert_true(
        _contains(body, String('"Period":3600')),
        "and the aggregation period rides: " + body,
    )


# =============================================================================
# §6 — ★★ THE AWS PARSE: PARALLEL ARRAYS.
# =============================================================================
def test_the_aws_response_pairs_its_two_PARALLEL_arrays() raises:
    """`Timestamps` and `Values` are two independent arrays CloudWatch promises
    are index-aligned. This is the happy path; the next test is the one that
    matters."""
    var body = String(
        '{"MetricDataResults":[{"Id":"m1","Label":"example-ecs-svc CPUUtilization",'
        '"Timestamps":[1789120800,1789124400],"Values":[12.5,13.75],'
        '"StatusCode":"Complete"}]}'
    )
    var page = parse_get_metric_data_body(body)
    assert_true(page.ok(), "parses: " + page.fault)
    assert_equal(page.point_count(), 2, "two points")
    assert_equal(
        page.series[0].points[0].end_time,
        String("1789120800"),
        "the provider's OWN spelling — epoch digits, not re-rendered RFC3339",
    )
    assert_equal(page.series[0].points[1].value, Float64(13.75), "…and pairing")


def test_a_LENGTH_DISAGREEMENT_is_a_FAULT_never_a_shorter_series() raises:
    """★★ THE AWS HEADLINE. Nothing in the JSON says the two arrays are the same
    length. A parser that zips `min(n, m)` drops the tail AND keeps pairing the
    rest — so every surviving point still looks right, and the series is quietly
    about a shorter window than the one that was asked for.

    MUTATION: replace the length check in `_zip_points` with `min(len, len)`."""
    var body = String(
        '{"MetricDataResults":[{"Id":"m1","Timestamps":[1,2,3],'
        '"Values":[10.0,20.0],"StatusCode":"Complete"}]}'
    )
    var page = parse_get_metric_data_body(body)
    assert_false(
        page.ok(),
        "⛔ a length disagreement is a FAULT, not a two-point series",
    )
    assert_true(
        _contains(page.fault, String("NOT echoed")),
        "…reported without the body: " + page.fault,
    )


# =============================================================================
# §7 — `PartialData`: a truncated answer inside an HTTP 200.
# =============================================================================
def test_PartialData_is_a_FAULT_not_a_short_answer() raises:
    """⛔ CloudWatch reports "I could not compute all of this" with a SUCCESSFUL
    call and a plausible short array. Taken at face value it says "the rate was
    fine" about a window nobody measured.

    MUTATION: drop the `StatusCode == PartialData` arm."""
    var body = String(
        '{"MetricDataResults":[{"Id":"m1","Label":"example-ecs-svc",'
        '"Timestamps":[1],"Values":[3.0],"StatusCode":"PartialData"}]}'
    )
    var page = parse_get_metric_data_body(body)
    assert_false(page.ok(), "⛔ PartialData is a FAULT")
    assert_true(
        _contains(page.fault, String("TRUNCATED")),
        "…and it says what happened: " + page.fault,
    )
    assert_equal(page.point_count(), 0, "no points are presented as complete")


def test_an_empty_aws_result_set_is_an_ANSWER() raises:
    var page = parse_get_metric_data_body(String('{"MetricDataResults":[]}'))
    assert_true(page.ok(), "empty is an ANSWER: " + page.fault)
    assert_equal(page.point_count(), 0, "with nothing in it")


def main() raises:
    test_the_handle_is_self_addressing_on_both_clouds()
    test_a_handle_that_is_not_one_yields_EMPTY_never_a_guess()
    test_the_gcp_filter_is_SCOPED_to_one_service()
    test_the_gcp_query_is_SERVER_AGGREGATED_and_that_is_MEASURED()
    test_an_UNBOUNDED_window_is_REFUSED_at_the_query()
    test_an_int64_metric_parses_even_though_its_value_is_QUOTED()
    test_a_double_valued_metric_parses_too_and_keeps_its_fraction()
    test_a_field_nobody_listed_cannot_reach_the_page()
    test_an_EMPTY_window_is_an_ANSWER_not_a_fault()
    test_a_malformed_gcp_body_is_reported_WITHOUT_echoing_it()
    test_the_not_configured_source_REFUSES_rather_than_answering_empty()
    test_the_double_records_the_WINDOW_as_well_as_the_handle()
    test_the_aws_body_is_FULLY_DIMENSIONED_or_REFUSED()
    test_the_aws_body_asks_for_OLDEST_first_and_that_is_not_cosmetic()
    test_the_aws_response_pairs_its_two_PARALLEL_arrays()
    test_a_LENGTH_DISAGREEMENT_is_a_FAULT_never_a_shorter_series()
    test_PartialData_is_a_FAULT_not_a_short_answer()
    test_an_empty_aws_result_set_is_an_ANSWER()
    print("PASS test_cloud_metric_source")
