# =============================================================================
# src/kci_publish/actions_env.mojo -- `ActionsOidcEnv`: the GitHub Actions
#   runner's two OIDC handshake variables, read once and passed in.
# =============================================================================
#
# A GitHub Actions job with `permissions: id-token: write` gets two
# variables: the URL to ask for an ID token, and a bearer token for that
# request. They are platform-set (the runner sets them; nothing else does), so
# they are read from the environment, never from a flag, and they are the only
# environment this package reads.
#
#   from_process()  reads both from this process's environment
#   absent()        neither is set: not under CI (tests, a laptop)
#   given(url, t)   both, as a test or another caller read them
#
# `is_absent` is true only when BOTH are unset or empty: that is "not a CI
# job", which a dry run records as NOT_UNDER_CI. One set without the other is a
# broken handshake, and `missing()` names the one that is unset; the flow
# reports it as a credential failure, never as "not under CI".
#
# The request token is a `SecretValue`: zeroized on drop, never copied.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.builtin.swap import swap
from std.os import getenv

from komira_secret_store import SecretValue

from kci_pkg_upload.github_oidc_credential import (
    ACTIONS_ID_TOKEN_REQUEST_TOKEN,
    ACTIONS_ID_TOKEN_REQUEST_URL,
)


struct ActionsOidcEnv(Movable):
    """The two handshake variables (file header).

    Layout: an owned String, a zeroizing `SecretValue` and two Bools. No
    pointer field."""

    var request_url: String
    var request_token: SecretValue
    var has_url: Bool
    var has_token: Bool

    def __init__(out self, var request_url: String, var request_token: SecretValue):
        self.has_url = request_url.byte_length() > 0
        self.has_token = not request_token.is_empty()
        self.request_url = request_url^
        self.request_token = request_token^

    @staticmethod
    def from_process() raises -> ActionsOidcEnv:
        var url = getenv(String(ACTIONS_ID_TOKEN_REQUEST_URL), String(""))
        var token = getenv(String(ACTIONS_ID_TOKEN_REQUEST_TOKEN), String(""))
        return ActionsOidcEnv(url^, SecretValue.from_string(token))

    @staticmethod
    def absent() raises -> ActionsOidcEnv:
        return ActionsOidcEnv(String(""), SecretValue(Span(List[UInt8]())))

    @staticmethod
    def given(var request_url: String, var request_token: SecretValue) -> ActionsOidcEnv:
        return ActionsOidcEnv(request_url^, request_token^)

    def is_absent(self) -> Bool:
        return not self.has_url and not self.has_token

    def take_request_token(mut self) raises -> SecretValue:
        """The request token, moved out (this value then holds an empty
        one and reads as having no token)."""
        var t = SecretValue(Span(List[UInt8]()))
        swap(self.request_token, t)
        self.has_token = False
        return t^

    def missing(self) -> String:
        """The variables that are unset or empty, comma-separated; "" when
        both are set."""
        var out = String("")
        if not self.has_url:
            out += String(ACTIONS_ID_TOKEN_REQUEST_URL)
        if not self.has_token:
            if out.byte_length() > 0:
                out += String(", ")
            out += String(ACTIONS_ID_TOKEN_REQUEST_TOKEN)
        return out^
