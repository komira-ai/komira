"""IANA time zones: TZif files (RFC 9636, which obsoletes RFC 8536) read
into zones, UTC to local and local to UTC with named gap and fold policies.

  offset.mojo    ZoneOffset (seconds east of UTC, DST flag, abbreviation) and
                 Transition
  posix_tz.mojo  the POSIX TZ string of a TZif footer: parse, evaluate
  tzif.mojo      parse_tzif: TZif versions 1 to 4 into a Zone
  zone.mojo      Zone: offset_at, next_transition, resolve, to_utc; the
                 GapPolicy and FoldPolicy a caller must name; local_seconds
  database.mojo  load_zone: a zone by name from a zoneinfo directory the
                 caller names; check_zone_name

The package bundles no zone data: a caller passes TZif bytes or names a
zoneinfo directory (komira's tests read the pinned release in
third_party/tzdata). Leap seconds are not modelled: an instant is POSIX
epoch seconds.
"""

from .offset import Transition, ZoneOffset
from .posix_tz import (
    PosixRule,
    PosixTz,
    RULE_DAY_OF_YEAR,
    RULE_JULIAN,
    RULE_MONTH_WEEK_DAY,
    parse_posix_tz,
)
from .tzif import parse_tzif
from .zone import (
    FoldPolicy,
    GapPolicy,
    LocalKind,
    LocalResolution,
    Zone,
    format_local,
    local_seconds,
    posix_zone,
    utc_zone,
)
from .database import check_zone_name, load_zone
