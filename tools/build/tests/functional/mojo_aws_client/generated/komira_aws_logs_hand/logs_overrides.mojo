"""The hand-written owner of GetLogEvents in the mojo_aws_client hand_srcs fixture.

`logs_overrides.json` names `get_log_events` here as the owner of the
operation's plain verb; aws-client-gen refuses the manifest unless this file
defines it, and mojo_aws_client copies this file into the generated package next
to the generated module.

The generated environment scan reads the imports of code only. This
docstring, the comment and the string below name std.pathlib, which is off
its allow-list, where it would read an import if they were code:
from std.pathlib import Path
"""

from komira_aws_core import AwsRequest

# Not code: import std.pathlib
comptime _NOT_AN_IMPORT = "a string; import std.pathlib: from std.pathlib import Path"
# A backtick identifier is a name, a quote and a `#` in it included; a
# backslash and the quote after it are one pair in a string, raw or not.
comptime `q'#` = 0
comptime _ESCAPED = "\"; import std.pathlib"
comptime _RAW = r"\"; import std.pathlib"

from .komira_aws_logs_hand import (
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)


def get_log_events(input: CloudWatchLogsGetLogEventsRequest) raises -> AwsRequest:
    """The GetLogEvents request, built by the generated encoder."""
    return build_get_log_events_request(input)
