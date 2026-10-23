# =============================================================================
# komira_test_verdict/exits.mojo -- the two exits that are not a pass and not
# a test failure: SKIP (77) and CANNOT_TELL (3). Neither is ever exit 0.
# =============================================================================
#
# A test that cannot run (nothing to run against, by default) prints one
# marker line and ENDS THE PROCESS with exit code 77:
#
#     KOMIRA-TEST: SKIP reason=<reason>
#
# A test that was asked to run against something and could not find out
# whether it can (a partial or contradictory configuration, say) prints one
# marker line and ENDS THE PROCESS with exit code 3:
#
#     KOMIRA-TEST: CANNOT_TELL reason=<reason>
#
#     def main() raises:
#         ...
#         if nothing_configured:
#             exit_skip(reason)      # does not return
#
# Both exit themselves rather than return a code for the caller to exit with:
# a returned value can be dropped, and a `main` that drops it and returns
# exits 0, which is a pass. 77 and 3 are non-zero, so a gated test that skips
# or cannot tell fails its gate by construction. No code path in this package
# maps either to exit 0.
#
# Together with the `Verdict` kinds (CLEAN 0, CANNOT_TELL 3, LEAK 6) these are
# one closed set of exit codes: 0 / 3 / 6 / 77.
#
# The marker line is for the person reading the log: it says WHY the test
# did not run. Nothing reads it to decide a verdict; the exit code does that.
# =============================================================================

from std.sys import exit

comptime SKIP_EXIT_CODE: Int = 77
comptime SKIP_MARKER: String = "KOMIRA-TEST: SKIP reason="
comptime CANNOT_TELL_EXIT_CODE: Int = 3
comptime CANNOT_TELL_MARKER: String = "KOMIRA-TEST: CANNOT_TELL reason="


def _one_line(reason: String) -> String:
    var r = reason.replace("\r", " ").replace("\n", " ")
    if r.byte_length() == 0:
        r = String("unspecified")
    return r^


def skip_line(reason: String) -> String:
    """The SKIP marker line for `reason`, kept on one line."""
    return String(SKIP_MARKER) + _one_line(reason)


def cannot_tell_line(reason: String) -> String:
    """The CANNOT_TELL marker line for `reason`, kept on one line."""
    return String(CANNOT_TELL_MARKER) + _one_line(reason)


def exit_skip(reason: String):
    """Print the SKIP marker line and end the process with exit code 77.
    Does not return."""
    print(skip_line(reason))
    exit(SKIP_EXIT_CODE)


def exit_cannot_tell(reason: String):
    """Print the CANNOT_TELL marker line and end the process with exit code
    3. Does not return."""
    print(cannot_tell_line(reason))
    exit(CANNOT_TELL_EXIT_CODE)
