"""`komira_test_verdict` -- the exit-code vocabulary of a test that can do
more than pass or fail.

`Verdict` is what a teardown or a leak check found: CLEAN (0), CANNOT_TELL
(3) or LEAK (6), the worst wins, and every reason is kept. `exit_skip` (77)
and `exit_cannot_tell` (3) end a test that could not run, each with a marker
line naming why, and never with exit 0.

A leaf: it imports only the standard library.
"""

from .exits import (
    CANNOT_TELL_EXIT_CODE,
    CANNOT_TELL_MARKER,
    SKIP_EXIT_CODE,
    SKIP_MARKER,
    cannot_tell_line,
    exit_cannot_tell,
    exit_skip,
    skip_line,
)
from .verdict import (
    VERDICT_CANNOT_TELL,
    VERDICT_CLEAN,
    VERDICT_LEAK,
    Verdict,
    verdict_kind_name,
)
