# =============================================================================
# komira_db/db_uuid.mojo — the UUID logical field type (re-surfaced core Uuid).
# =============================================================================
#
# The generated DbStorable structs carry UUID columns as a
# typed `Uuid` field. The canonical UUID type is the shared core
# primitive `komira_uuid.uuid.Uuid`. The
# DB codegen needs a `Uuid(InlineArray[UInt8,16])` constructor (which core
# provides) AND a `.bytes()` accessor returning the 16 big-endian bytes (which
# the generated `to_row()` calls as `self.id.bytes()`). Core exposes the same
# 16 bytes via `as_bytes()`; this module re-surfaces the core type with the
# `bytes()` name the codegen emits, delegating storage + parsing to core.
#
# Inline 16-byte POD wrapping the core Uuid — no heap, no pointer (trivially relocation-safe,
# same as the underlying core InlineArray storage). NO UnsafePointer crosses
# this module's boundary.
# =============================================================================

from komira_uuid.uuid import (
    Uuid as CoreUuid,
    generate_uuidv7 as _core_generate_uuidv7,
    from_hyphenated as _core_from_hyphenated,
)


struct Uuid(ImplicitlyCopyable, Movable, Writable):
    """A 128-bit UUID, the DB logical-type rendering of the shared core
    `komira_uuid.uuid.Uuid`. Stores the 16 big-endian bytes inline (no
    heap). Adds the `bytes()` accessor name the DbStorable codegen emits
    (`self.id.bytes()` in the generated `to_row`) on top of the core type."""

    var _inner: CoreUuid

    @always_inline
    def __init__(out self):
        """The nil UUID (all 16 bytes zero)."""
        self._inner = CoreUuid()

    @always_inline
    def __init__(out self, bytes: Array[UInt8, 16]):
        """Wrap an existing 16-byte big-endian buffer (the `from_row` path:
        `Uuid(row.get_uuid(col))`)."""
        self._inner = CoreUuid(bytes)

    @always_inline
    def __init__(out self, inner: CoreUuid):
        """Wrap a core Uuid directly."""
        self._inner = inner

    @always_inline
    def bytes(self) -> Array[UInt8, 16]:
        """The 16 big-endian bytes — the name the generated `to_row` calls
        (`DbValue.uuid(self.id.bytes())`)."""
        return self._inner.as_bytes()

    @always_inline
    def as_bytes(self) -> Array[UInt8, 16]:
        """Alias of `bytes()` (matches the core surface name)."""
        return self._inner.as_bytes()

    @always_inline
    def byte_at(self, i: Int) -> UInt8:
        return self._inner.byte_at(i)

    @always_inline
    def core(self) -> CoreUuid:
        """The underlying core Uuid (for callers that want the full core API)."""
        return self._inner

    def to_hyphenated(self) -> String:
        return self._inner.to_hyphenated()

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._inner == other._inner

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self._inner != other._inner

    @always_inline
    def __lt__(self, other: Self) -> Bool:
        return self._inner < other._inner

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self._inner.to_hyphenated())

    def __str__(self) -> String:
        return self._inner.to_hyphenated()


def generate_uuidv7() raises -> Uuid:
    """Mint a fresh UUIDv7 (delegates to the core generator)."""
    return Uuid(_core_generate_uuidv7())


def from_hyphenated(s: String) raises -> Uuid:
    """Parse a canonical hyphenated UUID string into a DB `Uuid`."""
    return Uuid(_core_from_hyphenated(s))
