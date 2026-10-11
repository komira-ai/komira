"""`komira_git_conformance` -- test-only: komira_git's SHA-1 collision
detection against sha1collisiondetection's C library.

`CSha1dc`, `c_ubc_check` and the `c_dv_*` accessors drive
sha1collisiondetection's C library (//third_party/sha1collisiondetection),
the oracle of komira_git's pure-Mojo `Sha1dc`.
"""

from .oracle import CSha1dc, c_dv_count, c_dv_field, c_dv_word, c_ubc_check
