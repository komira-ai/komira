# =============================================================================
# komira_http_client/outbound_budget.mojo — A BUDGET MAY NOT EXCEED THE DEADLINE
#   OF THE CONTEXT IT RUNS INSIDE.
# =============================================================================
#
# `HttpClient[C].with_defaults(...)` leaves `HttpClientConfig.request_timeout_us`
# at `0`, and `0` selects `_HEAD_DRIVE_DEFAULT_TIMEOUT_US = 600s`
# (`state_machine.mojo`). A process serving requests on a platform with a fixed
# per-request deadline (a Cloud Run service: 300s by default) would then carry
# an outbound budget twice as long as the request containing it.
#
#   A budget that exceeds its container is not a budget.
#
# ── WHY THE CLAMP IS NOT A POLICY TRADEOFF ───────────────────────────────────
#
# The usual objection to shortening a timeout — "you are converting a slow but
# working call into a failure" — DOES NOT APPLY past the ceiling, and that is the
# whole argument for this file. Past the containing request's deadline:
#
#   * the answer CANNOT BE DELIVERED. The platform has already returned 504 to
#     the caller; whatever the outbound call eventually produces is discarded.
#   * the work is STILL BEING PAID FOR. The platform does not kill the handler at
#     the ceiling — it stops being able to answer, and the container keeps
#     running. On a single-threaded serve loop that is a total outage of every
#     other route for the remainder.
#
# So clamping at the ceiling does not trade latency for reliability. It removes
# work whose result is provably unusable. An outbound call held open by an
# unhealthy peer for most of a request's ceiling, while every other route on the
# same loop waits behind it, is exactly the failure this prevents.
#
# ── WHAT THIS FILE DOES *NOT* DO, STATED SO IT IS NOT MIS-CITED ──────────────
#
# ⛔ IT IS NOT A BLANKET REDUCTION, AND `600s` IS STILL CORRECT SOMEWHERE. A
# process with NO containing request deadline — a batch job, a Kubernetes pod, a
# CLI, a bench, a test — keeps the generous default BYTE-IDENTICALLY. That is
# the case `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` was written for ("a local-LLM
# generation can legitimately run for many seconds-to-minutes") and it is
# untouched. The discriminator is the PLATFORM the process runs on, not the call
# site: a library client is used from a service, a job and a CLI alike, so the
# answer cannot be authored where the client is built.
#
# ⛔ IT DOES NOT DIVIDE THE REQUEST'S TIME AMONG ITS PARTS. `ceiling - reserve`
# is the largest budget that is not a lie; it is NOT a per-call allowance. A
# handler that makes several sequential outbound calls still needs its own
# pass-level bound. A caller that knows its own share passes it explicitly and
# this file returns it VERBATIM.
#
# ⛔ IT DOES NOT MAKE A HANDLER FAST. On a 300s ceiling the clamp lands at 295s,
# which is still a long in-handler block. This file makes the DEFAULT stop
# lying; a handler that must answer quickly states its own short budget.
#
# ── WHERE THE PLATFORM COMES FROM ────────────────────────────────────────────
# PURE: every function here takes VALUES (`Int` microseconds, `String` platform
# facts) and returns VALUES. It reads no environment, opens no fd, allocates no
# buffer, and holds no state. ZERO `UnsafePointer` in any signature, NO wildcard
# origin, no struct at all. The process's platform facts arrive from its own
# configuration (command-line flags set by the deployer); the serving binary
# passes them to `serving_request_ceiling_us` and builds its clients with
# `HttpClientConfig.for_serving_ceiling(ceiling)`. A process that states no
# platform is treated as having no containing deadline.
# =============================================================================


# =============================================================================
# §1 — the three numbers. Each is DERIVED; none is a preference.
# =============================================================================

comptime OUTBOUND_CEILING_NONE: Int = 0
"""The ceiling of a context that has no deadline — a Cloud Run job, a Kubernetes
pod, a CLI, a bench, a test. NOT "unknown": a process with no request ceiling
genuinely has none, and the generous default is CORRECT there."""

comptime CLOUD_RUN_REQUEST_CEILING_US: Int = 300_000_000
"""The wall deadline of ONE request on a Cloud Run **service** (300s, the
platform's default per-service `timeoutSeconds`).

⚠ THIS IS THE PLATFORM DEFAULT, NOT A SETTING THIS LIBRARY OWNS. A service
deployed with a different request timeout has a different ceiling; such a
process passes its own ceiling to `HttpClientConfig.for_serving_ceiling`
instead of relying on this constant."""

comptime OUTBOUND_CEILING_RESERVE_US: Int = 5_000_000
"""How far INSIDE the ceiling the largest permissible budget sits (5s).

⚠ THE RESERVE BUYS ATTRIBUTION, NOT HEADROOM. A budget EQUAL to the ceiling
expires at the same instant the platform gives up, so the failure is the
platform's opaque 504 and the handler never gets to say what timed out. A budget
strictly inside it means the drive loop raises a typed `HttpError[TIMEOUT]`
naming the peer and the budget, WHILE the request can still carry that answer
back. 5s covers the drive loop's own re-check granularity
(`_HEAD_DRIVE_PARK_TIMEOUT_US` = 50ms), the unwind, and rendering + writing a
response on a loaded single-threaded loop, with an order of magnitude to spare.

⛔ IT IS DELIBERATELY NOT SIZED TO "THE REST OF THE HANDLER". How a request
divides its time among its parts is knowledge only the handler has; inventing a
fraction here would be a policy nobody authored. See the header."""


# =============================================================================
# §2 — the DISCRIMINATOR. Which container am I inside?
# =============================================================================
#
# ⚠ NOT THE SAME QUESTION AS "am I deployed at all", which does not distinguish
# a service from a job. Here they are OPPOSITE answers: a service is inside a
# request and a job is not.
#
# The inputs are the platform's own identity values (Cloud Run's service,
# revision, configuration, job and execution names; AWS Lambda's runtime API
# endpoint), handed to the process by its deployer as configuration.


def serving_request_ceiling_us(
    k_service: String,
    k_revision: String,
    k_configuration: String,
    cloud_run_job: String,
    cloud_run_execution: String,
    lambda_runtime_api: String,
) -> Int:
    """The wall deadline of the request this process's outbound calls run
    inside, in microseconds, or `OUTBOUND_CEILING_NONE` when there is none.

    PURE: takes the platform VALUES, reads nothing. Every argument is the value
    the platform assigned this process, or `""` when it assigned none.

    THE TABLE (there is no other outcome):

      Cloud Run JOB marker present      -> NONE. A job's task timeout bounds the
                                           whole task, not a request; there is no
                                           request to outlive. 600s stays correct.
      Cloud Run SERVICE marker present  -> CLOUD_RUN_REQUEST_CEILING_US.
      AWS Lambda runtime API present    -> NONE, WITH A KNOWN GAP (see below).
      nothing                           -> NONE. Not deployed: a CLI, a bench,
                                           a test, a dev process.

    ⚠ THE JOB ARM IS CHECKED FIRST, AND ORDER IS THE ANSWER TO A REAL CASE. A
    Cloud Run job's container is ALSO handed `K_SERVICE`-shaped identity by some
    runtimes; asking "is it a service" first would classify every job as
    request-scoped and clamp a batch task that legitimately runs for minutes.
    Asking "is it a job" first cannot make the opposite mistake, because
    `CLOUD_RUN_JOB` is never injected into a service.

    ⚠ KUBERNETES IS NOT AN ARM AT ALL, ON PURPOSE. `KUBERNETES_SERVICE_HOST`
    says a pod, and a pod is not a request — it may be a server, a job, or a
    sidecar. A pod cannot be told apart from the inside, so it answers NONE rather than
    guessing.

    ⛔ THE LAMBDA GAP IS REAL AND IS NOT CLOSED HERE. A Lambda invocation DOES
    have a hard deadline, and the runtime API delivers it per-invocation in the
    `Lambda-Runtime-Deadline-Ms` response header of `/runtime/invocation/next`.
    That is a per-invocation value, not a per-process one, so it cannot be
    answered here. Returning a GUESSED function timeout would be worse than
    returning NONE — it would clamp correct calls on a 15-minute function."""
    if cloud_run_job.byte_length() > 0:
        return OUTBOUND_CEILING_NONE
    if cloud_run_execution.byte_length() > 0:
        return OUTBOUND_CEILING_NONE
    if k_service.byte_length() > 0:
        return CLOUD_RUN_REQUEST_CEILING_US
    if k_revision.byte_length() > 0:
        return CLOUD_RUN_REQUEST_CEILING_US
    if k_configuration.byte_length() > 0:
        return CLOUD_RUN_REQUEST_CEILING_US
    if lambda_runtime_api.byte_length() > 0:
        # See the ⛔ block above: a real deadline exists and we cannot see it.
        return OUTBOUND_CEILING_NONE
    return OUTBOUND_CEILING_NONE


# =============================================================================
# §3 — the RULE. One function, one answer.
# =============================================================================

comptime OUTBOUND_BUDGET_DEFAULT_US: Int = 600_000_000
"""The budget for a call with no containing deadline and no authored one.

⚠ THIS IS THE SAME NUMBER AS `_HEAD_DRIVE_DEFAULT_TIMEOUT_US`
(`state_machine.mojo`) AND MUST STAY THE SAME NUMBER. It is restated here rather
than imported because this module is the PURE rule and `state_machine.mojo`
imports the reactor, the runtime and four codec modules — depending on it would
make the rule untestable in isolation. `test_outbound_budget_rule.mojo` asserts
the two are equal, so a future edit to either one goes RED rather than silently
forking the default."""


def largest_permissible_budget_us(ceiling_us: Int) -> Int:
    """The largest budget an outbound call may carry inside a context whose
    deadline is `ceiling_us`, or `OUTBOUND_BUDGET_DEFAULT_US` when there is no
    containing deadline.

    Never returns a non-positive value: a ceiling smaller than the reserve is a
    pathological container (a sub-5s request timeout), and the correct answer
    there is "the whole ceiling", not "no budget at all" — a zero would be read
    downstream as "use the default", i.e. exactly the bug."""
    if ceiling_us <= OUTBOUND_CEILING_NONE:
        return OUTBOUND_BUDGET_DEFAULT_US
    var permitted = ceiling_us - OUTBOUND_CEILING_RESERVE_US
    if permitted <= 0:
        return ceiling_us
    return permitted


def outbound_budget_exceeds_ceiling(requested_us: Int, ceiling_us: Int) -> Bool:
    """True iff `requested_us` is a budget that would outlive the context
    containing it — i.e. somebody AUTHORED a number bigger than its container.

    `requested_us <= 0` is NOT an excess: it means "no number was authored", the
    `with_defaults` case, which `outbound_budget_us` resolves by DERIVING one. The
    distinction matters: a derived budget is corrected silently and correctly, an
    authored one is a statement about the world that turned out to be false."""
    if requested_us <= 0:
        return False
    if ceiling_us <= OUTBOUND_CEILING_NONE:
        return False
    return requested_us > largest_permissible_budget_us(ceiling_us)


def outbound_budget_refusal_detail(requested_us: Int, ceiling_us: Int) -> String:
    """The one-line diagnostic for an authored budget that exceeds its container.

    A STRING, not a raise: the site that would raise it is
    `HttpClientConfig.for_serving_ceiling`, which is not `raises`, and making
    it raise would ripple through every caller. A caller that IS already raising composes the refusal in one
    line:

        if outbound_budget_exceeds_ceiling(us, ceiling):
            raise Error(outbound_budget_refusal_detail(us, ceiling))

    Until a site adopts that, `outbound_budget_us` CLAMPS — which is loud in the
    only way that costs nothing: `HttpClientConfig.budget_was_clamped()` reports
    it, and the drive loop's TIMEOUT names the clamped number."""
    return String(
        "outbound budget "
        + String(requested_us // 1_000_000)
        + "s exceeds the deadline of the context containing it ("
        + String(ceiling_us // 1_000_000)
        + "s); the largest permissible budget here is "
        + String(largest_permissible_budget_us(ceiling_us) // 1_000_000)
        + "s. A budget that exceeds its container is not a budget: past the"
        + " ceiling the answer cannot be delivered, so the work is unusable"
        + " while still holding the serve loop."
    )


def tighter_budget_us(a_us: Int, b_us: Int) -> Int:
    """THE COMPOSITION RULE. Two budgets stated over the SAME call resolve to
    ONE, and it is the tighter of them. `0` on either side means "that party
    stated no budget", not "that party asked for unbounded".

      both stated   -> the smaller. A caller who asked for 8s inside a client
                       configured for 60s gets 8s; the reverse gets 8s too.
                       The bound that binds is the one that fires first, and
                       which party authored it is not a tiebreaker.
      one stated    -> that one, VERBATIM. This is what makes the whole
                       mechanism a no-op for every existing caller: a request
                       carrying 0 resolves to the client's configured budget,
                       byte for byte.
      neither       -> 0, i.e. "still unstated" — which `OutboundDriver`
                       resolves to its own generous default. NOT a zero
                       budget; a zero would read downstream as "use the
                       default" anyway, but returning 0 rather than a
                       substituted number keeps the decision in ONE place.

    ⛔ WHY MIN AND NOT "THE MOST RECENT WINS". A per-request budget that could
    LOOSEN a client's configured one would let a call escape the containing
    request's ceiling that `outbound_budget_us` exists to enforce — a budget
    that exceeds its container is not a budget. MIN is also IDEMPOTENT
    (`tighter_budget_us(x, x) == x`) and ASSOCIATIVE, which is why it is safe
    to compose at more than one frame on the way down: a budget that is
    re-composed by a forwarder cannot drift."""
    if a_us <= 0:
        return b_us
    if b_us <= 0:
        return a_us
    if b_us < a_us:
        return b_us
    return a_us


def outbound_budget_us(requested_us: Int, ceiling_us: Int) -> Int:
    """THE RULE. The budget an outbound call actually gets.

      requested > 0, inside the ceiling  -> requested, VERBATIM. A caller that
                                            knows its own share keeps it (a
                                            20s unit budget, a 30s probe
                                            budget).
      requested > 0, over the ceiling    -> clamped to the largest permissible.
                                            `outbound_budget_exceeds_ceiling`
                                            is True for exactly this case.
      requested <= 0, no ceiling         -> OUTBOUND_BUDGET_DEFAULT_US. The
                                            generous default, for every job,
                                            pod, CLI, bench and test.
      requested <= 0, inside a ceiling   -> DERIVED from the ceiling. This is the
                                            `with_defaults` case and the whole
                                            point of the file."""
    var permitted = largest_permissible_budget_us(ceiling_us)
    if requested_us <= 0:
        return permitted
    if requested_us > permitted:
        return permitted
    return requested_us
