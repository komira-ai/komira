"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. A backtick identifier holds a `'`; Mojo reads it as
part of the name, not the start of a string. The import of std.pathlib
follows it after a semicolon; Path.home reads HOME inside the standard
library. The generated environment scan (_no_env_reads) reads the name
whole and refuses std.pathlib, which is not on its allow-list.
"""

from komira_aws_core import AwsRequest
comptime `q'` = 0; from std.pathlib import Path

from .env_read_backtick_quote import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
