# =============================================================================
# src/kci_pkg_upload/prefix_dev_registry.mojo — `PrefixDevRegistry`: a conda
#   channel on prefix.dev (or a server speaking its upload API).
# =============================================================================
#
# The coordinate's `repo` is `<host>/<channel>`, no scheme, where `<channel>`
# is prefix.dev's channel path: `<namespace>` for a namespace's primary
# channel, `<namespace>/<channel>` for any other, e.g.
# `prefix.dev/komira-ai/gamma` (`prefix_dev_repo_of_location` turns
# `https://<host>/<channel>` into it). The two segments travel unchanged in
# every path below. The `@` of the website route
# (`https://prefix.dev/channels/@<namespace>/...`) is never part of an upload,
# API or repository path, and is refused. Every request is HTTPS on 443.
#   Sources: https://prefix.dev/docs/prefix/channels/concepts (channel paths,
#   the `@`), https://prefix.dev/docs/prefix/api (`POST
#   /api/v1/upload/:channel`, "The channel path uses format
#   `namespace/channel`"), https://prefix.dev/docs/prefix/channels/use (the
#   repository URL `https://prefix.dev/<namespace>/<channel>`).
#
#   upload     POST https://<host>/api/v1/upload/<channel>
#              e.g. POST https://prefix.dev/api/v1/upload/komira-ai/gamma
#              Authorization: Bearer <token>   (surface PREFIX_DEV)
#              multipart/form-data, ONE part named `file`:
#                Content-Disposition: form-data; name="file"; filename="<file>"
#                Content-Type: application/octet-stream
#                Content-Length: <n>
#                X-File-Name: <file>
#                X-File-SHA256: <hex>
#              — the part rattler's `upload prefix` sends.
#   read_back  GET https://<host>/<channel>/<subdir>/repodata.json, the file's
#              (e.g. https://prefix.dev/komira-ai/gamma/linux-64/repodata.json;
#              the `<subdir>/repodata.json` suffix is the conda channel
#              layout, not stated by the pages above)
#              `sha256` (`conda_repodata.mojo`). The server answers 303 to a
#              signed URL on another host; the credential is carried only to
#              hops on `<host>`.
#   fetch      GET https://<host>/<channel>/<subdir>/<file>, redirects followed
#              the same way.
#   package_names
#              GET the same repodata.json; the package names its listings
#              hold (`classify_repodata_names`), read with the same redirect
#              and credential rules as `read_back`.
#
# ⛔ NEVER `force`. The server overwrites an existing file name when asked to
# (`?force=true`), and an overwrite of a published file is a different package
# under the same name. There is no parameter that sends it: a 409 is
# DUPLICATE_REFUSED, and the caller reads back to tell an identical file
# (converged) from a different one (a conflict).
#
# ⛔ AN UPLOAD NEEDS A CREDENTIAL. An EMPTY `Authorization` for PREFIX_DEV is
# refused before the request: an anonymous upload is a 401 at best. A READ
# carries whatever the credential gives for PREFIX_DEV, EMPTY meaning anonymous
# — a public channel is read anonymously, a private one with the token.
#
# The status rows are rattler's handling of the same endpoint; the server
# publishes no specification, so they are UNVERIFIED until a live upload has
# recorded them:
#   2xx CREATED; 409 DUPLICATE_REFUSED; 401/403 AUTH_REFUSED; 429
#   RATE_LIMITED; 5xx UNKNOWN; 400/404/413/422 and anything else (a 3xx
#   included — an upload is never redirected) REJECTED.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_crypto import hex_lower, sha256
from komira_http_core.codec.types import HTTP_METHOD_POST

from .coordinate import (
    PackageCoordinate,
    PackageFile,
    refuse_malformed_file_name,
    repo_host,
    repo_path,
)
from .conda_repodata import (
    NameListing,
    classify_repodata_answer,
    classify_repodata_names,
)
from .credential import SURFACE_PREFIX_DEV, RegistryCredential
from .http_read import get_following_redirects
from .identity import ContentIdentity, ascii_lower
from .legacy_upload import unknown_after_transport_fault
from .outcome import (
    READ_PRESENT,
    READ_UNKNOWN,
    UPLOAD_AUTH_REFUSED,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_RATE_LIMITED,
    UPLOAD_REJECTED,
    UPLOAD_UNKNOWN,
    Fetched,
    ReadBack,
    UploadOutcome,
    excerpt_unless_echoes,
    upload_kind_name,
    withhold_if_echoes,
)
from .pypi_registry import read_kind_of_fetch_status
from .transport import PkgRequest, PkgTransport, try_exchange
from .wire import append_str, bytes_contain


comptime PREFIX_DEV_UPLOAD_PATH: String = "/api/v1/upload/"
"""The upload endpoint's path, before the channel name."""

comptime _BOUNDARY_DOMAIN: String = "kci_pkg_upload prefix.dev boundary\n"


def prefix_dev_repo_of_location(location: String) raises -> String:
    """`https://<host>/<channel>` as a coordinate's `repo` (`<host>/<channel>`),
    where `<channel>` is `<namespace>` or `<namespace>/<channel>`. RAISES (a
    local fault) unless the location is exactly that: HTTPS, a host with no
    port, and one or two non-empty channel path segments (`prefix_dev_channel`).
    """
    var scheme = String("https://")
    if not location.startswith(scheme):
        raise Error(
            String("kci_pkg_upload: conda channel location '")
            + location
            + String("' is not an https:// URL")
        )
    var repo = String(location[byte = scheme.byte_length() :])
    _ = prefix_dev_channel(repo)
    return repo^


def prefix_dev_channel(repo: String) raises -> String:
    """The channel path of a `<host>/<channel>` repo: `<namespace>` or
    `<namespace>/<channel>`, the `/` kept, as the upload path and the
    repository path both carry it. RAISES (a local fault) when the path is not
    one or two segments, a segment is empty, `.` or `..`, or the path holds an
    `@`, a query, a fragment or a percent sign: a channel path is sent in a URL
    path as is."""
    var path = repo_path(repo)
    if path.byte_length() < 2:
        raise Error(
            String("kci_pkg_upload: conda repo '")
            + repo
            + String(
                "' names no channel; write it as <host>/<namespace> or"
                " <host>/<namespace>/<channel>"
            )
        )
    var channel = String(path[byte=1:])
    if (
        channel.find(String("?")) >= 0
        or channel.find(String("#")) >= 0
        or channel.find(String("%")) >= 0
    ):
        raise Error(
            String("kci_pkg_upload: conda repo '")
            + repo
            + String(
                "' holds a query, a fragment or a percent sign; a channel path"
                " is sent in a URL path as is"
            )
        )
    if channel.find(String("@")) >= 0:
        raise Error(
            String("kci_pkg_upload: conda repo '")
            + repo
            + String(
                "' holds an '@'. prefix.dev writes '@' only in its website"
                " route; an upload, API or repository path names the channel"
                " as <namespace>/<channel>"
            )
        )
    var segments = List[String]()
    var rest = channel.copy()
    while True:
        var cut = rest.find(String("/"))
        if cut < 0:
            segments.append(rest.copy())
            break
        segments.append(String(rest[byte=:cut]))
        var tail = String(rest[byte = cut + 1 :])
        rest = tail^
    for i in range(len(segments)):
        if segments[i].byte_length() == 0:
            raise Error(
                String("kci_pkg_upload: conda repo '")
                + repo
                + String("' has an EMPTY channel path segment")
            )
        if segments[i] == String(".") or segments[i] == String(".."):
            raise Error(
                String("kci_pkg_upload: conda repo '")
                + repo
                + String("': '")
                + segments[i]
                + String("' is not a channel path segment")
            )
    if len(segments) > 2:
        raise Error(
            String("kci_pkg_upload: conda repo '")
            + repo
            + String(
                "' must name <namespace> or <namespace>/<channel> after the"
                " host, nothing more"
            )
        )
    return channel^

def _refuse_malformed_subdir(c: PackageCoordinate) raises:
    if c.subdir.byte_length() == 0:
        raise Error(
            String("kci_pkg_upload: a conda coordinate names no subdir: ")
            + c.describe()
        )
    refuse_malformed_subdir_segment(c.subdir)


def refuse_malformed_subdir_segment(subdir: String) raises:
    """A conda subdir is one non-empty path segment with no query, fragment
    or percent sign: it is sent in a URL path as is. RAISES (a local fault)."""
    if subdir.byte_length() == 0:
        raise Error("kci_pkg_upload: a conda subdir is EMPTY")
    if (
        subdir.find(String("/")) >= 0
        or subdir.find(String("?")) >= 0
        or subdir.find(String("#")) >= 0
        or subdir.find(String("%")) >= 0
        or subdir == String(".")
        or subdir == String("..")
    ):
        raise Error(
            String("kci_pkg_upload: conda subdir '")
            + subdir
            + String("' is not one path segment")
        )


def refuse_malformed_conda_coordinate(c: PackageCoordinate) raises:
    """The local checks every conda request makes before it is composed: a
    channel path of one or two segments, one subdir segment, a one-segment file name ending in
    `.conda` or `.tar.bz2`."""
    _ = prefix_dev_channel(c.repo)
    _refuse_malformed_subdir(c)
    refuse_malformed_file_name(c)
    if not (
        c.file_name.endswith(String(".conda"))
        or c.file_name.endswith(String(".tar.bz2"))
    ):
        raise Error(
            String("kci_pkg_upload: '")
            + c.file_name
            + String("' is not a conda package file (.conda or .tar.bz2)")
        )


def _strip_conda_extension(file_name: String) -> String:
    if file_name.endswith(String(".conda")):
        return String(file_name[byte = : file_name.byte_length() - 6])
    if file_name.endswith(String(".tar.bz2")):
        return String(file_name[byte = : file_name.byte_length() - 8])
    return file_name.copy()


def refuse_name_not_the_files(c: PackageCoordinate) raises:
    """RAISE unless `c.file_name` is `<distribution>-<version>-<build>` plus
    the extension. A conda name may hold `-`, a version and a build may not,
    so the file name is split at its LAST two `-`. The name compares
    ASCII-case-insensitively (a conda name is lowercase), the version
    exactly."""
    var stem = _strip_conda_extension(c.file_name)
    var last = stem.rfind(String("-"))
    var mid = -1
    if last > 0:
        mid = String(stem[byte=:last]).rfind(String("-"))
    if last <= 0 or mid <= 0 or last == stem.byte_length() - 1:
        raise Error(
            String("kci_pkg_upload: '")
            + c.file_name
            + String("' is not <name>-<version>-<build>.conda")
        )
    var name = String(stem[byte=:mid])
    var version = String(stem[byte = mid + 1 : last])
    if ascii_lower(name) != ascii_lower(c.distribution) or version != c.version:
        raise Error(
            String("kci_pkg_upload: coordinate ")
            + c.distribution
            + String(" ")
            + c.version
            + String(" does not name the file '")
            + c.file_name
            + String("'")
        )


def prefix_dev_upload_boundary(sha256_hex: String) -> String:
    """The multipart boundary for a file whose sha256 is `sha256_hex`:
    deterministic in the file (a retry sends identical bytes), 64 hex
    characters in four dash-joined groups."""
    var seed = String(_BOUNDARY_DOMAIN) + sha256_hex
    var h = hex_lower(Span(sha256(seed.as_bytes())))
    return (
        String(h[byte=0:16])
        + String("-")
        + String(h[byte=16:32])
        + String("-")
        + String(h[byte=32:48])
        + String("-")
        + String(h[byte=48:64])
    )


def encode_prefix_dev_form(f: PackageFile, boundary: String) raises -> List[UInt8]:
    """The one-part multipart body (see the file header for the exact part
    headers). RAISES when the file name could break its quoted parameter or a
    header line, or when the file contains its own delimiter."""
    var delim = String("--") + boundary
    var fb = f.coordinate.file_name.as_bytes()
    for i in range(len(fb)):
        var c = fb[i]
        if c == UInt8(ord('"')) or c == UInt8(10) or c == UInt8(13):
            raise Error(
                String("kci_pkg_upload: file name '")
                + f.coordinate.file_name
                + String("' cannot be carried in a quoted filename parameter")
            )
    if bytes_contain(Span(f.bytes), delim):
        raise Error(
            String("kci_pkg_upload: the file '")
            + f.coordinate.file_name
            + String("' contains its own multipart delimiter; refusing to send")
        )
    var out = List[UInt8]()
    append_str(out, delim)
    append_str(
        out,
        String('\r\nContent-Disposition: form-data; name="file"; filename="')
        + f.coordinate.file_name
        + String('"\r\nContent-Type: application/octet-stream\r\nContent-Length: ')
        + String(len(f.bytes))
        + String("\r\nX-File-Name: ")
        + f.coordinate.file_name
        + String("\r\nX-File-SHA256: ")
        + f.identity.sha256_hex
        + String("\r\n\r\n"),
    )
    out.extend(Span(f.bytes))
    append_str(out, String("\r\n"))
    append_str(out, delim)
    append_str(out, String("--\r\n"))
    return out^


def build_prefix_dev_upload_request(
    f: PackageFile, authorization: String
) raises -> PkgRequest:
    """The complete upload request for `f` (every header and body byte except
    what the transport adds: Host, Content-Length). RAISES on a local fault
    before anything is sent, an EMPTY authorization included."""
    refuse_malformed_conda_coordinate(f.coordinate)
    refuse_name_not_the_files(f.coordinate)
    if authorization.byte_length() == 0:
        raise Error(
            String("kci_pkg_upload: an upload to ")
            + f.coordinate.repo
            + String(
                " needs a credential, and the one given presents none for"
                " PREFIX_DEV. The request was not sent"
            )
        )
    var boundary = prefix_dev_upload_boundary(f.identity.sha256_hex)
    var body = encode_prefix_dev_form(f, boundary)
    var req = PkgRequest(
        HTTP_METHOD_POST,
        repo_host(f.coordinate.repo),
        String(PREFIX_DEV_UPLOAD_PATH) + prefix_dev_channel(f.coordinate.repo),
    )
    req.with_header(
        String("Content-Type"),
        String("multipart/form-data; boundary=") + boundary,
    )
    req.with_header(String("Accept"), String("application/json"))
    req.with_authorization(authorization)
    req.body = body^
    return req^


def _outcome(
    kind: Int, status: Int, body: List[UInt8], authorization: String
) -> UploadOutcome:
    var detail = (
        upload_kind_name(kind)
        + String(" (HTTP ")
        + String(status)
        + String("): ")
        + excerpt_unless_echoes(body, authorization)
    )
    return UploadOutcome(kind, status, withhold_if_echoes(detail^, authorization))


def classify_prefix_dev_upload(
    status: Int, body: List[UInt8], authorization: String
) -> UploadOutcome:
    """What a prefix.dev answer to the upload means (see the file header)."""
    if status >= 200 and status < 300:
        return _outcome(UPLOAD_CREATED, status, body, authorization)
    if status == 409:
        return _outcome(UPLOAD_DUPLICATE_REFUSED, status, body, authorization)
    if status == 401 or status == 403:
        return _outcome(UPLOAD_AUTH_REFUSED, status, body, authorization)
    if status == 429:
        return _outcome(UPLOAD_RATE_LIMITED, status, body, authorization)
    if status >= 500:
        return _outcome(UPLOAD_UNKNOWN, status, body, authorization)
    return _outcome(UPLOAD_REJECTED, status, body, authorization)


def _subdir_path(c: PackageCoordinate) raises -> String:
    return repo_path(c.repo) + String("/") + c.subdir + String("/")


struct PrefixDevRegistry(Deinitable):
    """The prefix.dev conda arm. Stateless: each method takes the transport
    and the credential by `mut` reference, so `RegistrySet` keeps ownership of
    both."""

    @staticmethod
    def upload[T: PkgTransport, C: RegistryCredential](
        mut transport: T, mut cred: C, f: PackageFile
    ) raises -> UploadOutcome:
        """POST the upload form. RAISES only for a local fault before the
        request; a transport fault is UNKNOWN."""
        refuse_malformed_conda_coordinate(f.coordinate)
        refuse_name_not_the_files(f.coordinate)
        var authorization = cred.authorization(
            SURFACE_PREFIX_DEV, repo_host(f.coordinate.repo)
        )
        var req = build_prefix_dev_upload_request(f, authorization)
        var ex = try_exchange(transport, req)
        if not ex.ok:
            return unknown_after_transport_fault(ex.fault, authorization)
        return classify_prefix_dev_upload(
            ex.response.status, ex.response.body, authorization
        )

    @staticmethod
    def read_back[T: PkgTransport, C: RegistryCredential](
        mut transport: T, mut cred: C, c: PackageCoordinate
    ) raises -> ReadBack:
        """What the subdir's repodata says it holds under `c.file_name`."""
        refuse_malformed_conda_coordinate(c)
        var authorization = cred.authorization(SURFACE_PREFIX_DEV, repo_host(c.repo))
        var got = get_following_redirects(
            transport,
            repo_host(c.repo),
            _subdir_path(c) + String("repodata.json"),
            String("application/json"),
            authorization,
        )
        var e = classify_repodata_answer(got, c.file_name, authorization)
        if e.kind == READ_PRESENT:
            return ReadBack(
                READ_PRESENT,
                e.status,
                ContentIdentity.of_sha256_hex(e.sha256_hex.copy()),
                String(""),
            )
        return ReadBack(e.kind, e.status, ContentIdentity.none(), e.detail.copy())

    @staticmethod
    def fetch[T: PkgTransport, C: RegistryCredential](
        mut transport: T, mut cred: C, c: PackageCoordinate
    ) raises -> Fetched:
        """The bytes the channel serves for `c.file_name`. The caller hashes
        them: a fetch never vouches for its own content."""
        refuse_malformed_conda_coordinate(c)
        var authorization = cred.authorization(SURFACE_PREFIX_DEV, repo_host(c.repo))
        var got = get_following_redirects(
            transport,
            repo_host(c.repo),
            _subdir_path(c) + c.file_name,
            String(""),
            authorization,
        )
        if not got.ok:
            return Fetched(READ_UNKNOWN, 0, List[UInt8](), got.detail.copy())
        var kind = read_kind_of_fetch_status(got.response.status)
        if kind == READ_PRESENT:
            return Fetched(READ_PRESENT, 200, got.response.body.copy(), String(""))
        return Fetched(
            kind,
            got.response.status,
            List[UInt8](),
            withhold_if_echoes(
                String("file GET answered HTTP ")
                + String(got.response.status)
                + String(": ")
                + excerpt_unless_echoes(got.response.body, authorization),
                authorization,
            ),
        )

    @staticmethod
    def package_names[T: PkgTransport, C: RegistryCredential](
        mut transport: T, mut cred: C, repo: String, subdir: String
    ) raises -> NameListing:
        """The package names `repo`'s `subdir` holds a file under, from its
        repodata. RAISES only for a local fault (a malformed repo or subdir)
        before the request; every server answer is a kind."""
        _ = prefix_dev_channel(repo)
        refuse_malformed_subdir_segment(subdir)
        var authorization = cred.authorization(SURFACE_PREFIX_DEV, repo_host(repo))
        var got = get_following_redirects(
            transport,
            repo_host(repo),
            repo_path(repo) + String("/") + subdir + String("/repodata.json"),
            String("application/json"),
            authorization,
        )
        return classify_repodata_names(got, authorization)
