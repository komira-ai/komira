"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. Two backtick identifiers each hold three single
quotes; read as quotes, they would open and close one triple-quoted string
round the import between them. The import of std.pathlib is a line of its
own; Path.home reads HOME inside the standard library. The generated
environment scan (_no_env_reads) reads each name whole and refuses
std.pathlib, which is not on its allow-list.
"""

from komira_aws_core import AwsRequest
comptime `p'''` = 0
from std.pathlib import Path
comptime `s'''` = 1

from .env_read_backtick_triple import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
