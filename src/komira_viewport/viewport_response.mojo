# =============================================================================
# ivp_response.mojo — the IVP grid-facet RESPONSE envelope codec.
# =============================================================================
#
# The response a viewport server returns for a grid ticket:
#
#   { view_version, schema, rowcount:{exact | estimated ± bound + refine token},
#     payload: Arrow-IPC slice (or JSON rows) }
#
# This module owns the ENVELOPE framing (header + RowCount + a length-prefixed
# opaque payload block); the payload bytes themselves are produced by the server (an
# Arrow-IPC encode of the window RecordBatch via ipc_encoder_dispatch, or a JSON
# render for test/MSW harnesses) and carried through here verbatim. Keeping the
# envelope in the fast `komira_ivp` lib (komira_core only) means the honest
# rowcount contract — EXACT vs ESTIMATED-with-error-bound — is unit-testable
# without linking the engine.
#
# Encapsulation: value structs + owned byte lists. No UnsafePointer crosses the
# boundary. Mojo 1.0.0b2 (def-only).
# =============================================================================

from .ivp_bytes import IvpWriter, IvpReader
from .ivp_ticket import (
    IVP_MAGIC_0, IVP_MAGIC_1, IVP_MAGIC_2, IVP_MAGIC_3,
    IVP_VERSION_1, IVP_FACET_GRID,
)


# --- RowCount kinds (the HONEST-count discriminant) --------------------------
comptime IVP_COUNT_EXACT: UInt8 = 0       # footer / manifest fast path (~70us)
comptime IVP_COUNT_ESTIMATED: UInt8 = 1   # bounded-error random-RG-sample count

# --- Payload encodings -------------------------------------------------------
comptime IVP_PAYLOAD_ARROW_IPC: UInt8 = 0
comptime IVP_PAYLOAD_JSON: UInt8 = 1


struct RowCount(Movable, Copyable):
    """The scrollbar-sizing count, honest about its provenance.

    EXACT: `value` is the true row count (unfiltered footer / manifest fast
    path). `error_bound` = 0, `refine_token` = "".

    ESTIMATED: `value` is a bounded-error estimate from a random row-group
    SAMPLE count (a filtered window). `error_bound` is the ± ABSOLUTE row error
    (a bound, not a stddev); `refine_token` is the opaque handle a client polls
    for the exact count once the M6 selection-artifact build completes. It is
    NEVER labelled HLL — the in-tree HLL machinery is equality-only."""

    var kind: UInt8
    var value: UInt64
    var error_bound: UInt64
    var refine_token: String

    def __init__(
        out self,
        kind: UInt8,
        value: UInt64,
        error_bound: UInt64,
        refine_token: String,
    ):
        self.kind = kind
        self.value = value
        self.error_bound = error_bound
        self.refine_token = refine_token

    @staticmethod
    def exact(value: UInt64) -> RowCount:
        """An EXACT count (unfiltered footer/manifest fast path)."""
        return RowCount(IVP_COUNT_EXACT, value, UInt64(0), String(""))

    @staticmethod
    def estimated(
        value: UInt64, error_bound: UInt64, refine_token: String
    ) -> RowCount:
        """A bounded-error SAMPLE estimate (filtered window)."""
        return RowCount(IVP_COUNT_ESTIMATED, value, error_bound, refine_token)

    def copy(self) -> Self:
        return Self(self.kind, self.value, self.error_bound, self.refine_token.copy())


struct GridResponse(Movable):
    """The decoded grid response (header fields + the opaque payload block)."""

    var view_version: UInt64
    var rowcount: RowCount
    var payload_kind: UInt8
    var payload: List[UInt8]

    def __init__(
        out self,
        view_version: UInt64,
        var rowcount: RowCount,
        payload_kind: UInt8,
        var payload: List[UInt8],
    ):
        self.view_version = view_version
        self.rowcount = rowcount^
        self.payload_kind = payload_kind
        self.payload = payload^


def _write_rowcount(mut w: IvpWriter, rc: RowCount):
    w.write_u8(rc.kind)
    w.write_uvarint(rc.value)
    w.write_uvarint(rc.error_bound)
    w.write_string(rc.refine_token)


def _read_rowcount(mut r: IvpReader) raises -> RowCount:
    var kind = r.read_u8()
    if kind != IVP_COUNT_EXACT and kind != IVP_COUNT_ESTIMATED:
        raise Error("ivp: unknown RowCount kind " + String(Int(kind)))
    var value = r.read_uvarint()
    var error_bound = r.read_uvarint()
    var refine_token = r.read_string()
    return RowCount(kind, value, error_bound, refine_token)


def encode_grid_response(
    view_version: UInt64,
    rc: RowCount,
    payload_kind: UInt8,
    payload: Span[UInt8, _],
) raises -> List[UInt8]:
    """Serialize a grid response: header (magic+version+grid facet) +
    view_version + RowCount + payload_kind + length-prefixed payload bytes."""
    var w = IvpWriter(capacity_hint=64 + len(payload))
    w.write_u8(IVP_MAGIC_0)
    w.write_u8(IVP_MAGIC_1)
    w.write_u8(IVP_MAGIC_2)
    w.write_u8(IVP_MAGIC_3)
    w.write_uvarint(IVP_VERSION_1)
    w.write_u8(IVP_FACET_GRID)
    w.write_uvarint(view_version)
    _write_rowcount(w, rc)
    w.write_u8(payload_kind)
    w.write_uvarint(UInt64(len(payload)))
    for i in range(len(payload)):
        w.write_u8(payload[i])
    return w.take_bytes()


def decode_grid_response(data: Span[UInt8, _]) raises -> GridResponse:
    """Parse grid-response bytes (fail-closed, symmetric to the ticket decode).
    Used by the JSON-fallback client + the codec tests; the Arrow client reads
    the payload block as an IPC stream."""
    var r = IvpReader.from_span(data)
    var m0 = r.read_u8()
    var m1 = r.read_u8()
    var m2 = r.read_u8()
    var m3 = r.read_u8()
    if (
        m0 != IVP_MAGIC_0 or m1 != IVP_MAGIC_1
        or m2 != IVP_MAGIC_2 or m3 != IVP_MAGIC_3
    ):
        raise Error("ivp: bad magic — not an IVP response")
    var version = r.read_uvarint()
    if version != IVP_VERSION_1:
        raise Error("ivp: unsupported response version " + String(version))
    var facet = r.read_u8()
    if facet != IVP_FACET_GRID:
        raise Error("ivp: response facet " + String(Int(facet)) + " is not grid")
    var view_version = r.read_uvarint()
    var rc = _read_rowcount(r)
    var payload_kind = r.read_u8()
    if payload_kind != IVP_PAYLOAD_ARROW_IPC and payload_kind != IVP_PAYLOAD_JSON:
        raise Error("ivp: unknown payload kind " + String(Int(payload_kind)))
    var plen64 = r.read_uvarint()
    var plen = Int(plen64)
    if r.remaining() < plen:
        raise Error("ivp: response payload length runs past buffer end")
    var payload = List[UInt8](capacity=plen)
    for _ in range(plen):
        payload.append(r.read_u8())
    r.expect_end()
    return GridResponse(view_version, rc^, payload_kind, payload^)
