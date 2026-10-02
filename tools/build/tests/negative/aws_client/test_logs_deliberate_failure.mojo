from caller_test_red.caller_test_red import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)
from std.testing import assert_equal


def main() raises:
    # The target is Logs_20140328.GetLogEvents; the expectation is wrong on
    # purpose, so the client's gate must refuse to publish its package.
    var req = build_get_log_events_request(CloudWatchLogsGetLogEventsRequest(String("web-1")))
    assert_equal(req.header(String("X-Amz-Target")), "Logs_20140328.GetLogEvent")
