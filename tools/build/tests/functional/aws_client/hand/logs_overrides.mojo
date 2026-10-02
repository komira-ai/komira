"""The hand-written owner of GetLogEvents in the aws_client hand_srcs fixture.

`logs_overrides.json` names `get_log_events` here as the owner of the
operation's plain verb; aws-client-gen refuses the manifest unless this file
defines it, and aws_client copies this file into the generated package next
to the generated module.
"""

from komira_aws_core import AwsRequest

from .komira_aws_logs_hand import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, built by the generated encoder."""
    return build_get_log_events_request(input)
