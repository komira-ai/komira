"""`komira_git_pack_conformance` -- test-only: komira_git's pack reader
against packs the pinned git writes (gen_packs.sh).

`read_fixture`, `parse_batch`, `parse_verify`, `parse_ids`, and
`check_pack_against_git`, which checks one pack against git's index,
verify-pack listing and cat-file dump (`check_git_pack` runs it on a pack's
fixture files).
"""

from .fixtures import GitObjects, VerifyLine, parse_batch, parse_ids, parse_verify, read_fixture
from .check import (
    PackStats,
    check_git_pack,
    check_pack_against_git,
    require_same_bytes,
    require_same_index,
)
