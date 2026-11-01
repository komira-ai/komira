"""A hand-written owner of GetLogEvents that builds a string with a t-string.

The package compiles and imports nothing off the environment scan's
allow-list. The braces of a t-string hold code, with string literals of
their own, which the generated environment scan (_no_env_reads) does not
lex, so it cannot say where the t-string ends; it refuses the file.
"""

from komira_aws_core import AwsRequest

from .env_read_t_string import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the t-string is not empty."""
    if String(t"{0}") == "":
        raise Error("empty")
    return build_get_log_events_request(input)
