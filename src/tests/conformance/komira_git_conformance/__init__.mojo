"""`komira_git_conformance` -- test-only: komira_git against external oracles.

`CSha1dc`, `c_ubc_check` and the `c_dv_*` accessors drive
sha1collisiondetection's C library (//third_party/sha1collisiondetection),
the oracle of komira_git's pure-Mojo `Sha1dc`.

The pack reader against packs the pinned git writes (gen_packs.sh):
`read_fixture`, `parse_batch`, `parse_verify`, `parse_ids`, and `check_pack`,
which checks one pack against git's index, verify-pack listing and cat-file
dump (`check_git_pack` runs it on a pack's fixture files).
"""

from .oracle import CSha1dc, c_dv_count, c_dv_field, c_dv_word, c_ubc_check
from .fixtures import GitObjects, VerifyLine, parse_batch, parse_ids, parse_verify, read_fixture
from .check import PackStats, check_git_pack, check_pack, require_same_bytes, require_same_index
