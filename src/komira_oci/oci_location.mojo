# =============================================================================
# oci_location.mojo — where an upload session's `Location` points, and whether
#   we may send to it.
# =============================================================================
#
# THE GAP THIS CLOSES. A blob upload is a session: the registry answers the
# opening POST with a `Location` and the client finishes with a PUT to it. The
# distribution spec lets that `Location` be a RELATIVE path (`/v2/…`) or an
# ABSOLUTE URL, and an absolute one may name a different host (an object store,
# say). The first version of this client used the value as a request PATH on the
# destination host. That is right only for the relative shape: an absolute URL
# used as a path is a malformed request, and — worse — a URL naming another host
# would have gone to the wrong place with the destination's credential attached.
#
# THE RULE, one function (`resolve_upload_location`), shared by every pusher:
#   * `/v2/…?…`                relative       -> the SAME host, as before.
#   * `https://same-host/…`    absolute       -> the same host; path + query are
#                                                taken from the URL.
#   * `https://other-host/…`   cross-host     -> REFUSED. A registry that uploads
#                                                elsewhere is a later, explicit
#                                                decision; and in no case is the
#                                                credential sent to a host other
#                                                than the one it was issued for.
#   * `http://…`, empty, no path, empty host, path-relative -> REFUSED, by the
#     shared komira_http policy (`resolve_redirect_location`), reworded here in
#     this client's vocabulary.
#
# Host comparison is exact bytes (the shared `carries_credential` rule): a
# case-variant of the same host is treated as another host and refused, which
# fails closed.
# =============================================================================

from komira_http_client.redirect_policy import (
    REDIRECT_REFUSED_EMPTY_HOST,
    REDIRECT_REFUSED_NO_LOCATION,
    REDIRECT_REFUSED_NO_PATH,
    REDIRECT_REFUSED_PLAINTEXT,
    RedirectTarget,
    carries_credential,
    resolve_redirect_location,
)


def resolve_upload_location(
    current_registry: String, location: String
) raises -> RedirectTarget:
    """Resolve an upload-session `Location` against the registry that issued it
    and return the (host, path+query) to PUT to — or RAISE naming why not.

    The returned host is ALWAYS `current_registry`: a cross-host `Location` is
    refused here, so a caller that sends to the returned target cannot carry a
    credential off the host it was issued for."""
    var target = resolve_redirect_location(current_registry, location)
    if target.is_resolved():
        if not carries_credential(current_registry, target.host):
            raise Error(
                String("oci: REFUSING an upload Location on another host '")
                + target.host
                + String("' (the session was opened on '")
                + current_registry
                + String(
                    "'). Uploading to a different host is not supported, and"
                    " the registry credential is never sent to a host other"
                    " than the one it was issued for."
                )
            )
        return target^
    if target.kind == REDIRECT_REFUSED_NO_LOCATION:
        raise Error(
            String(
                "oci: the registry accepted a blob upload session but returned"
                " no Location header — there is no URL to PUT the blob to (host "
            )
            + current_registry
            + String(")")
        )
    if target.kind == REDIRECT_REFUSED_PLAINTEXT:
        raise Error(
            String("oci: REFUSING an upload Location over PLAINTEXT http '")
            + location
            + String("' — registry traffic is HTTPS-only.")
        )
    if target.kind == REDIRECT_REFUSED_NO_PATH:
        raise Error(
            String("oci: the upload Location '")
            + location
            + String("' names a host but no path. REFUSING.")
        )
    if target.kind == REDIRECT_REFUSED_EMPTY_HOST:
        raise Error(
            String("oci: the upload Location '")
            + location
            + String("' has an EMPTY host. REFUSING.")
        )
    raise Error(
        String("oci: cannot resolve the upload Location '")
        + location
        + String(
            "' — it is neither an absolute https url nor an absolute path."
            " REFUSING to guess what it is relative to."
        )
    )


def append_query(location: String, param: String) -> String:
    """Append `param` to an upload-session URL, choosing `?` or `&` correctly.

    The session URL is SERVER-CHOSEN and opaque: some registries return a bare
    path, others one that already carries state in a query string. Guessing the
    separator wrong turns the finalizing `digest=` into part of a previous
    parameter's value, and the registry rejects the upload with a message that
    does not mention the real cause."""
    if location.find(String("?")) >= 0:
        return location + String("&") + param
    return location + String("?") + param
