# =============================================================================
# oci_push.mojo — push a verified OCI LAYOUT to a registry, and tag it.
# =============================================================================
#
# `OciCopier` moves an image from one registry to another. `LayoutPusher` puts
# an image that exists only as a directory (`oci_layout_reader.mojo`) into a
# registry: the publisher uploads the SAME layout, directly, to each target
# registry, so the digest in every cell is the layout's own and no cell needs
# rights on another cell's registry.
#
# THE SEQUENCE (every step is a read-or-write over `OciTransport`):
#
#   1. read the TAG. Present on another digest -> REFUSED, before a byte is
#      sent. Present on ours -> NOOP (one request).
#   2. HEAD the manifest by digest. Present -> skip every blob.
#   3. each missing blob (layers, then config): HEAD; absent -> open an upload
#      session, resolve its Location (cross-host refused), read the blob ONCE
#      from disk (re-verified), monolithic PUT `?digest=`, the body MOVED into
#      the request. A lost/expired session gets a NEW session, a bounded number
#      of times.
#   4. PUT the manifest BY DIGEST, verbatim bytes. A blob a manifest names must
#      already be present, which is why this comes after step 3 and why a
#      registry rejects a manifest pushed first.
#   5. PUT the manifest under the TAG.
#   6. READ BACK: HEAD the manifest by digest and read the tag.
#
# THE TAG IS CLASSIFIED BY A READ, NEVER BY A STATUS CODE. A registry's answer
# to "this immutable tag already exists on other content" is 400, 403 or 409
# depending on the registry, and 403 is also what a permission that has not
# propagated yet returns. So when a tag PUT fails, for ANY status or a transport
# fault, the tag is READ and compared by digest:
#     same digest   -> success (another publisher won the race with our bytes);
#     other digest  -> REFUSED (a different image owns this revision);
#     absent        -> retry if the failure was transient, else PARTIAL;
#     unreadable    -> INDETERMINATE. Never inferred.
#
# OUTCOMES (a `PushResult.outcome`; none of these is an exception):
#   UPLOADED / NOOP / TAG_ADDED  success.
#   REFUSED       a definite no: bad input, a different digest owns the tag, a
#                 blob that no longer matches its digest.
#   FAILED        stopped, safe to retry from the top (the registry or the
#                 credential said no, or the transport faulted before anything
#                 that matters was written).
#   PARTIAL       the image is usable BY DIGEST, but the tag could not be added.
#   INDETERMINATE a write's outcome could not be read; never a pass.
#
# RETRIES are bounded and narrow: 5xx and transport faults (`MAX_SEND_ATTEMPTS`),
# and 403 ONLY when the caller says the repository was created moments ago
# (`retry_forbidden`; `MAX_FORBIDDEN_RETRIES`). 400, 401, 404 and 409 are never
# retried by status. There is no mount: a layout push has no source repository.
#
# SECRETS: the credential is attached to each request and appears in no result
# or error text.
#
# Encapsulation: owned values only; the transport is held by value.
# =============================================================================

from std.time import sleep

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from .oci_auth import OciAuth
from .oci_digest import digest_of_bytes, validate_digest_format
from .oci_layout_reader import LayoutBlob, OciLayout
from .oci_location import append_query, resolve_upload_location
from .oci_ref import manifest_accept_header
from .oci_transport import OciRequest, OciResponse, OciTransport


# ---- bounds (named, so a test pins them and raising one is a code change) -----

# Total sends of one logical request (the first try plus retries) on a 5xx or a
# transport fault.
comptime MAX_SEND_ATTEMPTS: Int = 4

# How many 403s are retried, in total per request, when the caller says the
# repository was just created and its permission may not have propagated.
comptime MAX_FORBIDDEN_RETRIES: Int = 4

# Fresh upload sessions tried for ONE blob when a session is lost or its PUT
# fails transiently.
comptime MAX_UPLOAD_SESSION_ATTEMPTS: Int = 3


# ---- outcomes -----------------------------------------------------------------

comptime PUSH_UPLOADED: Int = 0
comptime PUSH_NOOP: Int = 1
comptime PUSH_TAG_ADDED: Int = 2
comptime PUSH_REFUSED: Int = 3
comptime PUSH_FAILED: Int = 4
comptime PUSH_INDETERMINATE: Int = 5
comptime PUSH_PARTIAL: Int = 6


def push_outcome_name(outcome: Int) -> String:
    if outcome == PUSH_UPLOADED:
        return String("UPLOADED")
    if outcome == PUSH_NOOP:
        return String("NOOP")
    if outcome == PUSH_TAG_ADDED:
        return String("TAG_ADDED")
    if outcome == PUSH_REFUSED:
        return String("REFUSED")
    if outcome == PUSH_FAILED:
        return String("FAILED")
    if outcome == PUSH_INDETERMINATE:
        return String("INDETERMINATE")
    if outcome == PUSH_PARTIAL:
        return String("PARTIAL")
    return String("UNKNOWN")


struct PushResult(Copyable, Movable, Deinitable):
    """What a push did, as a value: the fields a release record needs.

    `registry` + `repository` are where it went; `digest` is the manifest digest
    (the image's identity); `platform` is `os/arch` from the layout's config;
    `tag` is the tag asked for. `outcome` is a `PUSH_*` code and `detail` says
    why in words when it is not a success. The counters say what the push moved:
    blobs sent, blobs the registry already had, and bytes sent."""

    var registry: String
    var repository: String
    var digest: String
    var platform: String
    var tag: String
    var outcome: Int
    var detail: String
    var blobs_uploaded: Int
    var blobs_skipped: Int
    var bytes_uploaded: Int

    def __init__(
        out self,
        var registry: String,
        var repository: String,
        var digest: String,
        var platform: String,
        var tag: String,
    ):
        self.registry = registry^
        self.repository = repository^
        self.digest = digest^
        self.platform = platform^
        self.tag = tag^
        self.outcome = PUSH_FAILED
        self.detail = String("")
        self.blobs_uploaded = 0
        self.blobs_skipped = 0
        self.bytes_uploaded = 0

    def is_success(self) -> Bool:
        return (
            self.outcome == PUSH_UPLOADED
            or self.outcome == PUSH_NOOP
            or self.outcome == PUSH_TAG_ADDED
        )

    def reference(self) -> String:
        """`host/repository@sha256:…` — the by-digest reference to deploy."""
        return self.registry + String("/") + self.repository + String("@") + self.digest

    def copy(self) -> Self:
        var out = PushResult(
            self.registry.copy(),
            self.repository.copy(),
            self.digest.copy(),
            self.platform.copy(),
            self.tag.copy(),
        )
        out.outcome = self.outcome
        out.detail = self.detail.copy()
        out.blobs_uploaded = self.blobs_uploaded
        out.blobs_skipped = self.blobs_skipped
        out.bytes_uploaded = self.bytes_uploaded
        return out^


# ---- input grammar --------------------------------------------------------------


def validate_oci_tag(tag: String) raises:
    """RAISE unless `tag` fits the OCI distribution tag grammar:
    `[A-Za-z0-9_][A-Za-z0-9._-]{0,127}`.

    A tag that is a digest (`sha256:…`), has a slash, a leading dot or dash, or
    is empty is not a tag — and with immutable tags a wrong one is a name that
    can never be fixed."""
    var n = tag.byte_length()
    if n == 0:
        raise Error(String("oci: the tag is empty"))
    if n > 128:
        raise Error(
            String("oci: the tag is ") + String(n) + String(" bytes; the limit is 128")
        )
    for i in range(n):
        var c = UInt8(ord(tag[byte=i]))
        var alnum = (
            (c >= UInt8(48) and c <= UInt8(57))
            or (c >= UInt8(65) and c <= UInt8(90))
            or (c >= UInt8(97) and c <= UInt8(122))
        )
        var ok = alnum or c == UInt8(95)
        if i > 0:
            ok = ok or c == UInt8(46) or c == UInt8(45)
        if not ok:
            raise Error(
                String("oci: '")
                + tag
                + String("' is not a valid tag (allowed: [A-Za-z0-9_][A-Za-z0-9._-]{0,127})")
            )


def _validate_repository(repository: String) raises:
    var n = repository.byte_length()
    if n == 0:
        raise Error(String("oci: the repository is empty"))
    if repository.startswith(String("/")) or repository.endswith(String("/")):
        raise Error(String("oci: the repository '") + repository + String("' has a leading or trailing '/'"))
    if repository.find(String("//")) >= 0 or repository.find(String("..")) >= 0:
        raise Error(String("oci: the repository '") + repository + String("' has an empty or '..' segment"))
    for i in range(n):
        var c = UInt8(ord(repository[byte=i]))
        var ok = (
            (c >= UInt8(97) and c <= UInt8(122))
            or (c >= UInt8(48) and c <= UInt8(57))
            or c == UInt8(46)
            or c == UInt8(95)
            or c == UInt8(45)
            or c == UInt8(47)
        )
        if not ok:
            raise Error(
                String("oci: the repository '")
                + repository
                + String("' must be lowercase [a-z0-9._-] segments joined by '/'")
            )


def _validate_registry(registry: String) raises:
    if registry.byte_length() == 0:
        raise Error(String("oci: the registry host is empty"))
    if registry.find(String("/")) >= 0 or registry.find(String(":")) >= 0:
        raise Error(
            String("oci: the registry '")
            + registry
            + String("' must be a bare host name (no scheme, port or path)")
        )


# ---- internal step values --------------------------------------------------------

comptime _TAG_ABSENT: Int = 0
comptime _TAG_PRESENT: Int = 1
comptime _TAG_UNREADABLE: Int = 2


struct _TagRead(Movable, Deinitable):
    var state: Int
    var digest: String
    var note: String

    def __init__(out self, state: Int, var digest: String, var note: String):
        self.state = state
        self.digest = digest^
        self.note = note^


struct _Step(Movable, Deinitable):
    """One step's verdict: ok, or an outcome code + the words for it."""

    var ok: Bool
    var outcome: Int
    var detail: String

    def __init__(out self):
        self.ok = True
        self.outcome = PUSH_UPLOADED
        self.detail = String("")

    @staticmethod
    def stop(outcome: Int, var detail: String) -> _Step:
        var s = _Step()
        s.ok = False
        s.outcome = outcome
        s.detail = detail^
        return s^


def _is_2xx_created(status: Int) -> Bool:
    return status == 200 or status == 201


struct LayoutPusher[T: OciTransport](Movable, Deinitable):
    """Pushes a verified `OciLayout` to one registry repository.

    Parametric over the transport so the tests drive the SAME code the
    production path runs, over a scripted or an in-process fake registry.

    `retry_forbidden` says "this repository was created moments ago": a 403 is
    then retried (bounded) because the permission may not have propagated.
    `backoff_ms` is the sleep before retry N (N * backoff_ms); 0 means none."""

    var _transport: Self.T
    var _auth: OciAuth
    var _retry_forbidden: Bool
    var _backoff_ms: Int

    def __init__(
        out self,
        var transport: Self.T,
        var auth: OciAuth,
        retry_forbidden: Bool = False,
        backoff_ms: Int = 250,
    ):
        self._transport = transport^
        self._auth = auth^
        self._retry_forbidden = retry_forbidden
        self._backoff_ms = backoff_ms

    def transport(ref self) -> ref [self._transport] Self.T:
        """Borrow the transport so a test can assert the exact conversation."""
        return self._transport

    # -------------------------------------------------------------------------
    # push
    # -------------------------------------------------------------------------
    def push(
        mut self,
        layout: OciLayout,
        registry: String,
        repository: String,
        tag: String,
    ) -> PushResult:
        """Push `layout` to `registry`/`repository` and tag it `tag`. Never
        raises: every end state is a `PushResult.outcome`."""
        var r = PushResult(
            registry.copy(),
            repository.copy(),
            layout.manifest_digest.copy(),
            layout.platform(),
            tag.copy(),
        )
        try:
            validate_oci_tag(tag)
            _validate_repository(repository)
            _validate_registry(registry)
        except e:
            r.outcome = PUSH_REFUSED
            r.detail = String(e)
            return r^

        # 1. the tag, before anything is sent.
        var tag0 = self._read_tag(registry, repository, tag)
        if tag0.state == _TAG_UNREADABLE:
            r.outcome = PUSH_FAILED
            r.detail = String("could not read the tag before pushing: ") + tag0.note
            return r^
        if tag0.state == _TAG_PRESENT and tag0.digest != layout.manifest_digest:
            r.outcome = PUSH_REFUSED
            r.detail = (
                String("tag '")
                + tag
                + String("' already names ")
                + tag0.digest
                + String(" but this image is ")
                + layout.manifest_digest
                + String(" — a different image owns this revision")
            )
            return r^
        if tag0.state == _TAG_PRESENT:
            # Tag already ours: the manifest it names exists. Nothing to do.
            r.outcome = PUSH_NOOP
            return r^

        # 2. is the manifest already there (the tag is absent)?
        var manifest_present = False
        try:
            var head = self._head_manifest(registry, repository, layout.manifest_digest)
            if head.status == 200:
                manifest_present = True
            elif head.status != 404:
                r.outcome = PUSH_FAILED
                r.detail = String("HEAD manifest returned HTTP ") + String(head.status)
                return r^
        except e:
            r.outcome = PUSH_FAILED
            r.detail = String("HEAD manifest failed: ") + String(e)
            return r^

        # 3. blobs.
        if not manifest_present:
            var blobs = layout.push_blobs()
            for i in range(len(blobs)):
                var step = self._ensure_blob(layout, registry, repository, blobs[i], r)
                if not step.ok:
                    r.outcome = step.outcome
                    r.detail = step.detail.copy()
                    return r^

            # 4. manifest by digest.
            var mstep = self._put_manifest(
                layout, registry, repository, layout.manifest_digest
            )
            if not mstep.ok:
                r.outcome = mstep.outcome
                r.detail = mstep.detail.copy()
                return r^

        # 5. the tag.
        var tstep = self._put_tag(layout, registry, repository, tag)
        if not tstep.ok:
            r.outcome = tstep.outcome
            r.detail = tstep.detail.copy()
            return r^
        # `_put_tag` leaves the DIGEST the tag ended on in `detail` when ok; the
        # outcome is decided here, from what this run actually wrote.
        if manifest_present:
            r.outcome = PUSH_TAG_ADDED
        else:
            r.outcome = PUSH_UPLOADED

        # 6. read back.
        var rb = self._read_back(registry, repository, tag, layout.manifest_digest)
        if not rb.ok:
            r.outcome = rb.outcome
            r.detail = rb.detail.copy()
        return r^

    # -------------------------------------------------------------------------
    # one logical request, with the bounded retry policy
    # -------------------------------------------------------------------------
    def _backoff(self, attempt: Int):
        if self._backoff_ms > 0:
            sleep(Float64(self._backoff_ms * attempt) / 1000.0)

    def _call(
        mut self, template: OciRequest, retry_403: Bool = True
    ) raises -> OciResponse:
        """Send `template` (copied per attempt, so it must be small), retrying
        5xx and transport faults up to `MAX_SEND_ATTEMPTS`, and 403 up to
        `MAX_FORBIDDEN_RETRIES` when `retry_forbidden` and `retry_403`. Returns
        the last response; RAISES only if the LAST attempt was a transport
        fault. Everything else (400, 401, 404, 409 ...) is returned at once."""
        var attempts = 0
        var forbidden = 0
        while True:
            attempts += 1
            var req = template.copy()
            self._auth.apply(req)
            var resp = OciResponse(0)
            try:
                resp = self._transport.send(req^)
            except e:
                if attempts >= MAX_SEND_ATTEMPTS:
                    raise e^
                self._backoff(attempts)
                continue
            if resp.status >= 500 and attempts < MAX_SEND_ATTEMPTS:
                self._backoff(attempts)
                continue
            if (
                resp.status == 403
                and retry_403
                and self._retry_forbidden
                and forbidden < MAX_FORBIDDEN_RETRIES
            ):
                forbidden += 1
                self._backoff(forbidden)
                continue
            return resp^

    def _manifest_request(
        self, method: UInt8, registry: String, repository: String, reference: String
    ) -> OciRequest:
        var req = OciRequest(
            method,
            registry.copy(),
            String("/v2/") + repository + String("/manifests/") + reference,
        )
        if method != HTTP_METHOD_PUT:
            req.with_header(String("accept"), manifest_accept_header())
        return req^

    def _head_manifest(
        mut self, registry: String, repository: String, reference: String
    ) raises -> OciResponse:
        return self._call(
            self._manifest_request(HTTP_METHOD_HEAD, registry, repository, reference)
        )

    # -------------------------------------------------------------------------
    # reading a tag — by DIGEST, from the registry's own header or the bytes
    # -------------------------------------------------------------------------
    def _read_tag(
        mut self, registry: String, repository: String, tag: String
    ) -> _TagRead:
        try:
            var head = self._head_manifest(registry, repository, tag)
            if head.status == 404:
                return _TagRead(_TAG_ABSENT, String(""), String(""))
            if head.status != 200:
                return _TagRead(
                    _TAG_UNREADABLE,
                    String(""),
                    String("HEAD tag returned HTTP ") + String(head.status),
                )
            var d = head.header(String("docker-content-digest"))
            if d.byte_length() > 0:
                try:
                    validate_digest_format(d, String("the tag's Docker-Content-Digest"))
                    return _TagRead(_TAG_PRESENT, d^, String(""))
                except e:
                    return _TagRead(_TAG_UNREADABLE, String(""), String(e))
            # No digest header: GET the manifest and hash the bytes. The digest
            # is then OURS, computed — not the registry's assertion.
            var get = self._call(
                self._manifest_request(HTTP_METHOD_GET, registry, repository, tag)
            )
            if get.status == 404:
                return _TagRead(_TAG_ABSENT, String(""), String(""))
            if get.status != 200:
                return _TagRead(
                    _TAG_UNREADABLE,
                    String(""),
                    String("GET tag returned HTTP ") + String(get.status),
                )
            return _TagRead(_TAG_PRESENT, digest_of_bytes(Span(get.body)), String(""))
        except e:
            return _TagRead(_TAG_UNREADABLE, String(""), String(e))

    # -------------------------------------------------------------------------
    # blobs
    # -------------------------------------------------------------------------
    def _ensure_blob(
        mut self,
        layout: OciLayout,
        registry: String,
        repository: String,
        blob: LayoutBlob,
        mut result: PushResult,
    ) -> _Step:
        var head = OciRequest(
            HTTP_METHOD_HEAD,
            registry.copy(),
            String("/v2/") + repository + String("/blobs/") + blob.digest,
        )
        try:
            var hr = self._call(head)
            if hr.status == 200:
                result.blobs_skipped += 1
                return _Step()
            if hr.status != 404:
                return _Step.stop(
                    PUSH_FAILED,
                    String("HEAD blob ") + blob.digest + String(" returned HTTP ") + String(hr.status),
                )
        except e:
            return _Step.stop(
                PUSH_FAILED, String("HEAD blob ") + blob.digest + String(" failed: ") + String(e)
            )

        var forbidden = 0
        for session_try in range(MAX_UPLOAD_SESSION_ATTEMPTS):
            # ---- open a session
            var location = String("")
            try:
                var start = OciRequest(
                    HTTP_METHOD_POST,
                    registry.copy(),
                    String("/v2/") + repository + String("/blobs/uploads/"),
                )
                var sr = self._call(start)
                if sr.status != 202:
                    return _Step.stop(
                        PUSH_FAILED,
                        String("opening an upload session returned HTTP ")
                        + String(sr.status)
                        + String(" (expected 202)"),
                    )
                location = sr.header(String("location"))
            except e:
                return _Step.stop(
                    PUSH_FAILED, String("opening an upload session failed: ") + String(e)
                )

            var target_host = String("")
            var target_path = String("")
            try:
                var target = resolve_upload_location(registry, location)
                target_host = target.host.copy()
                target_path = target.path.copy()
            except e:
                return _Step.stop(PUSH_FAILED, String(e))

            # ---- read the blob ONCE (re-verified), move it into the request
            var data = List[UInt8]()
            try:
                data = layout.read_blob(blob)
            except e:
                return _Step.stop(PUSH_REFUSED, String(e))

            var put = OciRequest(
                HTTP_METHOD_PUT,
                target_host^,
                append_query(target_path, String("digest=") + blob.digest),
            )
            put.with_header(String("content-type"), String("application/octet-stream"))
            put.with_body(data^)
            self._auth.apply(put)
            var status = -1
            try:
                var pr = self._transport.send(put^)
                status = pr.status
            except e:
                status = -1

            if status == 201:
                result.blobs_uploaded += 1
                result.bytes_uploaded += blob.size
                return _Step()
            # A lost session (404), a server fault (5xx), a transport fault, or a
            # not-yet-propagated 403 gets a NEW session. Anything else is final.
            var transient = (
                status == -1
                or status == 404
                or status >= 500
                or (
                    status == 403
                    and self._retry_forbidden
                    and forbidden < MAX_FORBIDDEN_RETRIES
                )
            )
            if status == 403:
                forbidden += 1
            if not transient:
                return _Step.stop(
                    PUSH_FAILED,
                    String("PUT blob ") + blob.digest + String(" returned HTTP ") + String(status),
                )
            self._backoff(session_try + 1)
        return _Step.stop(
            PUSH_FAILED,
            String("PUT blob ")
            + blob.digest
            + String(" did not succeed in ")
            + String(MAX_UPLOAD_SESSION_ATTEMPTS)
            + String(" upload sessions"),
        )

    # -------------------------------------------------------------------------
    # manifest by digest
    # -------------------------------------------------------------------------
    def _put_manifest(
        mut self,
        layout: OciLayout,
        registry: String,
        repository: String,
        reference: String,
    ) -> _Step:
        var req = self._manifest_request(HTTP_METHOD_PUT, registry, repository, reference)
        req.with_header(String("content-type"), layout.manifest_media_type.copy())
        req.with_body(layout.manifest_raw.copy())
        try:
            var resp = self._call(req)
            if not _is_2xx_created(resp.status):
                return _Step.stop(
                    PUSH_FAILED,
                    String("PUT manifest ") + reference + String(" returned HTTP ") + String(resp.status),
                )
            var confirmed = resp.header(String("docker-content-digest"))
            if confirmed.byte_length() > 0 and confirmed != layout.manifest_digest:
                return _Step.stop(
                    PUSH_FAILED,
                    String("the registry stored the manifest as ")
                    + confirmed
                    + String(" but it is ")
                    + layout.manifest_digest,
                )
        except e:
            return _Step.stop(
                PUSH_INDETERMINATE,
                String("PUT manifest: the outcome could not be read: ") + String(e),
            )
        return _Step()

    # -------------------------------------------------------------------------
    # the tag: PUT, and on ANY failure classify by a READ
    # -------------------------------------------------------------------------
    def _put_tag(
        mut self,
        layout: OciLayout,
        registry: String,
        repository: String,
        tag: String,
    ) -> _Step:
        var transient_used = 0
        var forbidden_used = 0
        while True:
            var req = self._manifest_request(HTTP_METHOD_PUT, registry, repository, tag)
            req.with_header(String("content-type"), layout.manifest_media_type.copy())
            req.with_body(layout.manifest_raw.copy())
            self._auth.apply(req)
            var status = -1
            var confirmed = String("")
            try:
                var resp = self._transport.send(req^)
                status = resp.status
                confirmed = resp.header(String("docker-content-digest"))
            except e:
                status = -1
            if _is_2xx_created(status):
                if confirmed.byte_length() > 0 and confirmed != layout.manifest_digest:
                    return _Step.stop(
                        PUSH_INDETERMINATE,
                        String("the registry tagged ") + confirmed + String(" but the image is ") + layout.manifest_digest,
                    )
                return _Step()
            # Failed (any status): the READ decides, never the status.
            var now = self._read_tag(registry, repository, tag)
            if now.state == _TAG_PRESENT:
                if now.digest == layout.manifest_digest:
                    return _Step()
                return _Step.stop(
                    PUSH_REFUSED,
                    String("tag '")
                    + tag
                    + String("' names ")
                    + now.digest
                    + String(" but this image is ")
                    + layout.manifest_digest
                    + String(" — a different image owns this revision"),
                )
            if now.state == _TAG_UNREADABLE:
                return _Step.stop(
                    PUSH_INDETERMINATE,
                    String("the tag PUT failed (HTTP ")
                    + String(status)
                    + String(") and the tag could not be read: ")
                    + now.note,
                )
            # Absent: retry only a transient failure, each kind bounded.
            if (status == -1 or status >= 500) and transient_used + 1 < MAX_SEND_ATTEMPTS:
                transient_used += 1
                self._backoff(transient_used)
                continue
            if (
                status == 403
                and self._retry_forbidden
                and forbidden_used < MAX_FORBIDDEN_RETRIES
            ):
                forbidden_used += 1
                self._backoff(forbidden_used)
                continue
            return _Step.stop(
                PUSH_PARTIAL,
                String("the image is pushed by digest, but the tag PUT failed (HTTP ")
                + String(status)
                + String(") and the tag is absent"),
            )

    # -------------------------------------------------------------------------
    # read-back
    # -------------------------------------------------------------------------
    def _read_back(
        mut self,
        registry: String,
        repository: String,
        tag: String,
        digest: String,
    ) -> _Step:
        try:
            var head = self._head_manifest(registry, repository, digest)
            if head.status != 200:
                return _Step.stop(
                    PUSH_INDETERMINATE,
                    String("read-back: HEAD manifest by digest returned HTTP ") + String(head.status),
                )
            var d = head.header(String("docker-content-digest"))
            if d.byte_length() > 0 and d != digest:
                return _Step.stop(
                    PUSH_INDETERMINATE,
                    String("read-back: the registry serves ") + d + String(" at ") + digest,
                )
        except e:
            return _Step.stop(
                PUSH_INDETERMINATE, String("read-back failed: ") + String(e)
            )
        var t = self._read_tag(registry, repository, tag)
        if t.state != _TAG_PRESENT or t.digest != digest:
            return _Step.stop(
                PUSH_INDETERMINATE,
                String("read-back: the tag '") + tag + String("' does not read back as ") + digest,
            )
        return _Step()
