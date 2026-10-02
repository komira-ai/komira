"""`komira_test_run_id` -- a per-run id, minted inside the test process from
the wall clock and 64 random bits and never derived from inputs, so a retry
and its twin get disjoint resources.

It names any per-run resource: a bucket prefix, a temporary directory, a
namespace. The clock and the random source are seams (`WallClock`,
`Entropy`) with real conformers (`SystemClock` over komira_clock,
`UrandomEntropy`) and fakes (`FixedWallClock`, `ScriptedEntropy`).
"""

from .run_id import RunId, hex16_lower, mint_run_id
from .seams import (
    Entropy,
    FixedWallClock,
    ScriptedEntropy,
    SystemClock,
    UrandomEntropy,
    WallClock,
)
