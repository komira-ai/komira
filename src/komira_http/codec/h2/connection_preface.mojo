# =============================================================================
# src/komira_http/codec/h2/connection_preface.mojo
# =============================================================================
#
#
# RFC 9113 §3.4 connection-preface validation. A client MUST open a
# connection by sending the 24-byte magic
#   "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
# followed by a SETTINGS frame. The server's first job is to validate
# the preface; on mismatch, the connection is closed without sending
# any reply (per RFC 9113 §3.4 — a server MUST treat invalid preface
# as a connection PROTOCOL_ERROR; sending GOAWAY for a misbehaved
# client that may not even be an HTTP/2 client is wasted I/O).
#
# No UnsafePointer in any public sig. No
# wildcard origin.
# =============================================================================

# The PRI * HTTP/2.0 preface magic. 24 bytes literal — RFC 9113 §3.4.
# Encoded as a List[UInt8] constant via helper so the compiler can fold.

comptime H2_CLIENT_PREFACE_LEN: Int = 24


comptime PREFACE_NEED_MORE: UInt8 = 0
comptime PREFACE_OK: UInt8 = 1
comptime PREFACE_ERROR: UInt8 = 2


@fieldwise_init
struct PrefaceCheckResult(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Outcome of preface validation.

    `status`:
      PREFACE_NEED_MORE — caller should read more bytes + retry.
      PREFACE_OK        — preface validated; `consumed` is 24.
      PREFACE_ERROR     — bytes do not match preface; caller closes the
                          connection without reply.
    """
    var status: UInt8
    var consumed: Int


# The 24-byte preface as a List[UInt8] sentinel; built once per call (the
# caller can cache it if hot-path matters; is a per-connection one-shot).


def _expected_preface_byte(i: Int) -> UInt8:
    """Return the i-th byte of "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"."""
    # 'P' 'R' 'I' ' ' '*' ' ' 'H' 'T'  'T' 'P' '/' '2' '.' '0' \r \n
    # \r \n 'S' 'M' \r \n \r \n
    if i == 0:
        return UInt8(ord("P"))
    if i == 1:
        return UInt8(ord("R"))
    if i == 2:
        return UInt8(ord("I"))
    if i == 3:
        return UInt8(0x20)  # ' '
    if i == 4:
        return UInt8(ord("*"))
    if i == 5:
        return UInt8(0x20)
    if i == 6:
        return UInt8(ord("H"))
    if i == 7:
        return UInt8(ord("T"))
    if i == 8:
        return UInt8(ord("T"))
    if i == 9:
        return UInt8(ord("P"))
    if i == 10:
        return UInt8(ord("/"))
    if i == 11:
        return UInt8(ord("2"))
    if i == 12:
        return UInt8(ord("."))
    if i == 13:
        return UInt8(ord("0"))
    if i == 14:
        return UInt8(0x0d)
    if i == 15:
        return UInt8(0x0a)
    if i == 16:
        return UInt8(0x0d)
    if i == 17:
        return UInt8(0x0a)
    if i == 18:
        return UInt8(ord("S"))
    if i == 19:
        return UInt8(ord("M"))
    if i == 20:
        return UInt8(0x0d)
    if i == 21:
        return UInt8(0x0a)
    if i == 22:
        return UInt8(0x0d)
    if i == 23:
        return UInt8(0x0a)
    return UInt8(0)


def H2_CLIENT_PREFACE() -> List[UInt8]:
    """Return the 24-byte preface bytes as a List[UInt8].

    A function rather than a comptime constant: Mojo 1.0.0b1 doesn't have
    a List literal constant form. Callers needing the literal bytes for
    diagnostics call this once at connection setup.
    """
    var out = List[UInt8]()
    var i = 0
    while i < H2_CLIENT_PREFACE_LEN:
        out.append(_expected_preface_byte(i))
        i = i + 1
    return out^


def check_client_preface(buf: Span[UInt8, _]) -> PrefaceCheckResult:
    """Validate `buf[0:24]` against the H2 client preface.

    Returns:
      NEED_MORE if len(buf) < 24.
      OK if the first 24 bytes match exactly.
      ERROR otherwise (caller closes connection).
    """
    var n = len(buf)
    if n < H2_CLIENT_PREFACE_LEN:
        return PrefaceCheckResult(status=PREFACE_NEED_MORE, consumed=0)
    var i = 0
    while i < H2_CLIENT_PREFACE_LEN:
        if buf[i] != _expected_preface_byte(i):
            return PrefaceCheckResult(status=PREFACE_ERROR, consumed=0)
        i = i + 1
    return PrefaceCheckResult(
        status=PREFACE_OK, consumed=H2_CLIENT_PREFACE_LEN,
    )
