# =============================================================================
# komira_async.cancellation.cancelled_error — re-export for clarity
# =============================================================================
# declares CancelledError in the errors module; this file
# re-exports it under the cancellation namespace for callers who reach for it
# in cancellation context (e.g., writing `except CancelledError:` after
# importing cancellation primitives).
# =============================================================================

from komira_async.errors.io_error import CancelledError
