"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. std.pathlib is imported inside a function body, at an
indent; Path.home reads HOME inside the standard library. The generated
environment scan (_no_env_reads) reads an import at any indent and refuses
std.pathlib, which is not on its allow-list.
"""

from komira_aws_core import AwsRequest

from .env_read_indented import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def _home() raises -> String:
    from std.pathlib import Path

    return String(Path.home())


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if _home() == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
