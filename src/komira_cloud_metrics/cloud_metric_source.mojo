# =============================================================================
# komira_cloud_metrics/cloud_metric_source.mojo — the CLOUD-NEUTRAL seam for
#   reading a TIME SERIES about ONE deployed workload, and the value PODs that
#   cross it.
# =============================================================================
#
# ⛔⛔ READ `__init__.mojo` FIRST. It carries the ARGUED CASE for why this
# package has a library half and NO live conformer and NO caller. In one line:
# every question a deploy gate asks has a DIRECT, SYNCHRONOUS answer already
# wired, and a metric is a lagging sampled proxy for it — measured lag ~26 min
# on Cloud Run. ⛔ DO NOT WIRE THIS INTO A VALIDATE STEP without reading §3
# there; the first person to try will re-derive a flake this package already
# wrote down.
#
# ── WHAT IT IS MODELLED ON, DELIBERATELY ────────────────────────────────────
# `kci_logs.CloudLogSource`, point for point, because the two seams
# answer the same SHAPE of question about the same deployed things and a second
# vocabulary for that is a second thing to keep in agreement:
#   * ONE VERB, keyed on the PROVIDER'S OWN self-addressing handle — never a
#     normalised `{project, region, kind, id}` POD, because a re-encoding
#     between the party that HAS the handle and the party that must address the
#     provider is where "reads the wrong project" is born.
#   * A FAULT IS A VALUE (`MetricPage.failed`), NEVER A RAISE.
#   * A RESPONSE BODY IS NEVER ECHOED.
#   * THE PARSE IS FIELD-ALLOW-LISTED.
#   * `NoCloudMetricSource` REFUSES; it does not fake an empty page.
#
# ── ⚠ THE ONE PLACE THE TWO SEAMS GENUINELY DIFFER, AND WHY ────────────────
# A log read is TOTAL over a handle: "give me this unit's lines". A metric read
# is not — a time series is a (metric, window, aligner) question about a
# workload, and NONE of those three is in the handle. So `read_series` takes a
# WINDOW alongside the handle, and the metric + aligner are the CONFORMER'S
# configuration (they are what makes one conformer "the request-count reader"
# rather than a general query engine).
# ⛔ THE ALTERNATIVE — a free-form `filter` string parameter — was rejected: it
# turns this seam into a query API whose every caller composes provider syntax,
# which is exactly the shape that put `gcloud logging read` in an operator's
# report in the first place.
#
# ENCAPSULATION: value PODs only. ZERO UnsafePointer crosses any signature, no
# wildcard origin, no FFI. Flat `String` / `Float64` / `List` fields, no
# byte-slab, no destroy-recreate pool member.
# def-based, Mojo 1.0.0b2.
# =============================================================================

from std.memory import ArcPointer


comptime DEFAULT_METRIC_ALIGNMENT_PERIOD: String = "3600s"
"""The server-side alignment period ONE `read_series` asks for by default.

⛔⛔ IT IS NOT A TUNING KNOB AND IT IS NOT COSMETIC — IT IS THE MEASURED
MITIGATION FOR A TRANSPORT CLIFF, measured on Cloud Run:

    an UNAGGREGATED `timeSeries.list` over a 24h window returned 2,546,731 bytes
    and FAILED after ~279s; the SAME code passed 12/12 at every window under
    ~1.1 MB. Hourly ALIGN_SUM over the same 24h returned the SAME 16 series in
    53,772 bytes — 47x smaller.

⚠ AND THE STALL DOES NOT REPRODUCE OFF CLOUD RUN. The same binary, endpoint and
payload run from a workstation passed in 12 seconds. So the cliff lives in the
CLOUD RUN JOB ENVIRONMENT — which is exactly where an in-cloud validate step
runs, and is one of the two reasons this package has no gate consumer."""

comptime DEFAULT_METRIC_ALIGNER: String = "ALIGN_SUM"
"""The per-series aligner. ⚠ RIGHT FOR A DELTA COUNTER and wrong for other
kinds: `request_count` is DELTA/INT64, for which ALIGN_SUM preserves "how many
requests". ALIGN_RATE answers a different question and ALIGN_MEAN is not defined
for a delta counter in a way any caller here wants. A conformer reading a GAUGE
must state its own."""


# =============================================================================
# §1 — MetricPoint — ONE aligned bucket. Flat POD.
# =============================================================================
@fieldwise_init
struct MetricPoint(Copyable, Movable, Deinitable):
    """One aligned point of one series.

      * `end_time` — the bucket's END, VERBATIM as the provider spelled it
                     (RFC3339 on GCP; epoch-millis digits on AWS). ⛔ NOT
                     normalised, for `CloudLogEntry.timestamp`'s reason: a
                     renderer that re-formats a provider timestamp can disagree
                     with the provider's own console, and the operator has both
                     open.
      * `value`    — the aligned value as a Float64. ⚠ An INT64 counter arrives
                     here as a Float64 and that is a DELIBERATE, LOSSY-ABOVE-2^53
                     choice: both clouds report aligned DOUBLE values for some
                     metrics and INT64 for others, and two numeric fields that
                     must never both be set is a worse contract than one that is
                     exact for every count this repo will ever read."""

    var end_time: String
    var value: Float64

    @staticmethod
    def empty() -> MetricPoint:
        return MetricPoint(String(""), Float64(0))


# =============================================================================
# §2 — MetricSeries — ONE label combination's points.
# =============================================================================
@fieldwise_init
struct MetricSeries(Copyable, Movable, Deinitable):
    """One series: the label combination that distinguishes it, plus its points
    OLDEST -> NEWEST.

    ⚠ `label_summary` IS A RENDERED SUMMARY, NOT A MAP, and it is deliberately
    not a `Dict`. A series' labels are provider- and metric-specific free-form
    keys; anything that reaches here has already passed an ALLOW-LIST at the
    parser, and what survives is a human clause for a report. A caller that
    needs to KEY on a label wants a narrower conformer, not a wider POD.

    ⚠ THE CARDINALITY IS THE RESIDUAL. 16 series were measured for ONE
    Cloud Run service (response_code x response_code_class x route). The
    aggregated response still scales with it, so a workload with ~20x the label
    cardinality reaches the transport cliff again."""

    var label_summary: String
    var points: List[MetricPoint]

    @staticmethod
    def empty() -> MetricSeries:
        return MetricSeries(String(""), List[MetricPoint]())

    def point_count(self) -> Int:
        return len(self.points)


# =============================================================================
# §3 — MetricPage — ONE read's result.
# =============================================================================
@fieldwise_init
struct MetricPage(Copyable, Movable, Deinitable):
    """What ONE `read_series` produced.

      * `series`     — one entry per label combination. EMPTY is an ANSWER.
      * `status`     — the HTTP status the provider answered, or 0 when the dial
                       never reached a verdict. A 403 and a DNS failure send an
                       operator to two different places.
      * `fault`      — EMPTY on a read that produced an answer (INCLUDING an
                       empty one). Non-empty means `series` is not an answer.
      * `next_token` — the provider's continuation token, carried so a future
                       paging read has somewhere to put it.

    ⛔⛔ EMPTY IS AN ANSWER, AND ON THIS SEAM THAT IS SHARPER THAN ON THE LOG ONE.
    An empty log stream means "the container printed nothing". An empty metric
    window means "no points have ARRIVED YET", which on Cloud Run is the normal
    state for ~26 minutes after a deploy (measured on Cloud Run: a ~26min gap
    between the newest point and now). ⛔ A CALLER THAT READS EMPTY AS
    UNHEALTHY HAS BUILT A CLOCK, NOT A GATE.

    ⛔ `fault` NEVER CARRIES A RESPONSE BODY — the `CloudLogPage.fault` rule,
    inherited deliberately. Status, byte count, transport message. Never bytes
    the server chose."""

    var series: List[MetricSeries]
    var status: Int
    var fault: String
    var next_token: String

    @staticmethod
    def empty(status: Int) -> MetricPage:
        """A read that REACHED the provider and got no series. ⛔ Distinct from
        a failure, and the distinction is the whole reason this is not modelled
        as "zero series means broken" — see the struct docstring."""
        return MetricPage(List[MetricSeries](), status, String(""), String(""))

    @staticmethod
    def failed(status: Int, reason: String) -> MetricPage:
        """A read that did NOT produce an answer. `reason` is a status/transport/
        parse statement — ⛔ never a response body."""
        return MetricPage(
            List[MetricSeries](), status, reason.copy(), String("")
        )

    def ok(self) -> Bool:
        """True iff the read produced an answer (whether or not it had series)."""
        return self.fault.byte_length() == 0

    def point_count(self) -> Int:
        """Points across every series — the ONE number a reader of this page
        usually wants. Counting it HERE, off the parsed value, rather than by
        scanning a raw body for `endTime` occurrences, is the difference
        between a count and a substring frequency."""
        var n = 0
        for i in range(len(self.series)):
            n += len(self.series[i].points)
        return n


# =============================================================================
# §4 — MetricWindow — the interval ONE read asks about.
# =============================================================================
@fieldwise_init
struct MetricWindow(Copyable, Movable, Deinitable):
    """The closed interval `[start, end]` a read covers, as the provider's own
    timestamp strings.

    ⛔ STRINGS, AND THE CALLER COMPOSES THEM — this package mints NO clock. A
    library that read the wall clock to build its own window would be
    untestable at the one thing most worth pinning (the exact bytes that reach
    the wire) and would make every hermetic assertion time-dependent. It is
    also what lets the two clouds keep their own spellings: RFC3339 on GCP,
    epoch SECONDS on AWS.

    ⚠ AN EMPTY BOUND IS A REFUSAL AT THE QUERY BUILDERS, never an open-ended
    read: an unbounded `timeSeries.list` is precisely the request that returned
    2.5 MB and stalled."""

    var start: String
    var end: String

    def ok(self) -> Bool:
        return self.start.byte_length() > 0 and self.end.byte_length() > 0


# =============================================================================
# §5 — CloudMetricSource — THE SEAM.
# =============================================================================
trait CloudMetricSource(Movable, Deinitable):
    """Read ONE workload's time series over a window, addressed by that cloud's
    OWN handle for it.

    ⛔ ONE VERB, AND `handle` IS DELIBERATELY THE PROVIDER'S OWN STRING —
    `CloudLogSource`'s rule, for its reason. Every arm's handle is
    self-addressing for the thing being measured:

      * GCP — a Cloud Run service resource name,
              `projects/<p>/locations/<r>/services/<s>`. The project is IN it,
              which is why `run_service_metric_path` needs nothing else.
      * AWS — an ECS service ARN,
              `arn:aws:ecs:<region>:<acct>:service/<cluster>/<service>`. The
              region, the cluster and the service name are IN it, which is what
              `GetMetricData`'s dimensions need.

    A conformer that cannot parse the handle it was given must return
    `MetricPage.failed(...)` SAYING SO — it must NOT guess, because a metric
    query that silently reads the wrong project returns SOMEONE ELSE'S numbers
    and the caller reads them as this workload's. On this seam that is worse
    than on the log one: a wrong LOG line usually looks wrong, and a wrong
    NUMBER never does.

    ⛔ IT MAY RAISE ONLY ON A PROGRAMMING FAULT. A dial failure, a 4xx, a body
    that does not parse — those are `MetricPage.failed(...)`.

    Conformers: `ScriptedCloudMetricSource` (the hermetic double, below),
    `NoCloudMetricSource` (the not-configured default). ⚠ THERE IS NO LIVE
    CONFORMER, ON PURPOSE — see `__init__.mojo` §3."""

    def read_series(
        mut self, handle: String, window: MetricWindow
    ) raises -> MetricPage:
        """Read `handle`'s series over `window`. Returns a `MetricPage`; see the
        trait docstring for what may and may not raise."""
        ...


# =============================================================================
# §6 — NoCloudMetricSource — the NOT-CONFIGURED default.
# =============================================================================
struct NoCloudMetricSource(
    CloudMetricSource, Copyable, Movable, Deinitable
):
    """The default binding of every `CloudMetricSource` type parameter.

    ⛔ IT REFUSES, IT DOES NOT RETURN AN EMPTY PAGE, and on this seam collapsing
    the two would be worse than on the log seam. An empty page means *no points
    arrived in this window* — a real, actionable answer that is also the NORMAL
    state for ~26 minutes after a deploy. "Nobody wired a metric source into
    this binary" is a different fact with a different next action, and a caller
    that cannot tell them apart reports a wiring gap as a quiet workload."""

    var _placeholder: UInt8

    def __init__(out self):
        self._placeholder = UInt8(0)

    def read_series(
        mut self, handle: String, window: MetricWindow
    ) raises -> MetricPage:
        return MetricPage.failed(
            0,
            String(
                "no cloud metric source is configured in this binary — the"
                " handle was recorded but nothing here can read it"
            ),
        )


# =============================================================================
# §7 — ScriptedCloudMetricSource — the hermetic double.
# =============================================================================
struct _ScriptedMetricState(Movable):
    """The double's interior: the per-handle script + the LOG OF EVERY READ.
    Flat `List[String]` / `List[MetricPage]`, no byte-slab, no
    wildcard origin, no UnsafePointer."""

    var handles: List[String]
    var pages: List[MetricPage]
    var calls: List[String]
    var windows: List[String]

    def __init__(out self):
        self.handles = List[String]()
        self.pages = List[MetricPage]()
        self.calls = List[String]()
        self.windows = List[String]()


struct ScriptedCloudMetricSource(CloudMetricSource, Movable, Deinitable):
    """An in-process `CloudMetricSource` that answers from a script and RECORDS
    every read.

    IT LIVES IN THE LIBRARY, NOT IN A TEST FILE — the `ScriptedCloudLogSource`
    convention, for its reason: a double reachable from only one file gets
    re-derived in the next one.

    ⛔ BEHIND AN `ArcPointer` SO `share()` READS THE AGGREGATE AFTER THE DOUBLE
    HAS BEEN MOVED INTO A SUBJECT. ⚠ This is the sanctioned `ArcPointer` case
    and no more: TRUE shared ownership, ONE thread, a test double
    (`docs/design/mojo_safety_and_idioms.md`)."""

    var _p: ArcPointer[_ScriptedMetricState]

    def __init__(out self):
        self._p = ArcPointer[_ScriptedMetricState](_ScriptedMetricState())

    def __init__(out self, *, var _share: ArcPointer[_ScriptedMetricState]):
        self._p = _share^

    def share(self) -> ScriptedCloudMetricSource:
        """A SECOND handle over ONE `_ScriptedMetricState`. SAFETY: ArcPointer
        ref-counted shared ownership; a TEST DOUBLE on ONE thread."""
        return ScriptedCloudMetricSource(
            _share=ArcPointer[_ScriptedMetricState](copy=self._p)
        )

    def script_page(mut self, handle: String, var page: MetricPage):
        """Script `handle`'s answer — INCLUDING a FAILED one, which is how a
        test proves a consumer reports a fault instead of changing a verdict."""
        self._p[].handles.append(handle.copy())
        self._p[].pages.append(page^)

    def read_series(
        mut self, handle: String, window: MetricWindow
    ) raises -> MetricPage:
        self._p[].calls.append(handle.copy())
        # ★ THE WINDOW IS RECORDED TOO. A consumer that read the right handle
        # over the WRONG window is the defect this seam is most likely to have,
        # and a double that discarded the window could not catch it.
        self._p[].windows.append(window.start + String("..") + window.end)
        for i in range(len(self._p[].handles)):
            if self._p[].handles[i] == handle:
                return self._p[].pages[i].copy()
        return MetricPage.empty(200)

    def call_count(self) -> Int:
        """How many reads this double served — the anti-vacuity check."""
        return len(self._p[].calls)

    def last_handle(self) -> String:
        """The handle of the most recent read, or EMPTY."""
        var n = len(self._p[].calls)
        if n == 0:
            return String("")
        return self._p[].calls[n - 1].copy()

    def last_window(self) -> String:
        """`"<start>..<end>"` of the most recent read, or EMPTY."""
        var n = len(self._p[].windows)
        if n == 0:
            return String("")
        return self._p[].windows[n - 1].copy()
