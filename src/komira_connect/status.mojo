# =============================================================================
# status.mojo — gRPC canonical status codes + mapping
# =============================================================================
#
# Per https://grpc.io/docs/guides/status-codes/ + https://connectrpc.com/docs/protocol/#error-codes.
# The gRPC canonical 17 status codes (0..16) map to:
#
#   1. An HTTP status code (Connect-RPC + gRPC-Web HTTP/1.1 transport)
#   2. A Connect error name string (Connect-JSON error envelope)
#   3. A gRPC-status integer (gRPC HTTP/2 trailer encoding)
#
# This module is the single source of truth for that mapping. It's pure
# data + comptime-friendly accessors; no UnsafePointer, no allocations beyond
# the String return values.
#
# All 17 codes are included — UNKNOWN is the catch-all when a handler raises
# without a more-specific code.
# =============================================================================


# =============================================================================
# §1 — The canonical 17 gRPC status codes (0..16).
# =============================================================================

comptime GRPC_STATUS_OK: UInt8 = 0
comptime GRPC_STATUS_CANCELLED: UInt8 = 1
comptime GRPC_STATUS_UNKNOWN: UInt8 = 2
comptime GRPC_STATUS_INVALID_ARGUMENT: UInt8 = 3
comptime GRPC_STATUS_DEADLINE_EXCEEDED: UInt8 = 4
comptime GRPC_STATUS_NOT_FOUND: UInt8 = 5
comptime GRPC_STATUS_ALREADY_EXISTS: UInt8 = 6
comptime GRPC_STATUS_PERMISSION_DENIED: UInt8 = 7
comptime GRPC_STATUS_RESOURCE_EXHAUSTED: UInt8 = 8
comptime GRPC_STATUS_FAILED_PRECONDITION: UInt8 = 9
comptime GRPC_STATUS_ABORTED: UInt8 = 10
comptime GRPC_STATUS_OUT_OF_RANGE: UInt8 = 11
comptime GRPC_STATUS_UNIMPLEMENTED: UInt8 = 12
comptime GRPC_STATUS_INTERNAL: UInt8 = 13
comptime GRPC_STATUS_UNAVAILABLE: UInt8 = 14
comptime GRPC_STATUS_DATA_LOSS: UInt8 = 15
comptime GRPC_STATUS_UNAUTHENTICATED: UInt8 = 16


# =============================================================================
# §2 — gRPC code → HTTP status (Connect-RPC + gRPC-Web transport).
# =============================================================================
#
# Per https://connectrpc.com/docs/protocol/#error-codes table.
# =============================================================================


def grpc_status_to_http_status(code: UInt8) -> UInt16:
    """Map a gRPC canonical code to the HTTP status the Connect-RPC /
    gRPC-Web transport surfaces.

    OK → 200; CANCELLED → 499; UNKNOWN/INTERNAL/DATA_LOSS → 500; etc.

    Unrecognized codes (>16) map to 500 INTERNAL.

    The mapping is pinned to the Connect protocol's authoritative table
    (https://connectrpc.com/docs/protocol/#error-codes), as enforced by
    the `connectrpc/conformance` oracle's
    `connect_client_code_to_http_code` test suite. Two rows differ from
    the obvious HTTP choice:
      - CANCELLED → 499 (Connect uses 499 "Client Closed Request",
        not the HTTP/1.1 408 Request Timeout).
      - FAILED_PRECONDITION → 400 (Connect maps it to 400 Bad
        Request, not 412 Precondition Failed).
    Regression-pinned by tests/test_L5_conformance_code_mapping.mojo.
    """
    if code == GRPC_STATUS_OK:
        return 200
    elif code == GRPC_STATUS_CANCELLED:
        return 499
    elif code == GRPC_STATUS_UNKNOWN:
        return 500
    elif code == GRPC_STATUS_INVALID_ARGUMENT:
        return 400
    elif code == GRPC_STATUS_DEADLINE_EXCEEDED:
        return 504
    elif code == GRPC_STATUS_NOT_FOUND:
        return 404
    elif code == GRPC_STATUS_ALREADY_EXISTS:
        return 409
    elif code == GRPC_STATUS_PERMISSION_DENIED:
        return 403
    elif code == GRPC_STATUS_RESOURCE_EXHAUSTED:
        return 429
    elif code == GRPC_STATUS_FAILED_PRECONDITION:
        return 400
    elif code == GRPC_STATUS_ABORTED:
        return 409
    elif code == GRPC_STATUS_OUT_OF_RANGE:
        return 400
    elif code == GRPC_STATUS_UNIMPLEMENTED:
        return 501
    elif code == GRPC_STATUS_INTERNAL:
        return 500
    elif code == GRPC_STATUS_UNAVAILABLE:
        return 503
    elif code == GRPC_STATUS_DATA_LOSS:
        return 500
    elif code == GRPC_STATUS_UNAUTHENTICATED:
        return 401
    else:
        return 500


# =============================================================================
# §3 — gRPC code → Connect error name string (Connect-JSON error envelope).
# =============================================================================
#
# Per https://connectrpc.com/docs/protocol/#error-codes — the `code` field
# of a Connect-JSON error envelope.
# =============================================================================


def _write_grpc_status_to_connect_name[W: Writer](mut writer: W, code: UInt8):
    """WRITE what `grpc_status_to_connect_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library
    that binds such a pair CROSSED returns the wrong string, or crashes
    its host process."""
    if code == GRPC_STATUS_OK:
        writer.write(String(""))
        return
    elif code == GRPC_STATUS_CANCELLED:
        writer.write(String("canceled"))
        return
    elif code == GRPC_STATUS_UNKNOWN:
        writer.write(String("unknown"))
        return
    elif code == GRPC_STATUS_INVALID_ARGUMENT:
        writer.write(String("invalid_argument"))
        return
    elif code == GRPC_STATUS_DEADLINE_EXCEEDED:
        writer.write(String("deadline_exceeded"))
        return
    elif code == GRPC_STATUS_NOT_FOUND:
        writer.write(String("not_found"))
        return
    elif code == GRPC_STATUS_ALREADY_EXISTS:
        writer.write(String("already_exists"))
        return
    elif code == GRPC_STATUS_PERMISSION_DENIED:
        writer.write(String("permission_denied"))
        return
    elif code == GRPC_STATUS_RESOURCE_EXHAUSTED:
        writer.write(String("resource_exhausted"))
        return
    elif code == GRPC_STATUS_FAILED_PRECONDITION:
        writer.write(String("failed_precondition"))
        return
    elif code == GRPC_STATUS_ABORTED:
        writer.write(String("aborted"))
        return
    elif code == GRPC_STATUS_OUT_OF_RANGE:
        writer.write(String("out_of_range"))
        return
    elif code == GRPC_STATUS_UNIMPLEMENTED:
        writer.write(String("unimplemented"))
        return
    elif code == GRPC_STATUS_INTERNAL:
        writer.write(String("internal"))
        return
    elif code == GRPC_STATUS_UNAVAILABLE:
        writer.write(String("unavailable"))
        return
    elif code == GRPC_STATUS_DATA_LOSS:
        writer.write(String("data_loss"))
        return
    elif code == GRPC_STATUS_UNAUTHENTICATED:
        writer.write(String("unauthenticated"))
        return
    else:
        writer.write(String("unknown"))
        return


def grpc_status_to_connect_name(code: UInt8) -> String:
    """Map a gRPC canonical code to the Connect-JSON error envelope name.

    "canceled" (US spelling per Connect spec), "invalid_argument", etc.
    OK has no error name; returns empty String.

    Unrecognized codes (>16) map to "unknown".
    """
    var out = String()
    _write_grpc_status_to_connect_name(out, code)
    return out^


# =============================================================================
# §4 — Reverse: Connect error name → gRPC code.
# =============================================================================
#
# For round-trip: when a Connect-JSON request arrives with an error envelope,
# parse the `code` string back to the gRPC numeric.
# =============================================================================


def connect_name_to_grpc_status(name: String) -> UInt8:
    """Map a Connect-JSON error name back to a gRPC code.

    Unrecognized names map to UNKNOWN (2).
    """
    if name == "canceled":
        return GRPC_STATUS_CANCELLED
    elif name == "unknown":
        return GRPC_STATUS_UNKNOWN
    elif name == "invalid_argument":
        return GRPC_STATUS_INVALID_ARGUMENT
    elif name == "deadline_exceeded":
        return GRPC_STATUS_DEADLINE_EXCEEDED
    elif name == "not_found":
        return GRPC_STATUS_NOT_FOUND
    elif name == "already_exists":
        return GRPC_STATUS_ALREADY_EXISTS
    elif name == "permission_denied":
        return GRPC_STATUS_PERMISSION_DENIED
    elif name == "resource_exhausted":
        return GRPC_STATUS_RESOURCE_EXHAUSTED
    elif name == "failed_precondition":
        return GRPC_STATUS_FAILED_PRECONDITION
    elif name == "aborted":
        return GRPC_STATUS_ABORTED
    elif name == "out_of_range":
        return GRPC_STATUS_OUT_OF_RANGE
    elif name == "unimplemented":
        return GRPC_STATUS_UNIMPLEMENTED
    elif name == "internal":
        return GRPC_STATUS_INTERNAL
    elif name == "unavailable":
        return GRPC_STATUS_UNAVAILABLE
    elif name == "data_loss":
        return GRPC_STATUS_DATA_LOSS
    elif name == "unauthenticated":
        return GRPC_STATUS_UNAUTHENTICATED
    else:
        return GRPC_STATUS_UNKNOWN


# =============================================================================
# §5 — ConnectError — the canonical raised-error shape.
# =============================================================================
#
# Handlers raise `Error(...)` strings; the dispatcher catches Error, then
# parses the prefix `[connect:<code>] message` to recover the gRPC status
# code. Handlers can use `format_connect_error(code, msg)` to format an
# error string the dispatcher can parse back.
#
# This matches komira_http's `HttpError`-shaped raised-Error pattern (a string
# prefix carries the structured code).
# =============================================================================


# =============================================================================
# §4b — format_grpc_status_error — the `[grpc:<N>]` anchor, defined ONCE.
# =============================================================================
#
# THE CONTRACT THIS EXISTS TO HOLD. Every classifier in this tree recovers a
# gRPC status from a raised Error by scanning for the `[grpc:` anchor —
# `komira_grpc.error.parse_grpc_status_code`, `is_retryable_grpc_error`, and
# every caller-side re-projection built on them. An error raised WITHOUT the
# anchor is not "less detailed": it is INVISIBLE to that whole layer, which
# reads it as -1 / not-retryable / unclassifiable.
#
# The wire-format primitives in this package (`envelope`, `codec_grpc`) raise on
# malformed input, and must raise ANCHORED errors: a bare `Error(...)` string
# is a transport-shaped failure reaching the caller untyped, so the layer whose
# job is to decide what to do about it never sees it.
#
# ⚠ THIS LIVES HERE, NOT IN `komira_grpc.error`, BECAUSE OF THE DEPENDENCY
# DIRECTION. `komira_grpc -> komira_connect` (never the reverse), and the raise
# sites that need the anchor are in `komira_connect`. Putting a second formatter
# next to those raise sites would be a parallel API, so the ONE
# definition sits at the bottom of the dependency order and
# `komira_grpc.error.format_grpc_error_message` delegates to it. Both spellings
# therefore cannot drift, and `parse_grpc_status_code` keeps working unchanged.
# =============================================================================


def format_grpc_status_error(code: UInt8, message: String) -> String:
    """Format a raised-Error string carrying a gRPC status.

    Shape: `[grpc:<code>] <message>` — the anchor
    `komira_grpc.error.parse_grpc_status_code` scans for.

    THE SINGLE DEFINITION of this shape;
    `komira_grpc.error.format_grpc_error_message` delegates here. Use it at
    EVERY raise site that represents a gRPC status, including the wire-format
    primitives in this package.

    Args:
        code:    GRPC canonical 0..16 status.
        message: Human-readable text.
    """
    return String("[grpc:") + String(Int(code)) + "] " + message


def format_connect_error(code: UInt8, message: String) -> String:
    """Format an error string handlers raise; the dispatcher parses it back.

    Shape: `[connect:<code>] <message>` — e.g.
    `[connect:5] user 42 not found`.
    """
    return String("[connect:") + String(Int(code)) + "] " + message


def parse_connect_error(text: String) -> Tuple[UInt8, String]:
    """Parse a raised-Error string back into (gRPC code, message).

    Returns (UNKNOWN, full text) if the text doesn't start with the
    `[connect:N]` prefix — fallback for unstructured handler errors.
    """
    var prefix = String("[connect:")
    if not text.startswith(prefix):
        return (GRPC_STATUS_UNKNOWN, text)
    # Find the closing `]`
    var p_len = prefix.byte_length()
    var close_idx = -1
    for i in range(p_len, text.byte_length()):
        if ord(text[byte=i]) == ord("]"):
            close_idx = i
            break
    if close_idx < 0:
        return (GRPC_STATUS_UNKNOWN, text)
    # Parse digits between p_len and close_idx
    var code = UInt8(0)
    var any_digit = False
    for i in range(p_len, close_idx):
        var c = ord(text[byte=i])
        if c >= ord("0") and c <= ord("9"):
            code = code * 10 + UInt8(c - ord("0"))
            any_digit = True
        else:
            return (GRPC_STATUS_UNKNOWN, text)
    if not any_digit:
        return (GRPC_STATUS_UNKNOWN, text)
    # Skip optional ' ' after the `]`
    var msg_start = close_idx + 1
    if msg_start < text.byte_length() and ord(text[byte=msg_start]) == ord(" "):
        msg_start += 1
    # Build the message substring from raw bytes (avoids slicing issues)
    var msg = String("")
    for i in range(msg_start, text.byte_length()):
        msg += text[byte=i]
    return (code, msg)
