"""A hand-written owner of GetLogEvents that reads the environment.

The package compiles; its generated environment scan (_no_env_reads) reads
this file as part of the package and fails on the read below.
"""

from std.os import getenv

from komira_aws_core import AwsRequest

from .env_read_hand import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless HOME is set."""
    if getenv("HOME") == "":
        raise Error("HOME is not set")
    return build_get_log_events_request(input)
