"""A hand-written owner of GetLogEvents that reads HOME through `from std import os`.

The package compiles. This import form does not contain the module's dotted
name, which the scan also bans; the read is os.path.expanduser, which reads
HOME inside the standard library. The generated environment scan
(_no_env_reads) refuses the name expanduser.
"""

from std import os

from komira_aws_core import AwsRequest

from .env_read_std_os import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, refused unless `~` expands."""
    if os.path.expanduser("~") == "~":
        raise Error("no home directory")
    return build_get_log_events_request(input)
