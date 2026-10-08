# =============================================================================
# client.mojo -- the generated client, pointed at the fake
# =============================================================================
#
# `loopback_client` builds the generated `SecretsManagerClient` the way an
# application builds it, with one difference: the endpoint configuration's
# `endpoint` is http://127.0.0.1:<port>, the fake. Its connector is the
# kernel TCP one (plaintext, a real socket), made by a plain function, as
# the client takes a `def () raises thin -> C` factory.
#
# The credentials are canned, the example key pair the AWS documentation
# uses; the fake holds the same pair (`fake_credentials`).
# `WRONG_SECRET_ACCESS_KEY` is that key with one character changed, for a client whose signature the
# fake must refuse.
#
# Each attempt is bounded by `LOOPBACK_REQUEST_TIMEOUT_US` (30 s), not the
# defaults' 600 s: the standard retry makes at most three sends with jitter
# under 1 s and 2 s between them, so a call against a server that stopped
# stepping (its listener still accepts) fails within about 93 s, inside the
# duet's `SERVE_DEADLINE_NS` (duet.mojo), instead of holding the build
# action for half an hour before the server's own error is reported.
#
# `leaks` is the custody check: whether a text holds the secret value's
# bytes anywhere.
# =============================================================================

from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerClient,
    SecretsManagerEndpointConfig,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from .sigv4_check import CannedCredential

comptime EXAMPLE_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
comptime EXAMPLE_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
comptime WRONG_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEZ"
comptime FAKE_REGION = "us-east-1"
comptime LOOPBACK_REQUEST_TIMEOUT_US = 30_000_000

comptime LoopbackClient = SecretsManagerClient[KernelTcpConnector, StaticCredsSource]


def fake_credentials() -> List[CannedCredential]:
    var out = List[CannedCredential]()
    out.append(
        CannedCredential(
            String(EXAMPLE_ACCESS_KEY_ID), String(EXAMPLE_SECRET_ACCESS_KEY)
        )
    )
    return out^


def _kernel_tcp() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def loopback_client(port: UInt16, secret_access_key: String) raises -> LoopbackClient:
    """The generated client, sending to http://127.0.0.1:`port` over kernel
    TCP, signing with the example access key id and `secret_access_key`."""
    var http = HttpClientConfig.defaults()
    http.request_timeout_us = LOOPBACK_REQUEST_TIMEOUT_US
    var config = SecretsManagerEndpointConfig()
    config.endpoint = Optional[String](
        String("http://127.0.0.1:") + String(Int(port))
    )
    return LoopbackClient(
        _kernel_tcp,
        http^,
        StaticCredsSource(
            AwsCredential(
                String(EXAMPLE_ACCESS_KEY_ID), secret_access_key, String("")
            )
        ),
        String(FAKE_REGION),
        config^,
    )


def leaks(text: String, secret_value: String) -> Bool:
    """True when `text` holds `secret_value`'s bytes."""
    return text.find(secret_value) >= 0
