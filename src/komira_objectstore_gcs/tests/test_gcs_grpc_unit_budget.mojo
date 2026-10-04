# =============================================================================
# test_gcs_grpc_unit_budget.mojo — the transport's request budget reaches the
#   HttpClient inside the generated client.
# =============================================================================
#
# A call's `grpc-timeout` is a request to the peer, and a peer that accepts a
# request and then goes silent is exactly the peer that will not honour it.
# What bounds such a call without the peer's help is the HttpClient's
# `request_timeout_us`, which komira_http_client enforces on both HTTP/1.1 and
# HTTP/2 (its own test drives a silent peer). A caller that runs each unit of
# work under a budget passes that budget in the backend's `HttpClientConfig`.
#
# What this file checks is that the value arrives: `request_timeout_us()`
# reads it back from the HttpClient the generated client owns, not from a
# copy the backend kept, so a parameter that stopped at a field would fail
# here.
#
# Hermetic: the backends are built and never called, so nothing is dialed.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_retry import ManualClock

from komira_objectstore_gcs import StorageGrpcBackend


comptime _UNIT_BUDGET_US: Int = 20_000_000
"""A caller's per-unit budget: 20 s."""

comptime _SERVING_CEILING_US: Int = 30_000_000
"""The deadline of a request a serving process runs inside: 30 s."""

comptime Backend = StorageGrpcBackend[KernelTcpConnector, StaticTokenSource, ManualClock]


def _backend(config: HttpClientConfig) raises -> Backend:
    return Backend(
        KernelTcpConnector.new(),
        StaticTokenSource(String("t")),
        ManualClock(0),
        config,
    )


def _authored(budget_us: Int) -> HttpClientConfig:
    var cfg = HttpClientConfig.defaults()
    cfg.request_timeout_us = budget_us
    return cfg^


def test_authored_budget_reaches_the_transport() raises:
    assert_equal(_backend(_authored(_UNIT_BUDGET_US)).request_timeout_us(), _UNIT_BUDGET_US)


def test_bounded_backend_is_inside_the_budget_and_below_the_default() raises:
    """Inside the budget, positive (0 would mean "the default", i.e. no
    bound of the caller's), and strictly below what a backend that authors
    nothing gets: if the two were equal the budget changed nothing."""
    var bounded = _backend(_authored(_UNIT_BUDGET_US)).request_timeout_us()
    var unauthored = _backend(HttpClientConfig.defaults()).request_timeout_us()
    assert_true(bounded > 0)
    assert_true(bounded <= _UNIT_BUDGET_US)
    assert_true(
        bounded < unauthored,
        String("bounded=") + String(bounded) + " unauthored=" + String(unauthored),
    )


def test_default_config_is_unchanged() raises:
    """A backend built from `HttpClientConfig.defaults()` gets exactly that
    config's budget, the generous one: no other caller's bound moved."""
    var got = _backend(HttpClientConfig.defaults()).request_timeout_us()
    assert_equal(got, HttpClientConfig.defaults().request_timeout_us)
    assert_true(got > _UNIT_BUDGET_US)


def test_serving_ceiling_reaches_the_transport() raises:
    """A serving process derives its budget from the deadline it runs inside;
    that derived value, under the ceiling, is what the transport carries."""
    var cfg = HttpClientConfig.for_serving_ceiling(_SERVING_CEILING_US)
    var got = _backend(cfg).request_timeout_us()
    assert_equal(got, cfg.request_timeout_us)
    assert_true(got > 0)
    assert_true(got <= _SERVING_CEILING_US)
    assert_true(got < _backend(HttpClientConfig.defaults()).request_timeout_us())


def main() raises:
    test_authored_budget_reaches_the_transport()
    test_bounded_backend_is_inside_the_budget_and_below_the_default()
    test_default_config_is_unchanged()
    test_serving_ceiling_reaches_the_transport()
    print("all unit budget tests passed (4)")
