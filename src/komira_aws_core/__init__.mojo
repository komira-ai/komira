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
  failed response), `aws_json_error_info` and `aws_query_error_code`.
- `aws_codec.mojo`: the awsJson scalar encoding (`AwsJsonToken`, the
  `aws_token_*` encoders and decoders, the AWS_TS_* timestamp formats) and
  the error shape (`aws_error_code*`, `aws_error_message_from_body`).
- `aws_json.mojo`: the `JsonValue`-typed `aws_json_*` / `aws_*_from_json` /
  `aws_ts_to_json` names a generated module calls, over komira_json.
- `aws_text.mojo`: the text form of a scalar bound to a URI label, a query
  value or a header (`aws_text_*` writers, strict `aws_*_from_text`
  readers), and the three Smithy timestamp formats as text, http-date
  (IMF-fixdate) included.
- `aws_rest.mojo`: the HTTP binding runtime of a restJson1 / restXml
  client: `AwsRestUri` (labels, greedy labels, query), host-prefix labels,
  list and prefix headers, the response code, and `aws_rest_json_error`.
- `aws_xml.mojo`: the restXml body codec over komira_xml (`aws_xml_write_*`
  and `aws_xml_get_*` scalars, wrapped and flattened lists and maps,
  xmlAttribute, xmlNamespace), `aws_rest_xml_error` /
  `aws_xml_error_info` (<ErrorResponse><Error>, a bare <Error>, ec2's
  <Response><Errors><Error>, the status as the code of an empty or non-XML
  body or a 5xx <html> page), and `aws_xml_body_is_error`,
  S3's 200-with-<Error> check.
- `aws_query.mojo`: the awsQuery / ec2Query runtime: `AwsQueryWriter` (the
  form body, `Action` and `Version` first, botocore's percent-encoding),
  `aws_query_key` / `aws_query_rename_last` (parameter names),
  `aws_query_set_body`, `aws_query_result` (the `<OpResult>` element of a
  response) and `aws_query_error` (<ErrorResponse><Error> and ec2's
  <Response><Errors><Error>, through `aws_xml_error_info`).
- `endpoint.mojo`: `AwsEndpoint`, the partitions, `aws_service_endpoint`,
  `resolve_endpoint`, and `aws_endpoint_config` (AWS_ENDPOINT_URL[_<SVC>],
  FIPS and dual-stack, from the standard settings only).
- `creds_source.mojo`: the `AwsCredsSource` trait a generated client signs
  through, a static source and the cached default chain.
- `shared_creds.mojo`: `SharedCredsSource`, a Copyable credential source
  whose clones share one refreshing source behind a lock (single flight).
- `http_credential_transport.mojo`: `SchemeSplitCredentialTransport`, the
  `CredentialTransport` that sends `http` and `https` requests over two
  `AwsHttpTransport`s; `process_creds.mojo`: `ProcessCredsSource`, the
  default chain over the process's environment, files and network, shared,
  and `process_creds_source`.
- `signed_request.mojo`: `build_sigv4_signed_request`, the socket-free half
  of a send, `build_unsigned_request`, the same request for an anonymous
  operation, `AwsPayloadSigning` (hashed, unsigned or precomputed), and
  `is_s3_signing_name`, the signing names signed by S3's rules.
- `endpoint_rules.mojo`: `EndpointRuleSet`, the interpreter of a service's
  Smithy endpoint ruleset (`endpoint-rule-set-1.json`), with its standard
  library; `partitions.mojo`: `AwsPartitionSet`, the partitions.json table
  its `aws.partition` reads.
- `endpoint_signing.mojo`: `aws_signing_target`, a resolved endpoint as the
  signer takes it (`AwsSigningTarget`: the `AwsEndpoint`, signing name and
  region, and headers), refusing an auth scheme this core cannot sign.
- `aws_send.mojo`: `send_sigv4_signed_request`, the transport half of a
  send a generated client calls: signed, sent over komira_http_client
  through a `Connector`, and retried; `send_sigv4_signed_request_with`
  over injected seams (`AwsHttpTransport`, the clocks, the retry loop and
  budget), and `AwsConnectorTransport`; `send_unsigned_request` and
  `send_unsigned_request_with`, the same sends for an anonymous operation.
- `aws_retry.mojo`: `AwsRetryClassifier`, botocore's standard retry
  conditions for komira_retry over an `AwsAttempt`, with
  `aws_standard_retry_policy` and `AwsRetryQuota`, the retry quota a
  client keeps; every operation is retried alike, whatever its method,
  but a conditional write the service may have acted on
  (`aws_request_is_conditional`), which is not resent.
- `idempotency.mojo`: `aws_idempotency_token`, the random UUID a
  generated client fills an unset `idempotencyToken` member with, once per
  call, as botocore does.
- `echo_connector.mojo`: `AwsEchoConnector`, a test double whose stream
  answers each request with an error naming the request head as it reached
  the wire, so a test of a generated client asserts each verb's request.
- `s3_wire.mojo`: `s3_copy_source`, `s3_content_range_total` and
  `s3_apply_request_checksum` (over `s3_crc32` / `s3_checksum_crc32`), the
  S3 header values no model states.
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
    aws_query_error_code,
    aws_request_id,
)
from .aws_query import (
    AWS_QUERY_CONTENT_TYPE,
    AwsQueryWriter,
    aws_query_error,
    aws_query_key,
    aws_query_rename_last,
    aws_query_result,
    aws_query_set_body,
)
from .aws_request import AwsRequest, AwsResponse, HttpResult
from .aws_rest import (
    AwsRestUri,
    aws_header_field,
    aws_header_http_date_list,
    aws_header_http_date_list_from,
    aws_header_list,
    aws_header_list_from,
    aws_host_label,
    aws_host_prefix,
    aws_prefix_headers,
    aws_response_code,
    aws_rest_json_error,
    aws_set_prefix_headers,
)
from .aws_text import (
    aws_blob_from_base64,
    aws_bool_from_text,
    aws_f64_from_text,
    aws_http_date_from_text,
    aws_i32_from_text,
    aws_i64_from_text,
    aws_int_from_text,
    aws_media_from_text,
    aws_text_blob,
    aws_text_bool,
    aws_text_f32,
    aws_text_f64,
    aws_text_int,
    aws_text_media,
    aws_text_ts,
    aws_ts_from_text,
)
from .aws_retry import (
    AWS_DYNAMODB_CRC32_HEADER,
    AWS_IDP_COMMUNICATION_ERROR,
    AWS_NO_RETRY_INCREMENT,
    AWS_RETRY_COST,
    AWS_RETRY_QUOTA_CAPACITY,
    AWS_STANDARD_MAX_ATTEMPTS,
    AWS_TIMEOUT_RETRY_COST,
    AwsAttempt,
    AwsRetryClassifier,
    AwsRetryQuota,
    aws_dynamodb_crc32_mismatch,
    aws_is_throttling_code,
    aws_is_transient_code,
    aws_is_transient_status,
    aws_request_is_conditional,
    aws_standard_retry_policy,
    aws_transport_error_is_timeout,
    aws_transport_error_kind,
    aws_transport_error_unsent,
)
from .idempotency import aws_idempotency_token
from .aws_send import (
    AwsConnectorTransport,
    AwsHttpTransport,
    aws_response_error_code,
    send_sigv4_signed_request,
    send_sigv4_signed_request_with,
    send_unsigned_request,
    send_unsigned_request_with,
)
from .echo_connector import (
    AWS_ECHO_CODE,
    AwsEchoConnector,
    AwsEchoStream,
    aws_echo_head,
)
from .aws_xml import (
    aws_rest_xml_error,
    aws_xml_attr,
    aws_xml_blob_of,
    aws_xml_body_is_error,
    aws_xml_bool_of,
    aws_xml_child,
    aws_xml_end,
    aws_xml_entry_key,
    aws_xml_entry_value,
    aws_xml_error_info,
    aws_xml_f32_of,
    aws_xml_f64_of,
    aws_xml_get_attr,
    aws_xml_get_blob,
    aws_xml_get_bool,
    aws_xml_get_f32,
    aws_xml_get_f64,
    aws_xml_get_int,
    aws_xml_get_string,
    aws_xml_get_string_list,
    aws_xml_get_string_map,
    aws_xml_get_struct,
    aws_xml_get_ts,
    aws_xml_int_of,
    aws_xml_list_end,
    aws_xml_list_items,
    aws_xml_list_start,
    aws_xml_map_end,
    aws_xml_map_entries,
    aws_xml_map_entry_start,
    aws_xml_map_start,
    aws_xml_namespace,
    aws_xml_parse,
    aws_xml_set_body,
    aws_xml_start,
    aws_xml_string_of,
    aws_xml_ts_of,
    aws_xml_write_blob,
    aws_xml_write_bool,
    aws_xml_write_f32,
    aws_xml_write_f64,
    aws_xml_write_int,
    aws_xml_write_string,
    aws_xml_write_string_list,
    aws_xml_write_string_map,
    aws_xml_write_text,
    aws_xml_write_ts,
)
from .credential import AwsCredential
from .creds_source import (
    AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS,
    AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS,
    AwsCredsSource,
    DefaultChainCredsSource,
    StaticCredsSource,
    expiration_unix_seconds,
)
from .shared_creds import SHARED_CREDS_REFRESH_FAILED, SharedCredsSource
from .http_credential_transport import SchemeSplitCredentialTransport
from .process_creds import (
    ProcessChainCredsSource,
    ProcessCredentialTransport,
    ProcessCredsSource,
    process_credential_transport,
    process_creds_source,
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
from .endpoint_signing import AwsSigningTarget, aws_signing_target
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
from .s3_wire import (
    S3_DEFAULT_CHECKSUM_ALGORITHM,
    s3_apply_request_checksum,
    s3_checksum_crc32,
    s3_content_range_total,
    s3_copy_source,
    s3_crc32,
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
from .signed_request import (
    AwsPayloadSigning,
    build_sigv4_signed_request,
    build_unsigned_request,
    is_s3_signing_name,
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
    SystemAwsClock,
    amz_date_from_unix,
)
from .sts_credentials import (
    STS_API_VERSION,
    TemporaryAwsCredential,
    build_assume_role,
    build_assume_role_with_web_identity,
    parse_sts_credentials,
)
