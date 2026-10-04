"""The hand-written owner of DeleteSecret's plain verb.

`secretsmanager_overrides.json` names `delete_secret` here, so the generated
client emits `delete_secret_raw` (and `delete_secret_raw_with`) and not
`delete_secret`; aws-client-gen refuses the manifest unless this file defines
it, and mojo_aws_client copies this file into the package next to the
generated module.

What is here is Secrets Manager behaviour no model states:

  * DeleteSecret is a soft delete unless forced. The secret is scheduled for
    deletion after a recovery window of 7 to 30 days (30 when unset), and its
    name stays taken until then: a CreateSecret under that name fails with
    InvalidRequestException, which `secret_name_is_scheduled_for_deletion`
    recognises. RestoreSecret cancels the deletion; a forced delete releases
    the name at once.
  * ForceDeleteWithoutRecovery and RecoveryWindowInDays are mutually
    exclusive; the service answers InvalidParameterException when both are
    sent.
  * The window's bounds are 7..30, which the model does not give.

`delete_secret` refuses the two argument errors before anything is sent,
naming the request members, and then calls the generated verb.
"""

from komira_aws_core import (
    AwsClock,
    AwsCredsSource,
    AwsHttpTransport,
    HttpResult,
)
from komira_http_core.transport.io_stream import Connector
from komira_retry import MonotonicClock, RetryBudget, RetryLoop, RetryRng, Sleeper

from .komira_aws_secretsmanager import (
    SecretsManagerDeleteSecretRequest,
    SecretsManagerDeleteSecretResponse,
    SecretsManagerSecretsManagerClient,
)

comptime SECRETSMANAGER_MIN_RECOVERY_DAYS: Int64 = 7
comptime SECRETSMANAGER_MAX_RECOVERY_DAYS: Int64 = 30


def check_delete_secret_request(input: SecretsManagerDeleteSecretRequest) raises:
    """Refuse the DeleteSecret arguments Secrets Manager rejects: a recovery
    window together with a forced delete, and a window outside 7..30."""
    if not input.recovery_window_in_days:
        return
    var days = input.recovery_window_in_days.value()
    var forced = False
    if input.force_delete_without_recovery:
        forced = input.force_delete_without_recovery.value()
    if forced:
        raise Error(
            "DeleteSecret: ForceDeleteWithoutRecovery and RecoveryWindowInDays"
            " are mutually exclusive: a forced delete releases the name now,"
            " a recovery window holds it for that many days. Set one."
        )
    if days < SECRETSMANAGER_MIN_RECOVERY_DAYS or days > SECRETSMANAGER_MAX_RECOVERY_DAYS:
        raise Error(
            String("DeleteSecret: RecoveryWindowInDays is ")
            + String(days)
            + ", and Secrets Manager accepts 7..30."
        )


def delete_secret[C: Connector, T: AwsCredsSource](
    mut client: SecretsManagerSecretsManagerClient[C, T],
    input: SecretsManagerDeleteSecretRequest,
) raises -> SecretsManagerDeleteSecretResponse:
    """`DeleteSecret`: the arguments checked, then the generated verb."""
    check_delete_secret_request(input)
    return client.delete_secret_raw(input)


def delete_secret_with[
    C: Connector,
    T: AwsCredsSource,
    X: AwsHttpTransport,
    K: AwsClock,
    L: MonotonicClock,
    S: Sleeper,
    R: RetryRng,
    B: RetryBudget,
](
    mut client: SecretsManagerSecretsManagerClient[C, T],
    input: SecretsManagerDeleteSecretRequest,
    mut transport: X,
    mut clock: K,
    mut retry: RetryLoop[L, S, R],
    mut budget: B,
) raises -> HttpResult:
    """`delete_secret` over the given seams: the arguments checked, then the
    generated `delete_secret_raw_with`, whose response is returned."""
    check_delete_secret_request(input)
    return client.delete_secret_raw_with(input, transport, clock, retry, budget)


def secret_name_is_scheduled_for_deletion(error_text: String) -> Bool:
    """True when a failed CreateSecret's error is the name still held by a
    secret scheduled for deletion, rather than a plain name collision: an
    InvalidRequestException saying the secret is scheduled for deletion.
    RestoreSecret brings that secret back, versions and all."""
    return (
        error_text.find("InvalidRequestException") >= 0
        and error_text.find("scheduled for deletion") >= 0
    )
