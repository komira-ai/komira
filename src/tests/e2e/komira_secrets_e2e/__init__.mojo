# komira_secrets_e2e: the generated secret-store clients against stateful
# fakes of their services, over a real socket on 127.0.0.1, in one process:
# AWS Secrets Manager (komira_aws_secretsmanager) over plaintext HTTP, and
# GCP Secret Manager v1 (komira_gcp_secretmanager) over TLS.
#
# A test-only package: its welded tests are the point. The library holds
# what they share: the AWS fake (fake_store.mojo, fake_service.mojo), its
# own SigV4 verifier (sigv4_check.mojo) and client (client.mojo); the GCP
# fake (gcp_store.mojo, gcp_fake.mojo), the TLS terminator in front of it
# (tls_front.mojo) and its server and client (gcp_server.mojo); and the
# runner that steps a server on one thread while the client runs on another
# (duet.mojo).

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
from .duet import ClientLeg, FakeServer, ServeStep, serve_while
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
from .gcp_store import (
    GCP_PROJECT_ID,
    GCP_PROJECT_NUMBER,
    GCP_REGION,
    GcpSecret,
    GcpStore,
    GcpVersion,
    crc32c,
)
from .gcp_fake import (
    INVALID_CREDENTIAL_MESSAGE,
    MISSING_CREDENTIAL_MESSAGE,
    FakeSecretManager,
)
from .tls_front import TlsFront
from .gcp_server import (
    GLOBAL_HOST,
    OTHER_ACCESS_TOKEN,
    REGIONAL_HOST,
    TEST_ACCESS_TOKEN,
    GcpFakeServer,
    NoTokenSource,
    gcp_fake_server,
    gcp_loopback_client,
)
