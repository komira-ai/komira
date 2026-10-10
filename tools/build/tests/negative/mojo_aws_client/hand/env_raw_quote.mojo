"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. A raw string holds a backslash and then a double
quote; Mojo pairs the two as in a plain string (the backslash is kept), so
that quote does not end the string. Read as the end, the next quote would
open a string that runs to the end of the line, over the import. The import
of std.pathlib follows the string after a semicolon; Path.home reads HOME
inside the standard library. The generated environment scan (_no_env_reads)
reads the pair and refuses std.pathlib, which is not on its allow-list.
"""

from komira_aws_core import AwsRequest
comptime _BACKSLASH_QUOTE = r"\""; from std.pathlib import Path

from .env_read_raw_quote import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
