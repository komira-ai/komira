"""The optimized plan's serialization (docs/design/optimized_plan.md §4.1,
§7.1, §7.2): the canonical protobuf encoder, the digest, the producer and the
executor's admission.

Modules:
  - canonical_encoder.mojo: `CanonicalPbEncoder`, a `WireEncoder` whose
    output is canonical, and `encode_canonical`, which encodes any
    `Serializable` with it.
  - optimized_body.mojo: the framing of an `OptimizedPlanBody` and the token
    for a body that is not one.
  - optimized_digest.mojo: `optimized_plan_digest`, sha256(body ‖
    canonical(DigestTrailer)).
  - optimized_produce.mojo: `produce_optimized_plan`, an optimized
    `LogicalPlan` to canonical `OptimizedPlan` bytes.
  - optimized_admit.mojo: `admit_optimized_plan`, the host's steps 1-8 of §7.2
    that this version carries, and `AdmittedOptimizedPlan`.

A refusal raises an `Error` whose text begins with its token.
"""

from .canonical_encoder import (
    CANONICAL_MAP_UNSUPPORTED,
    CanonicalPbEncoder,
    encode_canonical,
)
from .optimized_admit import (
    OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH,
    OPTIMIZED_PLAN_DIGEST_MISMATCH,
    OPTIMIZED_PLAN_NOT_CANONICAL,
    AdmittedOptimizedPlan,
    admit_optimized_plan,
)
from .optimized_body import (
    OPTIMIZED_BODY_UNBOUNDED_V1,
    OPTIMIZED_PLAN_BODY_MALFORMED,
)
from .optimized_digest import header_plan_digest, optimized_plan_digest
from .optimized_produce import produce_optimized_plan
