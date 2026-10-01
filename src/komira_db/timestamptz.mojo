# =============================================================================
# komira_db/timestamptz.mojo — the TIMESTAMPTZ logical field type.
# =============================================================================
#
# The generated DbStorable structs carry TIMESTAMPTZ columns
# as a typed `Timestamptz` field — the generator emits
# this field type from the `(komira.db.col_type) = "timestamptz"` option so
# the value cascade has a typed target distinct from a plain BIGINT. The
# canonical carrier value is MICROSECONDS since the UNIX epoch (matching
# `PgValue.timestamptz_micros` and the pg binary codec, which converts to the
# pg 2000-epoch at the wire). Inline POD — no heap, no pointer (trivially relocation-safe).
# =============================================================================


struct Timestamptz(ImplicitlyCopyable, Movable, Writable):
    """A timestamp-with-timezone logical value: microseconds since the UNIX
    epoch. Backend-neutral (the driver converts to its native epoch/encoding).
    Inline 8-byte POD — trivially relocation-safe in any container."""

    var micros: Int64
    """Microseconds since 1970-01-01T00:00:00Z (UTC)."""

    @always_inline
    def __init__(out self):
        """The UNIX epoch (0 µs)."""
        self.micros = 0

    @always_inline
    def __init__(out self, micros: Int64):
        self.micros = micros

    @staticmethod
    @always_inline
    def from_micros(micros: Int64) -> Timestamptz:
        return Timestamptz(micros)

    @always_inline
    def unix_micros(self) -> Int64:
        return self.micros

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self.micros == other.micros

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self.micros != other.micros

    @always_inline
    def __lt__(self, other: Self) -> Bool:
        return self.micros < other.micros

    @always_inline
    def __le__(self, other: Self) -> Bool:
        return self.micros <= other.micros

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.micros)

    def __str__(self) -> String:
        return String(self.micros)
