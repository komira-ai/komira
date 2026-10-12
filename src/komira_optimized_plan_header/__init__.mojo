"""The `OptimizedPlan` header, decoded and encoded without its body, and the
header library's admission checks (docs/design/optimized_plan.md §4.1, §7.2
steps 1-3; optimized_plan_udf_runtime.md §10.11 checks 1-3).

A scheduler reads fields 1-7 of an `OptimizedPlan` through this package and
never parses `body`. Its dependency closure excludes `komira_plan_wire`, and
the BUCK file's `closure_excludes` fails the build if it ever does not.

Modules:
  - header_codec.mojo: `decode_optimized_plan_header` (steps 1 and 2: size,
    format version, structure) and `encode_optimized_plan_header`; the
    accepted `format_version` set.
  - header_admit.mojo: `check_optimized_plan_header` (step 3: producer,
    revocation, digest length, needs, write target),
    `admit_optimized_plan_header` (steps 1-3), and
    `check_optimized_plan_contract` (step 4, which the host runs); the accepted
    `optimizer_contract_version` set.
  - header_environment.mojo: `admit_plan_environment`, the checks of the pair
    (plan, environment image) that need only the manifest bytes.

Every refusal raises an `Error` whose text begins with its token, a constant
next to the code that raises it.
"""

from .header_codec import (
    OPTIMIZED_PLAN_FORMAT_VERSION_1,
    OPTIMIZED_PLAN_HEADER_ALLOWANCE_BYTES,
    OPTIMIZED_PLAN_HEADER_MALFORMED,
    OPTIMIZED_PLAN_LIMIT_EXCEEDED,
    OPTIMIZED_PLAN_MAX_BODY_BYTES,
    OPTIMIZED_PLAN_MAX_BYTES,
    OPTIMIZED_PLAN_VERSION_UNSUPPORTED,
    decode_optimized_plan_header,
    encode_optimized_plan_header,
    optimized_plan_format_versions,
    version_set_text,
)
from .header_admit import (
    OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED,
    OPTIMIZED_PLAN_CONTRACT_VERSION_1,
    OPTIMIZED_PLAN_DIGEST_BYTES,
    OPTIMIZED_PLAN_DIGEST_MALFORMED,
    OPTIMIZED_PLAN_NEEDS_MISSING,
    OPTIMIZED_PLAN_PRODUCER_MISSING,
    OPTIMIZED_PLAN_PRODUCER_REVOKED,
    OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH,
    admit_optimized_plan_header,
    check_optimized_plan_contract,
    check_optimized_plan_header,
    require_header_needs,
    require_header_producer,
    optimized_plan_contract_versions,
)
from .header_environment import (
    OPTIMIZED_ENV_BASE_UNRELEASED,
    OPTIMIZED_ENV_ENGINE_TOO_OLD,
    OPTIMIZED_ENV_RUNTIME_MISSING,
    BaseRelease,
    PlanEnvironment,
    admit_plan_environment,
)
