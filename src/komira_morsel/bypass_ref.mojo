# =============================================================================
# ParquetBypassRef — opaque handle to parquet-side bypass-payload state
# =============================================================================
#
# Created by the cycle-fix dispatch
# (an internal doc §2.4 path iii, OQ-B simplified
# refactor). Replaces `Morsel.raw_chunks: Optional[List[RawColumnChunk]]`
# with `Morsel.raw_chunks: Optional[ParquetBypassRef]`, dropping the
# direct dep from `komira_morsel` onto `komira_parquet`'s
# `RawColumnChunk` struct (which would re-introduce a cycle once
# `komira_parquet` deps on `komira_morsel`).
#
# Design (OQ-B, ratified):
#
#   * `ParquetBypassRef` is an opaque POD struct that carries a
#     non-owning ArcPointer to a `List[RawColumnChunk]` defined inside
#     `komira_parquet/parquet_bypass_payload.mojo`. The actual
#     `RawColumnChunk` type lives in parquet; only parquet-internal
#     callsites construct or resolve the ref.
#
#   * Engine-side consumers (any code in `komira_engine_runtime`,
#     `komira_engine_operators`, `komira_engine_dispatch`,
#     `komira_async`, `komira_sdk`) see ONLY `Optional[ParquetBypassRef]`
#     on a Morsel. They pass it through unchanged.
#
#   * No callback registry, no module-init resolver registration. Audit
#     showed `attach_raw_chunks` / `has_raw_chunks` / `num_raw_chunks` /
#     `.raw_chunks` are referenced only in `morsel.mojo` itself (no
#     external production callers as of ``); the simplified
#     opaque-handle model is sufficient.
#
# This module contains ONLY the opaque ref struct. The
# `RawColumnChunk` payload struct, the parquet-internal constructor
# (`from_raw_chunks`), and the parquet-internal resolver
# (`resolve_to_raw_chunks`) live in
# `komira_parquet/parquet_bypass_payload.mojo`.
#
# Pointer discipline (maintainer): the public surface here is
# UnsafePointer-free. Internal storage is a Mojo `ArcPointer[UInt64]`
# carrying a type-erased opaque handle that the parquet-internal code
# bitcasts back to its owning payload type. The bitcast lives in
# `parquet_bypass_payload.mojo` with a `# SAFETY:` comment per the
# encapsulation rule.
# =============================================================================

from std.memory import ArcPointer


struct ParquetBypassRef(Movable, Copyable):
    """Opaque handle to a parquet-side bypass payload (List[RawColumnChunk]).

    Engine consumers see only this type on Morsel.raw_chunks. They never
    decode or peek into the payload — only parquet-internal code
    (`komira_parquet/parquet_bypass_payload.mojo`) constructs and
    resolves the handle.

    Internal representation: an ArcPointer to a UInt64 sentinel that
    parquet-internal code uses as the address of the owning
    `List[RawColumnChunk]`. The opaqueness is enforced by keeping the
    construct/resolve API parquet-internal (NOT exposed through
    `komira_morsel`'s public facade).

    Movable + Copyable: refcount-bump on copy; cheap to thread through
    Morsel handoffs across worker boundaries. The underlying payload is
    decoded only at the parquet-internal write site that actually
    consumes the bypass bytes.
    """

    # SAFETY: opaque type-erased handle. The ArcPointer payload is a
    # `UInt64` sentinel that the parquet-internal API treats as the
    # address of the owning payload struct. The actual bitcast happens
    # inside `komira_parquet/parquet_bypass_payload.mojo` with the
    # owning lifetime contract documented there. Engine code never
    # bitcasts the field — it only passes the ref through unchanged.
    var _opaque: ArcPointer[UInt64]

    @always_inline
    def __init__(out self, var opaque: ArcPointer[UInt64]):
        """Construct a bypass ref from a parquet-internal opaque handle.

        Only `komira_parquet/parquet_bypass_payload.mojo` should call
        this constructor. Engine code never instantiates a
        ParquetBypassRef directly.
        """
        self._opaque = opaque^

    @always_inline
    def _opaque_addr(self) -> UInt64:
        """Return the opaque sentinel as a UInt64.

        Parquet-internal callers (`komira_parquet/parquet_bypass_payload.mojo`)
        re-bitcast this back to a `UnsafePointer[List[RawColumnChunk]]`
        for resolution. Engine callers never use this method — it is
        not part of the engine-facing API.
        """
        return self._opaque[]
