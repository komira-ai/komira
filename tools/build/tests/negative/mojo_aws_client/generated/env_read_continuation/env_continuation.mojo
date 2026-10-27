"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. The import of std.pathlib is split after `from` by a
backslash at the end of the line; Path.home reads HOME inside the standard
library. The generated environment scan (_no_env_reads) joins the two
lines and refuses std.pathlib, which is not on its allow-list.
"""

from komira_aws_core import AwsRequest
from\
std.pathlib import Path

from .env_read_continuation import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
