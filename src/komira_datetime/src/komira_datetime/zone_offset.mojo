# =============================================================================
# zone_offset.mojo -- a local time type: UTC offset, DST flag, abbreviation
# =============================================================================
#
# The value a zone gives for an instant: `utc_offset` is seconds EAST of UTC
# (New York in winter is -18000), the sign RFC 8536 uses for `utoff` and the
# opposite of the POSIX TZ string's. Two offsets are equal when all three
# fields are; a transition that changes none of them is not a transition.
# =============================================================================


@fieldwise_init
struct ZoneOffset(Copyable, Equatable, Movable):
    """A local time type: seconds east of UTC, whether it is daylight saving
    time, and its abbreviation (`EST`, `+0545`, `-00`)."""

    var utc_offset: Int
    var is_dst: Bool
    var abbreviation: String

    def __eq__(self, other: Self) -> Bool:
        return (
            self.utc_offset == other.utc_offset
            and self.is_dst == other.is_dst
            and self.abbreviation == other.abbreviation
        )

    def __ne__(self, other: Self) -> Bool:
        return not self == other


@fieldwise_init
struct Transition(Copyable, Movable):
    """A change of local time type at the UTC instant `at` (epoch seconds):
    `before` is in effect up to `at - 1`, `after` from `at` on."""

    var at: Int
    var before: ZoneOffset
    var after: ZoneOffset
