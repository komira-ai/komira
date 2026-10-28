"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. A triple-quoted string literal ends in an escaped
double quote; read without the escape, the string would close one quote
early and the quote left over would open a string over the import. The
import of std.pathlib follows after a semicolon; Path.home reads HOME
inside the standard library. The generated environment scan
(_no_env_reads) reads the escape and refuses std.pathlib, which is not on
its allow-list.
"""

from komira_aws_core import AwsRequest
comptime _QUOTED = """a\""""; from std.pathlib import Path

from .env_read_triple_escape import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)



def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
