"""Test-only: komira_datetime's time zones against the pinned tz release
(third_party/tzdata) and zdump's reading of it (goldens/, regen_goldens.sh).
The library holds the data paths and the golden reader; the tests are in
tests/."""

from .goldens import (
    FOOTER_GOLDENS,
    GoldenChange,
    IANA_VERSION_LINE,
    NAMED_GOLDENS,
    ZONE_COUNT,
    ZONES_LIST,
    first_line,
    read_goldens,
    read_lines,
    show_transition,
    zoneinfo_dir,
)
