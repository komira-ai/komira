"""`komira_aws_core` -- the ONE hand-written AWS core under the generated AWS
clients.

This part holds the `AwsCredential` value and AWS Signature Version 4
(`sigv4.mojo`): header signing, query signing (presigned URLs) and a signing
key cache. It is pure computation over `komira_crypto`: no clock, no network,
and nothing read from the environment. Credential providers, retries and the
signed-request transport are separate modules of this package.
"""

from .credential import AwsCredential
from .sigv4 import (
    EMPTY_PAYLOAD_SHA256,
    MAX_PRESIGN_EXPIRES_SECONDS,
    SIGV4_ALGORITHM,
    UNSIGNED_PAYLOAD,
    Header,
    SigningKeyCache,
    SigV4PresignResult,
    SigV4Result,
    SigV4SigningContext,
    canonical_query,
    canonical_uri,
    derive_signing_key,
    sigv4_presign,
    sigv4_sign,
    sigv4_sign_cached,
    sigv4_sign_payload_hash,
    sigv4_string_to_sign,
    uri_encode,
)
