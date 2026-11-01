# =============================================================================
# komira_hash -- FNV-1a, the one spelling of its constants and its fold.
# =============================================================================
#
# A leaf package with ZERO deps, so the observability packages, the name
# registry and any other package that needs a cheap, stable, non-cryptographic
# hash of a byte string can share one definition without depending on each
# other. Import it flat:
#
#     from komira_hash import fnv1a_32, fnv1a_64
#     var id = fnv1a_32(name.as_bytes())
#
# FNV-1a is NOT a cryptographic hash and is not collision resistant against an
# adversary; use it for identifiers and table keys over trusted names only.
# =============================================================================

from .fnv1a import (
    FNV1A_32_OFFSET_BASIS,
    FNV1A_32_PRIME,
    FNV1A_64_OFFSET_BASIS,
    FNV1A_64_PRIME,
    fnv1a_32,
    fnv1a_64,
)
