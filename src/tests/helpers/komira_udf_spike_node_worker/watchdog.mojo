# A bound on how long a test of this package runs.
#
# The tests run as build actions (welded test_srcs), which have no timeout:
# a test that hangs, waiting on a worker that will never answer, would hold
# its executor until someone stops it. Each test arms an alarm first, so a
# hang ends the test with SIGALRM (a failure) instead.

from std.ffi import external_call

comptime TEST_LIMIT_S = 240
"""Seconds a test of this package may run; each runs well under a minute."""


def arm_watchdog(seconds: Int = TEST_LIMIT_S):
    """End this process with SIGALRM after `seconds` (alarm(2); the default
    action of SIGALRM terminates the process). Replaces an earlier alarm."""
    _ = external_call["alarm", UInt32](UInt32(seconds))
