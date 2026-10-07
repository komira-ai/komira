"""`komira_gcp_fcm`: Firebase Cloud Messaging HTTP v1 `messages:send`, the
content-blind wake of one device.

  message.mojo  `FcmWake` (`id`, `kind`, `source`: the whole data map), the
                request body `fcm_message_json` (data-only, Android priority
                HIGH), `fcm_send_path`, `FCM_SCOPE` and `fcm_adc_options`.
  outcome.mojo  `FcmOutcome` and `classify_fcm_response`: ACCEPTED, DEAD
                (HTTP 404 or FcmError UNREGISTERED), TRANSIENT (HTTP 429,
                5xx, or no answer) or REFUSED (any other status), with the
                server's retry delay; never body text.
  client.mojo   `FcmClient[C: Connector, T: GcpTokenSource]` and its
                `send_one`, `send_failure_outcome` (a send with no
                answer), `FcmEndpoint`, and
                `fcm_application_default_token_source` and its seamed
                `fcm_application_default_token_source_from` (komira_gcp_core's
                Application Default Credentials with `FCM_SCOPE`).

The package reads no environment itself; the Application Default
Credentials entry reads the variables komira_gcp_core documents.
"""

from .message import (
    FCM_ANDROID_PRIORITY,
    FCM_HOST,
    FCM_SCOPE,
    FcmWake,
    check_project_id,
    fcm_adc_options,
    fcm_message_json,
    fcm_send_path,
)
from .outcome import (
    FCM_ACCEPTED,
    FCM_DEAD,
    FCM_ERROR_TYPE,
    FCM_REFUSED,
    FCM_RPC,
    FCM_TRANSIENT,
    FcmOutcome,
    classify_fcm_response,
    fcm_error_code,
    fcm_outcome_name,
)
from .client import (
    FCM_PORT,
    JSON_CONTENT_TYPE,
    LOOPBACK_HOST,
    FcmClient,
    FcmEndpoint,
    URL_INVALID_KIND,
    fcm_application_default_token_source,
    fcm_application_default_token_source_from,
    send_failure_outcome,
    token_mint_error,
)
