# =============================================================================
# kci_deploy/data_plane_readiness.mojo -- WAIT FOR THE DATA PLANE, not for a
#   control-plane read-back: the gap between "the IAM binding was written" and
#   "a request through the front door is no longer refused".
# =============================================================================
#
# THE READ-BACK IS NOT EVIDENCE. The last mutation of an API-edge converge binds
# the gateway service account `roles/run.invoker` on the backend Cloud Run
# service. A control-plane `GetIamPolicy` read returns that binding instantly
# after the write, on every attempt. It looks like verification and verifies
# nothing about the surface that matters: Cloud IAM's data plane, where the
# gateway's hop to the backend is actually authorized, converges on its own
# schedule. A validation suite started seconds after the grant can see every
# request through the edge refused; container cold starts only hide this by
# accident, and warm jobs expose it.
#
# WHAT COUNTS AS READY, AND WHY IT IS NOT "200". This is not a health check and
# must never become one. It answers exactly one question: did the request get
# PAST the IAM front end? A 404 from the backend is a perfect answer: the hop
# happened. Gating on 2xx would hang on every healthy service whose readiness
# path does not exist, which is all of them by construction (see
# `EDGE_READINESS_PATH`).
#
# 403 IS THE SIGNAL AND 401 IS NOT. Cloud Run's invoker check refuses an
# unauthorized principal with 403. A 401 means something ANSWERED and rejected
# the credential: the edge is alive and routing, which is ready for this gate.
#
# THE 403 ATTRIBUTION HAS A PRECONDITION: the edge enforces no authentication
# of its own, so a 403 at the front door can only come from the backend hop.
# If edge authentication is turned on, the edge can emit its own 403 and the
# attribution stops holding. That is why this gate WAITS and REPORTS but does
# not FAIL a deploy: a wrong FAIL would block a healthy deploy on an
# authorization change made elsewhere. The verdict belongs to the validate
# gates, which retry.
#
# ENCAPSULATION: a String URL in, an Int status back, a flat result out. No
# pointer field, no wildcard origin. Generic over `P: DataPlaneProbe` and
# `R: Reporter`, so a binary binds a live HTTPS GET and the hermetic test binds
# a scripted status sequence over the same loop.
# =============================================================================

from kci_deploy.reporter import Reporter
from kci_deploy.validate import PollBudget


comptime DATA_PLANE_UNREACHABLE: Int = 0
"""The probe could not complete a request at all (DNS / TLS / connect fault). A
freshly created gateway hostname may not resolve yet, so this is not-ready-yet,
not a verdict."""

comptime HTTP_FORBIDDEN: Int = 403
"""Cloud Run's invoker check refusing the gateway's hop: the signal this gate
exists for."""


def is_invoker_refusal(status: Int) -> Bool:
    """Is `status` the IAM refusal this gate waits out?

    403 only. Not 401 (something answered and rejected a credential: the edge is
    alive), not 404 (the backend answered), not 5xx (the backend answered badly).
    Widening this predicate is how a readiness probe turns into a health check and
    starts blocking deploys on conditions it was never meant to judge."""
    return status == HTTP_FORBIDDEN


def is_data_plane_ready(status: Int) -> Bool:
    """Is `status` evidence the request got PAST the IAM front end?

    Everything except a refusal and an unreachable dial. Deliberately permissive:
    the question is "did the hop happen", and a 404 answers yes."""
    return status != DATA_PLANE_UNREACHABLE and not is_invoker_refusal(status)


trait DataPlaneProbe:
    """ONE request against a live URL, reported as an HTTP status.

    Conformers: a binary's HTTPS GET; the hermetic test's scripted status sequence.
    `raises` is reserved for a harness fault the conformer cannot express as a
    status. A dial failure must come back as `DATA_PLANE_UNREACHABLE`, because "the
    host does not resolve yet" is exactly the condition this loop waits out."""

    def probe_status(mut self, url: String) raises -> Int:
        """GET `url`; return its HTTP status, or `DATA_PLANE_UNREACHABLE` (0) if
        the request could not be completed at all."""
        ...


@fieldwise_init
struct DataPlaneReadiness(Copyable, Movable, Deinitable):
    """The outcome of the readiness wait:
      * `ready`       -- True iff a probe got past the IAM front end.
      * `attempts`    -- how many probes ran (0 iff the gate was SKIPPED).
      * `last_status` -- the last observed status (0 = never reachable).
      * `skipped`     -- True iff no probe was possible; `summary` says why. A skip
                         is not a ready, and the two are separate fields so no
                         caller can read one as the other.
      * `summary`     -- the one-line report."""

    var ready: Bool
    var attempts: Int
    var last_status: Int
    var skipped: Bool
    var summary: String

    @staticmethod
    def skipped_because(reason: String) -> DataPlaneReadiness:
        """No probe was possible. Not ready and not a failure: an absence of
        evidence, reported as one."""
        return DataPlaneReadiness(False, 0, DATA_PLANE_UNREACHABLE, True, reason)


comptime EDGE_READINESS_PATH: String = "/__deploy_readiness_probe__"
"""The path the readiness probe GETs on a CATCH_ALL edge.

It is deliberately a path nothing serves, and that is the design:

  1. A CATCH_ALL edge routes `/**`, so ANY path reaches the backend: the request
     crosses the hop whose authorization is being waited on. On a SINGLE_PATH
     edge only the declared route is routed, and an undeclared path 404s at the
     edge BEFORE the backend hop; such a probe would read ready instantly and
     prove nothing. That is why `edge_readiness_probe_url` refuses to build one
     rather than probing the declared route.
  2. Nothing serves it, so no handler runs. The one declared route of a
     SINGLE_PATH edge is typically a webhook ingest, and probing it would fire
     the side effect it exists to deliver. A GET is idempotent by the HTTP
     contract and a nonexistent path is idempotent by construction.
  3. Its answer (a backend 404) is the evidence. `is_data_plane_ready` treats it
     as ready, which is why this gate must never expect 2xx."""


def edge_readiness_probe_url(
    edge_logical_id: String,
    edge_origin: String,
    client_edge_suffix: String,
) raises -> String:
    """The URL to probe for the API-edge node `edge_logical_id`, or EMPTY when
    no safe probe exists for it.

    Non-empty only for a CATCH_ALL node (whose logical id ends with
    `client_edge_suffix`), whose `/**` route sends an arbitrary path to the backend.
    Empty for a SINGLE_PATH node: its only routed path is the declared ingest, and
    every other path is answered by the edge before the backend hop, so the choice
    there is between a probe that proves nothing and a probe that fires a side
    effect. An empty return makes the caller say so instead of reporting ready.

    `client_edge_suffix` is passed in so the caller supplies the value derived from
    its node-id constructor, and this module keeps no second copy of the naming
    rule."""
    if edge_origin.byte_length() == 0:
        return String("")
    if not edge_logical_id.endswith(client_edge_suffix):
        return String("")
    var base = edge_origin.copy()
    while base.byte_length() > 0 and base.endswith(String("/")):
        # Bind, then transfer: `base = String(base[...])` would read `base` while
        # the assignment constructs into it.
        var trimmed = String(base[byte=0 : base.byte_length() - 1])
        base = trimmed^
    return base + EDGE_READINESS_PATH


def await_data_plane_ready[
    P: DataPlaneProbe, R: Reporter
](
    mut probe: P, url: String, budget: PollBudget, mut reporter: R
) raises -> DataPlaneReadiness:
    """Probe `url` until the request gets PAST the IAM front end, or the budget is
    exhausted, sleeping `budget.interval_ms` between probes.

    Returns as soon as `is_data_plane_ready` holds. A refusal (403) or an
    unreachable dial (0) is retried. An EMPTY `url` is a SKIP with the reason
    stated, never a ready.

    Exhausting the budget is not an error here, and a caller must not turn it into
    one lightly: the 403 attribution holds only while the edge enforces no
    authentication of its own. This gate's job is to WAIT (to move the validate
    gates out of the propagation window) and to make the refusal VISIBLE when it
    does not clear. The verdict is the validate gates', which retry."""
    if url.byte_length() == 0:
        return DataPlaneReadiness.skipped_because(
            String(
                "no safe data-plane probe exists for this edge (only a CATCH_ALL"
                " edge routes an arbitrary path to the backend; a SINGLE_PATH"
                " edge's only routed path is its declared ingest, and probing"
                " that would fire the side effect it exists to deliver)"
            )
        )
    reporter.info(
        String("data-plane: waiting for the edge hop to be authorized — GET ")
        + url
        + String(" up to ")
        + String(budget.max_attempts)
        + String(" time(s), interval ")
        + String(budget.interval_ms)
        + String("ms")
    )
    var attempt = 0
    var last = DATA_PLANE_UNREACHABLE
    while attempt < budget.max_attempts:
        attempt += 1
        last = probe.probe_status(url)
        if is_data_plane_ready(last):
            reporter.info(
                String("data-plane: READY on attempt ")
                + String(attempt)
                + String(" (HTTP ")
                + String(last)
                + String(" — the request reached past the IAM front end; this")
                + String(" gate does NOT judge what answered)")
            )
            return DataPlaneReadiness(
                True,
                attempt,
                last,
                False,
                String("ready after ")
                + String(attempt)
                + String(" probe(s), HTTP ")
                + String(last),
            )
        reporter.info(
            String("data-plane: attempt ")
            + String(attempt)
            + String("/")
            + String(budget.max_attempts)
            + String(" -> ")
            + (
                String("HTTP 403 (the gateway SA's hop to the backend is still")
                + String(" refused — the scoped run.invoker grant has not")
                + String(" propagated)")
                if is_invoker_refusal(last)
                else String("unreachable (no response — the gateway host may not")
                + String(" resolve yet)")
            )
        )
        if attempt < budget.max_attempts:
            budget.sleep_between()
    return DataPlaneReadiness(
        False,
        attempt,
        last,
        False,
        String("NOT ready after ")
        + String(attempt)
        + String(" probe(s) — last ")
        + (
            String("HTTP 403")
            if is_invoker_refusal(last)
            else String("no response")
        )
        + String(
            ". Every request through this edge is being refused, so a validation"
            " suite run against it now measures the refusal, not the service —"
            " a row asserting a NON-2xx status PASSES during a total outage."
        ),
    )
