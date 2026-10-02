# =============================================================================
# komira_test_infra/skip.mojo -- SKIP with a reason, which is never a pass.
# =============================================================================
#
# A test that cannot run (no S3-compatible endpoint configured and no pinned
# MinIO binary given -- the default) prints one marker line and ENDS THE PROCESS with exit code 77:
#
#     KOMIRA-TEST-INFRA: SKIP reason=<reason>
#
#     def main() raises:
#         ...
#         if choice.kind == BACKEND_CHOICE_SKIP:
#             exit_skip(choice.reason)      # does not return
#
# `exit_skip` exits itself rather than returning a code for the caller to
# exit with: a returned value can be dropped, and a `main` that drops it and
# returns exits 0, which is a pass. 77 is non-zero, so a gated test that skips
# fails its gate by construction. No code path in this library maps a skip to
# exit 0.
#
# The marker line is for the person reading the log: it says WHY the test
# did not run. Nothing reads it to decide a verdict; the exit code does that.
# =============================================================================

from std.sys import exit

comptime SKIP_EXIT_CODE: Int = 77
comptime SKIP_MARKER: String = "KOMIRA-TEST-INFRA: SKIP reason="


def skip_line(reason: String) -> String:
    """The marker line for `reason`, kept on one line."""
    var r = reason.replace("\r", " ").replace("\n", " ")
    if r.byte_length() == 0:
        r = String("unspecified")
    return String(SKIP_MARKER) + r


def exit_skip(reason: String):
    """Print the SKIP marker line and end the process with exit code 77.
    Does not return."""
    print(skip_line(reason))
    exit(SKIP_EXIT_CODE)
