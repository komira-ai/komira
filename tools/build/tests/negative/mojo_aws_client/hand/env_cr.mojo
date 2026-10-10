"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. The import of std.pathlib follows a carriage return
that is not followed by a line feed, which Mojo reads as the end of a
line; Path.home reads HOME inside the standard library. The generated
environment scan (_no_env_reads) refuses a file with a carriage return.
"""

from komira_aws_core import AwsRequest
comptime _ZERO = 0from std.pathlib import Path

from .env_read_cr import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)



def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
