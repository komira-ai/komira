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
- `aws_request.mojo`: `AwsRequest` (unsigned, what a generated
  `build_<op>_request` returns), `AwsResponse` (what a generated
  `parse_<op>_response` reads) and `HttpResult` (what a transport returns).
  Every body is bytes.
- `aws_error.mojo`: `AwsErrorInfo` (status, code, message, request id of a
  failed response) and `aws_json_error_info`.
- `aws_codec.mojo`: the awsJson scalar encoding (`AwsJsonToken`, the
  `aws_token_*` encoders and decoders, the AWS_TS_* timestamp formats) and
  the error shape (`aws_error_code*`, `aws_error_message_from_body`).
- `aws_json.mojo`: the `JsonValue`-typed `aws_json_*` / `aws_*_from_json` /
  `aws_ts_to_json` names a generated module calls, over komira_json.
- `endpoint.mojo`: `AwsEndpoint`, the partitions, `aws_service_endpoint`,
  `resolve_endpoint`, and `aws_endpoint_config` (AWS_ENDPOINT_URL[_<SVC>],
  FIPS and dual-stack, from the standard settings only).
- `creds_source.mojo`: the `AwsCredsSource` trait a generated client signs
  through, a static source and the cached default chain.
- `signed_request.mojo`: `build_sigv4_signed_request`, the socket-free half
  of a send, and `AwsPayloadSigning` (hashed, unsigned or precomputed).
- `endpoint_rules.mojo`: `EndpointRuleSet`, the interpreter of a service's
  Smithy endpoint ruleset (`endpoint-rule-set-1.json`), with its standard
  library; `partitions.mojo`: `AwsPartitionSet`, the partitions.json table
  its `aws.partition` reads.
- `s3_wire.mojo`: `s3_copy_source` and `s3_content_range_total`, the two S3
  header values no model states.
"""

from .aws_codec import (
    AWS_ERROR_CODE_MAX_BYTES,
    AWS_ERROR_MESSAGE_MAX_BYTES,
    AWS_JSON_BOOL,
    AWS_JSON_NUMBER,
    AWS_JSON_STRING,
    AWS_TS_ISO8601,
    AWS_TS_RFC822,
    AWS_TS_UNIX,
    AwsJsonToken,
    aws_blob_from_text,
    aws_error_code,
    aws_error_code_from_body,
    aws_error_message_from_body,
    aws_f64_from_token,
    aws_is_error_status,
    aws_token_blob,
    aws_token_bool,
    aws_token_f32,
    aws_token_f64,
    aws_token_i32,
    aws_token_i64,
    aws_token_string,
    aws_token_ts,
    aws_ts_from_token,
)
from .aws_json import (
    aws_blob_from_json,
    aws_f64_from_json,
    aws_json_blob,
    aws_json_bool,
    aws_json_f32,
    aws_json_f64,
    aws_json_i32,
    aws_json_i64,
    aws_json_string,
    aws_ts_from_json,
    aws_ts_to_json,
)
from .aws_error import (
    AWS_REQUEST_ID_MAX_BYTES,
    AwsErrorInfo,
    aws_json_error_info,
    aws_request_id,
)
from .aws_request import AwsRequest, AwsResponse, HttpResult
from .credential import AwsCredential
from .creds_source import (
    AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS,
    AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS,
    AwsCredsSource,
    DefaultChainCredsSource,
    StaticCredsSource,
    expiration_unix_seconds,
)
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
from .endpoint import (
    AwsEndpoint,
    AwsEndpointConfig,
    AwsPartition,
    aws_endpoint_config,
    aws_partition_for_region,
    aws_service_endpoint,
    resolve_endpoint,
    service_endpoint_env_var,
)
from .endpoint_rules import (
    ENDPOINT_RULESET_MAX_DEPTH,
    EndpointOutcome,
    EndpointParams,
    EndpointRuleSet,
    ResolvedEndpoint,
    is_valid_host_label,
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
from .partitions import AwsPartitionSet
from .s3_wire import s3_content_range_total, s3_copy_source
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
from .signed_request import AwsPayloadSigning, build_sigv4_signed_request
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
