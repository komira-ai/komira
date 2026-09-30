# =============================================================================
# tests/test_cloud_log_source.mojo — ★ THE CLOUD-LOG READ CAPABILITY, made
#   falsifiable, on BOTH cloud arms, with ZERO network.
# =============================================================================
#
# ── WHAT THIS FILE GUARDS ────────────────────────────────────────────────────
# When a deploy gate fails on a cloud execution, the release tool should fetch
# that execution's container output itself rather than end its report with a
# `gcloud logging read` command for the operator to run by hand.
#
#   §2  THE GCP REQUEST — the filter is BYTE-IDENTICAL to the one in the
#       equivalent `gcloud logging read` command, and the body asks for OLDEST
#       FIRST. Both are load-bearing, and §2c proves the second is not cosmetic.
#   §3  THE REFUSALS — a handle with no execution id, and a body with no project,
#       produce EMPTY rather than a query that would read the wrong project.
#       ⛔ These are the assertions that keep "silently reads someone else's
#       logs" out of the tree.
#   §4  THE ALLOW-LIST — a `LogEntry` carries free-form maps the emitting service
#       controls (`labels`, `resource`, `httpRequest`, `jsonPayload`). A key
#       nobody listed cannot print itself. Asserted against a body carrying a
#       live-looking token in a non-listed field.
#   §5  THE THREE STATES — entries / empty / fault, each a DIFFERENT value, so
#       "the container printed nothing" and "I could not read" never collapse.
#   §6  THE ADAPTER — a page becomes the `RunLogTail` the deploy report already
#       renders, so no second printer exists.
#   §7  THE AWS ARM — the pure half, proving the SAME trait carries CloudWatch
#       with no change to the seam, the POD or the adapter.
#
# Hermetic: pure functions + the in-library scripted double. No socket, no
# cloud, no sleep, no clock.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_ci_logs import RunLogTail, render_run_log_tail

from komira_ci_logs import (
    CloudLogEntry,
    CloudLogPage,
    DEFAULT_CONTAINER_LOG_LIMIT,
    DEFAULT_MAX_CONTAINER_LOG_PAGES,
    CONTAINER_LOG_PAGE_ROUND_TRIP_MS,
    CONTAINER_LOG_EMPTY_PAGE_BUDGET_MS,
    DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES,
    ContainerLogPager,
    walk_container_log_pages,
    container_log_next_page_size,
    container_log_should_continue,
    CONTAINER_LOG_CREDIBLE_FLOOR,
    CONTAINER_LOG_SETTLE_S,
    DEFAULT_MAX_CONTAINER_LOG_SETTLES,
    ContainerLogWalker,
    container_log_should_settle,
    read_container_output_settled,
    NON_TEXT_PAYLOAD_MARKER,
    NoCloudLogSource,
    ScriptedCloudLogSource,
    cloud_log_page_to_run_log_tail,
    cloud_run_execution_entries_list_body,
    cloud_run_execution_log_filter,
    cloudwatch_logs_host,
    ecs_task_arn_region,
    ecs_task_id,
    ecs_task_log_stream,
    entries_list_body,
    execution_leaf,
    execution_project,
    get_log_events_body,
    LOGGING_HOST,
    parse_entries_list_body,
    parse_get_log_events_body,
)


comptime _EXEC: String = (
    "projects/example-project/locations/us-central1/jobs/example-e2e"
    "/executions/example-e2e-abc12"
)
"""⚠ A REAL-SHAPED HANDLE: the full execution resource name, whose leaf differs
from the resource name. A handle that did not have that shape would not catch
that the label carries the LEAF and not the resource name."""


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def _lines(a: String, b: String, c: String) -> List[String]:
    var out = List[String]()
    out.append(a.copy())
    out.append(b.copy())
    out.append(c.copy())
    return out^


# =============================================================================
# §1 — handle arithmetic.
# =============================================================================
def test_the_handle_is_self_addressing() raises:
    """The execution resource name carries the project AND the leaf, which is
    why the seam takes a bare String and no `{project, region}` POD."""
    assert_equal(
        execution_project(_EXEC), String("example-project"), "project off the name"
    )
    assert_equal(
        execution_leaf(_EXEC),
        String("example-e2e-abc12"),
        "the LEAF id, which is what the log label carries",
    )
    # An already-absolute spelling must answer identically — the leading-slash
    # normalise is what makes ONE marker set cover both.
    assert_equal(
        execution_project(String("/") + _EXEC),
        String("example-project"),
        "an absolute form parses the same",
    )


# =============================================================================
# §2 — the GCP request.
# =============================================================================
def test_the_filter_is_the_one_the_report_has_been_printing() raises:
    """⛔ BYTE-IDENTICAL to the filter in the equivalent `gcloud` command. An
    operator comparing this tool's output against their own `gcloud` run must not
    have to wonder whether two different questions were asked."""
    var f = cloud_run_execution_log_filter(_EXEC)
    assert_equal(
        f,
        String(
            'resource.type="cloud_run_job" AND'
            ' labels."run.googleapis.com/execution_name"='
            '"example-e2e-abc12"'
        ),
        "the filter must match the printed command exactly",
    )


def test_the_request_body_scopes_the_project_and_escapes_the_filter() raises:
    """The project is the `resourceNames` SCOPE (not part of the filter), and the
    filter — which is mostly double quotes — is JSON-escaped. An unescaped filter
    is not a wrong query, it is a body that is not JSON, surfacing as an opaque
    400."""
    var body = cloud_run_execution_entries_list_body(_EXEC, 200)
    assert_true(
        _contains(body, String('"resourceNames":["projects/example-project"]')),
        "the project is the scope: " + body,
    )
    assert_true(
        _contains(body, String('\\"cloud_run_job\\"')),
        "the filter's quotes MUST be escaped: " + body,
    )
    assert_false(
        _contains(body, String('"filter":"resource.type="')),
        "an UNESCAPED filter would produce a body that is not JSON: " + body,
    )
    assert_true(
        _contains(body, String('"pageSize":200')), "the fetch bound: " + body
    )


def test_the_body_asks_for_OLDEST_first_and_that_is_not_cosmetic() raises:
    """★ `orderBy: "timestamp asc"`.

    ⛔ THE ANTI-"just reverse it locally" ASSERTION. Asking DESCENDING and
    reversing produces the same list only while the page bound does not bite. The
    moment a stream is longer than `pageSize`, descending returns the NEWEST N of
    the WHOLE STREAM and ascending returns the OLDEST N of it — and the bounded
    renderer then shows the head of the stream as its tail, which for a validator
    is exactly the half WITHOUT the failing rows."""
    var body = cloud_run_execution_entries_list_body(_EXEC, 50)
    assert_true(
        _contains(body, String('"orderBy":"timestamp asc"')),
        "oldest first, from the provider: " + body,
    )


# =============================================================================
# §3 — the REFUSALS. ⛔ The assertions that keep "reads the wrong project" out.
# =============================================================================
def test_a_handle_with_no_execution_id_is_REFUSED_not_guessed() raises:
    """A filter with no execution id matches EVERY job execution in the project.
    A caller that ran it would show the operator somebody else's rows under this
    step's name — worse than no output at all."""
    assert_equal(
        cloud_run_execution_log_filter(
            String("projects/example-project/locations/us-central1/jobs/j")
        ).byte_length(),
        0,
        "no execution id -> EMPTY filter, never a match-everything one",
    )
    assert_equal(
        cloud_run_execution_entries_list_body(String("not-a-resource-name")),
        String(""),
        "an unparseable handle yields no request at all",
    )


def test_an_empty_project_is_REFUSED_at_the_body() raises:
    """The project refusal lives at the BODY, not the filter — on the REST API
    the project is `resourceNames`, a separate field. The two functions look like
    they should agree about it and correctly do not."""
    assert_equal(
        entries_list_body(String(""), String('resource.type="cloud_run_job"')),
        String(""),
        "no project -> no request",
    )
    assert_equal(
        entries_list_body(String("example-project"), String("")),
        String(""),
        "no filter -> no request",
    )


def test_the_not_configured_source_REFUSES_rather_than_answering_empty() raises:
    """⛔ `NoCloudLogSource` must NOT return an empty page. "Nobody wired a log
    source into this binary" and "the container printed nothing" are different
    facts with different next actions, and collapsing them is how a missing
    wiring gets diagnosed for weeks as a quiet validator."""
    var src = NoCloudLogSource()
    var page = src.read_container_output(_EXEC, 200)
    assert_false(page.ok(), "not-configured is a FAULT, not an empty answer")
    assert_true(
        _contains(page.fault, String("no cloud log source is configured")),
        "and it says which: " + page.fault,
    )


# =============================================================================
# §4 — the ALLOW-LIST.
# =============================================================================
def test_a_field_nobody_listed_cannot_print_itself() raises:
    """⛔ THE SECURITY BOUNDARY. A `LogEntry` carries free-form maps the emitting
    service controls. This body puts a live-looking grant token in `labels` and
    in `jsonPayload` — neither is on the allow-list, so neither may appear
    anywhere in the parsed page."""
    var body = String(
        '{"entries":[{"insertId":"abc123",'
        '"labels":{"secret":"ya29.A0AVERYLIVELOOKINGTOKEN"},'
        '"resource":{"type":"cloud_run_job",'
        '"labels":{"project_id":"other-project"}},'
        '"httpRequest":{"requestUrl":"https://x/?token=ya29.LEAK"},'
        '"jsonPayload":{"password":"hunter2"},'
        '"severity":"ERROR",'
        '"timestamp":"2026-09-12T10:00:00.5Z",'
        '"textPayload":"row 3/12 FAIL: item list returned 0"}]}'
    )
    var page = parse_entries_list_body(body, _EXEC)
    assert_true(page.ok(), "an entry with extra fields still PARSES")
    assert_equal(len(page.entries), 1, "one entry")
    var e = page.entries[0].copy()
    assert_equal(
        e.text,
        String("row 3/12 FAIL: item list returned 0"),
        "the allow-listed text survives",
    )
    assert_equal(e.severity, String("ERROR"), "severity survives")
    assert_equal(
        e.timestamp, String("2026-09-12T10:00:00.5Z"), "timestamp survives"
    )
    # ⛔ The three that must not.
    assert_false(
        _contains(e.text + e.severity + e.timestamp, String("ya29.")),
        "NO label/httpRequest value may reach a rendered field",
    )
    assert_false(
        _contains(e.text + e.severity + e.timestamp, String("hunter2")),
        "NO jsonPayload value may reach a rendered field",
    )
    assert_false(
        _contains(e.text + e.severity + e.timestamp, String("other-project")),
        "NO resource label may reach a rendered field",
    )


def test_a_structured_payload_entry_is_KEPT_not_dropped() raises:
    """An entry with no `textPayload` keeps its place and its timestamp, with the
    marker in its text.

    ⛔ DROPPING IT WOULD RENDER A FULL STREAM AS AN EMPTY ONE and tell the
    operator "nothing was printed" about a container that printed 40 structured
    lines — the exact wrong diagnosis this package exists to stop making."""
    # ⚠ THE PAYLOAD VALUE IS DELIBERATELY UNLIKE ANY PROSE THIS PACKAGE WRITES.
    # The first version of this test asserted on the word "structured" and FAILED
    # — because `NON_TEXT_PAYLOAD_MARKER` contains that word itself. The
    # assertion was right and the NEEDLE was wrong, which is the quiet way a
    # leak test starts matching its own output instead of the thing it guards.
    var body = String(
        '{"entries":[{"timestamp":"2026-09-12T10:00:01Z",'
        '"jsonPayload":{"msg":"PAYLOAD_VALUE_THAT_MUST_NOT_LEAK"}}]}'
    )
    var page = parse_entries_list_body(body, _EXEC)
    assert_equal(len(page.entries), 1, "the entry is KEPT")
    assert_equal(
        page.entries[0].timestamp,
        String("2026-09-12T10:00:01Z"),
        "its timestamp survives — that is what proves output exists",
    )
    assert_true(
        _contains(page.entries[0].text, String("no textPayload")),
        "and it says why it has no text: " + page.entries[0].text,
    )
    assert_false(
        _contains(
            page.entries[0].text, String("PAYLOAD_VALUE_THAT_MUST_NOT_LEAK")
        ),
        "⛔ but the payload's CONTENTS still do not leak: "
        + page.entries[0].text,
    )


def test_a_text_payload_that_looks_like_json_does_not_fool_the_scan() raises:
    """A container printing JSON is ordinary. The scanner must treat it as a
    STRING, not as structure — the property `json_skip_value` is there to
    preserve."""
    var body = String(
        '{"entries":[{"textPayload":'
        '"{\\"severity\\":\\"INFO\\",\\"textPayload\\":\\"decoy\\"}",'
        '"severity":"ERROR"}]}'
    )
    var page = parse_entries_list_body(body, _EXEC)
    assert_equal(len(page.entries), 1, "exactly ONE entry, not two")
    assert_equal(
        page.entries[0].severity,
        String("ERROR"),
        "the REAL severity wins, not the one inside the text",
    )
    assert_true(
        _contains(page.entries[0].text, String("decoy")),
        "the text is carried verbatim: " + page.entries[0].text,
    )


# =============================================================================
# §5 — the THREE STATES.
# =============================================================================
def test_an_absent_entries_key_is_a_SUCCESS_with_nothing_in_it() raises:
    """Cloud Logging omits `entries` entirely when a filter matches nothing.
    ⛔ That is an ANSWER, not an error — modelling it as one is how a container
    that crashed before printing gets reported as an observability fault."""
    var page = parse_entries_list_body(String("{}"), _EXEC)
    assert_true(page.ok(), "no entries key is still an ANSWER")
    assert_equal(len(page.entries), 0, "and it is empty")


def test_a_malformed_body_is_reported_WITHOUT_echoing_it() raises:
    """⛔ NO RESPONSE BODY IS EVER ECHOED — a byte count and a position only. A
    4xx/5xx body from an auth-adjacent API is exactly the body that carries
    material."""
    var body = String(
        '{"entries":[{"textPayload":"unterminated,'
        '"secret":"ya29.LEAKED_IN_A_MALFORMED_BODY"'
    )
    var page = parse_entries_list_body(body, _EXEC)
    assert_false(page.ok(), "a malformed body is a FAULT")
    assert_false(
        _contains(page.fault, String("ya29.")),
        "⛔ the fault must not carry the body: " + page.fault,
    )
    assert_true(
        _contains(page.fault, String("NOT echoed")),
        "and it says so out loud: " + page.fault,
    )


# =============================================================================
# §6 — the ADAPTER onto `RunLogTail`.
# =============================================================================
def test_a_page_renders_through_the_EXISTING_report_renderer() raises:
    """★ THE REASON NO SECOND PRINTER EXISTS. A page becomes the `RunLogTail`
    `run_validation_dag` already prints, so a cloud container stream reaches the
    operator through the exact path a pipeline run stream does."""
    var page = CloudLogPage.empty(200)
    page.entries.append(
        CloudLogEntry(
            String("2026-09-12T10:00:00Z"), String("INFO"), String("row 1 ok")
        )
    )
    page.entries.append(
        CloudLogEntry(
            String("2026-09-12T10:00:02Z"),
            String("ERROR"),
            String("VERDICT: FAIL (11/12 rows)"),
        )
    )
    var tail = cloud_log_page_to_run_log_tail(page, _EXEC)
    assert_true(tail.ok(), "a good page is a good tail")
    assert_equal(len(tail.records), 2, "both entries survive")
    assert_equal(tail.records[0].seq, 1, "seq is the 1-based ORDINAL")
    assert_equal(tail.records[1].seq, 2, "…and it advances")
    assert_equal(
        tail.records[1].level, String("ERROR"), "severity -> level"
    )
    assert_equal(
        tail.records[1].step,
        String("2026-09-12T10:00:02Z"),
        "⚠ timestamp -> `step`, the deliberate stretch stated in the adapter",
    )
    assert_equal(tail.run_id, _EXEC, "the handle names the stream")
    var out = render_run_log_tail(tail, 40, 400)
    assert_true(
        _contains(out, String("VERDICT: FAIL (11/12 rows)")),
        "⭐ THE WHOLE POINT: the validator's own verdict line reaches the"
        " operator's terminal: " + out,
    )
    assert_true(
        _contains(out, _EXEC), "and the report names the execution: " + out
    )


def test_a_faulted_page_becomes_a_fetch_error_not_a_fake_empty() raises:
    """⛔ A fault must render as COULD NOT READ, never as NO RECORDS. The two
    send the operator to different places, and only one of them is about their
    container."""
    var page = CloudLogPage.failed(403, String("HTTP 403 from logging"))
    var tail = cloud_log_page_to_run_log_tail(page, _EXEC)
    assert_false(tail.ok(), "a failed page is a failed tail")
    var out = render_run_log_tail(tail, 40, 400)
    assert_true(
        _contains(out, String("COULD NOT READ")), "…and says so: " + out
    )
    assert_true(
        _contains(out, String("verdict above")),
        "and states that the step's verdict is unchanged: " + out,
    )


def test_the_scripted_double_honours_the_fetch_bound() raises:
    """A double that ignored a bound its live peer enforces would let a test pass
    over an unbounded read. It keeps the LAST `limit`, which is where a
    validator's failing rows are."""
    var src = ScriptedCloudLogSource()
    src.script_text(
        _EXEC, _lines(String("a"), String("b"), String("c"))
    )
    var page = src.read_container_output(_EXEC, 2)
    assert_equal(len(page.entries), 2, "bounded to 2")
    assert_equal(
        page.entries[1].text, String("c"), "keeping the LAST, not the first"
    )
    assert_equal(src.call_count(), 1, "one read")
    assert_equal(src.last_handle(), _EXEC, "of the handle it was asked for")
    # A handle nobody scripted is an EMPTY answer, not a fault — a real provider
    # answers exactly that for an execution that printed nothing.
    var other = src.read_container_output(String("projects/p/x"), 10)
    assert_true(other.ok(), "an unscripted handle is an ANSWER")
    assert_equal(len(other.entries), 0, "…with nothing in it")


# =============================================================================
# §7 — THE AWS ARM. The PURE half: this section proves the SEAM carries
#      CloudWatch with no change to the trait, the POD or the adapter.
# =============================================================================
def test_the_aws_arm_derives_its_stream_from_the_task_arn_alone() raises:
    """The ECS handle is self-addressing the same way the GCP one is — which is
    what makes ONE trait verb, keyed on the provider's own string, carry both."""
    assert_equal(
        ecs_task_id(
            String(
                "arn:aws:ecs:us-east-1:123456789012:task/example-validate"
                "/abc123def456"
            )
        ),
        String("abc123def456"),
        "the LAST segment",
    )
    # ⛔ THE LEGACY ARN, which has no cluster segment. A fixed index would return
    # the CLUSTER NAME here — a string that looks entirely plausible in a stream
    # name and matches nothing.
    assert_equal(
        ecs_task_id(String("arn:aws:ecs:us-east-1:123456789012:task/xyz789")),
        String("xyz789"),
        "the legacy two-segment ARN answers the same way",
    )
    assert_equal(
        ecs_task_log_stream(
            String("ecs"),
            String("validator"),
            String(
                "arn:aws:ecs:us-east-1:123456789012:task/example-validate"
                "/abc123def456"
            ),
        ),
        String("ecs/validator/abc123def456"),
        "the awslogs convention: <prefix>/<container>/<task-id>",
    )
    # The refusal, same discipline as the GCP filter's.
    assert_equal(
        ecs_task_log_stream(
            String(""), String("validator"), String("arn:...:task/abc")
        ).byte_length(),
        0,
        "no prefix -> REFUSE, never a partially-formed stream name",
    )


def test_the_aws_arm_asks_for_oldest_first_too() raises:
    """⚠ On `GetLogEvents` the DEFAULT is the opposite (`startFromHead=false`),
    so omitting the field is not the same as stating it."""
    var body = get_log_events_body(
        String("/ecs/example-validate"), String("ecs/validator/abc123"), 200
    )
    assert_true(
        _contains(body, String('"startFromHead":true')),
        "oldest first: " + body,
    )
    assert_true(_contains(body, String('"limit":200')), "bounded: " + body)
    assert_equal(
        get_log_events_body(String(""), String("s")),
        String(""),
        "no group -> no request",
    )


def test_the_aws_response_parses_through_the_SAME_page_and_adapter() raises:
    """★ THE EXPRESSIBILITY PROOF. A CloudWatch response reaches the operator
    through the identical `CloudLogPage` -> `RunLogTail` -> `render_run_log_tail`
    path, with ZERO change to the trait, the POD or the adapter. ⛔ `timestamp`
    is epoch millis here and RFC3339 on GCP; both are carried VERBATIM, because a
    renderer that re-formats a provider's timestamp can disagree with that
    provider's console — which the operator has open."""
    var body = String(
        '{"events":[{"timestamp":1789200000000,"ingestionTime":1789200000123,'
        '"message":"VERDICT: FAIL (3/4 rows)"}],'
        '"nextForwardToken":"f/12345"}'
    )
    var page = parse_get_log_events_body(body)
    assert_true(page.ok(), "it parses")
    assert_equal(len(page.entries), 1, "one event")
    assert_equal(
        page.entries[0].text,
        String("VERDICT: FAIL (3/4 rows)"),
        "the message survives",
    )
    assert_equal(
        page.entries[0].timestamp,
        String("1789200000000"),
        "epoch millis, VERBATIM — not converted",
    )
    assert_equal(
        page.next_token, String("f/12345"), "the cursor is carried"
    )
    var tail = cloud_log_page_to_run_log_tail(
        page, String("arn:aws:ecs:us-east-1:1:task/c/abc")
    )
    var out = render_run_log_tail(tail, 40, 400)
    assert_true(
        _contains(out, String("VERDICT: FAIL (3/4 rows)")),
        "the same renderer prints it: " + out,
    )
    assert_false(
        tail.done,
        "⚠ a carried cursor renders done=false — the honest answer for a"
        " resume-token API, and the one behavioural difference between arms",
    )


def test_the_aws_arm_does_not_leak_a_non_listed_field() raises:
    """`ingestionTime` is deliberately OFF the allow-list: it is when CloudWatch
    RECEIVED the line, not when the container wrote it, and two clocks in one
    rendered stream is how a reader concludes an event happened after something
    it preceded."""
    var body = String(
        '{"events":[{"timestamp":1789200000000,"ingestionTime":1789999999999,'
        '"message":"x"}]}'
    )
    var page = parse_get_log_events_body(body)
    assert_equal(
        page.entries[0].timestamp,
        String("1789200000000"),
        "the EMIT time, never the ingestion time",
    )


# =============================================================================
# §8 — ★★ THE AWS ARM'S HANDLE IS NOT TOTAL, AND WHAT IT DOES CARRY IS DERIVED
#      RATHER THAN CONFIGURED.
# =============================================================================
def test_the_aws_conformer_holds_NO_region_because_the_handle_carries_one() raises:
    """⭐⭐ THE PROPERTY THE GCP ARM GETS FOR FREE, MADE EXPLICIT ON AWS.

    `LiveCloudRunExecutionLogs` holds no PROJECT: the execution resource name
    carries it, so the conformer cannot be pointed at a project that disagrees
    with the handle it was given. A CloudWatch read needs a REGION twice — the
    endpoint host AND the SigV4 credential scope — so a `_region` FIELD would be
    that disagreement in AWS clothing, and the wrong one reads ANOTHER REGION'S
    log group of the same name (every region can have a `/example/fargate`).

    MUTATION: give `LiveEcsTaskLogs` a `_region` field and sign with it.
    Everything still compiles and every hermetic test still passes; the failure
    appears only when a task is placed outside the conformer's configured
    region, and it appears as an EMPTY STREAM.

    ⚠ BOTH ARN SHAPES, and the region is at the same index in each — segment 3,
    counting from `arn:`. That is why this is derivable at all."""
    assert_equal(
        ecs_task_arn_region(
            String("arn:aws:ecs:us-east-1:111122223333:task/example-fargate/t1")
        ),
        String("us-east-1"),
        "the long (cluster-qualified) ARN shape",
    )
    assert_equal(
        ecs_task_arn_region(
            String("arn:aws:ecs:eu-west-3:111122223333:task/t1")
        ),
        String("eu-west-3"),
        "and the legacy shape with no cluster segment",
    )


def test_an_UNPARSEABLE_arn_yields_NO_region_and_never_a_default() raises:
    """⛔ EMPTY IS A REFUSAL, NEVER `us-east-1`.

    The tempting fallback is the region most things are in, and it is the worst
    possible one: a task in `us-west-2` whose logs are read from `us-east-1`
    answers `ResourceNotFoundException`, which the caller renders as "the
    container printed nothing" — the opposite of true, stated with the
    validator's authority.

    MUTATION: `return String("us-east-1")` on the empty path."""
    assert_equal(
        ecs_task_arn_region(String("")), String(""), "an empty handle"
    )
    assert_equal(
        ecs_task_arn_region(String("example-fargate/t1")),
        String(""),
        "a bare stream-ish string that is not an ARN at all",
    )
    assert_equal(
        ecs_task_arn_region(String("arn:aws:ecs")),
        String(""),
        "a truncated ARN that never reaches the region segment",
    )
    assert_equal(
        ecs_task_arn_region(
            String("arn:aws:ecs::111122223333:task/example-fargate/t1")
        ),
        String(""),
        (
            "⛔ and an ARN whose region segment is EMPTY — which is the shape a"
            " partially-composed ARN takes, and the one a length check would"
            " wave through"
        ),
    )


def test_the_cloudwatch_host_is_REGIONAL_where_the_gcp_one_is_GLOBAL() raises:
    """The ONE structural difference between the two clouds' transports, and the
    reason the AWS arm derives a region from its handle at all.

    Cloud Logging is ONE global host (`logging.googleapis.com`) that takes the
    project INSIDE the request body. CloudWatch Logs is PER-REGION and the
    region is in the HOSTNAME, so the handle has to answer a question the GCP
    handle never has to.

    ⛔ AN EMPTY REGION PRODUCES AN EMPTY HOST, not `logs..amazonaws.com` — a
    string that resolves to nothing and fails as a DNS error, which is the one
    diagnosis that sends an operator to their network."""
    assert_equal(
        cloudwatch_logs_host(String("us-east-1")),
        String("logs.us-east-1.amazonaws.com"),
        "the regional endpoint",
    )
    assert_equal(
        cloudwatch_logs_host(String("")),
        String(""),
        "⛔ an empty region is an empty host, never a malformed one",
    )
    assert_equal(
        LOGGING_HOST,
        String("logging.googleapis.com"),
        "…and its GCP peer carries no region at all",
    )


# =============================================================================
# §8 — ★★ THE BOUNDED MULTI-PAGE WALK.
#
# ── THE PROBLEM ──────────────────────────────────────────────────────────────
# A conformer performing exactly ONE `entries:list`, issued at T+0 the
# instant a step is decided STEP_FAIL, is not enough: Cloud Logging ingests
# ASYNCHRONOUSLY — seconds to a minute behind a container that has just died —
# and `entries:list` routinely answers with FEWER entries than `pageSize` PLUS a
# `nextPageToken`. So a SHORT FIRST PAGE would be presented as the container's
# whole output, and an EMPTY first read as "the container printed nothing".
#
# ⛔ THE POLICY IS TESTED HERE AND NOT IN THE CONFORMER, ON PURPOSE. That file
# owns the ROUND TRIP; a walk is a SEQUENCE of requests, so the decision to make
# another one is this leaf's. Left behind the socket, the bound would be a
# comment. `container_log_should_continue` / `container_log_next_page_size` are
# pure, and every branch of the walk is decided by them.
# =============================================================================
def test_the_walk_follows_a_continuation_token() raises:
    """★ THE CASE THE WALK EXISTS FOR: a page that came back SHORT and carried a
    token. A reader that stopped on "fewer than I asked for" — or worse, on "zero
    entries" — would reproduce the single-read defect with extra steps, because
    that is precisely the shape a still-ingesting provider returns."""
    assert_true(
        container_log_should_continue(
            1, 0, 3, 200, String("tok-abc"), String("")
        ),
        "a short page WITH a token must be followed",
    )
    assert_true(
        container_log_should_continue(
            1, 1, 0, 200, String("tok-abc"), String("")
        ),
        "⛔ and an EMPTY page with a token too — that IS the ingestion-lag"
        " shape, and stopping there is the defect",
    )


def test_a_stream_that_ENDED_is_not_re_read() raises:
    """⛔ NO TOKEN IS THE ONLY `False` THAT MEANS COMPLETE. The provider said the
    stream ends here; asking again is a POLL, not paging, and a poll inside a
    failure report costs wall time exactly where wall time is a SIGKILL on the
    host process this sits inside."""
    assert_false(
        container_log_should_continue(
            1, 1, 0, 200, String(""), String("")
        ),
        "an empty page with NO token is the end of the stream, not a retry",
    )
    assert_false(
        container_log_should_continue(
            1, 0, 200, 200, String(""), String("")
        ),
        "and so is a full one",
    )


def test_the_walk_is_BOUNDED_and_the_bound_is_the_point() raises:
    """⛔ THE HALF THAT MATTERS MORE THAN THE PAGING. An unbounded drain is an
    enrichment that can take longer than the failure it annotates, on a path a
    validation DAG walks once per red step — and the runner it sits inside gets
    SIGKILLed on its own deadline, which runs NO teardown and leaves a live cloud
    service behind. The remainder is REPORTED (the token survives -> `done=false`)
    rather than silently dropped."""
    assert_true(
        container_log_should_continue(
            DEFAULT_MAX_CONTAINER_LOG_PAGES - 1,
            0,
            5,
            200,
            String("tok"),
            String("prev"),
        ),
        "below the bound, with more to read: continue",
    )
    assert_false(
        container_log_should_continue(
            DEFAULT_MAX_CONTAINER_LOG_PAGES,
            0,
            5,
            200,
            String("tok"),
            String("prev"),
        ),
        "⛔ AT the bound it stops even though the provider offered more",
    )
    assert_true(
        DEFAULT_MAX_CONTAINER_LOG_PAGES > 1,
        "sanity: a bound of 1 would never follow a continuation token, so it"
        " would not be a paging bound at all",
    )
    assert_true(
        DEFAULT_MAX_CONTAINER_LOG_PAGES <= 5,
        "⛔ and a bound nobody would notice is not a bound — this number is the"
        " ceiling on how long a failure report may spend annotating itself",
    )


def test_limit_is_the_TOTAL_and_the_walk_asks_for_the_remainder() raises:
    """⛔ `CloudLogSource.read_container_output`'s contract is "read up to
    `limit` entries". Asking for `limit` on each of three pages would return up
    to THREE TIMES the number the caller stated — a bound that silently means
    something else is worse than none, because every caller sizing a report
    around it is wrong by a factor nobody wrote down."""
    assert_equal(
        container_log_next_page_size(200, 0), 200, "the first round asks for all"
    )
    assert_equal(
        container_log_next_page_size(200, 150),
        50,
        "the second asks for the REMAINDER, never for 200 again",
    )
    assert_equal(
        container_log_next_page_size(200, 200), 0, "a satisfied walk asks for 0"
    )
    assert_false(
        container_log_should_continue(
            1, 0, 200, 200, String("tok"), String("")
        ),
        "…and stops, even with a token in hand — but see the next case for what"
        " must happen to that token",
    )
    assert_equal(
        container_log_next_page_size(0, 0),
        DEFAULT_CONTAINER_LOG_LIMIT,
        "a caller that expressed no bound takes the package default, ONCE,"
        " here — the same normalisation every other reader of `limit` applies",
    )


def test_a_walk_stopped_by_its_own_bound_still_says_the_stream_goes_on() raises:
    """★ THE TOKEN IS KEPT, NOT DISCARDED, WHEN **WE** STOPPED. `done` is derived
    from `next_token`, so a page that stopped at the caller's `limit` or at the
    page bound renders `done=false` — the reader learns the stream did not end
    where the read did. Dropping the token would make a bounded read
    indistinguishable from a complete one, which is the class of silent
    truncation this package's renderer exists to prevent."""
    var stopped_early = CloudLogPage(
        List[CloudLogEntry](), 200, String(""), String("tok-more"), 3, 0
    )
    var tail = cloud_log_page_to_run_log_tail(stopped_early, String("exec-x"))
    assert_false(
        tail.done,
        "⛔ a surviving token means NOT done, however many pages were read",
    )
    assert_equal(tail.pages, 3, "and the page count is the walk's own")
    var out = render_run_log_tail(tail^)
    assert_true(
        out.find(String("3 page(s), 0 settle(s), done=false")) >= 0,
        String("and the report says both. Got: ") + out,
    )


def test_the_page_count_on_the_wire_is_the_conformer_s_own() raises:
    """⛔ THE ADAPTER MUST NOT HARDCODE `pages = 1`. The seam follows a token,
    so a constant would be a FALSE STATEMENT in the very sentence ("read N
    page(s)") the report exists to make trustworthy. It comes from the party
    that did the reading.

    ⚠ AND THE TWO REFUSAL SHAPES DIFFER. A 4xx REACHED the provider and read one
    page; a handle we refused to send never dialled and read zero."""
    var three = CloudLogPage(
        List[CloudLogEntry](), 200, String(""), String(""), 3, 0
    )
    assert_equal(
        cloud_log_page_to_run_log_tail(three, String("e")).pages,
        3,
        "a three-page walk reports three",
    )
    assert_equal(
        cloud_log_page_to_run_log_tail(
            CloudLogPage.failed(403, String("HTTP 403 ... NOT echoed")),
            String("e"),
        ).pages,
        1,
        "a 403 REACHED the provider — one page",
    )
    assert_equal(
        cloud_log_page_to_run_log_tail(
            CloudLogPage.failed(0, String("cannot derive a query")), String("e")
        ).pages,
        0,
        "⛔ a refusal that never dialled read ZERO — `status == 0` is this"
        " module's own marker for a dial that reached no verdict",
    )


def test_a_page_token_rides_the_request_and_is_ESCAPED() raises:
    """The request half of the walk. ⛔ A token is echoed back VERBATIM and never
    synthesised — it is an opaque provider string — and it is ESCAPED like every
    other value in this body, because "a token never needs escaping" is exactly
    the assumption that produces an opaque 400 the first time it does."""
    var first = cloud_run_execution_entries_list_body(_EXEC, 200)
    assert_true(
        first.find(String("pageToken")) < 0,
        String(
            "⛔ BYTE-IDENTICAL FOR THE FIRST READ: a caller with no token emits"
            " no key, so a first-page request carries no token field. Got: "
        )
        + first,
    )
    var next = cloud_run_execution_entries_list_body(
        _EXEC, 50, String("tok\"abc")
    )
    assert_true(
        next.find(String('"pageToken":"tok\\\"abc"')) >= 0,
        String("the token rides, escaped. Got: ") + next,
    )
    assert_true(
        next.find(String('"pageSize":50')) >= 0,
        String(
            "…alongside the REMAINDER the walk asked for, not the original"
            " total. Got: "
        )
        + next,
    )


def test_a_refused_handle_is_still_refused_with_a_token_in_hand() raises:
    """⛔ THE REFUSAL OUTRANKS THE CONTINUATION. A handle that yields no project
    or no execution leaf produces an EMPTY body whether or not a token is
    supplied — a paging read must never become the path by which a project-less
    query gets sent, because that one returns SOMEBODY ELSE'S entries and the
    operator reads them as this execution's."""
    assert_equal(
        cloud_run_execution_entries_list_body(
            String("projects/p/locations/r/jobs/j"), 200, String("tok")
        ),
        String(""),
        "no execution leaf: refused, token or not",
    )


# =============================================================================
# ★★ §9 — THE SETTLE. The walk of §8 is necessary and NOT ENOUGH.
#
# A fetch can reach the provider, walk `2 pages, done=true` — and return
# **ONE LINE** for a validator that had printed many rows. Paging answers "is
# there more RIGHT NOW"; it cannot answer "will there be more in five seconds",
# and for a container that died a moment ago that is the question.
#
# ⛔ EVERY CASE HERE DRIVES THE REAL LOOP, `read_container_output_settled` — the
# same function BOTH live conformers call. A test that only exercised the
# predicate would prove the policy and nothing about the WIRING (which argument,
# which result is kept), and a bound whose wiring nothing tests is a comment.
# The double counts its waits instead of taking them, so the file still has no
# clock.
# =============================================================================
struct ScriptedWalker(ContainerLogWalker, Movable, Deinitable):
    """A walker whose Nth walk returns `counts[N]` entries (or a fault when
    `fault_on_walk` matches), and which COUNTS its waits instead of taking
    them."""

    var counts: List[Int]
    var tokens: List[String]
    var walks: Int
    var waits: Int
    var waited_seconds: Int
    var fault_on_walk: Int
    var pages_per_walk: Int

    def __init__(
        out self,
        var counts: List[Int],
        var tokens: List[String],
        fault_on_walk: Int = -1,
        pages_per_walk: Int = 1,
    ):
        self.counts = counts^
        self.tokens = tokens^
        self.walks = 0
        self.waits = 0
        self.waited_seconds = 0
        self.fault_on_walk = fault_on_walk
        self.pages_per_walk = pages_per_walk

    def walk_once(
        mut self, handle: String, want: Int, session: String
    ) raises -> CloudLogPage:
        var i = self.walks
        self.walks += 1
        if i == self.fault_on_walk:
            return CloudLogPage.failed(403, String("scripted fault"))
        var n = self.counts[i] if i < len(self.counts) else 0
        var tok = self.tokens[i] if i < len(self.tokens) else String("")
        var out = List[CloudLogEntry]()
        for k in range(n):
            out.append(
                CloudLogEntry(
                    String("2026-09-13T00:00:0") + String(k) + String("Z"),
                    String("INFO"),
                    String("line ") + String(k),
                )
            )
        # ⚠ `settles = 0` FROM A WALK. The settle count is the LOOP's, never a
        # walker's — a double that reported its own would let the loop's
        # bookkeeping go untested behind a plausible number.
        return CloudLogPage(
            out^, 200, String(""), tok^, self.pages_per_walk, 0
        )

    def settle_wait(mut self, seconds: Int):
        self.waits += 1
        self.waited_seconds += seconds


def _counts(a: Int, b: Int = -1, c: Int = -1) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    if b >= 0:
        out.append(b)
    if c >= 0:
        out.append(c)
    return out^


def _ended(n: Int) -> List[String]:
    """`n` walks that each report the stream as ENDING (no continuation)."""
    var out = List[String]()
    for _ in range(n):
        out.append(String(""))
    return out^


def test_a_read_that_ENDED_with_almost_nothing_SETTLES_and_re_reads() raises:
    """⛔ THE CASE THE SETTLE EXISTS FOR. One line, `done=true`, at T+0 — which
    is not evidence the container printed one line."""
    var w = ScriptedWalker(_counts(1, 9), _ended(2))
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(w.walks, 2, "the read was ATTEMPTED AGAIN after the settle")
    assert_equal(w.waits, 1, "exactly ONE settle was spent")
    assert_equal(
        w.waited_seconds,
        CONTAINER_LOG_SETTLE_S,
        "and it waited the package's own interval, not a local number",
    )
    assert_equal(
        len(page.entries), 9, "the settled read is what is RETURNED"
    )
    assert_equal(
        page.pages, 2, "and `pages` counts BOTH provider reads, honestly"
    )
    _ = w^


def test_the_settle_COUNT_rides_out_on_the_page_and_through_the_adapter() raises:
    """★★★ THE WAITS ARE REPORTED, NOT ONLY SPENT.

    ── THE GAP THIS CLOSES ─────────────────────────────────────────
    `pages` says how much of the stream was walked. Without `settles`, NOTHING
    says whether the tool WAITED — so `0 entries, 1 page, done=true` would be the
    same string whether the read had given the provider its full ten-second
    ingestion window or had asked once at T+0 and believed the answer.

    ⛔ COUNTED IN THE LOOP AND NOWHERE ELSE, for the reason the loop is in the
    leaf: a conformer keeping its own count would be bookkeeping behind a socket,
    and the renderer would print a number nothing tests. The two walkers below
    both report `settles = 0` on the pages they return; the count in the RESULT
    is the loop's."""
    var w = ScriptedWalker(_counts(0, 4), _ended(2))
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(w.waits, 1, "sanity: one settle was actually spent")
    assert_equal(
        page.settles,
        1,
        (
            "★★ and the PAGE says so. The walker returned `settles = 0` on both"
            " of its pages — this number can only have come from the loop"
        ),
    )
    var tail = cloud_log_page_to_run_log_tail(page, String("exec-z"))
    assert_equal(
        tail.settles,
        1,
        "⭐ AND IT SURVIVES THE ADAPTER — a count the renderer cannot see is a"
        " count the operator cannot read",
    )
    var out = render_run_log_tail(tail^)
    assert_true(
        out.find(String("1 settle(s)")) >= 0,
        String("…all the way to the rendered line. Got: ") + out,
    )
    _ = w^


def test_a_ZERO_settle_read_reports_ZERO_not_a_blank() raises:
    """⛔ THE NEGATIVE TWIN, and it is the one that makes the field a
    MEASUREMENT rather than a decoration. A credible first read spends no wait,
    and the report must say `0 settle(s)` — an omitted number and a zero are
    indistinguishable to a reader, which is the whole shape of this defect."""
    var w = ScriptedWalker(_counts(CONTAINER_LOG_CREDIBLE_FLOOR), _ended(1))
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(page.settles, 0, "no wait was spent and the page says 0")
    var out = render_run_log_tail(
        cloud_log_page_to_run_log_tail(page, String("exec-z"))
    )
    assert_true(
        out.find(String("0 settle(s)")) >= 0,
        String(
            "⭐ printed as an explicit ZERO. Got: "
        )
        + out,
    )
    _ = w^


def test_a_FAULT_mid_settle_still_reports_the_waits_it_spent() raises:
    """⛔ A SETTLE THAT WAS SPENT AND THEN HIT A 403 STILL COST THE WALL IT COST.

    The fault return is a SECOND construction site inside the loop, and a field
    wired only on the success path is a field that reads as 0 on exactly the
    reports where the enrichment took longest. `pages` already accumulates across
    that boundary for the same reason."""
    # walk 0 -> 0 entries, stream ENDED  => the loop settles (waits = 1)
    # walk 1 -> the scripted 403           => the fault return runs
    var counts = _counts(0)
    var toks = _ended(1)
    var w = ScriptedWalker(counts^, toks^)
    w.fault_on_walk = 1
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_false(page.ok(), "sanity: the second walk faulted")
    assert_equal(w.waits, 1, "sanity: a settle had already been spent")
    assert_equal(
        page.settles,
        1,
        (
            "⛔ and the FAULT return carries it. A wall that was paid must be"
            " reported on the report that paid it"
        ),
    )
    _ = w^


def test_a_CREDIBLE_first_read_costs_ZERO_SECONDS() raises:
    """★ THE COST GUARD FOR THE COMMON RED STEP. Once ingestion has caught up —
    which is the overwhelmingly common case — a failing step's enrichment must
    add no wall time at all."""
    var w = ScriptedWalker(_counts(CONTAINER_LOG_CREDIBLE_FLOOR), _ended(1))
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(w.walks, 1, "ONE read, and the read was CREDIBLE")
    assert_equal(w.waits, 0, "⛔ and ZERO settles — no second is spent")
    assert_equal(len(page.entries), CONTAINER_LOG_CREDIBLE_FLOOR, "kept")
    _ = w^


def test_an_OUTSTANDING_continuation_token_is_never_settled_on() raises:
    """⛔ A walk that stopped on its OWN bound has more RIGHT NOW. Waiting for
    more to ARRIVE answers a question nobody asked, and it is the branch a naive
    "settle whenever the read is short" would get wrong."""
    var toks = List[String]()
    toks.append(String("more-please"))
    var w = ScriptedWalker(_counts(0), toks^)
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(w.walks, 1, "ONE read, with a token outstanding")
    assert_equal(w.waits, 0, "⛔ and ZERO settles despite ZERO entries")
    assert_false(
        page.next_token.byte_length() == 0,
        "and the token SURVIVES, so the renderer still says done=false",
    )
    _ = w^


def test_a_settle_that_GREW_NOTHING_stops_the_waiting() raises:
    """Five seconds that produced no new entry means the next five will not
    either. An empty stream is an ANSWER."""
    var w = ScriptedWalker(_counts(0, 0, 0), _ended(3))
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(w.waits, 1, "ONE settle, then it stopped — not the ceiling")
    assert_equal(w.walks, 2, "two reads")
    assert_equal(len(page.entries), 0, "and the empty answer is returned")
    _ = w^


def test_the_settle_CEILING_holds_even_while_the_stream_keeps_growing() raises:
    """⛔ THE BOUND IS THE POINT. A stream that grows by one entry per settle
    would otherwise poll forever inside a failure report, in a process that gets
    SIGKILLed on its own deadline."""
    # ⚠ THE STREAM MUST GENUINELY GROW EVERY ROUND, or the "grew nothing" arm
    # stops the loop first and this test would pass for the WRONG REASON —
    # reporting the ceiling held when it was never approached. 0 -> 1 -> 2 -> 3
    # grows on every settle and stays under the credible floor throughout.
    var g = List[Int]()
    g.append(0)
    g.append(1)
    g.append(2)
    g.append(3)
    var w2 = ScriptedWalker(g^, _ended(9))
    var page = read_container_output_settled[ScriptedWalker](
        w2, String("h"), 50
    )
    assert_equal(
        w2.waits,
        DEFAULT_MAX_CONTAINER_LOG_SETTLES,
        "the settle budget is spent and NOT exceeded",
    )
    assert_equal(
        w2.waited_seconds,
        DEFAULT_MAX_CONTAINER_LOG_SETTLES * CONTAINER_LOG_SETTLE_S,
        "⛔ THE WHOLE CEILING, in seconds: 2 x 5 = 10 added to a RED step only",
    )
    assert_equal(w2.walks, DEFAULT_MAX_CONTAINER_LOG_SETTLES + 1, "and 3 reads")
    assert_equal(
        len(page.entries),
        2,
        "with the best read returned — and it is the THIRD walk's 2, which is"
        " what proves the loop actually reached the ceiling rather than"
        " stopping early on a stream that stopped growing",
    )
    _ = w2^


def test_a_FAULT_ends_the_settle_and_KEEPS_the_earlier_entries() raises:
    """⛔ TWO RULES AT ONCE. Settling on a 403 makes the report late without
    making it better; and discarding an earlier round's entries because a later
    round faulted trades a diagnosable partial read for an undiagnosable empty
    one."""
    var w = ScriptedWalker(_counts(1, 0), _ended(2), fault_on_walk=1)
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(w.walks, 2, "the fault came on the SECOND walk")
    assert_equal(w.waits, 1, "one settle had been spent before it")
    assert_false(page.ok(), "the fault is REPORTED, not swallowed")
    assert_equal(
        len(page.entries),
        1,
        "⛔ and the entry read BEFORE the fault survives it",
    )
    _ = w^


def test_a_re_read_that_came_back_SHORTER_never_regresses_the_evidence() raises:
    """A settle re-reads from the beginning — a fresh query, not a continuation
    — so in principle it can answer with less. Whichever read saw more wins."""
    var g = List[Int]()
    g.append(1)
    g.append(0)
    var w = ScriptedWalker(g^, _ended(2))
    var page = read_container_output_settled[ScriptedWalker](
        w, String("h"), 50
    )
    assert_equal(
        len(page.entries),
        1,
        "the SHORTER re-read did not erase the entry the first read had",
    )
    _ = w^


def test_the_settle_predicate_ignores_growth_on_its_FIRST_decision() raises:
    """⚠ There is no previous read to have grown from, so consulting
    `grew_since_last` at `settles_done == 0` — with the obvious `False` seed —
    would disable the settle entirely. This is the assertion that catches that
    one-word regression."""
    assert_true(
        container_log_should_settle(0, String(""), 0, False),
        "an empty ENDED first read settles, `grew` notwithstanding",
    )
    assert_false(
        container_log_should_settle(0, String(""), 1, False),
        "but a SECOND settle needs the first to have grown something",
    )
    assert_true(
        container_log_should_settle(0, String(""), 1, True),
        "and it takes one when it did",
    )


# =============================================================================
# §10 — ★★ THE EMPTY-PAGE WALK, DRIVEN THROUGH THE **SHARED LOOP**.
#
# ── ⛔ THE PROBLEM ───────────────────────────────────────────────────────────
#   run-log: NO CONTAINER OUTPUT read for … — 0 row(s) (3 page(s), 0 settle(s),
#   done=false). … it stopped on its own page/row bound with a continuation
#   token outstanding
#
# THREE PAGES WALKED, ZERO ROWS RETURNED, token still outstanding. A page bound
# counted over ALL pages fires against the ONE case it was never meant to stop:
# `entries:list` returns pages with NO matching entries while it scans a wide
# window under a narrow filter, so the walk burns its whole budget on empty
# pages and reports `0 row(s)` AS THE ANSWER.
#
# ⛔ THESE DRIVE THE LOOP, NOT ONLY THE PREDICATE. §8 proves the ARITHMETIC;
# such a read is decided by the ARGUMENTS the loop passes to it, and the loop
# lives in the leaf precisely so a test can reach them.
# =============================================================================
struct ScriptedPager(ContainerLogPager, Movable, Deinitable):
    """A pager whose Nth page returns `counts[N]` entries and `tokens[N]` as its
    continuation, RECORDING every page size and cursor it was asked for.

    `tail_mode` decides what happens PAST the script, which is where the
    pathological cases live:
      0 — zero entries, NO token. The stream ENDED.
      1 — zero entries, an ALWAYS-ADVANCING token. An infinite empty stream; the
          case a bound has to terminate.
      2 — zero entries, THE SAME token every time. CloudWatch's end-of-stream
          shape (`nextForwardToken` is always present and repeats)."""

    var counts: List[Int]
    var tokens: List[String]
    var reads: Int
    var sizes: List[Int]
    var cursors: List[String]
    var fault_on_page: Int
    var tail_mode: Int

    def __init__(
        out self,
        var counts: List[Int],
        var tokens: List[String],
        tail_mode: Int = 0,
        fault_on_page: Int = -1,
    ):
        self.counts = counts^
        self.tokens = tokens^
        self.reads = 0
        self.sizes = List[Int]()
        self.cursors = List[String]()
        self.fault_on_page = fault_on_page
        self.tail_mode = tail_mode

    def fetch_page(
        mut self, handle: String, page_size: Int, cursor: String, session: String
    ) raises -> CloudLogPage:
        var i = self.reads
        self.reads += 1
        self.sizes.append(page_size)
        self.cursors.append(cursor.copy())
        if i == self.fault_on_page:
            return CloudLogPage.failed(403, String("scripted fault"))
        var n = self.counts[i] if i < len(self.counts) else 0
        var tok = String("")
        if i < len(self.tokens):
            tok = self.tokens[i].copy()
        elif self.tail_mode == 1:
            tok = String("tok-") + String(i)
        elif self.tail_mode == 2:
            tok = String("tok-stuck")
        var out = List[CloudLogEntry]()
        for k in range(n):
            out.append(
                CloudLogEntry(
                    String("2026-09-14T00:00:00Z"),
                    String("INFO"),
                    String("page ") + String(i) + String(" line ") + String(k),
                )
            )
        return CloudLogPage(out^, 200, String(""), tok^, 1, 0)


def _ints(
    a: Int = -1, b: Int = -1, c: Int = -1, d: Int = -1, e: Int = -1
) -> List[Int]:
    """A page script. ⚠ `-1` is the ABSENT marker, not zero — ZERO ENTRIES is a
    real and load-bearing page here, so a sentinel of 0 would make the whole
    empty-page suite unwritable."""
    var out = List[Int]()
    if a >= 0:
        out.append(a)
    if b >= 0:
        out.append(b)
    if c >= 0:
        out.append(c)
    if d >= 0:
        out.append(d)
    if e >= 0:
        out.append(e)
    return out^


def _toks(n: Int, last_ends: Bool) -> List[String]:
    """`n` pages' continuation tokens, each DIFFERENT from the last so the
    anti-livelock arm does not fire. `last_ends` makes the final page report the
    stream as ENDED (no token)."""
    var out = List[String]()
    for i in range(n):
        if last_ends and i == n - 1:
            out.append(String(""))
        else:
            out.append(String("t") + String(i + 1))
    return out^


def test_a_walk_whose_first_pages_are_EMPTY_still_REACHES_the_rows() raises:
    """★★ THE CASE THE BUDGET EXISTS FOR, AND THE FLOOR. Four pages with
    nothing in them, then the rows. Charged against the output-volume bound,
    this walk would stop at page THREE and report `0 row(s)` as the container's
    output."""
    assert_true(
        4 > DEFAULT_MAX_CONTAINER_LOG_PAGES,
        "⛔ ANTI-VACUITY: the rows must sit BEYOND the output-volume bound, or"
        " this test would pass against a walk that charges empty pages to that bound",
    )
    var p = ScriptedPager(
        _ints(0, 0, 0, 0, 5),
        _toks(5, True),
    )
    var page = walk_container_log_pages[ScriptedPager](
        p, String("h"), 200, String("")
    )
    assert_equal(
        len(page.entries),
        5,
        "⛔ THE FLOOR: the rows behind four empty pages are REACHED",
    )
    assert_equal(p.reads, 5, "and it took exactly five provider reads")
    assert_equal(page.pages, 5, "which the page reports honestly")
    assert_true(
        page.next_token.byte_length() == 0,
        "the provider ended the stream, so nothing is outstanding",
    )
    assert_equal(
        p.cursors[1],
        String("t1"),
        "⛔ each request carries the PROVIDER'S OWN cursor, never an invented"
        " one",
    )
    assert_equal(
        p.sizes[0], 200, "the first round asks for the caller's whole total"
    )
    assert_equal(
        p.sizes[4],
        200,
        "and an EMPTY page consumed none of it, so the round that finally has"
        " rows may still ask for all of them",
    )


def test_the_empty_page_walk_has_a_CEILING_and_an_ALL_EMPTY_stream_ENDS() raises:
    """★★ THE CEILING, AND TERMINATION. A walk that paged forever would also
    "reach the rows" — so the bound is pinned from BOTH sides. An infinite stream
    of empty pages with an always-advancing cursor is the pathological input, and
    it must stop, keep the token, and SAY it stopped early."""
    var p = ScriptedPager(_ints(), _toks(0, False), tail_mode=1)
    var page = walk_container_log_pages[ScriptedPager](
        p, String("h"), 200, String("")
    )
    assert_equal(
        p.reads,
        DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES,
        "⛔ THE CEILING: an all-empty stream stops at the EMPTY-page budget and"
        " nowhere else — not unbounded, and not at the output-volume bound",
    )
    assert_equal(len(page.entries), 0, "there was nothing to find")
    assert_true(
        page.next_token.byte_length() > 0,
        "⛔ AND THE TOKEN SURVIVES: the walk stopped, the STREAM did not, and"
        " dropping it would render a truncated read as a complete one",
    )
    var tail = cloud_log_page_to_run_log_tail(page^, String("exec-x"))
    assert_false(tail.done, "so the report says done=false")
    var out = render_run_log_tail(tail^)
    assert_true(
        _contains(out, String("DID NOT REACH THE END")),
        "and it says so in words, not only in a flag",
    )


def test_a_HEALTHY_read_is_UNCHANGED_by_the_empty_page_budget() raises:
    """⛔ THE COST GUARD. The empty-page budget must buy a read that IS producing
    output exactly NOTHING — otherwise this is the "just raise `max_pages`" fix
    wearing a second constant's name, and every healthy read pays for it."""
    var p = ScriptedPager(
        _ints(2, 2, 2, 2, 2),
        _toks(5, False),
    )
    var page = walk_container_log_pages[ScriptedPager](
        p, String("h"), 200, String("")
    )
    assert_equal(
        p.reads,
        DEFAULT_MAX_CONTAINER_LOG_PAGES,
        "⛔ a walk whose every page produced entries stops at the OUTPUT-VOLUME"
        " bound, exactly as it would without the empty-page budget",
    )
    assert_equal(len(page.entries), 6, "with the three pages' worth of rows")
    assert_true(
        page.next_token.byte_length() > 0,
        "and the token it stopped on is kept, so `done=false`",
    )


def test_a_cursor_that_does_NOT_ADVANCE_cuts_the_walk() raises:
    """★★ THE ANTI-LIVELOCK ARM, AND IT IS WHAT MAKES THIS LOOP SAFE FOR AWS.
    CloudWatch's `nextForwardToken` is ALWAYS present and REPEATS at the end of a
    stream, so a walk keyed only on "is there a token" would spend its entire
    empty-page budget proving a stream had ended — every read, on every red
    step."""
    var p = ScriptedPager(_ints(), _toks(0, False), tail_mode=2)
    var page = walk_container_log_pages[ScriptedPager](
        p, String("h"), 200, String("")
    )
    assert_equal(
        p.reads,
        2,
        "⛔ the SAME token twice ends the walk on the second read — the whole"
        " cost of confirming the end on a position-cursor API",
    )
    assert_true(
        2 < DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES,
        "⛔ ANTI-VACUITY: it must be the ADVANCE arm that cut this and not the"
        " empty-page budget, or this test proves nothing about either",
    )
    assert_equal(len(page.entries), 0, "and nothing was found")


def test_a_FAULT_mid_walk_KEEPS_what_the_empty_pages_finally_bought() raises:
    """⛔ PARTIAL IS REPORTED AS PARTIAL. Two empty pages, then rows, then a 403.
    Discarding the rows because the NEXT page faulted would trade a diagnosable
    partial read for an undiagnosable empty one — and those rows are the ones
    the empty-page budget was spent to reach."""
    var p = ScriptedPager(
        _ints(0, 0, 3),
        _toks(3, False),
        fault_on_page=3,
    )
    var page = walk_container_log_pages[ScriptedPager](
        p, String("h"), 200, String("")
    )
    assert_false(page.ok(), "the fault is reported")
    assert_equal(page.status, 403, "with the provider's own status")
    assert_equal(
        len(page.entries), 3, "and the rows already read are KEPT"
    )
    assert_equal(page.pages, 4, "over four provider reads, counted honestly")


def test_the_AWS_request_carries_the_FORWARD_TOKEN_and_escapes_it() raises:
    """★★ THE SECOND ARM'S REQUEST HALF. `GetLogEvents` may answer
    with an EMPTY `events` list AND a forward token — AWS's own guidance is to
    repeat with the token until the SAME token comes back twice — so this arm
    walks too, and a walk that could not CARRY the cursor would be one round
    trip wearing a loop's name.

    ⛔ `startFromHead` STAYS `true`, AND THAT IS NOT INCIDENTAL: AWS REQUIRES it
    when a previous `nextForwardToken` is supplied. The two fields interact and
    this is the one place both are written."""
    var first = get_log_events_body(
        String("/ecs/example"), String("s"), 200
    )
    assert_true(
        first.find(String("nextToken")) < 0,
        String(
            "⛔ BYTE-IDENTICAL FOR THE FIRST READ: no token, no key, so every"
            " first-page request carries no token field. Got: "
        )
        + first,
    )
    var next = get_log_events_body(
        String("/ecs/example"), String("s"), 50, String('f/3"abc')
    )
    assert_true(
        next.find(String('"nextToken":"f/3\\"abc"')) >= 0,
        String("the token rides, ESCAPED like every other value. Got: ")
        + next,
    )
    assert_true(
        next.find(String('"limit":50')) >= 0,
        String(
            "…alongside the REMAINDER the shared walk asked for, not the"
            " original total. Got: "
        )
        + next,
    )
    assert_true(
        next.find(String('"startFromHead":true')) >= 0,
        String(
            "⛔ and oldest-first SURVIVES the token, which AWS requires. Got: "
        )
        + next,
    )


def test_the_empty_page_BUDGET_is_DERIVED_from_a_stated_wall() raises:
    """★★ THE ARGUMENT FOR THE NUMBER, PINNED. A bound that is a bare literal is
    a bound the next reader raises. This one is WALL divided by an assumed
    round trip, and the wall is strictly less than ONE settle — because an
    empty-page sweep and a settle are alternative ways of spending time to get
    the same rows, so the sweep must not cost more than the wait it stands in
    for."""
    assert_true(
        CONTAINER_LOG_PAGE_ROUND_TRIP_MS > 0,
        "sanity: the assumed round trip is a real number",
    )
    assert_true(
        DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES
        * CONTAINER_LOG_PAGE_ROUND_TRIP_MS
        <= CONTAINER_LOG_EMPTY_PAGE_BUDGET_MS,
        "⛔ the page count is DERIVED from the wall budget — raising it without"
        " moving the budget is changing the argument silently",
    )
    assert_true(
        CONTAINER_LOG_EMPTY_PAGE_BUDGET_MS < CONTAINER_LOG_SETTLE_S * 1000,
        "⛔ and the wall budget is strictly LESS than one settle",
    )
    assert_true(
        DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES > DEFAULT_MAX_CONTAINER_LOG_PAGES,
        "⛔ it has to buy something: a zero-row read otherwise stops at the"
        " output-volume bound with a token in hand",
    )
    assert_true(
        DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES
        + DEFAULT_MAX_CONTAINER_LOG_PAGES
        <= 20,
        "⛔ AND THE WALK'S WORST CASE IS THE SUM OF THE TWO BOUNDS. A page"
        " either produced entries or did not; there is no third kind, so this"
        " is the whole termination argument in one number",
    )


# =============================================================================
# §11 — ★★ THE NEXT-ACTION ADVICE BRANCHES ON `done`.
#
# ── ⛔ THE PROBLEM: ONE PARAGRAPH, TWO CONTRADICTORY REMEDIES ────────────────
# A report that says BOTH *"re-run THIS gate alone once ingestion has caught up
# … which re-reads this same stream at a later T"* AND *"no amount of waiting
# produces it and a re-read is what fetches it"* sends an operator reading the
# first sentence to wait for data that is ALREADY on the provider.
# =============================================================================
def _container_tail(rows: Int, done: Bool, settles: Int) -> RunLogTail:
    var page = CloudLogPage.empty(200)
    for k in range(rows):
        page.entries.append(
            CloudLogEntry(
                String("2026-09-14T00:00:00Z"),
                String("INFO"),
                String("row ") + String(k),
            )
        )
    if not done:
        page.next_token = String("tok-more")
    page.settles = settles
    return cloud_log_page_to_run_log_tail(page^, String("exec-x"))


def test_a_read_with_a_TOKEN_OUTSTANDING_is_told_to_RE_READ_not_to_WAIT() raises:
    """⛔ `done=false` MEANS WAITING BUYS NOTHING. The walk stopped on its own
    bound while the provider still held stream, so the missing rows are already
    there and a SECOND READ is the entire remedy."""
    var out = render_run_log_tail(_container_tail(0, False, 0))
    assert_true(
        _contains(out, String("RE-READ this stream NOW")),
        "the remedy names a re-read, and says NOW",
    )
    assert_false(
        _contains(out, String("ONCE INGESTION HAS CAUGHT UP")),
        "⛔ AND IT MUST NOT ALSO SAY 'wait' — that is the self-contradiction"
        " this branch exists to remove",
    )
    assert_true(
        _contains(out, String("no amount of waiting produces it")),
        "the evidence clause still states WHY, and now AGREES with the remedy",
    )


def test_a_read_the_provider_ENDED_is_still_told_to_wait_for_ingestion() raises:
    """⛔ THE OTHER BRANCH, AND IT MUST SURVIVE. `done=true` says the provider
    reported the stream as ending here — so a short answer is either genuinely
    short or was taken before ingestion caught up, and TIME is the remedy. A fix
    that made every report say "re-read now" would have broken the case the
    settle was built for."""
    var out = render_run_log_tail(_container_tail(1, True, 0))
    assert_true(
        _contains(out, String("ONCE INGESTION HAS CAUGHT UP")),
        "an ENDED stream is the ingestion-lag case and keeps that advice",
    )
    assert_false(
        _contains(out, String("RE-READ this stream NOW")),
        "and must not be told the opposite in the same paragraph",
    )
    assert_true(
        _contains(out, String("SPENT **NO** SETTLE")),
        "and the zero-wait finding is untouched by this change",
    )


def main() raises:
    test_the_handle_is_self_addressing()
    test_the_filter_is_the_one_the_report_has_been_printing()
    test_the_request_body_scopes_the_project_and_escapes_the_filter()
    test_the_body_asks_for_OLDEST_first_and_that_is_not_cosmetic()
    test_a_handle_with_no_execution_id_is_REFUSED_not_guessed()
    test_an_empty_project_is_REFUSED_at_the_body()
    test_the_not_configured_source_REFUSES_rather_than_answering_empty()
    test_a_field_nobody_listed_cannot_print_itself()
    test_a_structured_payload_entry_is_KEPT_not_dropped()
    test_a_text_payload_that_looks_like_json_does_not_fool_the_scan()
    test_an_absent_entries_key_is_a_SUCCESS_with_nothing_in_it()
    test_a_malformed_body_is_reported_WITHOUT_echoing_it()
    test_a_page_renders_through_the_EXISTING_report_renderer()
    test_a_faulted_page_becomes_a_fetch_error_not_a_fake_empty()
    test_the_scripted_double_honours_the_fetch_bound()
    test_the_aws_arm_derives_its_stream_from_the_task_arn_alone()
    test_the_aws_arm_asks_for_oldest_first_too()
    test_the_aws_response_parses_through_the_SAME_page_and_adapter()
    test_the_aws_arm_does_not_leak_a_non_listed_field()
    test_the_aws_conformer_holds_NO_region_because_the_handle_carries_one()
    test_an_UNPARSEABLE_arn_yields_NO_region_and_never_a_default()
    test_the_cloudwatch_host_is_REGIONAL_where_the_gcp_one_is_GLOBAL()
    # §8 — ★★ the BOUNDED multi-page walk. A single read at T+0 against an
    # asynchronously-ingesting provider would present an empty or short first
    # page as the container's whole output.
    test_the_walk_follows_a_continuation_token()
    test_a_stream_that_ENDED_is_not_re_read()
    test_the_walk_is_BOUNDED_and_the_bound_is_the_point()
    test_limit_is_the_TOTAL_and_the_walk_asks_for_the_remainder()
    test_a_walk_stopped_by_its_own_bound_still_says_the_stream_goes_on()
    test_the_page_count_on_the_wire_is_the_conformer_s_own()
    test_a_page_token_rides_the_request_and_is_ESCAPED()
    test_a_refused_handle_is_still_refused_with_a_token_in_hand()
    # §10 — ★★ the EMPTY-PAGE walk, driven through the SHARED loop.
    # ⚠ THESE RUN BEFORE THE SETTLE CASES for the file's standing reason: a Mojo
    # test binary aborts on the first failed assertion, so a probe that breaks
    # the walk must red in a test that NAMES the walk.
    test_a_walk_whose_first_pages_are_EMPTY_still_REACHES_the_rows()
    test_the_empty_page_walk_has_a_CEILING_and_an_ALL_EMPTY_stream_ENDS()
    test_a_HEALTHY_read_is_UNCHANGED_by_the_empty_page_budget()
    test_a_cursor_that_does_NOT_ADVANCE_cuts_the_walk()
    test_a_FAULT_mid_walk_KEEPS_what_the_empty_pages_finally_bought()
    test_the_AWS_request_carries_the_FORWARD_TOKEN_and_escapes_it()
    test_the_empty_page_BUDGET_is_DERIVED_from_a_stated_wall()
    # §11 — ★★ the next-action advice BRANCHES on `done`.
    test_a_read_with_a_TOKEN_OUTSTANDING_is_told_to_RE_READ_not_to_WAIT()
    test_a_read_the_provider_ENDED_is_still_told_to_wait_for_ingestion()
    # §9 — ★★ the BOUNDED SETTLE. Paging is not waiting: a read can be
    # `2 pages, done=true` and ONE LINE.
    # ⚠ THE COST GUARD RUNS FIRST, DELIBERATELY. A Mojo test binary aborts on the
    # first failed assertion, so a probe that breaks the credible-floor branch
    # would otherwise red on the settle case below and leave THIS one's own
    # assertion unproven. Order is what makes each probe name its own test.
    # ★★★ the waits are REPORTED, not only spent. These run before
    # the other settle cases for the same reason the cost guard does: a Mojo test
    # binary aborts on the first failed assertion, so a probe that breaks the
    # count would otherwise red somewhere that does not name it.
    test_the_settle_COUNT_rides_out_on_the_page_and_through_the_adapter()
    test_a_ZERO_settle_read_reports_ZERO_not_a_blank()
    test_a_FAULT_mid_settle_still_reports_the_waits_it_spent()
    test_a_CREDIBLE_first_read_costs_ZERO_SECONDS()
    test_a_read_that_ENDED_with_almost_nothing_SETTLES_and_re_reads()
    test_an_OUTSTANDING_continuation_token_is_never_settled_on()
    test_a_settle_that_GREW_NOTHING_stops_the_waiting()
    test_the_settle_CEILING_holds_even_while_the_stream_keeps_growing()
    test_a_FAULT_ends_the_settle_and_KEEPS_the_earlier_entries()
    test_a_re_read_that_came_back_SHORTER_never_regresses_the_evidence()
    test_the_settle_predicate_ignores_growth_on_its_FIRST_decision()
    print("PASS test_cloud_log_source")
