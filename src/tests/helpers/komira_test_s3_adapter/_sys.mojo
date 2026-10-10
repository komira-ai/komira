# =============================================================================
# komira_test_s3_adapter/_sys.mojo -- usleep(3). Package-private: imported
# only by `runner`.
# =============================================================================
#
# A binary that links komira_async (every user of this package does, through
# komira_supervisor and the HTTP client) gets the reactor's own `nanosleep`
# declaration, so std's `time.sleep` would not legalize there; `usleep` is
# what the job supervisor and the table store call for the same reason. The
# call takes a plain integer, so no pointer crosses this boundary.
# =============================================================================

from std.ffi import external_call


def _sleep_ms(ms: Int):
    """Block the calling thread for `ms` milliseconds (nothing for ms <= 0)."""
    if ms <= 0:
        return
    # FFI-BOUNDARY: usleep takes a by-value microsecond count; there is no
    # pointer and nothing to own or free.
    _ = external_call["usleep", Int32](UInt32(ms * 1000))
