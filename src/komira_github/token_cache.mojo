# =============================================================================
# komira_github/token_cache.mojo -- installation access tokens, read from
#   GitHub's answer and kept until shortly before they expire.
# =============================================================================
#
# `POST /app/installations/{id}/access_tokens` answers 201 with
#   {"token":"ghs_...","expires_at":"2026-10-09T12:00:00Z", ...}
# A token lives one hour. The cache hands a token out only while more than
# `INSTALLATION_TOKEN_REFRESH_MARGIN_S` (300 s) of it remain: at
# `expires_at - 300` and after, it is stale and the client mints a new one.
# So a token handed out lasts at least five minutes, long enough for the
# request it is minted for (a page walk, a check-run update) to finish
# before GitHub stops accepting it, and a host clock a little behind
# GitHub's does not send expired tokens.
#
# Tokens are cached per installation AND per scope: the scope is the exact
# request body that minted the token ("" for the installation's whole grant,
# the one-repository body of request.mojo for a scoped one), so a narrow
# token is never handed out for a broad request or the reverse. A 401 on a
# token drops every token of its installation (`invalidate`).
#
# An answer whose `expires_at` is not after now (by the caller's clock) is
# refused rather than cached, and so is one without a non-empty `token`.
# =============================================================================

from komira_datetime import parse_rfc3339
from komira_json import JSON_STRING, parse_json_bytes

from .error import KIND_BAD_RESPONSE, github_error


comptime INSTALLATION_TOKEN_REFRESH_MARGIN_S: Int64 = 300
"""A cached token is replaced once this few seconds of it remain."""


struct InstallationToken(Copyable, Movable, Deinitable):
    """An installation access token, the installation it belongs to, the
    scope it was minted for (the request body; "" for the whole grant) and
    its expiry in Unix seconds."""

    var token: String
    var installation_id: Int64
    var scope: String
    var expires_at: Int64

    def __init__(
        out self, var token: String, installation_id: Int64, var scope: String, expires_at: Int64
    ):
        self.token = token^
        self.installation_id = installation_id
        self.scope = scope^
        self.expires_at = expires_at


def token_is_fresh(expires_at: Int64, now_unix_s: Int64) -> Bool:
    """True while more than the refresh margin of a token remains:
    `now < expires_at - 300`."""
    return now_unix_s < expires_at - INSTALLATION_TOKEN_REFRESH_MARGIN_S


def read_installation_token(
    body: List[UInt8], installation_id: Int64, var scope: String, now_unix_s: Int64
) raises -> InstallationToken:
    """The token in a 201 answer's body (module header for what is
    refused). No message quotes the body."""
    var token = String("")
    var expires_text = String("")
    try:
        var doc = parse_json_bytes(body)
        var t = doc.get(String("token"))
        var e = doc.get(String("expires_at"))
        if t.kind_tag() == JSON_STRING:
            token = t.as_string()
        if e.kind_tag() == JSON_STRING:
            expires_text = e.as_string()
    except:
        raise github_error(
            KIND_BAD_RESPONSE, "the access token answer is not an object with token and expires_at"
        )
    if token.byte_length() == 0:
        raise github_error(KIND_BAD_RESPONSE, "the access token answer has no token")
    var expires_at: Int64
    try:
        expires_at = Int64(parse_rfc3339(expires_text).seconds)
    except:
        raise github_error(KIND_BAD_RESPONSE, "the access token's expires_at is not an RFC 3339 time")
    if expires_at <= now_unix_s:
        raise github_error(KIND_BAD_RESPONSE, "the access token has already expired")
    return InstallationToken(token^, installation_id, scope^, expires_at)


struct InstallationTokenCache(Movable, Deinitable, Sized):
    """Fresh tokens by (installation, scope) (module header)."""

    var _entries: List[InstallationToken]

    def __init__(out self):
        self._entries = List[InstallationToken]()

    def get(self, installation_id: Int64, scope: String, now_unix_s: Int64) -> Optional[InstallationToken]:
        """The cached token for this installation and scope while it is
        fresh (`token_is_fresh`); None otherwise."""
        for i in range(len(self._entries)):
            ref e = self._entries[i]
            if e.installation_id == installation_id and e.scope == scope:
                if token_is_fresh(e.expires_at, now_unix_s):
                    return e.copy()
                return None
        return None

    def put(mut self, token: InstallationToken):
        """Keep `token`, replacing any of its installation and scope."""
        for i in range(len(self._entries)):
            if (
                self._entries[i].installation_id == token.installation_id
                and self._entries[i].scope == token.scope
            ):
                self._entries[i] = token.copy()
                return
        self._entries.append(token.copy())

    def invalidate(mut self, installation_id: Int64):
        """Drop every token of `installation_id`."""
        var kept = List[InstallationToken]()
        for i in range(len(self._entries)):
            if self._entries[i].installation_id != installation_id:
                kept.append(self._entries[i].copy())
        self._entries = kept^

    def __len__(self) -> Int:
        return len(self._entries)
