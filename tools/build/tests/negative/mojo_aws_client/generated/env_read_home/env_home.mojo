"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. No name the scan bans appears here: Path.home reads
HOME inside the standard library. The generated environment scan
(_no_env_reads) refuses the import of std.pathlib, which is not on its
allow-list.
"""

from std.pathlib import Path

from komira_aws_core import AwsRequest

from .env_read_home import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
