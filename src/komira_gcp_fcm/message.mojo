# =============================================================================
# komira_gcp_fcm/message.mojo -- the FCM HTTP v1 `messages:send` request:
#   the content-blind wake, the request body, the path and the OAuth scope.
# =============================================================================
#
# A wake carries exactly three strings, `id`, `kind` and `source`, and
# nothing else (`FcmWake`). The device that receives it fetches the content
# from `source` over its own authenticated channel; the push service never
# sees it. The body is
#
#   {"message":{"token":"<registration token>",
#               "data":{"id":"<id>","kind":"<kind>","source":"<source>"},
#               "android":{"priority":"HIGH"}}}
#
# with no `notification` block, so the message is data-only (the app's own
# code runs on receipt and decides what to show), and `android.priority`
# HIGH, so it is delivered at once to a device in Doze. The field names and
# the enum spelling are FCM's v1 REST reference (`Message`, `AndroidConfig`,
# `AndroidMessagePriority`). Every value is a JSON string escaped by
# komira_json, so a `"` or `\` in a token or a wake field cannot leave its
# string.
#
# `FCM_SCOPE` is the OAuth scope FCM v1 accepts for `messages:send`;
# `fcm_adc_options()` asks Application Default Credentials for a token with
# exactly that scope.
# =============================================================================

from komira_gcp_core import AdcOptions
from komira_json import JsonValue


comptime FCM_HOST: String = "fcm.googleapis.com"
"""The FCM HTTP v1 host."""
comptime FCM_SCOPE: String = "https://www.googleapis.com/auth/firebase.messaging"
"""The OAuth 2.0 scope of FCM HTTP v1 `messages:send`."""
comptime FCM_ANDROID_PRIORITY: String = "HIGH"
"""`AndroidMessagePriority` of every wake."""


@fieldwise_init
struct FcmWake(Copyable, Movable, Deinitable):
    """What a woken device is told: which item (`id`), what kind of event
    (`kind`) and which service holds it (`source`). These three are the
    message's whole `data` map; there is no field for content."""

    var id: String
    var kind: String
    var source: String


def _require(what: String, value: String) raises:
    if value.byte_length() == 0:
        raise Error("komira_gcp_fcm: the " + what + " is empty")


def check_project_id(project_id: String) raises:
    """A project id: non-empty, only `[a-z0-9.:-]` (a project id, or a
    legacy domain-scoped `example.com:project`), and starting with
    `[a-z0-9]`. It is spliced into the request path, so a `/`, `?` or `#`
    would send the request elsewhere. A server that normalises dot
    segments (RFC 3986 section 6.2.2.3) would remove a `..` segment together
    with `projects`, sending the request to `/v1/messages:send`, and a `.`
    segment, sending it to `/v1/projects/messages:send`."""
    var b = project_id.as_bytes()
    if len(b) == 0:
        raise Error("komira_gcp_fcm: the project id is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("."))
            or c == UInt8(ord(":"))
            or c == UInt8(ord("-"))
        )
        if not ok:
            raise Error(
                "komira_gcp_fcm: the project id holds a byte outside"
                " [a-z0-9.:-]"
            )
    var first = b[0]
    if not (
        (first >= UInt8(ord("a")) and first <= UInt8(ord("z")))
        or (first >= UInt8(ord("0")) and first <= UInt8(ord("9")))
    ):
        raise Error(
            "komira_gcp_fcm: the project id does not start with [a-z0-9]"
        )


def fcm_send_path(project_id: String) raises -> String:
    """`/v1/projects/<project_id>/messages:send`."""
    check_project_id(project_id)
    return String("/v1/projects/") + project_id + String("/messages:send")


def fcm_message_json(device_token: String, wake: FcmWake) raises -> String:
    """The `messages:send` body for one registration token (module header).
    Refused when the token or any wake field is empty: FCM would answer an
    empty token with INVALID_ARGUMENT, and an empty wake field reaches the
    device as a wake it cannot act on."""
    _require(String("device token"), device_token)
    _require(String("wake id"), wake.id)
    _require(String("wake kind"), wake.kind)
    _require(String("wake source"), wake.source)
    var data = JsonValue.empty_object()
    data.set_member(String("id"), JsonValue.from_string(wake.id.copy()))
    data.set_member(String("kind"), JsonValue.from_string(wake.kind.copy()))
    data.set_member(String("source"), JsonValue.from_string(wake.source.copy()))
    var android = JsonValue.empty_object()
    android.set_member(
        String("priority"), JsonValue.from_string(String(FCM_ANDROID_PRIORITY))
    )
    var message = JsonValue.empty_object()
    message.set_member(
        String("token"), JsonValue.from_string(device_token.copy())
    )
    message.set_member(String("data"), data^)
    message.set_member(String("android"), android^)
    var body = JsonValue.empty_object()
    body.set_member(String("message"), message^)
    return body.serialize()


def fcm_adc_options() -> AdcOptions:
    """Application Default Credentials options asking for `FCM_SCOPE` and
    nothing else."""
    var scopes = List[String]()
    scopes.append(String(FCM_SCOPE))
    return AdcOptions(scopes^)
