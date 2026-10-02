# =============================================================================
# komira_test_infra/skip.mojo -- SKIP with a reason, which is never a pass.
# =============================================================================
#
# A test that cannot run (no shared store configured and no pinned MinIO
# given) prints one marker line and exits with 77:
#
#     KOMIRA-TEST-INFRA: SKIP reason=<reason>
#
#     def main() raises:
#         ...
#         if choice.kind == BACKEND_SKIP:
#             exit(report_skip(choice.reason))
#
# 77 is non-zero, so a gated test that skips fails its gate by construction,
# and a CI step that sees the marker line refuses the run as well. No code
# path in this library maps a skip to exit 0.
# =============================================================================

comptime SKIP_EXIT_CODE: Int = 77
comptime SKIP_MARKER: String = "KOMIRA-TEST-INFRA: SKIP reason="


def skip_line(reason: String) -> String:
    """The marker line for `reason`, kept on one line."""
    var r = reason.replace("\r", " ").replace("\n", " ")
    if r.byte_length() == 0:
        r = String("unspecified")
    return String(SKIP_MARKER) + r


def report_skip(reason: String) -> Int:
    """Print the SKIP marker line and return 77 for the test to exit with."""
    print(skip_line(reason))
    return SKIP_EXIT_CODE
