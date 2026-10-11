"""`komira_gcp_wif` — Google Cloud workload identity federation from AWS.

An AWS workload (a Lambda, an ECS task, an EC2 instance) gets Google
credentials without a Google key: it proves its AWS role to Google's Security
Token Service and receives a federated Google access token. This package is
that exchange, plus one use of the token that has no generated client:
minting a JWT self-signed by a service account through IAM Credentials
`signJwt`.

Two legs, composed through komira_gcp_core's token seam:

  1. `AwsWifTokenFetcher` (sts.mojo) is a komira_gcp_core
     `AccessTokenFetcher`: it signs AWS `GetCallerIdentity` (aws_subject.mojo,
     the `aws1` subject token of Google's external-account credentials) and
     exchanges it at `sts.googleapis.com`. Wrapped in komira_gcp_core's
     `CachingTokenSource`, it is a `GcpTokenSource`, the seam every generated
     `komira_gcp_<service>` client takes its bearer from.
  2. `WifTokenMinter` (sign_jwt.mojo) takes any `GcpTokenSource` and calls
     `signJwt`. Leg 2 is never dialed when the token source raises.

Wire details follow the reference implementation, Google's auth library for
Python (`google/auth/aws.py`, `google/oauth2/sts.py`); each file's header
names them. Both legs send through komira_http_client over a
komira_http_core `Connector` the caller binds (public-CA TLS in production,
`ScriptedConnector` in the tests), and a non-2xx answer is reported through
komira_gcp_core's `parse_gcp_status`, which never echoes a body.

Configuration is by parameter. The package reads no environment: the AWS
credential comes from a komira_aws_core `AwsCredsSource` (bind
`DefaultChainCredsSource` for the AWS SDK's standard chain), and the region,
the provider audience and the service account are arguments. An
`external_account` file (external_account.mojo) is given as its text: the
caller reads the file, from the path the provider-standard credentials
variable names or a flag; a file-sourced subject token is read through a
komira_gcp_core `FileSource`.

Modules:
  - aws_subject.mojo : `aws1_signed_request`, `aws1_subject_token`,
                       `Aws1SignedRequest`, `aws_sts_host`.
  - sts.mojo         : `AwsWifTokenFetcher`, `sts_exchange_form`,
                       `parse_sts_token_response`, `oauth_error_code`,
                       `is_oauth_error_code`.
  - external_account.mojo : `parse_external_account`,
                       `ExternalAccountConfig`, `ExternalAccountFetcher`
                       (an `external_account` file's flow: the subject from
                       a file or URL, the exchange, and impersonation when
                       the file names it), `subject_token_from`,
                       `generate_access_token_body`,
                       `parse_generate_access_token_response`.
  - sign_jwt.mojo    : `WifTokenMinter`, `sign_jwt_claims`,
                       `sign_jwt_request_body`, `sign_jwt_path`,
                       `parse_sign_jwt_response`.
  - _post.mojo       : private, not re-exported: the one HTTPS POST both legs
                       send.
"""

from .aws_subject import (
    AWS_STS_SERVICE,
    AWS_SUBJECT_TOKEN_TYPE,
    GET_CALLER_IDENTITY_QUERY,
    TARGET_RESOURCE_HEADER,
    Aws1SignedRequest,
    aws1_signed_request,
    aws1_subject_token,
    aws_sts_host,
)
from .sts import (
    ACCESS_TOKEN_TYPE,
    CLOUD_PLATFORM_SCOPE,
    FORM_CONTENT_TYPE,
    GOOGLE_STS_HOST,
    GOOGLE_STS_PATH,
    TOKEN_EXCHANGE_GRANT,
    AwsWifTokenFetcher,
    is_oauth_error_code,
    oauth_error_code,
    parse_sts_token_response,
    sts_exchange_form,
)
from .external_account import (
    EXTERNAL_ACCOUNT_TYPE,
    IMPERSONATION_LIFETIME_SECONDS,
    JWT_SUBJECT_TOKEN_TYPE,
    ExternalAccountConfig,
    ExternalAccountFetcher,
    generate_access_token_body,
    parse_external_account,
    parse_generate_access_token_response,
    subject_token_from,
)
from .sign_jwt import (
    IAMCREDENTIALS_HOST,
    JSON_CONTENT_TYPE,
    SIGNED_JWT_TTL_SECONDS,
    WifTokenMinter,
    parse_sign_jwt_response,
    sign_jwt_claims,
    sign_jwt_path,
    sign_jwt_request_body,
)
