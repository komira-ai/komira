# komira_secrets_e2e: the generated AWS Secrets Manager client
# (komira_aws_secretsmanager) against a stateful fake of the service, over a
# real socket on 127.0.0.1, in one process.
#
# A test-only package: its welded tests are the point. The library holds
# what they share: the fake (fake_store.mojo, fake_service.mojo), its own
# SigV4 verifier (sigv4_check.mojo), the runner that steps the server on one
# thread while the client runs on another (duet.mojo), and the client
# pointed at the fake with canned credentials (client.mojo).

from .sigv4_check import (
    CannedCredential,
    SIGV4_ALGORITHM,
    SigV4Verdict,
    canonical_header_value,
    sigv4_signature,
    verify_sigv4,
)
from .fake_store import (
    FAKE_EPOCH_SECONDS,
    STAGE_CURRENT,
    STAGE_PREVIOUS,
    FakeSecret,
    SecretStore,
    SecretVersion,
)
from .fake_service import (
    AWS_JSON_11,
    FAULT_500_AFTER_APPLY,
    FAULT_500_BEFORE_APPLY,
    SECRETSMANAGER_SIGNING_NAME,
    FakeSecretsManager,
    ScriptedFault,
    WireRecord,
)
from .duet import ClientLeg, FakeServer, serve_while
from .client import (
    EXAMPLE_ACCESS_KEY_ID,
    EXAMPLE_SECRET_ACCESS_KEY,
    FAKE_REGION,
    LoopbackClient,
    WRONG_SECRET_ACCESS_KEY,
    fake_credentials,
    leaks,
    loopback_client,
)
