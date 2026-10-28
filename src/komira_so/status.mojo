"""Status codes, the ABI version and the two-call buffer test of libkomira."""

# Every fallible call of the C ABI returns one of these. Zero is success and
# every failure is negative, so a caller tells "I passed NULL" from "the
# engine refused" from "my buffer is too small" by the value alone.
comptime KOMIRA_OK: Int32 = 0
"""The call succeeded."""
comptime KOMIRA_ERR_NULL_CTX: Int32 = -1
"""The context handle is NULL."""
comptime KOMIRA_ERR_NULL_ARG: Int32 = -2
"""A required pointer argument other than the context is NULL."""
comptime KOMIRA_ERR_ENGINE: Int32 = -3
"""The engine refused the request; the context's last error says why."""
comptime KOMIRA_ERR_BUFFER_TOO_SMALL: Int32 = -4
"""The caller's buffer cannot hold the output. This is a measurement, not a
failure: the required length has been stored in `*out_len` and nothing has
been written to the buffer."""
comptime KOMIRA_ERR_TOO_LARGE: Int32 = -5
"""A byte input is longer than `KOMIRA_MAX_INPUT_BYTES`. Nothing was read from
it; the context's last error says so."""

comptime KOMIRA_MAX_INPUT_BYTES: UInt64 = 64 * 1024 * 1024
"""The longest byte input (the plan of `komira_plan_render`) a call accepts:
64 MiB. The library copies an input in full before decoding it, so the length
the host passes is bounded before anything is allocated; a longer one is
`KOMIRA_ERR_TOO_LARGE`. A length of exactly this many bytes is accepted."""

# The ABI version is `ABI_MAJOR * 1000 + ABI_MINOR`: 1000 is 1.0 and 2003 is
# 2.3. A new symbol raises the minor version; changing or removing a symbol
# raises the major version and resets the minor to 0. The minor version stays
# below 1000 so that the integer decodes uniquely.
comptime ABI_MAJOR: Int32 = 1
"""The major version: raised by a change that breaks an existing caller."""
comptime ABI_MINOR: Int32 = 1
"""The minor version: raised by an addition that breaks no caller."""
comptime _ABI_MINOR_LIMIT: Int32 = 1000


@always_inline
def abi_version() -> Int32:
    """The version of the C ABI as `major * 1000 + minor`."""
    comptime assert ABI_MINOR >= 0 and ABI_MINOR < _ABI_MINOR_LIMIT
    return ABI_MAJOR * _ABI_MINOR_LIMIT + ABI_MINOR


@always_inline
def input_length_status(length: UInt64) -> Int32:
    """The test a byte input's length passes before it is copied in:
    `KOMIRA_ERR_TOO_LARGE` when `length` is above `KOMIRA_MAX_INPUT_BYTES`
    (which includes any length that would be negative as a signed value),
    `KOMIRA_OK` otherwise."""
    if length > KOMIRA_MAX_INPUT_BYTES:
        return KOMIRA_ERR_TOO_LARGE
    return KOMIRA_OK


@always_inline
def buffer_status(needed: Int, capacity: UInt64) -> Int32:
    """The two-call protocol's test of a caller's buffer.

    A call that returns bytes stores their count in `*out_len` first, then
    returns this: `KOMIRA_ERR_BUFFER_TOO_SMALL` when `capacity` is below
    `needed` (and writes nothing), `KOMIRA_OK` otherwise. A caller sizes its
    buffer by calling once with capacity zero.
    """
    if capacity < UInt64(needed):
        return KOMIRA_ERR_BUFFER_TOO_SMALL
    return KOMIRA_OK
