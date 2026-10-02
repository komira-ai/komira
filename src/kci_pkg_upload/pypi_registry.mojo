# =============================================================================
# src/kci_pkg_upload/pypi_registry.mojo — `PypiLegacyRegistry`: a
#   warehouse (pypi.org, test.pypi.org) over the legacy upload and the JSON
#   API.
# =============================================================================
#
#   upload     POST https://upload.pypi.org/legacy/        (pypi.org)
#              POST https://<host><path>/legacy/            (any other warehouse,
#                                                            e.g. test.pypi.org)
#              surface PYPI_UPLOAD; the form is `legacy_upload.mojo`'s.
#   read_back  GET https://<host><path>/pypi/<normalized>/<version>/json,
#              ANONYMOUS — the file's `digests.sha256`.
#   fetch      the `url` that same listing gives (files.pythonhosted.org for
#              pypi.org), anonymous, redirects followed.
#
# ⚠ The JSON API is served through a CDN and can lag an upload. A fresh upload
# that reads back ABSENT is the idempotency table's "re-probe" row, never a
# failure the client decides on its own.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_http.client.redirect_policy import REDIRECT_RESOLVED, RedirectTarget

from .coordinate import (
    PackageCoordinate,
    PackageFile,
    normalize_distribution_name,
    refuse_malformed_file_name,
    repo_host,
    repo_path,
)
from .credential import SURFACE_PYPI_UPLOAD, RegistryCredential
from .http_read import get_following_redirects, resolve_index_href
from .identity import ContentIdentity
from .index_lookup import IndexEntry, classify_index_answer
from .legacy_upload import (
    build_legacy_upload_request,
    classify_warehouse_upload,
    unknown_after_transport_fault,
)
from .outcome import (
    READ_ABSENT,
    READ_AUTH_REFUSED,
    READ_PRESENT,
    READ_RATE_LIMITED,
    READ_UNKNOWN,
    Fetched,
    ReadBack,
    UploadOutcome,
    excerpt_unless_echoes,
    withhold_if_echoes,
)
from .transport import PkgTransport, try_exchange


comptime PYPI_ORG: String = "pypi.org"
comptime PYPI_UPLOAD_HOST: String = "upload.pypi.org"


def pypi_upload_target(repo: String) raises -> RedirectTarget:
    """Where a warehouse takes the legacy upload: `upload.pypi.org/legacy/`
    for `pypi.org`, `<host><path>/legacy/` for any other (TestPyPI's is
    `test.pypi.org/legacy/`). RAISES on a malformed repo."""
    var host = repo_host(repo)
    var path = repo_path(repo)
    if host == String(PYPI_ORG) and path.byte_length() == 0:
        return RedirectTarget(REDIRECT_RESOLVED, String(PYPI_UPLOAD_HOST), String("/legacy/"))
    return RedirectTarget(REDIRECT_RESOLVED, host^, path + String("/legacy/"))


def pypi_json_api_path(c: PackageCoordinate) raises -> String:
    return (
        repo_path(c.repo)
        + String("/pypi/")
        + normalize_distribution_name(c.distribution)
        + String("/")
        + c.version
        + String("/json")
    )


def read_kind_of_fetch_status(status: Int) -> Int:
    if status == 200:
        return READ_PRESENT
    if status == 404 or status == 410:
        return READ_ABSENT
    if status == 401 or status == 403:
        return READ_AUTH_REFUSED
    if status == 429:
        return READ_RATE_LIMITED
    return READ_UNKNOWN


struct PypiLegacyRegistry(Deinitable):
    """The warehouse protocol arm. Stateless: each method takes the transport
    and the credential by `mut` reference, so `RegistrySet` keeps ownership of
    both."""

    @staticmethod
    def upload[T: PkgTransport, C: RegistryCredential](
        mut transport: T, mut cred: C, f: PackageFile
    ) raises -> UploadOutcome:
        """POST the legacy upload. RAISES only for a local fault before the
        request: a malformed coordinate or METADATA, or a credential that
        refuses `PYPI_UPLOAD` or presents none for it. A transport fault is
        UNKNOWN."""
        refuse_malformed_file_name(f.coordinate)
        var target = pypi_upload_target(f.coordinate.repo)
        # The index the coordinate names (`pypi.org`), not its upload host
        # (`upload.pypi.org`): a credential is issued by, and bound to, the
        # index.
        var authorization = cred.authorization(
            SURFACE_PYPI_UPLOAD, repo_host(f.coordinate.repo)
        )
        if authorization.byte_length() == 0:
            raise Error(
                String("kci_pkg_upload: an upload to ")
                + f.coordinate.repo
                + String(
                    " needs a credential, and the one given presents none for"
                    " PYPI_UPLOAD. The request was not sent"
                )
            )
        var req = build_legacy_upload_request(
            target.host, target.path, f, authorization
        )
        var ex = try_exchange(transport, req)
        if not ex.ok:
            return unknown_after_transport_fault(ex.fault, authorization)
        return classify_warehouse_upload(
            ex.response.status, ex.response.body, authorization
        )

    @staticmethod
    def lookup[T: PkgTransport](mut transport: T, c: PackageCoordinate) raises -> IndexEntry:
        refuse_malformed_file_name(c)
        var got = get_following_redirects(
            transport,
            repo_host(c.repo),
            pypi_json_api_path(c),
            String("application/json"),
            String(""),
        )
        return classify_index_answer(
            got, c.file_name, String("urls"), String("digests"), String(""), String("")
        )

    @staticmethod
    def read_back[T: PkgTransport, C: RegistryCredential](
        mut transport: T, mut cred: C, c: PackageCoordinate
    ) raises -> ReadBack:
        """What the JSON API says the release holds under `c.file_name`.
        Anonymous: the credential is never asked for a public read."""
        var e = PypiLegacyRegistry.lookup(transport, c)
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
        """The bytes the index serves for `c.file_name`, via the URL its JSON
        listing gives. Anonymous."""
        var e = PypiLegacyRegistry.lookup(transport, c)
        if e.kind != READ_PRESENT:
            return Fetched(e.kind, e.status, List[UInt8](), e.detail.copy())
        return fetch_listed_file(transport, e, String(""), String(""))


def fetch_listed_file[T: PkgTransport](
    mut transport: T,
    e: IndexEntry,
    index_host: String,
    authorization: String,
) -> Fetched:
    """GET the file an index entry lists. `authorization` (EMPTY = anonymous)
    is carried only when the file's host IS `index_host` — a file served from
    a CDN or a signed storage URL never receives the index credential."""
    if e.url.byte_length() == 0:
        return Fetched(
            READ_UNKNOWN,
            e.status,
            List[UInt8](),
            String("the index lists the file with no URL"),
        )
    var t = resolve_index_href(e.page_host, e.page_path, e.url)
    if not t.is_resolved():
        return Fetched(
            READ_UNKNOWN,
            e.status,
            List[UInt8](),
            String("the index's file URL cannot be followed: ") + e.url,
        )
    var auth = String("")
    if index_host.byte_length() > 0 and t.host == index_host:
        auth = authorization.copy()
    var got = get_following_redirects(transport, t.host, t.path, String(""), auth)
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
            + excerpt_unless_echoes(got.response.body, auth),
            auth,
        ),
    )
