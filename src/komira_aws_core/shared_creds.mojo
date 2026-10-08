# =============================================================================
# komira_aws_core/shared_creds.mojo -- one refreshing credential source, shared
# =============================================================================
#
# THE PROBLEM. `DefaultChainCredsSource` refreshes a temporary credential (an
# instance or container role, STS, web identity) before it expires, but it owns
# its caches and is not Copyable. A client that must be cloned (S3Store,
# S3ConditionalStore and S3Fs clone their credential source with every
# clone, and each clone is used on its own thread) could
# therefore only hold a `StaticCredsSource`, a credential fetched once that went
# stale after its expiry.
#
# THE SHAPE. `SharedCredsSource[S]` holds ONE `S` (usually the default chain)
# behind an `ArcPointer`, with a `SpinMutex`. A clone is a reference-count
# bump: every clone reads and refreshes the same cache, so the chain is
# resolved once per refresh no matter how many clones or threads sign.
#
# THE REFRESH POLICY IS `S`'S, NOT THIS TYPE'S. `DefaultChainCredsSource`
# applies botocore's RefreshableCredentials windows (creds_source.mojo): with
# fewer than 15 minutes left it tries to refresh on every send and keeps
# serving the cached credential if the attempt fails, with fewer than 10
# minutes left a failed refresh raises, and a credential with no expiry (keys
# from the environment or a file, or stated by the caller) is never refreshed.
# Those margins are botocore's advisory and mandatory refresh timeouts; 10
# minutes is long enough for a send and its retries to finish inside the
# credential's life, and 15 spreads the early attempts over several sends
# before the hard edge. This type adds only what sharing needs:
#
#   * SINGLE FLIGHT. `credentials()` holds the lock around the whole call into
#     `S`, so when several threads find the credential inside its window,
#     one of them refreshes and the others wait, then read what it stored:
#     the provider is called once, not once per thread.
#   * AN ERROR THAT NAMES THE FAILURE. When `S` cannot produce a credential
#     (the cache holds none that is still safe, and the refresh failed), the
#     error says so in this type's words, followed by `S`'s own message, which
#     the AwsCredsSource contract says names a setting and never a secret.
#
# NOTHING HERE CAN PRINT A CREDENTIAL. The type is not Writable or Stringable,
# its state is private, and no message is built from a credential's fields.
#
# WHAT IT COSTS. Every `credentials()` takes the lock, briefly when the cache
# is fresh. A refresh holds it for the duration of the provider's network
# calls, and the waiters sleep in short steps (komira_sync).
# =============================================================================

from std.memory import ArcPointer

from komira_sync import SpinMutex

from .credential import AwsCredential
from .creds_source import AwsCredsSource


comptime SHARED_CREDS_REFRESH_FAILED = (
    "AWS credentials are missing, expired or about to expire, and refreshing"
    " them failed: "
)


struct _SharedState[S: AwsCredsSource & Movable & Deinitable](
    Movable, Deinitable
):
    """What every clone of a `SharedCredsSource` reaches: the lock and the
    source it guards."""

    var mutex: SpinMutex
    var source: Self.S

    def __init__(out self, var source: Self.S):
        self.mutex = SpinMutex()
        self.source = source^


struct SharedCredsSource[S: AwsCredsSource & Movable & Deinitable](
    AwsCredsSource, Copyable, Movable, Deinitable
):
    """A credential source whose clones share one `S` and its caches."""

    var _state: ArcPointer[_SharedState[Self.S]]

    def __init__(out self, var source: Self.S):
        self._state = ArcPointer[_SharedState[Self.S]](
            _SharedState[Self.S](source^)
        )

    def credentials(mut self) raises -> AwsCredential:
        """The credential to sign with now: `S`'s answer, computed under the
        lock shared by every clone. Raises the named refresh failure when `S`
        has no credential it can hand out."""
        # `ref` through the Arc: the state is shared, and the lock is what
        # makes the mutation of `source` exclusive.
        ref state = self._state[]
        state.mutex.lock()
        try:
            var cred = state.source.credentials()
            state.mutex.unlock()
            return cred^
        except e:
            state.mutex.unlock()
            raise Error(String(SHARED_CREDS_REFRESH_FAILED) + String(e))
