# =============================================================================
# oci_push.mojo — upload a LOCAL OCI image layout into a registry. The
#   layout-to-registry half that `OciCopier` (registry-to-registry) lacks.
# =============================================================================
#
# WHERE IT SITS. The `oci_image` build rule writes an OCI image layout and
# pushes nothing. A release places that image in a registry with an EXPLICIT
# publish step, under a registry-write credential, and every later step refers
# to it as `repo@sha256:…`. This module is that placement: it reads the layout
# through `OciLayoutSource` and speaks the OCI distribution push protocol over
# the SAME one-method `OciTransport` seam, and the same bearer-token auth, as
# `OciCopier`.
#
# THE CONTRACT, IN ONE SENTENCE: `push` either makes the layout's image
# resolvable at the destination under the digest the BUILD computed, or it
# raises, and when it raises over a bad layout it has made no registry call.
#
# ─── THE ORDER, AND WHY ─────────────────────────────────────────────────────
#
#   phase 1  PLAN, OFFLINE. Read index.json, walk the manifest tree, and read
#            EVERY file the push will send, checking that it hashes to its name
#            and that its size is the one its descriptor states. Nothing has
#            touched the network yet, so a corrupt or hand-edited layout is
#            refused with the registry untouched.
#   phase 2  UPLOAD, LEAVES FIRST. For each image manifest: its layers, then
#            its config, then the manifest itself, PUT by DIGEST. An index is
#            PUT only after every manifest it names. A manifest is therefore
#            never written while a blob or child it references is missing,
#            and the root becomes resolvable last, after everything under it.
#   phase 3  TAG. When the destination ref is `:<tag>`, the root manifest is
#            PUT once more under the tag. The tag moves only after the content
#            it will point at is complete.
#
# Each blob is `HEAD`ed first and skipped when present (200), so a re-run, or
# a push of an image that shares its base layers with one already there,
# uploads only what is missing. A manifest PUT is idempotent by construction
# (the URL names the digest). Re-running a completed push is therefore safe
# and moves no layer bytes.
#
# ─── WHAT IS VERIFIED ───────────────────────────────────────────────────────
#
#   * every layout file hashes to its name, and is the size its descriptor
#     states — twice: in phase 1, and again as it is read for upload, so a
#     file changed between the two reads is still refused;
#   * a manifest's own `mediaType` agrees with its descriptor's;
#   * a destination ref pinned `@sha256:…` names the layout's root digest;
#   * the registry's `Docker-Content-Digest`, wherever it sends one (blob
#     PUT, manifest PUT, tag PUT), names the digest that was sent. A registry
#     that stored something else is refused, not believed.
#
# ─── AUTH ───────────────────────────────────────────────────────────────────
#
# One bearer token, as `OciCopier` takes it: the caller resolves a token with
# push scope on the destination repository. The `WWW-Authenticate` token
# exchange is out of scope here exactly as it is for the copier. A 401 or 403
# from any call stops the push at that call with a message that says it was
# the credential, and carries the registry's challenge.
#
# Blob uploads are MONOLITHIC (POST a session, PUT the bytes with
# `?digest=`), as the copier's are; chunked upload is a follow-on there and
# here.
#
# Encapsulation: the public API is `OciLayoutPusher[T]` + owned `String`
# values. No UnsafePointer crosses the module boundary; no wildcard origins;
# no unsafe_from_address.
# =============================================================================

from komira_http_client.redirect_policy import (
    carries_credential,
    resolve_redirect_location,
)
from komira_http_core.codec.types import (
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)
from komira_json import JsonValue, parse_json_value

from .oci_copy import _append_query, _body_hint
from .oci_digest import digest_of_bytes, validate_digest_format
from .oci_layout import layout_image_digest
from .oci_layout_source import OciLayoutSource
from .oci_ref import (
    MEDIA_TYPE_DOCKER_MANIFEST,
    MEDIA_TYPE_OCI_MANIFEST,
    OciImageRef,
    media_type_is_index,
    parse_oci_ref,
)
from .oci_transport import OciRequest, OciResponse, OciTransport


# How deep an index may nest. Content addressing makes a cycle impossible (a
# manifest cannot contain its own digest), so this bounds only a pathological
# layout; real images are one level (an image) or two (an index of images).
comptime _MAX_INDEX_DEPTH: Int = 8


# =============================================================================
# §1 — the plan's records.
# =============================================================================


struct _Descriptor(Copyable, Movable, Deinitable):
    """A content descriptor as read from a layout: digest, size, media type.

    `media_type` is empty when the descriptor does not state one. Owned
    `String` fields and an `Int64`. No pointer field."""

    var digest: String
    var media_type: String
    var size: Int64

    def __init__(out self, var digest: String, var media_type: String, size: Int64):
        self.digest = digest^
        self.media_type = media_type^
        self.size = size

    def __init__(out self, *, copy: Self):
        self.digest = copy.digest.copy()
        self.media_type = copy.media_type.copy()
        self.size = copy.size


struct _PlannedManifest(Copyable, Movable, Deinitable):
    """One manifest the push will PUT, with the blobs that must precede it.

    `raw` is sent VERBATIM: the digest covers these exact bytes, so they are
    never re-serialized. `blobs` is in upload order (layers, then config) and
    is empty for an index, whose children are planned as manifests of their
    own. Owned fields only. No pointer field."""

    var digest: String
    var media_type: String
    var raw: List[UInt8]
    var is_index: Bool
    var blobs: List[_Descriptor]

    def __init__(
        out self,
        var digest: String,
        var media_type: String,
        var raw: List[UInt8],
        is_index: Bool,
        var blobs: List[_Descriptor],
    ):
        self.digest = digest^
        self.media_type = media_type^
        self.raw = raw^
        self.is_index = is_index
        self.blobs = blobs^

    def __init__(out self, *, copy: Self):
        self.digest = copy.digest.copy()
        self.media_type = copy.media_type.copy()
        self.raw = copy.raw.copy()
        self.is_index = copy.is_index
        self.blobs = copy.blobs.copy()


# =============================================================================
# §2 — OciLayoutPusher.
# =============================================================================


struct OciLayoutPusher[T: OciTransport](Movable, Deinitable):
    """Uploads a local OCI image layout into a registry, leaves first.

    Parametric over the transport `T`, like `OciCopier`: the falsifiers drive
    this exact code over `ScriptedOciTransport`, and production drives it over
    `HttpOciTransport[C]`. There is no test-only branch in this file.

    The transport by value + one owned `String` token. No pointer field."""

    var _transport: Self.T
    var _token: String

    def __init__(out self, var transport: Self.T, var token: String):
        self._transport = transport^
        self._token = token^

    def transport(ref self) -> ref [self._transport] Self.T:
        """Borrow the transport, so a falsifier can assert over the exact
        registry conversation a push produced. Returns a borrow of the value
        the CALLER supplied; no internal type escapes."""
        return self._transport

    def push[L: OciLayoutSource](
        mut self, mut layout: L, dst_ref: String
    ) raises -> String:
        """Upload `layout` to `dst_ref` and return the root manifest digest,
        which is the digest the build computed.

        `dst_ref` is `<registry>/<repository>:<tag>` (the root is PUT by
        digest, then under the tag) or `<registry>/<repository>@sha256:…`
        (by digest only, and the digest must be the layout's root).

        RAISES, before any registry call, on a layout that is not exactly
        one image or whose files do not hash to their names or sizes; and,
        during the push, on any refused call or on a registry digest that
        disagrees with the one sent."""
        var dst = parse_oci_ref(dst_ref)

        # ---- phase 1: PLAN + VERIFY, offline --------------------------------
        var plan = _plan(layout)
        var root = plan[len(plan) - 1].digest.copy()
        if dst.is_digest and dst.reference != root:
            raise Error(
                String("oci: destination ref '")
                + dst_ref
                + String("' pins digest ")
                + dst.reference
                + String(" but the layout's image is ")
                + root
                + String(
                    ". A push cannot change a digest; refusing before any"
                    " registry call."
                )
            )

        # ---- phase 2: UPLOAD, leaves first ----------------------------------
        var sent = List[String]()
        for i in range(len(plan)):
            for j in range(len(plan[i].blobs)):
                if _contains(sent, plan[i].blobs[j].digest):
                    continue
                self._ensure_blob(dst, layout, plan[i].blobs[j])
                sent.append(plan[i].blobs[j].digest.copy())
            self._put_manifest(dst, plan[i], plan[i].digest)

        # ---- phase 3: TAG ---------------------------------------------------
        if not dst.is_digest:
            self._put_manifest(dst, plan[len(plan) - 1], dst.reference)
        return root^

    # -------------------------------------------------------------------------
    # Blobs.
    # -------------------------------------------------------------------------
    def _ensure_blob[L: OciLayoutSource](
        mut self, dst: OciImageRef, mut layout: L, blob: _Descriptor
    ) raises:
        """Make `blob` present in the destination repository: HEAD, and
        upload only on a 404."""
        var head = OciRequest(
            HTTP_METHOD_HEAD,
            dst.registry.copy(),
            String("/v2/") + dst.repository + String("/blobs/") + blob.digest,
        )
        head.with_bearer(self._token)
        var head_resp = self._transport.send(head)
        if head_resp.status == 200:
            return
        if _is_auth_refusal(head_resp.status):
            raise _auth_error(dst, String("HEAD blob ") + blob.digest, head_resp)
        if head_resp.status != 404:
            raise Error(
                String("oci: HEAD blob ")
                + blob.digest
                + String(" in ")
                + dst.repository
                + String(" returned HTTP ")
                + String(head_resp.status)
                + String(" (expected 200 present or 404 absent)")
                + _body_hint(head_resp)
            )

        # Open a monolithic upload session.
        var start = OciRequest(
            HTTP_METHOD_POST,
            dst.registry.copy(),
            String("/v2/") + dst.repository + String("/blobs/uploads/"),
        )
        start.with_bearer(self._token)
        var start_resp = self._transport.send(start)
        if _is_auth_refusal(start_resp.status):
            raise _auth_error(dst, String("POST blob upload"), start_resp)
        if start_resp.status != 202:
            raise Error(
                String("oci: opening a blob upload session in ")
                + dst.repository
                + String(" returned HTTP ")
                + String(start_resp.status)
                + String(" (expected 202)")
                + _body_hint(start_resp)
            )

        # The session URL is SERVER-CHOSEN: a path on the registry, or an
        # absolute https URL on another host. It is resolved by komira_http's
        # shared policy (which refuses plaintext), and the bearer goes only
        # where that policy says a credential minted for the registry may go.
        var location = start_resp.header(String("location"))
        var target = resolve_redirect_location(dst.registry, location)
        if not target.is_resolved():
            raise Error(
                String("oci: the upload session Location '")
                + location
                + String("' for blob ")
                + blob.digest
                + String(
                    " is missing, plaintext, or not resolvable against the"
                    " registry host. REFUSING to guess where to PUT the bytes."
                )
            )

        # Re-read and RE-VERIFY at upload time: phase 1 proved the file, but a
        # file that changed since is refused here rather than uploaded.
        var data = _read_verified(layout, blob, String("blob"))
        var put = OciRequest(
            HTTP_METHOD_PUT,
            target.host.copy(),
            _append_query(target.path, String("digest=") + blob.digest),
        )
        if carries_credential(dst.registry, target.host):
            put.with_bearer(self._token)
        put.with_header(
            String("content-type"), String("application/octet-stream")
        )
        put.with_body(data^)
        var put_resp = self._transport.send(put)
        if _is_auth_refusal(put_resp.status):
            raise _auth_error(dst, String("PUT blob ") + blob.digest, put_resp)
        if put_resp.status != 201:
            raise Error(
                String("oci: PUT blob ")
                + blob.digest
                + String(" to ")
                + dst.repository
                + String(" returned HTTP ")
                + String(put_resp.status)
                + String(" (expected 201 Created)")
                + _body_hint(put_resp)
            )
        _check_registry_digest(
            put_resp, blob.digest, String("blob ") + blob.digest
        )

    # -------------------------------------------------------------------------
    # Manifests.
    # -------------------------------------------------------------------------
    def _put_manifest(
        mut self, dst: OciImageRef, m: _PlannedManifest, reference: String
    ) raises:
        """PUT manifest `m`, verbatim, under `reference` (its digest, or a
        tag), and refuse a registry that reports another digest."""
        var req = OciRequest(
            HTTP_METHOD_PUT,
            dst.registry.copy(),
            String("/v2/") + dst.repository + String("/manifests/") + reference,
        )
        req.with_header(String("content-type"), m.media_type.copy())
        req.with_bearer(self._token)
        req.with_body(m.raw.copy())
        var resp = self._transport.send(req)
        var what = String("PUT manifest ") + m.digest
        if reference != m.digest:
            what = what + String(" as '") + reference + String("'")
        if _is_auth_refusal(resp.status):
            raise _auth_error(dst, what, resp)
        if resp.status != 201 and resp.status != 200:
            raise Error(
                String("oci: ")
                + what
                + String(" to ")
                + dst.registry
                + String("/")
                + dst.repository
                + String(" returned HTTP ")
                + String(resp.status)
                + _body_hint(resp)
            )
        _check_registry_digest(resp, m.digest, String("manifest ") + m.digest)


# =============================================================================
# §3 — phase 1: the offline plan.
# =============================================================================


def _plan[L: OciLayoutSource](mut layout: L) raises -> List[_PlannedManifest]:
    """Every manifest under the layout's single root, LEAVES FIRST (the root
    is last), with every file it will send already read and verified."""
    var index_bytes = layout.index_json()
    var index_text = String(unsafe_from_utf8=Span(index_bytes))
    # The same "exactly one image" rule `stage` applies to a layout.
    var root_digest = layout_image_digest(index_text)
    var index_doc = parse_json_value(index_text)
    var root = _descriptor_of(
        index_doc.get(String("manifests")).element_at(0),
        String("layout index.json manifests[0]"),
    )
    if root.digest != root_digest:
        raise Error(String("oci: layout index.json read inconsistently"))
    var visited = List[String]()
    var out = List[_PlannedManifest]()
    _visit(layout, root, visited, out, 0)
    return out^


def _visit[L: OciLayoutSource](
    mut layout: L,
    desc: _Descriptor,
    mut visited: List[String],
    mut out: List[_PlannedManifest],
    depth: Int,
) raises:
    """Post-order: every child of an index is appended before the index, so
    `out` is leaves first even when two indexes share a child."""
    if _contains(visited, desc.digest):
        return
    if depth > _MAX_INDEX_DEPTH:
        raise Error(
            String("oci: the layout nests indexes deeper than ")
            + String(_MAX_INDEX_DEPTH)
            + String(" levels at ")
            + desc.digest
        )
    visited.append(desc.digest.copy())

    var raw = _read_verified(layout, desc, String("manifest"))
    var doc = parse_json_value(String(unsafe_from_utf8=Span(raw)))
    var media = _manifest_media_type(doc, desc)

    if media_type_is_index(media):
        if not doc.has(String("manifests")):
            raise Error(
                String("oci: index ") + desc.digest + String(" has no 'manifests'")
            )
        var arr = doc.get(String("manifests"))
        if arr.array_len() == 0:
            raise Error(
                String("oci: index ")
                + desc.digest
                + String(" names ZERO manifests; there is nothing to push")
            )
        for i in range(arr.array_len()):
            var child = _descriptor_of(
                arr.element_at(i),
                String("index ") + desc.digest + String(" manifests[") + String(i) + String("]"),
            )
            _visit(layout, child, visited, out, depth + 1)
        out.append(
            _PlannedManifest(
                desc.digest.copy(), media^, raw^, True, List[_Descriptor]()
            )
        )
        return

    if not (
        media.startswith(MEDIA_TYPE_OCI_MANIFEST)
        or media.startswith(MEDIA_TYPE_DOCKER_MANIFEST)
    ):
        raise Error(
            String("oci: manifest ")
            + desc.digest
            + String(" has media type '")
            + media
            + String("', which is neither an image manifest nor an index")
        )

    # Upload order: the layers, in manifest order, then the config.
    var blobs = List[_Descriptor]()
    if doc.has(String("layers")):
        var layers = doc.get(String("layers"))
        for i in range(layers.array_len()):
            blobs.append(
                _descriptor_of(
                    layers.element_at(i),
                    String("manifest ") + desc.digest + String(" layers[") + String(i) + String("]"),
                )
            )
    if not doc.has(String("config")):
        raise Error(
            String("oci: image manifest ") + desc.digest + String(" has no 'config'")
        )
    blobs.append(
        _descriptor_of(
            doc.get(String("config")),
            String("manifest ") + desc.digest + String(" config"),
        )
    )
    # The offline half of the content check: every blob this manifest will
    # send hashes to its name now, before any registry call.
    for i in range(len(blobs)):
        _ = _read_verified(layout, blobs[i], String("blob"))
    out.append(_PlannedManifest(desc.digest.copy(), media^, raw^, False, blobs^))


def _descriptor_of(entry: JsonValue, where: String) raises -> _Descriptor:
    """A descriptor's `digest` (required, validated), `size` (required, a
    non-negative integer) and `mediaType` (optional)."""
    if not entry.has(String("digest")):
        raise Error(String("oci: ") + where + String(" has no 'digest'"))
    var digest = entry.get(String("digest")).as_string()
    validate_digest_format(digest, where)
    if not entry.has(String("size")):
        raise Error(String("oci: ") + where + String(" has no 'size'"))
    var size_v = entry.get(String("size"))
    if not size_v.is_integral_number():
        raise Error(String("oci: ") + where + String(" 'size' is not an integer"))
    var size = size_v.as_int64()
    if size < 0:
        raise Error(String("oci: ") + where + String(" 'size' is negative"))
    var media = String("")
    if entry.has(String("mediaType")):
        media = entry.get(String("mediaType")).as_string()
    return _Descriptor(digest^, media^, size)


def _manifest_media_type(doc: JsonValue, desc: _Descriptor) raises -> String:
    """The Content-Type a manifest is PUT under: its own `mediaType`, which
    must agree with its descriptor's when both are stated."""
    var own = String("")
    if doc.has(String("mediaType")):
        own = doc.get(String("mediaType")).as_string()
    if own.byte_length() > 0 and desc.media_type.byte_length() > 0:
        if own != desc.media_type:
            raise Error(
                String("oci: manifest ")
                + desc.digest
                + String(" says it is '")
                + own
                + String("' but its descriptor says '")
                + desc.media_type
                + String("'")
            )
    if own.byte_length() > 0:
        return own^
    if desc.media_type.byte_length() > 0:
        return desc.media_type.copy()
    raise Error(
        String("oci: manifest ")
        + desc.digest
        + String(
            " states no mediaType and neither does its descriptor; refusing to"
            " guess the Content-Type the registry validates it against"
        )
    )


def _read_verified[L: OciLayoutSource](
    mut layout: L, desc: _Descriptor, kind: String
) raises -> List[UInt8]:
    """The bytes stored under `desc.digest`, REFUSED unless they hash to that
    digest and are `desc.size` long."""
    var data = layout.read_blob(desc.digest)
    var actual = digest_of_bytes(Span(data))
    if actual != desc.digest:
        raise Error(
            String("oci: LAYOUT FILE DOES NOT HASH TO ITS NAME: the ")
            + kind
            + String(" stored as ")
            + desc.digest
            + String(" content-addresses to ")
            + actual
            + String(
                ". REFUSING the push: a layout whose files do not match their"
                " names is corrupt or was edited after the build, and its"
                " bytes must not be published under the build's digest."
            )
        )
    if Int64(len(data)) != desc.size:
        raise Error(
            String("oci: the ")
            + kind
            + String(" ")
            + desc.digest
            + String(" is ")
            + String(len(data))
            + String(" bytes but its descriptor states size ")
            + String(desc.size)
            + String(". REFUSING the push.")
        )
    return data^


# =============================================================================
# §4 — small helpers.
# =============================================================================


def _contains(names: List[String], name: String) -> Bool:
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def _is_auth_refusal(status: Int) -> Bool:
    return status == 401 or status == 403


def _auth_error(dst: OciImageRef, what: String, resp: OciResponse) -> Error:
    var challenge = resp.header(String("www-authenticate"))
    var msg = (
        String("oci: the registry ")
        + dst.registry
        + String(" refused the credential (HTTP ")
        + String(resp.status)
        + String(") for ")
        + what
        + String(" in ")
        + dst.repository
        + String(
            ". This client sends the bearer token it was given and does not"
            " perform the token exchange; supply a token with push scope on"
            " the repository."
        )
    )
    if challenge.byte_length() > 0:
        msg = msg + String(" Challenge: ") + challenge
    return Error(msg^)


def _check_registry_digest(
    resp: OciResponse, sent: String, what: String
) raises:
    """Refuse a `Docker-Content-Digest` that names other content than was
    sent. An absent header is accepted (the URL already named the digest)."""
    var confirmed = resp.header(String("docker-content-digest"))
    if confirmed.byte_length() == 0:
        return
    if confirmed != sent:
        raise Error(
            String("oci: the registry stored ")
            + what
            + String(" under a DIFFERENT digest ")
            + confirmed
            + String(
                " (Docker-Content-Digest). The content-address was not"
                " preserved. REFUSING."
            )
        )
