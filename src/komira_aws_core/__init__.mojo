"""`komira_aws_core` -- the ONE hand-written AWS core under the generated AWS
clients.

- `credential.mojo`: the `AwsCredential` value.
- `sigv4.mojo`: AWS Signature Version 4: header signing, query signing
  (presigned URLs) and a signing key cache.
- `credential_chain.mojo`: the AWS SDK default credential provider chain and
  region resolution, reading the STANDARD AWS SDK environment variables and
  shared files only, through the seams of `sources.mojo` (environment, files,
  clock).
- `shared_config.mojo`: the shared config and credentials file parser.
- `sts_credentials.mojo`, `container_credentials.mojo`,
  `imds_credentials.mojo`: the network-backed providers as request builders
  and response parsers. They exchange bytes through the
  `CredentialTransport` trait (`credential_transport.mojo`); this package
  opens no socket.
"""

from .credential import AwsCredential
from .credential_chain import (
    MAX_SOURCE_PROFILE_DEPTH,
    AwsCredentialParams,
    ResolvedAwsCredential,
    resolve_aws_credentials,
    resolve_aws_region,
)
from .credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
    host_header,
)
from .container_credentials import (
    ContainerEndpoint,
    build_container_request,
    container_endpoint_full,
    container_endpoint_relative,
    parse_container_credentials,
)
from .imds_credentials import (
    build_imds_credentials_request,
    build_imds_role_request,
    build_imds_token_request,
    imds_endpoint,
    parse_imds_credentials,
    parse_imds_role,
    parse_imds_token,
)
from .shared_config import (
    AwsProfile,
    AwsProfileSet,
    ProfileChoice,
    SharedFilePaths,
    load_profiles,
    parse_profile_file,
    select_profile,
    shared_file_paths,
)
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
from .sources import (
    AwsClock,
    EnvSource,
    FileSource,
    FixedClock,
    MapEnv,
    MapFiles,
    ProcessEnv,
    ProcessFiles,
    amz_date_from_unix,
)
from .sts_credentials import (
    STS_API_VERSION,
    TemporaryAwsCredential,
    build_assume_role,
    build_assume_role_with_web_identity,
    parse_sts_credentials,
)
