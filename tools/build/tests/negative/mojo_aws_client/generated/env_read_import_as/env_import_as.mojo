"""A hand-written owner of GetLogEvents that reads HOME through std.pathlib.

The package compiles. std.pathlib is the second name of a plain import
list, renamed; Path.home reads HOME inside the standard library. The
generated environment scan (_no_env_reads) reads each name of the list and
refuses std.pathlib, which is not on its allow-list.
"""

import komira_aws_core, std.pathlib as pl

from .env_read_import_as import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(
    input: CloudWatchLogsGetLogEventsRequest,
) raises -> komira_aws_core.AwsRequest:
    """The GetLogEvents request, refused unless the home directory is known."""
    if String(pl.Path.home()) == "":
        raise Error("no home directory")
    return build_get_log_events_request(input)
