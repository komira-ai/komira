# komira_aws_scheduler

An Amazon EventBridge Scheduler client, generated at build time from
botocore's pinned `scheduler` model (restJson1). The module
`komira_aws_scheduler.komira_aws_scheduler` holds, for CreateSchedule,
GetSchedule, UpdateSchedule and DeleteSchedule:

- an input struct (`Scheduler<Operation>Input`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`
  (method, `/schedules/<name>` path, query and JSON body), refusing a value
  outside the model's bounds before a request exists;
- a response parser `parse_<operation>_response` over a komira_aws_core
  `AwsResponse`, and the modeled error shapes (`SchedulerConflictException`
  and the others), each read with `from_aws_json`;
- an endpoint resolver `resolve_<operation>_endpoint`, which runs the
  service's published endpoint ruleset
  (`komira_aws_scheduler_endpoint_rules()`) over a `SchedulerEndpointConfig`;
- `SchedulerClient`, which resolves each call's endpoint, signs it with SigV4
  (signing name `scheduler`) and sends it over the komira_http_core
  `Connector` it is given, retried as the AWS SDKs' standard mode retries.

UpdateSchedule replaces the whole schedule (the service resets every field
the request leaves out), so a caller sends the same shape it created with.
The client's verbs fill an unset `ClientToken` with a fresh UUID before the
request is built, so a resend carries the same token; the builders send what
they are given. Other Scheduler operations (schedule groups, listing) are not
generated. The package reads no environment.

## Examples

Build a CreateSchedule request for a nightly cron schedule. Nothing is sent:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_aws_scheduler.komira_aws_scheduler import SCHEDULER_FLEXIBLE_TIME_WINDOW_MODE_OFF
from komira_aws_scheduler.komira_aws_scheduler import SCHEDULER_SCHEDULE_STATE_ENABLED
from komira_aws_scheduler.komira_aws_scheduler import SchedulerCreateScheduleInput
from komira_aws_scheduler.komira_aws_scheduler import SchedulerFlexibleTimeWindow, SchedulerTarget
from komira_aws_scheduler.komira_aws_scheduler import build_create_schedule_request

var target = SchedulerTarget(
    String("arn:aws:lambda:us-east-1:123456789012:function:reaper"),
    String("arn:aws:iam::123456789012:role/scheduler-invoke"),
)
var input = SchedulerCreateScheduleInput(
    SchedulerFlexibleTimeWindow(String(SCHEDULER_FLEXIBLE_TIME_WINDOW_MODE_OFF)),
    String("nightly-reap"),
    String("cron(0 3 * * ? *)"),
    target^,
)
input.set_group_name(String("apps"))
input.set_state(String(SCHEDULER_SCHEDULE_STATE_ENABLED))
var req = build_create_schedule_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/schedules/nightly-reap")
assert_equal(req.header(String("Content-Type")), "application/json")
assert_equal(
    req.body_text(),
    '{"FlexibleTimeWindow":{"Mode":"OFF"},"GroupName":"apps",'
    + '"ScheduleExpression":"cron(0 3 * * ? *)","State":"ENABLED",'
    + '"Target":{"Arn":"arn:aws:lambda:us-east-1:123456789012:function:reaper",'
    + '"RoleArn":"arn:aws:iam::123456789012:role/scheduler-invoke"}}',
)
```

GetSchedule is a GET naming the schedule; a name the model's bounds refuse
never becomes a request:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_scheduler.komira_aws_scheduler import SchedulerGetScheduleInput
from komira_aws_scheduler.komira_aws_scheduler import build_get_schedule_request

var get = SchedulerGetScheduleInput(String("nightly-reap"))
get.set_group_name(String("apps"))
var get_req = build_get_schedule_request(get)
assert_equal(get_req.method, "GET")
assert_equal(get_req.uri, "/schedules/nightly-reap?groupName=apps")
with assert_raises(contains="Name"):
    _ = build_get_schedule_request(SchedulerGetScheduleInput(String("")))
```

Decode a GetSchedule answer, and read a restJson1 error (the code from the
`X-Amzn-Errortype` header, cut at its first `:`):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse, aws_rest_json_error
from komira_aws_scheduler.komira_aws_scheduler import SchedulerResourceNotFoundException
from komira_aws_scheduler.komira_aws_scheduler import parse_get_schedule_response
from komira_json import parse_json_value

var out = parse_get_schedule_response(
    AwsResponse.of_text(
        200,
        String(
            '{"Name":"nightly-reap","GroupName":"apps","State":"ENABLED",'
            + '"ScheduleExpression":"cron(0 3 * * ? *)","FlexibleTimeWindow":{"Mode":"OFF"}}'
        ),
    )
)
assert_equal(out.name.value(), "nightly-reap")
assert_equal(out.state.value(), "ENABLED")
assert_equal(out.flexible_time_window.value().mode, "OFF")

var resp = AwsResponse.of_text(
    404, String('{"Message":"Schedule nightly-reap does not exist."}')
)
resp.add_header(String("X-Amzn-Errortype"), String("ResourceNotFoundException:http://example.com/"))
var info = aws_rest_json_error(resp)
assert_equal(info.status, 404)
assert_equal(info.code, "ResourceNotFoundException")
var err = SchedulerResourceNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
assert_equal(err.message, "Schedule nightly-reap does not exist.")
```

Resolve the endpoint a call goes to:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_aws_scheduler.komira_aws_scheduler import SchedulerGetScheduleInput
-->
```mojo
from komira_aws_scheduler.komira_aws_scheduler import SchedulerEndpointConfig
from komira_aws_scheduler.komira_aws_scheduler import komira_aws_scheduler_endpoint_rules
from komira_aws_scheduler.komira_aws_scheduler import resolve_get_schedule_endpoint

var rules = komira_aws_scheduler_endpoint_rules()
var input = SchedulerGetScheduleInput(String("nightly-reap"))
assert_equal(
    resolve_get_schedule_endpoint(rules, SchedulerEndpointConfig(String("us-west-2")), input).url,
    "https://scheduler.us-west-2.amazonaws.com",
)
var fips = SchedulerEndpointConfig(String("us-east-1"))
fips.use_fips = Optional[Bool](True)
assert_equal(
    resolve_get_schedule_endpoint(rules, fips, input).url,
    "https://scheduler-fips.us-east-1.amazonaws.com",
)
```
