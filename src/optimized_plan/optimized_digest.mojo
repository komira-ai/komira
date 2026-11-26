# =============================================================================
# optimized_digest.mojo: `plan_digest` (docs/design/optimized_plan.md §7.1).
# =============================================================================
#
#   plan_digest = sha256(body ‖ canonical(DigestTrailer))
#
# The trailer copies, from the header, `format_version`,
# `producer.optimizer_contract_version`, `write_target`, and `needs.udfs`,
# `needs.runtimes` and `needs.data_scopes`: the fields that change what the
# plan does or may read, bound to the body so none of them changes without
# changing the digest. `needs.unbounded` is not in it: it is a summary the host
# checks against the body (OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH). Advice is
# outside the digest (§6.3).
#
# A header with no `producer` or no `needs` has no trailer:
# OPTIMIZED_PLAN_PRODUCER_MISSING / OPTIMIZED_PLAN_NEEDS_MISSING.
# =============================================================================

from crypto import sha256
from optimized_plan_header import (
    OPTIMIZED_PLAN_DIGEST_BYTES,
    require_header_needs,
    require_header_producer,
)
from plan_proto.optimized_plan import DigestTrailer, OptimizedPlan
from plan_proto.plan import WireWriteTarget

from .canonical_encoder import encode_canonical


def digest_trailer_of(header: OptimizedPlan) raises -> DigestTrailer:
    """The `DigestTrailer` of `header`, copied field by field."""
    require_header_producer(header)
    require_header_needs(header)
    var write_target = Optional[WireWriteTarget](None)
    if header.write_target:
        write_target = Optional(header.write_target.value().copy())
    ref needs = header.needs.value()
    return DigestTrailer(
        header.format_version,
        header.producer.value().optimizer_contract_version,
        write_target^,
        needs.udfs.copy(),
        needs.runtimes.copy(),
        needs.data_scopes.copy(),
    )


def header_plan_digest(header: OptimizedPlan) raises -> List[UInt8]:
    """The digest `header` should carry: `optimized_plan_digest` of its own
    `body` under its own trailer."""
    return optimized_plan_digest(Span(header.body), header)


def optimized_plan_digest(body: Span[UInt8, _], header: OptimizedPlan) raises -> List[UInt8]:
    """The 32-byte `plan_digest` of `body` under the trailer of `header`."""
    var hashed = List[UInt8](capacity=len(body) + 64)
    hashed.extend(body)
    hashed.extend(encode_canonical(digest_trailer_of(header)))
    var digest = sha256(Span(hashed))
    var out = List[UInt8](capacity=OPTIMIZED_PLAN_DIGEST_BYTES)
    for i in range(OPTIMIZED_PLAN_DIGEST_BYTES):
        out.append(digest[i])
    return out^
