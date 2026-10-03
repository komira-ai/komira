"""`HttpClientConfig` of komira_http_client.client, as a client-mode
generated client takes it (its constructor's `http_config`) and hands it to
`send_sigv4_signed_request` unchanged.

Of the real config only the two fields a caller's choice between its
constructors sets are kept: `context_ceiling_us`, the deadline of the
request the process serves inside (0 when there is none), and
`request_timeout_us`, the per-request budget (0 selects the 600 s default).
`for_serving_ceiling` records the ceiling and, unlike the real one, derives
no budget from it, so `request_timeout_us` stays 0 here: no code of this
cell sends a request. The stub `send_sigv4_signed_request` echoes both
fields, so a caller's test can read that its config reached the send.
"""


@fieldwise_init
struct HttpClientConfig(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The per-request budget and the containing deadline, in
    microseconds."""

    var request_timeout_us: Int
    var context_ceiling_us: Int

    @staticmethod
    def for_serving_ceiling(ceiling_us: Int) -> HttpClientConfig:
        """The config of a process whose containing request has the
        deadline `ceiling_us` (0 = none)."""
        return HttpClientConfig(request_timeout_us=0, context_ceiling_us=ceiling_us)

    @staticmethod
    def defaults() -> HttpClientConfig:
        """The config of a process with no containing request deadline."""
        return HttpClientConfig.for_serving_ceiling(0)
