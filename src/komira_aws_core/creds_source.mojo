# =============================================================================
# komira_aws_core/creds_source.mojo -- what a generated client signs with
# =============================================================================
#
# A generated AWS client is parametric over `T: AwsCredsSource` and calls
# `credentials()` once per send. Two sources:
#
# - `StaticCredsSource`: one credential, stated by the caller.
# - `DefaultChainCredsSource`: the AWS SDK default credential provider chain
#   (credential_chain.mojo) behind a cache. A long-term credential is resolved
#   once. A temporary one (STS, container, instance metadata) is refreshed
#   on the two windows botocore's RefreshableCredentials uses
#   (_DEFAULT_ADVISORY_REFRESH_TIMEOUT = 15 min,
#   _DEFAULT_MANDATORY_REFRESH_TIMEOUT = 10 min); see `credentials()`.
#
# The chain's own seams (environment, files, the credential transport, the
# clock) are moved into the source, so the source is the one owner of them.
# =============================================================================

from .aws_codec import aws_token_string, aws_ts_from_token
from .credential import AwsCredential
from .credential_chain import (
    AwsCredentialParams,
    ResolvedAwsCredential,
    resolve_aws_credentials,
)
from .credential_transport import CredentialTransport
from .sources import AwsClock, EnvSource, FileSource


# With FEWER than this many seconds left before expiry (strictly less, as
# botocore's refresh_needed) a refresh is ATTEMPTED on every send, and a
# failure keeps the cached credential. Exactly this many left: cached.
comptime AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS = 15 * 60
# With FEWER than this many seconds left (strictly less) a refresh MUST
# succeed: a failure raises, so no request is signed with a credential that
# could expire in flight (AWS answers ExpiredToken) or before a retry.
comptime AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS = 10 * 60


trait AwsCredsSource(Movable, Deinitable):
    """A source of the credential to sign the next request with."""

    def credentials(mut self) raises -> AwsCredential:
        """The credential to sign with now. Raises when none can be
        found; the message names the setting, never a secret."""
        ...


struct StaticCredsSource(AwsCredsSource, Copyable, Movable, Deinitable):
    """One credential, stated by the caller. It never expires here."""

    var credential: AwsCredential

    def __init__(out self, credential: AwsCredential):
        self.credential = credential

    def credentials(mut self) raises -> AwsCredential:
        return self.credential


def expiration_unix_seconds(expiration: String) raises -> Int:
    """A chain expiration ("" or ISO 8601) as Unix seconds, -1 for none."""
    if expiration.byte_length() == 0:
        return -1
    try:
        return Int(aws_ts_from_token(aws_token_string(expiration)))
    except:
        raise Error("a credential expiration is not an ISO 8601 time")


struct DefaultChainCredsSource[
    E: EnvSource & Movable & Deinitable,
    F: FileSource & Movable & Deinitable,
    X: CredentialTransport & Movable & Deinitable,
    K: AwsClock & Movable & Deinitable,
](AwsCredsSource, Movable, Deinitable):
    """The AWS SDK default credential chain, cached until it is about to
    expire."""

    var params: AwsCredentialParams
    var env: Self.E
    var files: Self.F
    var transport: Self.X
    var clock: Self.K
    var _cached: Optional[ResolvedAwsCredential]
    var _expires_at: Int
    var resolutions: Int

    def __init__(
        out self,
        params: AwsCredentialParams,
        var env: Self.E,
        var files: Self.F,
        var transport: Self.X,
        var clock: Self.K,
    ):
        self.params = params.copy()
        self.env = env^
        self.files = files^
        self.transport = transport^
        self.clock = clock^
        self._cached = None
        self._expires_at = -1
        self.resolutions = 0

    def credentials(mut self) raises -> AwsCredential:
        var now = self.clock.now_unix_seconds()
        if self._cached:
            if (
                self._expires_at < 0
                or now + AWS_CREDENTIAL_ADVISORY_REFRESH_SECONDS
                <= self._expires_at
            ):
                return self._cached.value().credential
        # Refresh policy: botocore RefreshableCredentials, comparison for
        # comparison. A window applies only when the time left is STRICTLY
        # LESS than its length (refresh_needed: `if seconds_remaining >=
        # refresh_in: return False`), so the checks above and below are
        # `now + WINDOW <= expires_at` for "outside the window".
        # - advisory (fewer than ADVISORY seconds left, at least MANDATORY):
        #   a failed refresh (an IMDS / STS / container blip) keeps signing
        #   with the cached credential and leaves the cache and
        #   `resolutions` as they were; the next send tries again.
        # - mandatory (fewer than MANDATORY seconds left, or expired, or
        #   nothing cached): a failed refresh raises, as botocore's
        #   `if is_mandatory: raise`, so a credential that could expire while
        #   a send and its retries are in flight is never handed out.
        # Differences from botocore that remain, all deliberate:
        # 1. An answer that has ALREADY expired is a failed refresh here, so
        #    in the advisory window the still-valid cached credential is
        #    kept. botocore instead stores that answer and raises
        #    RuntimeError ("refreshed credentials are still expired");
        #    failing a send that holds a credential with ten minutes or more
        #    left buys nothing. In the mandatory window both raise.
        # 2. "Already expired" is `expires_at <= now`; botocore's _is_expired
        #    is refresh_needed(0), i.e. strictly past expiry, so an answer
        #    expiring in exactly 0 s is accepted there and refused here.
        # 3. Time is whole seconds (AwsClock); botocore compares fractional
        #    seconds. The boundaries above are exact at that granularity.
        var r: ResolvedAwsCredential
        var exp: Int
        try:
            r = resolve_aws_credentials(
                self.params, self.env, self.files, self.transport, self.clock
            )
            exp = expiration_unix_seconds(r.expiration)
            if exp >= 0 and exp <= now:
                raise Error(
                    "the AWS credential from the "
                    + r.source
                    + " provider has already expired"
                )
        except e:
            if (
                self._cached
                and now + AWS_CREDENTIAL_MANDATORY_REFRESH_SECONDS
                <= self._expires_at
            ):
                return self._cached.value().credential
            raise e^
        self.resolutions += 1
        var cred = r.credential
        self._cached = r^
        self._expires_at = exp
        return cred
