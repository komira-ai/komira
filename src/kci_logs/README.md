# kci_logs

Reads the logs behind a failed step, for the release tool and its validators.
Two families share one bounded, redacting renderer (`render_run_log_tail` over a
`RunLogTail`). Run logs: `build_run_logs_url` composes a run's
`.../runs/<id>/logs?after=&limit=` URL, `fetch_run_log_tail` follows its cursor
over a `RunLogTransport` trait, and `parse_run_logs_body` keeps only the
allow-listed fields (`seq`, `ts`, `level`, `step`, `message`) and never echoes a
response body. Cloud logs: a terminated container's output (a Cloud Run Job
execution or an ECS task) is read behind the cloud-neutral `CloudLogSource`
trait, with the pure request and parse halves for Cloud Logging
(`cloud_run_execution_log_filter`, `parse_entries_list_body`) and CloudWatch
Logs (`ecs_task_log_stream`, `get_log_events_body`, `parse_get_log_events_body`),
and bounded paging and settle loops. The package has no dependencies, opens no
socket (the transport is a trait the caller implements), and its readers never
raise: a transport fault or a non-200 answer is recorded on the tail.

## Examples

Compose the URL of one page of a run's log stream:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_logs import DEFAULT_RUN_PATH_PREFIX, build_run_logs_url

assert_equal(
    build_run_logs_url("https://runs.example/", DEFAULT_RUN_PATH_PREFIX, "r1", 7, 50),
    "https://runs.example/runs/r1/logs?after=7&limit=50",
)
```

Parse a page: keys outside the allow-list are dropped, and the renderer
redacts credential-shaped text:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from kci_logs import parse_run_logs_body, redact_secretish, render_run_log_tail

var tail = parse_run_logs_body(
    '{"run_id":"r1","lines":[{"seq":1,"ts":5,"level":"error","step":"deploy",'
    + '"message":"Bearer abc123 rejected","secret":"s3cr3t"}],'
    + '"next_cursor":1,"done":true}',
    "r1",
)
assert_true(tail.ok())
assert_equal(len(tail.records), 1)
assert_equal(tail.records[0].step, "deploy")
assert_true(tail.done)
assert_equal(redact_secretish("Bearer abc123 rejected"), "Bearer [REDACTED] rejected")
var text = render_run_log_tail(tail)
assert_true("[REDACTED]" in text)
assert_false("abc123" in text)
assert_false("s3cr3t" in text)
```

Read through a transport; a non-200 answer becomes a `fetch_error` that names
the status and never the body:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo module
from kci_logs import RunLogResponse, RunLogTransport, fetch_run_log_tail


struct FixedAnswer(RunLogTransport, Movable, Deinitable):
    var status: Int
    var body: String

    def __init__(out self, status: Int, body: String):
        self.status = status
        self.body = body

    def get(mut self, url: String) raises -> RunLogResponse:
        return RunLogResponse.of(self.status, self.body)


def main() raises:
    var good = FixedAnswer(
        200,
        '{"run_id":"r1","lines":[{"seq":1,"ts":5,"level":"info","step":"build",'
        + '"message":"compiled"}],"next_cursor":1,"done":true}',
    )
    var tail = fetch_run_log_tail[FixedAnswer](good, "https://runs.example", "r1")
    assert_true(tail.ok())
    assert_equal(tail.records[0].message, "compiled")
    assert_equal(tail.pages, 1)

    var denied = FixedAnswer(403, '{"access_token":"leak"}')
    var failed = fetch_run_log_tail[FixedAnswer](denied, "https://runs.example", "r1")
    assert_false(failed.ok())
    assert_true("HTTP 403" in failed.fetch_error)
    assert_false("leak" in failed.fetch_error)
```

Derive the CloudWatch Logs stream an ECS task writes to; a missing part is a
refusal (an empty name), never a partial one:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_logs import ecs_task_id, ecs_task_log_stream

var arn = "arn:aws:ecs:us-east-1:123456789012:task/example-cluster/abc123"
assert_equal(ecs_task_id(arn), "abc123")
assert_equal(ecs_task_log_stream("ecs", "validator", arn), "ecs/validator/abc123")
assert_equal(ecs_task_log_stream("", "validator", arn), "")
```
