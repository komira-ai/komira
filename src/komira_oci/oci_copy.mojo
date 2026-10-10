# =============================================================================
# oci_copy.mojo — the registry-to-registry, DIGEST-PRESERVING copy. A native
#   equivalent of `crane copy`.
# =============================================================================
#
# WHAT A `stage` PROMOTE ACTUALLY IS. An image is built once, into the build
# project's registry, and must appear — BYTE-IDENTICAL, under the SAME digest —
# in each target environment's registry. Not rebuilt, not re-tagged: copied,
# with its content-address intact, because the recorded deployable ref IS that
# digest. If the digest changes, every provenance claim attached to the build
# (what was tested, what was signed, what was reviewed) stops referring to what
# is deployed.
#
# So this module's contract is one sentence: `copy_by_digest` either produces the
# same digest in the destination, or it RAISES. There is no third outcome, and
# in particular there is no "copied, digest unknown".
#
# ─── THE THREE THINGS THAT ARE EASY TO GET WRONG ────────────────────────────
#
# (1) RE-SERIALIZING THE MANIFEST. A manifest's digest covers its exact bytes.
#     Parsing it to JSON and writing it back out yields equivalent JSON with a
#     different digest. This copier parses manifests ONLY to discover which
#     descriptors to follow, and PUTs `raw` — the original bytes — verbatim.
#
# (2) ASSUMING ONE MANIFEST. A multi-arch image is an INDEX whose `manifests[]`
#     entries are themselves manifests. Copying only the index moves a pointer
#     to blobs that do not exist in the destination; the image pulls on no
#     architecture. `_discover` walks the whole tree.
#
# (3) PUSHING THE PARENT FIRST. A registry rejects (or, worse, accepts and later
#     serves broken) an index whose children are absent. Manifests are therefore
#     PUT in REVERSE discovery order — leaves first, root last. The root landing
#     last is also what makes the copy atomic from a puller's point of view: the
#     digest a deploy will pull becomes resolvable only once everything under it
#     already is.
#
# ─── WHY THE BLOB GET FOLLOWS REDIRECTS ─────────────────────────────────────
# A registry does not serve layer bytes from the registry API host. It answers
# `GET /v2/<repo>/blobs/<digest>` with a 3xx to wherever the bytes actually
# live, and the client is expected to follow. Artifact Registry, for example,
# answers:
#
#     HTTP/2 302
#     location: /artifacts-downloads/namespaces/<project>/repositories/
#               <repo>/downloads/<single-use-token>
#
# — a RELATIVE path on the SAME host, carrying a single-use token (a second GET
# of the same blob yields a different one), exactly one hop, and the second hop
# answers 200 with bytes that hash to the descriptor. It is NOT the signed
# cross-host CDN URL the folklore predicts, which is why the rule below is
# written in terms of "the host the token was minted for" rather than in terms
# of any one registry's layout.
#
# ★ THE PATH THAT IS EASY NEVER TO EXERCISE. The GET is the THIRD thing
# `_ensure_blob` tries, reached only when (a) the destination HEAD misses AND
# (b) the cross-repo mount misses. While a destination repository already
# exists, (a) or (b) answers and the GET never runs; the first copy into a NEW
# destination repository is what reaches it. That is why the falsifier drives
# the whole mount-declined path rather than a redirect helper in isolation.
#
# THE BEARER IS SCOPED TO THE HOST IT WAS MINTED FOR. `_follow_redirects`
# re-attaches the source token only when a hop's host equals the ORIGINAL
# request's host — not merely the PREVIOUS hop's, which would let A -> B -> B
# walk the token onto B. A registry token handed to a third-party storage host
# is a credential leak, and several object stores reject a request carrying
# both a bearer and their own query-string signature with a 400 naming neither
# cause. Refusing a plaintext `http://` downgrade is the same argument: this
# transport is HTTPS-only by construction (`OCI_REGISTRY_PORT`).
#
# The chain is bounded — but the property that actually makes following a
# registry's pointer safe is not the redirect rules, it is that the bytes are
# CONTENT-ADDRESS-VERIFIED after the follow. A redirect landing anywhere other
# than at the real blob cannot produce bytes that hash to the digest, and
# `verify_digest` runs before those bytes are written anywhere.
#
# ─── WHY THE BLOB MOUNT IS TRIED FIRST ──────────────────────────────────────
# `POST /v2/<dst>/blobs/uploads/?mount=<digest>&from=<src>` asks the registry to
# link an existing blob into another repository WITHOUT transferring it. For a
# build-project -> release-project promote this is the common case and it is the
# difference between moving zero bytes and moving hundreds of megabytes: both
# projects live on the SAME Artifact Registry host, and a mount is only possible
# within one registry. When the hosts differ the mount is not attempted at all
# (it cannot succeed), and when the registry DECLINES the mount it answers 202
# with an upload session instead of 201 — which this code treats as the ordinary
# fallback path, not as an error.
#
# Encapsulation: owned Strings / Lists across every boundary; no UnsafePointer,
# no wildcard origin.
# =============================================================================

from komira_json import parse_json_value, JsonValue
from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)
# THE REDIRECT POLICY IS komira_http's, AND THE LOOP IS OURS. What a redirect
# is, how a `Location` resolves, how many hops are allowed and which host the
# bearer may reach are shared with every other scriptable client
# (`redirect_policy.mojo`); `_follow_redirects` below stays here, above our own
# transport seam, for the reason its comment gives.
from komira_http_client.redirect_policy import (
    MAX_REDIRECT_HOPS,
    REDIRECT_REFUSED_EMPTY_HOST,
    REDIRECT_REFUSED_NO_LOCATION,
    REDIRECT_REFUSED_NO_PATH,
    REDIRECT_REFUSED_PLAINTEXT,
    RedirectTarget,
    carries_credential,
    is_authorization_header,
    is_redirect_status,
    resolve_redirect_location,
)

from .oci_digest import digest_of_bytes, verify_digest
from .oci_ref import (
    MEDIA_TYPE_OCI_INDEX,
    MEDIA_TYPE_OCI_MANIFEST,
    OciImageRef,
    manifest_accept_header,
    media_type_is_index,
    parse_oci_ref,
)
from .oci_location import append_query, resolve_upload_location
from .oci_transport import OciRequest, OciResponse, OciTransport


# =============================================================================
# §1 — the discovered-manifest record.
# =============================================================================


struct _DiscoveredManifest(Copyable, Movable, Deinitable):
    """One manifest found while walking the source image, with its ORIGINAL
    bytes and the media type the source served it under.

    `raw` is the authoritative artifact — see (1) above. `media_type` is carried
    because the destination PUT must declare the SAME type the source did."""

    var digest: String
    var media_type: String
    var raw: List[UInt8]
    var is_index: Bool

    def __init__(
        out self,
        var digest: String,
        var media_type: String,
        var raw: List[UInt8],
        is_index: Bool,
    ):
        self.digest = digest^
        self.media_type = media_type^
        self.raw = raw^
        self.is_index = is_index

    def copy(self) -> Self:
        return _DiscoveredManifest(
            self.digest.copy(),
            self.media_type.copy(),
            self.raw.copy(),
            self.is_index,
        )


# =============================================================================
# §2 — OciCopier.
# =============================================================================


struct OciCopier[T: OciTransport](Movable, Deinitable):
    """A digest-preserving registry-to-registry image copier.

    Parametric over the transport `T` so the falsifiers drive the SAME code the
    production path drives, over `ScriptedOciTransport` instead of the network —
    there is no test-only branch anywhere in this file.

    The two bearer tokens are separate because a cross-project promote reads
    from one GCP project and writes to another; they are frequently the same
    credential, but the API must not assume it.

    Owned `String` fields + the transport by value. No pointer field."""

    var _transport: Self.T
    var _src_token: String
    var _dst_token: String

    def __init__(
        out self, var transport: Self.T, var src_token: String, var dst_token: String
    ):
        self._transport = transport^
        self._src_token = src_token^
        self._dst_token = dst_token^

    def transport(ref self) -> ref [self._transport] Self.T:
        """Borrow the transport.

        This exists so a falsifier can assert over the exact registry
        conversation the copy produced — which host, which verb, which path.
        It returns a borrow of the value the CALLER supplied, so it leaks no
        internal type; it is the `&self.inner` accessor, not an escape hatch."""
        return self._transport

    # -------------------------------------------------------------------------
    # The public entry point — deliberately the SAME signature as the release
    # tool's `ImageStager.copy_by_digest` seam, so the conformer that wires this
    # into `stage` is a pass-through with no argument reshaping.
    # -------------------------------------------------------------------------
    def copy_by_digest(
        mut self, src_ref: String, dst_ref: String
    ) raises -> String:
        """Copy the image at `src_ref` to `dst_ref`, PRESERVING the digest.

        Returns the digest that is now resolvable at the destination. RAISES if
        the source is not by-digest, if any fetched bytes fail their
        content-address check, or if the destination reports a digest other than
        the source's."""
        var src = parse_oci_ref(src_ref)
        var dst = parse_oci_ref(dst_ref)

        if not src.is_digest:
            raise Error(
                String("oci: refusing to stage from a by-TAG source '")
                + src_ref
                + String(
                    "' — a stage promote is a CONTENT-ADDRESSED copy, and a tag"
                    " can be repointed between the resolve and the copy. Pass a"
                    " '@sha256:…' source."
                )
            )
        if dst.is_digest and dst.reference != src.reference:
            raise Error(
                String("oci: destination ref '")
                + dst_ref
                + String("' pins digest ")
                + dst.reference
                + String(" but the source is ")
                + src.reference
                + String(
                    " — a digest-preserving copy cannot change the digest. Fix"
                    " the caller; do not relax this check."
                )
            )

        # ---- phase 1: DISCOVER the manifest tree, root first ----------------
        var found = self._discover(src)

        # ---- phase 2: copy every BLOB each image manifest references --------
        for i in range(len(found)):
            if found[i].is_index:
                continue
            self._copy_blobs_of(src, dst, found[i].raw)

        # ---- phase 3: PUT the manifests, LEAVES FIRST (see (3) above) -------
        var confirmed = String("")
        for i in range(len(found) - 1, -1, -1):
            confirmed = self._put_manifest(dst, found[i])

        # `found[0]` is the root, and phase 3 walks backwards, so the LAST PUT is
        # the root — `confirmed` therefore holds the root's confirmed digest.
        if confirmed != src.reference:
            raise Error(  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                String("oci: stage copy of ")  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + src_ref  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + String(" -> ")  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + dst_ref  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + String(" did NOT preserve the digest: source ")  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + src.reference  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + String(", destination confirmed ")  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + confirmed  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                + String(  # cov: unreachable _put_manifest returns the root digest it PUT or raises
                    ". REFUSING to report success — the recorded deployable ref"
                    " would point at different content than was built."
                )
            )
        return confirmed^

    # -------------------------------------------------------------------------
    # Phase 1 — DISCOVER.
    # -------------------------------------------------------------------------
    def _discover(mut self, src: OciImageRef) raises -> List[_DiscoveredManifest]:
        """Breadth-first walk of the manifest tree from `src.reference`.

        Returned ROOT FIRST: phase 3 reverses it to push leaves first. A visited
        set makes the walk terminate on a malformed self-referential index and
        de-duplicates the (legitimate, common) case of two platforms sharing a
        child."""
        var out = List[_DiscoveredManifest]()
        var queue = List[String]()
        queue.append(src.reference.copy())
        var head = 0

        while head < len(queue):
            var digest = String(queue[head])
            head += 1
            if _contains(out, digest):
                continue

            var resp = self._get_manifest(src, digest)
            if resp.status != 200:
                raise Error(
                    String("oci: GET manifest ")
                    + digest
                    + String(" from ")
                    + src.registry
                    + String("/")
                    + src.repository
                    + String(" returned HTTP ")
                    + String(resp.status)
                    + String(_body_hint(resp))
                )

            # ⚠ THE CONTENT-ADDRESS CHECK, ON THE BYTES WE ACTUALLY RECEIVED.
            # Not on what `Docker-Content-Digest` claims — that header is the
            # registry's assertion about its own storage, and believing it is
            # precisely the weaker provenance claim `crane digest` makes.
            verify_digest(
                Span(resp.body),
                digest,
                String("manifest ") + digest,
            )

            var media_type = resp.header(String("content-type"))
            if media_type.byte_length() == 0:
                # A registry that omits Content-Type leaves only the body to
                # say what it is, and the destination PUT must declare a type.
                # An index misdeclared as a manifest would drop every child.
                media_type = _media_type_from_body(resp.body)
            var is_index = media_type_is_index(media_type)

            if is_index:
                var children = _index_child_digests(resp.body)
                for ci in range(len(children)):
                    queue.append(String(children[ci]))

            out.append(
                _DiscoveredManifest(
                    digest.copy(), media_type^, resp.body.copy(), is_index
                )
            )

        return out^

    def _get_manifest(
        mut self, src: OciImageRef, digest: String
    ) raises -> OciResponse:
        var req = OciRequest(
            HTTP_METHOD_GET,
            src.registry.copy(),
            String("/v2/") + src.repository + String("/manifests/") + digest,
        )
        req.with_header(String("accept"), manifest_accept_header())
        req.with_bearer(self._src_token)
        return self._follow_redirects(req, self._src_token.copy())

    # -------------------------------------------------------------------------
    # Redirect following — see the header note. Lives on the COPIER, not on the
    # transport, and that placement is the same call this file's seam already
    # made: "the protocol belongs in the CLIENT; the transport's whole job is
    # 'move bytes over HTTP'" (`oci_transport.mojo`'s header). A redirect is
    # protocol control flow, and putting it under the seam would make it
    # invisible to `ScriptedOciTransport` — a redirect could then not be
    # SCRIPTED, so the falsifier for redirect following could not exist.
    # Here, a redirect is two queued responses and the assertion is over the
    # real conversation.
    # -------------------------------------------------------------------------
    def _follow_redirects(
        mut self, request: OciRequest, var bearer: String
    ) raises -> OciResponse:
        """Send `request` (a GET) and follow any redirect chain to its answer.

        Non-redirect statuses — including 404 — are returned UNTOUCHED, because
        the callers use status as control flow and a transformed 404 would break
        the "not there, upload it" path.

        `bearer` is re-attached to a hop ONLY when that hop's host equals the
        ORIGINAL request's host. Comparing against the original rather than the
        previous hop is what keeps an `A -> B -> B` chain from walking the
        token onto B."""
        var resp = self._transport.send(request.copy())
        var host = request.registry.copy()
        var hops = 0
        while is_redirect_status(resp.status):
            if hops >= MAX_REDIRECT_HOPS:
                raise Error(
                    String("oci: the redirect chain for ")
                    + request.registry
                    + request.path
                    + String(" exceeded ")
                    + String(MAX_REDIRECT_HOPS)
                    + String(
                        " hops without reaching a body — refusing to keep"
                        " following (the registry is looping)."
                    )
                )
            hops += 1
            var target = _resolve_redirect_or_raise(
                host, resp.header(String("location"))
            )
            var next_req = OciRequest(
                HTTP_METHOD_GET, target.host.copy(), target.path.copy()
            )
            # Carry the original headers EXCEPT the credential. `accept` is
            # load-bearing on a manifest GET (it selects index-vs-manifest), so
            # dropping every header would change what the redirect target
            # serves. (`OciRequest.with_bearer` is this file's only writer of
            # the credential and uses the lowercase literal; the shared
            # predicate ignores case, so a differently-cased copy would be
            # dropped too rather than carried to every hop.)
            for i in range(len(request.header_names)):
                if is_authorization_header(request.header_names[i]):
                    continue
                next_req.with_header(
                    String(request.header_names[i]),
                    String(request.header_values[i]),
                )
            # Re-attached LAST, as before, so the hop's header order is
            # unchanged; and only where the shared rule allows — compared
            # against the ORIGINAL request's host, never this hop's
            # predecessor.
            if carries_credential(request.registry, target.host):
                next_req.with_bearer(bearer)
            host = target.host.copy()
            resp = self._transport.send(next_req^)
        return resp^

    # -------------------------------------------------------------------------
    # Phase 2 — BLOBS.
    # -------------------------------------------------------------------------
    def _copy_blobs_of(
        mut self, src: OciImageRef, dst: OciImageRef, manifest_raw: List[UInt8]
    ) raises:
        """Ensure the destination holds the config blob and every layer blob this
        image manifest references."""
        var digests = image_blob_digests(manifest_raw)
        for i in range(len(digests)):
            self._ensure_blob(src, dst, String(digests[i]))

    def _ensure_blob(
        mut self, src: OciImageRef, dst: OciImageRef, digest: String
    ) raises:
        # (a) Already there? A HEAD is one round trip and skips everything else.
        # On a re-stage of an unchanged base image this short-circuits nearly
        # every layer.
        var head = OciRequest(
            HTTP_METHOD_HEAD,
            dst.registry.copy(),
            String("/v2/") + dst.repository + String("/blobs/") + digest,
        )
        head.with_bearer(self._dst_token)
        var head_resp = self._transport.send(head^)
        if head_resp.status == 200:
            return

        # (b) CROSS-REPOSITORY MOUNT — only possible within ONE registry.
        var upload_location = String("")
        if src.registry == dst.registry:
            var mount = OciRequest(
                HTTP_METHOD_POST,
                dst.registry.copy(),
                String("/v2/")
                + dst.repository
                + String("/blobs/uploads/?mount=")
                + digest
                + String("&from=")
                + src.repository,
            )
            mount.with_bearer(self._dst_token)
            var mount_resp = self._transport.send(mount^)
            if mount_resp.status == 201:
                # Mounted — zero bytes transferred. The common path for a
                # cross-PROJECT, same-HOST promote.
                return
            if mount_resp.status == 202:
                # The registry DECLINED the mount and handed back an upload
                # session instead. This is a normal answer, not a fault: AR
                # declines when the caller lacks read on the source repository.
                upload_location = mount_resp.header(String("location"))
            elif mount_resp.status != 404 and mount_resp.status != 405:
                raise Error(
                    String("oci: blob mount of ")
                    + digest
                    + String(" into ")
                    + dst.repository
                    + String(" returned HTTP ")
                    + String(mount_resp.status)
                    + String(_body_hint(mount_resp))
                )

        # (c) Open an upload session if the mount attempt did not leave us one.
        if upload_location.byte_length() == 0:
            var start = OciRequest(
                HTTP_METHOD_POST,
                dst.registry.copy(),
                String("/v2/") + dst.repository + String("/blobs/uploads/"),
            )
            start.with_bearer(self._dst_token)
            var start_resp = self._transport.send(start^)
            if start_resp.status != 202:
                raise Error(
                    String("oci: opening a blob upload session in ")
                    + dst.repository
                    + String(" returned HTTP ")
                    + String(start_resp.status)
                    + String(" (expected 202)")
                    + String(_body_hint(start_resp))
                )
            upload_location = start_resp.header(String("location"))
        # ⚠ The session URL is resolved, never used raw as a path: it may be an
        # absolute URL, and one naming another host is REFUSED (the credential
        # must not leave the host it was issued for). See oci_location.mojo.
        var upload_target = resolve_upload_location(
            dst.registry, upload_location
        )

        # (d) Fetch the blob from the SOURCE and verify its content-address
        # before it is written anywhere. A layer that does not hash to its
        # descriptor is corruption; pushing it would put a broken blob under a
        # digest that claims to be good.
        var get = OciRequest(
            HTTP_METHOD_GET,
            src.registry.copy(),
            String("/v2/") + src.repository + String("/blobs/") + digest,
        )
        get.with_bearer(self._src_token)
        # FOLLOWS REDIRECTS — a registry answers a blob GET with a 3xx to where
        # the bytes actually live. `verify_digest` below is what makes that safe.
        var blob = self._follow_redirects(get, self._src_token.copy())
        if blob.status != 200:
            raise Error(
                String("oci: GET blob ")
                + digest
                + String(" from ")
                + src.repository
                + String(" returned HTTP ")
                + String(blob.status)
                + String(_body_hint(blob))
            )
        verify_digest(Span(blob.body), digest, String("blob ") + digest)

        # (e) Monolithic PUT to close the session. The `digest` query parameter
        # is what tells the registry to finalize + verify.
        var put = OciRequest(
            HTTP_METHOD_PUT,
            upload_target.host.copy(),
            append_query(upload_target.path, String("digest=") + digest),
        )
        put.with_bearer(self._dst_token)
        put.with_header(
            String("content-type"), String("application/octet-stream")
        )
        put.with_body(blob.take_body())
        var put_resp = self._transport.send(put^)
        if put_resp.status != 201:
            raise Error(
                String("oci: PUT blob ")
                + digest
                + String(" to ")
                + dst.repository
                + String(" returned HTTP ")
                + String(put_resp.status)
                + String(" (expected 201 Created)")
                + String(_body_hint(put_resp))
            )

    # -------------------------------------------------------------------------
    # Phase 3 — MANIFESTS.
    # -------------------------------------------------------------------------
    def _put_manifest(
        mut self, dst: OciImageRef, m: _DiscoveredManifest
    ) raises -> String:
        """PUT one manifest BY DIGEST, verbatim, and return the digest the
        destination confirms.

        Addressing the PUT by DIGEST rather than by tag is what makes the copy
        idempotent and makes the preserved-digest assertion meaningful: the URL
        itself states the content-address the registry must agree to."""
        var req = OciRequest(
            HTTP_METHOD_PUT,
            dst.registry.copy(),
            String("/v2/") + dst.repository + String("/manifests/") + m.digest,
        )
        req.with_header(String("content-type"), m.media_type.copy())
        req.with_bearer(self._dst_token)
        # VERBATIM — see (1) at the top of the file.
        req.with_body(m.raw.copy())
        var resp = self._transport.send(req^)
        if resp.status != 201 and resp.status != 200:
            raise Error(
                String("oci: PUT manifest ")
                + m.digest
                + String(" to ")
                + dst.registry
                + String("/")
                + dst.repository
                + String(" returned HTTP ")
                + String(resp.status)
                + String(_body_hint(resp))
            )
        # Prefer the registry's own assertion when it makes one — a
        # `Docker-Content-Digest` that DISAGREES with what we pushed means the
        # registry stored something else, and that must fail loudly rather than
        # be papered over with the digest we already believe.
        var confirmed = resp.header(String("docker-content-digest"))
        if confirmed.byte_length() == 0:
            return m.digest.copy()
        if confirmed != m.digest:
            raise Error(
                String("oci: the destination stored manifest ")
                + m.digest
                + String(" under a DIFFERENT digest ")
                + confirmed
                + String(
                    " — the registry did not preserve the content-address."
                    " REFUSING."
                )
            )
        return confirmed^


# =============================================================================
# §3 — manifest parsing (DISCOVERY ONLY — never a re-serialization).
# =============================================================================


def _index_child_digests(raw: List[UInt8]) raises -> List[String]:
    """The `manifests[].digest` values of an image index / manifest list."""
    var doc = parse_json_value(String(unsafe_from_utf8=Span(raw)))
    var out = List[String]()
    if not doc.has(String("manifests")):
        return out^
    var arr = doc.get(String("manifests"))
    for i in range(arr.array_len()):
        var entry = arr.element_at(i)
        if entry.has(String("digest")):
            out.append(entry.get(String("digest")).as_string())
    return out^


def _media_type_from_body(raw: List[UInt8]) raises -> String:
    """The media type of a manifest served with no `Content-Type`.

    The body's own `mediaType` when it is a non-empty string (an OCI index or
    image manifest, a Docker manifest list or image manifest); otherwise an OCI
    index when the body has a `manifests` array (the field `mediaType` is
    optional in an OCI index); otherwise an OCI image manifest."""
    var doc = parse_json_value(String(unsafe_from_utf8=Span(raw)))
    if doc.has(String("mediaType")):
        var declared = doc.get(String("mediaType"))
        if declared.is_string():
            var media_type = declared.as_string()
            if media_type.byte_length() > 0:
                return media_type^
    if doc.has(String("manifests")) and doc.get(String("manifests")).is_array():
        return String(MEDIA_TYPE_OCI_INDEX)
    return String(MEDIA_TYPE_OCI_MANIFEST)


def image_blob_digests(raw: List[UInt8]) raises -> List[String]:
    """The config digest + every layer digest of an image manifest.

    The config is listed FIRST purely so a failure reads in the order a human
    debugging a broken image would look: config, then layers in order."""
    var doc = parse_json_value(String(unsafe_from_utf8=Span(raw)))
    var out = List[String]()
    if doc.has(String("config")):
        var cfg = doc.get(String("config"))
        if cfg.has(String("digest")):
            out.append(cfg.get(String("digest")).as_string())
    if doc.has(String("layers")):
        var layers = doc.get(String("layers"))
        for i in range(layers.array_len()):
            var layer = layers.element_at(i)
            if layer.has(String("digest")):
                out.append(layer.get(String("digest")).as_string())
    return out^


# =============================================================================
# §4 — small helpers.
# =============================================================================


def _contains(found: List[_DiscoveredManifest], digest: String) -> Bool:
    for i in range(len(found)):
        if found[i].digest == digest:
            return True
    return False


# --- redirect resolution (see "WHY THE BLOB GET FOLLOWS REDIRECTS" up top) ---
#
# WHICH shapes are followed and which refused is `resolve_redirect_location`'s
# decision (komira_http). What is left here is only the WORDING of each refusal,
# in this client's vocabulary — the registry, the blob — which the shared policy
# deliberately does not know.


def _resolve_redirect_or_raise(
    current_registry: String, location: String
) raises -> RedirectTarget:
    """Resolve a `Location` against the registry that issued it, or RAISE
    naming why it will not be followed."""
    var target = resolve_redirect_location(current_registry, location)
    if target.is_resolved():
        return target^
    if target.kind == REDIRECT_REFUSED_NO_LOCATION:
        raise Error(
            String(
                "oci: the registry answered a redirect with NO Location header"
                " — there is no URL to follow (host "
            )
            + current_registry
            + String(")")
        )
    if target.kind == REDIRECT_REFUSED_PLAINTEXT:
        raise Error(
            String(
                "oci: REFUSING to follow a redirect to a PLAINTEXT url '"
            )
            + location
            + String(
                "' — registry traffic is HTTPS-only, and neither carrying a"
                " bearer token in the clear nor silently rewriting the scheme"
                " to one the registry did not name is acceptable."
            )
        )
    if target.kind == REDIRECT_REFUSED_NO_PATH:
        raise Error(
            String("oci: the redirect Location '")
            + location
            + String(
                "' names a host but no path — a host root is not a blob."
                " REFUSING."
            )
        )
    if target.kind == REDIRECT_REFUSED_EMPTY_HOST:
        raise Error(
            String("oci: the redirect Location '")
            + location
            + String("' has an EMPTY host. REFUSING.")
        )
    # REDIRECT_REFUSED_UNRESOLVABLE — and, fail-closed, any kind the policy
    # grows later that this renderer has not been taught: it is refused, never
    # followed.
    raise Error(
        String("oci: cannot resolve the redirect Location '")
        + location
        + String(
            "' — it is neither an absolute https url nor an absolute path."
            " REFUSING to guess what it is relative to."
        )
    )


def _body_hint(resp: OciResponse) -> String:
    """A short excerpt of an error body, for diagnosis.

    Truncated: a registry error body can be large, and a multi-kilobyte blob of
    JSON in an exception message buries the status code that actually matters."""
    if len(resp.body) == 0:
        return String("")
    var n = len(resp.body)
    if n > 400:
        n = 400
    var head = List[UInt8]()
    for i in range(n):
        head.append(resp.body[i])
    return String(" — ") + String(unsafe_from_utf8=Span(head))
