# The caller's test of the mojo_aws_client hand_srcs fixture: the hand-written
# module was copied into the generated package, is importable from it, and
# builds the request through the generated encoder.
from komira_aws_logs_hand.komira_aws_logs_hand import CloudWatchLogsGetLogEventsRequest
from komira_aws_logs_hand.logs_overrides import get_log_events
from std.testing import assert_equal


def main() raises:
    var req = get_log_events(CloudWatchLogsGetLogEventsRequest(String("web-1")))
    assert_equal(req.header(String("X-Amz-Target")), "Logs_20140328.GetLogEvents")
    assert_equal(req.body_text(), '{"logStreamName":"web-1"}')
