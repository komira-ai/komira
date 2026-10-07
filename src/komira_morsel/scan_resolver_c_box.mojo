# =============================================================================
# scan_resolver_c_box — THE ONE PLACE an erased scan resolver becomes a C
# `void*`, and the one place it becomes a resolver again.
# =============================================================================
#
# RFC v2 "broker and search as plan citizens" §2.1 / §5 row P1, plan commit C3.
#
# WHY THIS EXISTS. `EngineContext.register_scan_kind` is NON-GENERIC so that a
# consumer LINKED against `komira.so` can register a scan kind its own
# translation unit compiled: `ErasedScanMorselResolver.erase[R]` instantiates
# `R`'s trampolines in the CONSUMER, and only code addresses and a heap home
# cross. But the `.so`'s `@extern` half is compiled into every consumer at
# every tier, and a tier-1 consumer has only the core packages on `-I`, so no door
# signature may NAME `ErasedScanMorselResolver` (a `komira_morsel` type). The
# resolver therefore crosses as a `void*` to ONE heap box, and this file is the
# only code that writes or reads that box.
#
# ⚠ THE BOX IS OWNED, AND THAT IS THE DIFFERENCE FROM A UDF THUNK OR A
# CONNECTOR SYMBOL. Those are code addresses nothing on either side frees, so
# passing one twice is two registrations. A box is a HEAP ALLOCATION holding a
# value: `scan_resolver_from_c_box` moves the value out and FREES the box, so a
# box passed twice is a use-after-free. Hand each box to exactly one consumer,
# once. A box nobody takes is a leak of one resolver (its store included).
#
# ⚠ FFI CARVE-OUT, STATED. `ScanResolverCBox` is an `UnsafePointer` in a public
# signature, which the encapsulation rule otherwise forbids. It is here only
# because a C ABI can carry nothing else, the same claim
# `komira_engine_operators.udf_registry.udf_thunk_symbol` makes for a UDF
# kernel. No other public surface in this package takes or returns one.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer

from komira_morsel.scan_morsel_resolver import ErasedScanMorselResolver


comptime ScanResolverCBox = UnsafePointer[NoneType, MutUntrackedOrigin]
"""A C `void*` to ONE heap-boxed `ErasedScanMorselResolver`. Produced only by
`scan_resolver_into_c_box`; consumed, exactly once, by
`scan_resolver_from_c_box`."""


comptime SCAN_RESOLVER_C_BOX_NULL: StaticString = "SCAN_RESOLVER_C_BOX_NULL"
"""Raised by `scan_resolver_from_c_box` for a NULL box: nothing to register."""


def scan_resolver_into_c_box(
    var resolver: ErasedScanMorselResolver,
) -> ScanResolverCBox:
    """Move `resolver` into a fresh heap box and return the box as a `void*`.

    The caller now owns the box and must hand it to exactly one
    `scan_resolver_from_c_box` (in practice: one `komira.so` registration
    door), which takes the value and frees the box.

    SAFETY: `OwnedPointer(resolver^)` allocates and move-constructs; taking its
    allocation and leaking it relinquishes the free, so the ONE owner of the
    bytes from here is whoever calls `scan_resolver_from_c_box` on the result.
    The origin cast only drops a compile-time lifetime the value no longer
    has: the box is not borrowed from anything.
    """
    var owned = OwnedPointer[ErasedScanMorselResolver](resolver^)
    return (
        owned^.unsafe_take_allocation()
        .unsafe_leak()
        .bitcast[NoneType]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )


def scan_resolver_from_c_box(
    box: ScanResolverCBox,
) raises -> ErasedScanMorselResolver:
    """Take the resolver out of a box made by `scan_resolver_into_c_box` and
    free the box. Raises `SCAN_RESOLVER_C_BOX_NULL` for a NULL box.

    SAFETY: `box` is the address `scan_resolver_into_c_box` returned, not yet
    consumed (the caller's contract; see the module header). Reconstructing ONE
    `OwnedPointer` over it and consuming it with `into_inner()` moves the value
    out and frees the allocation exactly once — the same single-owner consume
    `_erased_scan_drop_for` performs on a resolver's home.
    """
    if Int(box) == 0:
        raise Error(
            String(SCAN_RESOLVER_C_BOX_NULL)
            + String(": no scan resolver to take -- the box is NULL")
        )
    var owned = OwnedPointer[ErasedScanMorselResolver](
        unsafe_from_raw_pointer=box.bitcast[ErasedScanMorselResolver]()
    )
    return owned^.into_inner()
