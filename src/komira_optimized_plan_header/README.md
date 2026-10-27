# `komira_optimized_plan_header`

## Responsibility

The `OptimizedPlan` header (`komira_plan_proto`'s `optimized_plan.proto`)
decoded and encoded with its body left as bytes, and the header library's
admission checks (`docs/design/optimized_plan.md` §4.1, §4.2, §7.2 steps 1-3;
`optimized_plan_udf_runtime.md` §10.11 checks 1-3). A scheduler reads fields
1-7 of a plan through this package and never parses `body`.

`komira_plan_wire`, the codec of the body, is outside this package's
dependency closure. The BUCK file says so with `closure_excludes`, and
analysis fails if a dependency, direct or transitive, brings it in
(`tools/build/mojo/README.md`).

- `header_codec`: `decode_optimized_plan_header` refuses more than
  `OPTIMIZED_PLAN_MAX_BYTES` before reading (`OPTIMIZED_PLAN_LIMIT_EXCEEDED`),
  a `format_version` outside `optimized_plan_format_versions()` or a field or
  enum value that version does not include (`OPTIMIZED_PLAN_VERSION_UNSUPPORTED`),
  and bytes no version can mean (`OPTIMIZED_PLAN_HEADER_MALFORMED`: bad
  framing, a wrong wire type, a singular field twice, an out-of-range scalar,
  ill-formed UTF-8). `encode_optimized_plan_header` is the generated encoder.
- `header_admit`: `check_optimized_plan_header` (step 3) refuses a missing
  producer or an empty `engine_build`, a build on the caller's revocation
  set, a `plan_digest` that is not 32 bytes, missing needs and an empty write
  path; `admit_optimized_plan_header` is decode and check.
  `check_optimized_plan_contract` is step 4, which the host runs, against
  `optimized_plan_contract_versions()`.
- `header_environment`: `admit_plan_environment` checks the environment image
  beside a plan from its digest and manifest bytes against the release
  records the caller passes: built FROM a released base
  (`OPTIMIZED_ENV_BASE_UNRELEASED`), a base whose engine accepts the plan's
  versions (`OPTIMIZED_ENV_ENGINE_TOO_OLD`), and every needed runtime in the
  base (`OPTIMIZED_ENV_RUNTIME_MISSING`).

Every refusal is an `Error` whose text begins with its token.

Not here: the body and segment codecs, the canonical encoder and the digests
(stage 5 of the design, a separate package); `OPTIMIZED_PLAN_NEEDS_OVER_LIMIT`,
whose limits cap `ResourceNeeds`, a message the schema holds unnumbered; and
runtimes declared by added image layers, which the image design has not
specified.

## Example

```mojo
from komira_optimized_plan_header import (
    admit_optimized_plan_header,
    encode_optimized_plan_header,
)
from komira_plan_proto.optimized_plan import DeclaredNeeds, OptimizedPlan, ProducerStamp, RuntimeNeed


def main() raises:
    var build = List[UInt8]()
    var digest = List[UInt8]()
    for _ in range(32):
        build.append(0xAB)
        digest.append(0xCD)
    var stamp = ProducerStamp(build.copy(), 1, List[UInt8](), "komira/mojo-sdk")
    var needs = DeclaredNeeds([], List[String](), False, List[RuntimeNeed]())
    var plan = OptimizedPlan(1, stamp^, digest^, List[UInt8](), needs^, None, None, List[UInt8]())
    var bytes = encode_optimized_plan_header(plan)

    var header = admit_optimized_plan_header(bytes.copy(), List[List[UInt8]]())
    print("admitted format_version", header.format_version)

    # The same plan, from a build on the revocation set, is refused by name.
    try:
        _ = admit_optimized_plan_header(bytes^, [build^])
    except e:
        print(String(e).split(":")[0])
```
