"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. Its function builds a string with a t-string of
prefix `Rt` (upper-case R, then t), whose braces hold a string literal that is one double
quote; the import of std.pathlib follows after a semicolon, and Path.home
reads HOME inside the standard library. Read as a plain string, the
t-string would end at that quote and the single quote after it would
open a string over the import. The generated environment scan
(_no_env_reads) refuses the file: it does not read t-strings.
"""

from komira_aws_core import AwsRequest

from .env_read_t_rt import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused if the home directory is a quote."""
    var quote = String(Rt"{'"'}"); from std.pathlib import Path
    if String(Path.home()) == quote:
        raise Error("the home directory is a quote")
    return build_get_log_events_request(input)
