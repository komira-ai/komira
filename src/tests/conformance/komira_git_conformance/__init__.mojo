"""`komira_git_conformance` -- test-only: komira_git against external oracles.

SHA-1 collision detection: `CSha1dc`, `c_ubc_check` and the `c_dv_*`
accessors drive sha1collisiondetection's C library
(//third_party/sha1collisiondetection), the oracle of komira_git's pure-Mojo
`Sha1dc`.

Protocol state machines: against the pinned git's transcripts (capture.sh;
the BUCK file says how they are made). `Scenario` loads one scenario;
`TranscriptGraph` is its server repository as a `CommitGraph`; `expect_bytes`
compares komira_git's bytes with git's and shows where they differ.

The pack reader against packs the pinned git writes (gen_packs.sh):
`read_fixture`, `parse_batch`, `parse_verify`, `parse_ids`, and
`check_pack_against_git`, which checks one pack against git's index,
verify-pack listing and cat-file dump (`check_git_pack` runs it on a pack's
fixture files). `check_pack` is the protocol tests' check of a pack received
in a transcript.
"""

from .checks import GitPack, PushVerdicts, check_pack, push_verdicts, read_git_packfile
from .graph import TranscriptGraph
from .oracle import CSha1dc, c_dv_count, c_dv_field, c_dv_word, c_ubc_check
from .transcript import Connection, Scenario, expect_bytes, ids, minus, show
from .fixtures import GitObjects, VerifyLine, parse_batch, parse_ids, parse_verify, read_fixture
from .check import (
    PackStats,
    check_git_pack,
    check_pack_against_git,
    require_same_bytes,
    require_same_index,
)
