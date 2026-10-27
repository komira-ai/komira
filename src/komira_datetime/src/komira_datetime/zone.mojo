# =============================================================================
# zone.mojo -- one time zone: UTC to local, local to UTC, the transitions
# =============================================================================
#
# A `Zone` is what a TZif file (RFC 8536) says: transition instants in
# ascending order, the local time type each one starts, the types, and an
# optional footer (a POSIX TZ string, posix_tz.mojo).
#
# UTC to local (`offset_at`):
#   - before the first transition, or with none and no footer: type 0
#     (RFC 8536 section 3.2);
#   - from a transition instant T on (T itself included), the type it starts,
#     up to the next transition;
#   - after the last transition, the footer when there is one, else the last
#     transition's type.
#
# Local to UTC (`resolve`, `to_utc`). A local time is seconds on the wall
# clock counted from 1970-01-01T00:00:00 (`local_seconds`), with no offset.
# An instant u shows local time L when u + offset_at(u) = L, so L has zero,
# one or two such instants:
#   UNIQUE  one instant;
#   GAP     none: the clock jumped over L (a spring-forward transition at T
#           from offset ob to oa > ob skips [T + ob, T + oa)). `earlier` is
#           L - oa, an instant before T showing L - (oa - ob); `later` is
#           L - ob, an instant from T on showing L + (oa - ob);
#   FOLD    two: the clock went back over L (a transition at T from ob to
#           oa < ob shows [T + oa, T + ob) twice). `earlier` is L - ob, in
#           the old offset; `later` is L - oa, in the new one.
# The policies choose one for `to_utc`, and each must be named by the
# caller: there is no default.
#   GapPolicy.SHIFT_FORWARD   `later`: L read in the offset before the gap,
#                             so 02:30 in a 02:00-03:00 gap is 03:30 (the
#                             RFC 5545 section 3.3.5 rule);
#   GapPolicy.SHIFT_BACKWARD  `earlier`: L read in the offset after the gap
#                             (01:30 for the same 02:30);
#   FoldPolicy.EARLIER / FoldPolicy.LATER  the first or the second instant;
#   REFUSE (both)             raise, naming the zone and the local time.
# =============================================================================

from std.collections import Optional

from .timestamp import DateTime, fields_from_seconds, seconds_from_fields

from .zone_offset import Transition, ZoneOffset
from .posix_tz import PosixTz, parse_posix_tz

# No UTC offset exceeds this (the TZif reader refuses one past 26 hours), so
# every instant showing a local time L lies in [L - _MAX_OFFSET, L + _MAX_OFFSET].
comptime _MAX_OFFSET = 26 * 3600


struct GapPolicy(Equatable, ImplicitlyCopyable, Movable):
    """What `Zone.to_utc` does with a local time the clock skipped."""

    var kind: Int

    comptime SHIFT_FORWARD = GapPolicy(0)
    comptime SHIFT_BACKWARD = GapPolicy(1)
    comptime REFUSE = GapPolicy(2)

    def __init__(out self, kind: Int):
        self.kind = kind

    def __eq__(self, other: Self) -> Bool:
        return self.kind == other.kind

    def __ne__(self, other: Self) -> Bool:
        return self.kind != other.kind


struct FoldPolicy(Equatable, ImplicitlyCopyable, Movable):
    """What `Zone.to_utc` does with a local time the clock showed twice."""

    var kind: Int

    comptime EARLIER = FoldPolicy(0)
    comptime LATER = FoldPolicy(1)
    comptime REFUSE = FoldPolicy(2)

    def __init__(out self, kind: Int):
        self.kind = kind

    def __eq__(self, other: Self) -> Bool:
        return self.kind == other.kind

    def __ne__(self, other: Self) -> Bool:
        return self.kind != other.kind


struct LocalKind(Equatable, ImplicitlyCopyable, Movable):
    """How many instants show a local time: one, none (a gap) or two (a
    fold)."""

    var kind: Int

    comptime UNIQUE = LocalKind(0)
    comptime GAP = LocalKind(1)
    comptime FOLD = LocalKind(2)

    def __init__(out self, kind: Int):
        self.kind = kind

    def __eq__(self, other: Self) -> Bool:
        return self.kind == other.kind

    def __ne__(self, other: Self) -> Bool:
        return self.kind != other.kind

    def name(self) -> String:
        if self.kind == 1:
            return String("GAP")
        if self.kind == 2:
            return String("FOLD")
        return String("UNIQUE")


@fieldwise_init
struct LocalResolution(Copyable, ImplicitlyCopyable, Movable):
    """The instants (UTC epoch seconds) for a local time (module header).
    For UNIQUE, `earlier == later`."""

    var kind: LocalKind
    var earlier: Int
    var later: Int


def local_seconds(
    year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0
) raises -> Int:
    """A wall-clock time as local seconds (seconds from 1970-01-01T00:00:00
    on the wall clock). Every field is checked as `seconds_from_fields`
    checks it."""
    return seconds_from_fields(year, month, day, hour, minute, second)


def _two(v: Int) -> String:
    if v < 10:
        return "0" + String(v)
    return String(v)


def format_local(local: Int) -> String:
    """`YYYY-MM-DDTHH:MM:SS` of local seconds (years 0..9999 as four digits)."""
    var f = fields_from_seconds(local)
    var y = String(f.year)
    while y.byte_length() < 4:
        y = "0" + y
    return (
        y + "-" + _two(f.month) + "-" + _two(f.day) + "T" + _two(f.hour) + ":"
        + _two(f.minute) + ":" + _two(f.second)
    )


struct Zone(Copyable, Movable):
    """One time zone (module header). Built by `parse_tzif`, `load_zone`,
    `posix_zone` or `utc_zone`."""

    var name: String
    var _times: List[Int]
    var _type_of: List[Int]
    var _types: List[ZoneOffset]
    var _has_footer: Bool
    var _footer: PosixTz

    def __init__(
        out self,
        var name: String,
        var times: List[Int],
        var type_index: List[Int],
        var types: List[ZoneOffset],
        has_footer: Bool,
        var footer: PosixTz,
    ):
        """The parts as the TZif reader checked them: `times` strictly
        ascending, each `type_index` entry an index into `types`, `types`
        non-empty."""
        self.name = name^
        self._times = times^
        self._type_of = type_index^
        self._types = types^
        self._has_footer = has_footer
        self._footer = footer^

    def transition_count(self) -> Int:
        """The transitions the file lists (the footer's are not counted)."""
        return len(self._times)

    def last_listed_transition(self) -> Optional[Int]:
        """The instant of the file's last transition, or None when it lists
        none (the footer governs every instant after it)."""
        if len(self._times) == 0:
            return None
        return self._times[len(self._times) - 1]

    def footer(self) -> String:
        """The footer's POSIX TZ string, or "" when there is none."""
        if self._has_footer:
            return self._footer.text.copy()
        return String()

    def offset_at(self, utc: Int) -> ZoneOffset:
        """The local time type in effect at the UTC instant `utc`."""
        var n = len(self._times)
        if n == 0:
            if self._has_footer:
                return self._footer.offset_at(utc)
            return self._types[0].copy()
        if utc < self._times[0]:
            return self._types[0].copy()
        if utc > self._times[n - 1] and self._has_footer:
            return self._footer.offset_at(utc)
        # The last transition at or before `utc`: lo ends at the first index
        # whose time is after `utc`.
        var lo = 0
        var hi = n
        while lo < hi:
            var mid = (lo + hi) // 2
            if self._times[mid] <= utc:
                lo = mid + 1
            else:
                hi = mid
        return self._types[self._type_of[lo - 1]].copy()

    def utc_offset_at(self, utc: Int) -> Int:
        """Seconds east of UTC at the instant `utc`."""
        return self.offset_at(utc).utc_offset

    def to_local(self, utc: Int) -> Int:
        """The local seconds the instant `utc` shows."""
        return utc + self.offset_at(utc).utc_offset

    def local_fields(self, utc: Int) -> DateTime:
        """The wall-clock fields the instant `utc` shows."""
        return fields_from_seconds(self.to_local(utc))

    def _next_candidate(self, after: Int) -> Optional[Int]:
        """The first instant after `after` where the file or the footer may
        change the type."""
        var n = len(self._times)
        if n > 0 and after < self._times[n - 1]:
            var lo = 0
            var hi = n
            while lo < hi:
                var mid = (lo + hi) // 2
                if self._times[mid] <= after:
                    lo = mid + 1
                else:
                    hi = mid
            return self._times[lo]
        if self._has_footer and self._footer.has_dst:
            return self._footer.next_edge_after(after)
        return None

    def next_transition(self, after: Int) -> Optional[Transition]:
        """The first instant strictly after `after` at which the local time
        type changes (offset, DST flag or abbreviation), with the types on
        both sides; None when it never changes again."""
        var t = after
        # A footer whose edges change nothing for two years never changes.
        var footer_limit = Optional[Int](None)
        while True:
            var c = self._next_candidate(t)
            if not c:
                return None
            var at = c.value()
            var before = self.offset_at(at - 1)
            var now = self.offset_at(at)
            if before != now:
                return Transition(at, before^, now^)
            var n = len(self._times)
            if n == 0 or at > self._times[n - 1]:
                if not footer_limit:
                    footer_limit = at + 2 * 366 * 86400
                elif at > footer_limit.value():
                    return None
            t = at

    def resolve(self, local: Int) raises -> LocalResolution:
        """The instants showing the local time `local` (module header)."""
        var lo = local - _MAX_OFFSET
        var hi = local + _MAX_OFFSET
        # Every offset in effect somewhere in [lo, hi].
        var offsets = List[Int]()
        offsets.append(self.offset_at(lo).utc_offset)
        var transitions = List[Transition]()
        var t = lo
        while True:
            var nxt = self.next_transition(t)
            if not nxt or nxt.value().at > hi:
                break
            var tr = nxt.value().copy()
            t = tr.at
            if tr.after.utc_offset not in offsets:
                offsets.append(tr.after.utc_offset)
            transitions.append(tr^)
        var found = False
        var earliest = 0
        var latest = 0
        for o in offsets:
            var u = local - o
            if self.offset_at(u).utc_offset == o:
                if not found or u < earliest:
                    earliest = u
                if not found or u > latest:
                    latest = u
                found = True
        if found:
            if earliest == latest:
                return LocalResolution(LocalKind.UNIQUE, earliest, latest)
            return LocalResolution(LocalKind.FOLD, earliest, latest)
        for ref tr in transitions:
            var ob = tr.before.utc_offset
            var oa = tr.after.utc_offset
            if tr.at + ob <= local and local < tr.at + oa:
                return LocalResolution(LocalKind.GAP, local - oa, local - ob)
        raise Error(
            "zone " + self.name + ": local time " + format_local(local)
            + " has no instant and lies in no gap"
        )

    def to_utc(
        self, local: Int, gap: GapPolicy, fold: FoldPolicy
    ) raises -> Int:
        """The UTC instant for the local time `local`, a gap or a fold
        settled by the named policy (module header)."""
        var r = self.resolve(local)
        if r.kind == LocalKind.GAP:
            if gap == GapPolicy.SHIFT_FORWARD:
                return r.later
            if gap == GapPolicy.SHIFT_BACKWARD:
                return r.earlier
            raise Error(
                "zone " + self.name + ": local time " + format_local(local)
                + " does not exist (the clock skipped it)"
            )
        if r.kind == LocalKind.FOLD:
            if fold == FoldPolicy.EARLIER:
                return r.earlier
            if fold == FoldPolicy.LATER:
                return r.later
            raise Error(
                "zone " + self.name + ": local time " + format_local(local)
                + " is ambiguous (the clock showed it twice)"
            )
        return r.earlier


def posix_zone(name: String, tz: String) raises -> Zone:
    """A zone given by a POSIX TZ string alone (no transition list), as
    TZif's footer would give it."""
    var footer = parse_posix_tz(tz)
    var types = List[ZoneOffset]()
    types.append(footer.standard.copy())
    return Zone(name.copy(), List[Int](), List[Int](), types^, True, footer^)


def utc_zone() raises -> Zone:
    """UTC: offset 0 at every instant, abbreviation `UTC`."""
    return posix_zone("UTC", "UTC0")
