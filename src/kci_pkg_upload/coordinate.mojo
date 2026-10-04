# =============================================================================
# src/kci_pkg_upload/coordinate.mojo — WHERE a package file lives
#   (`PackageCoordinate`), WHAT is uploaded (`PackageFile`), and the substrate
#   ordinals the registry dispatch keys on.
# =============================================================================
#
# ─── THE SUBSTRATE ORDINALS ─────────────────────────────────────────────────
# A substrate names the registry protocol a file is placed on (public PyPI, a
# prefix.dev conda channel, ...), and `RegistrySet` dispatches on it. The
# ordinals are this package's own: a caller maps a channel's artifact type and
# location to one of them, and any other number is refused by `RegistrySet` as
# having no arm. Values are never reused for a different protocol.
#
# ─── WHY THE FILE CARRIES ITS OWN IDENTITY ──────────────────────────────────
# `PackageFile` computes its `ContentIdentity` from its bytes in its only
# constructor. An identity supplied beside the bytes could disagree with them,
# and every presence and read-back comparison would then be answering a
# question about some other file.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from .identity import ContentIdentity, content_identity_of


# The substrates this package has an arm for (see the header).
comptime SUBSTRATE_PUBLIC_PYPI: Int = 4
comptime SUBSTRATE_PREFIX_DEV_CONDA: Int = 6


def substrate_name(substrate: Int) -> String:
    if substrate == SUBSTRATE_PUBLIC_PYPI:
        return String("PUBLIC_PYPI")
    if substrate == SUBSTRATE_PREFIX_DEV_CONDA:
        return String("PREFIX_DEV_CONDA")
    return String("SUBSTRATE(") + String(substrate) + String(")")


struct PackageCoordinate(Copyable, Movable, Deinitable):
    """One file's address on one registry.

      substrate    — a substrate ordinal (see the header).
      repo         — HOST + PATH with no scheme and no trailing slash, e.g.
                     `pypi.org` / `test.pypi.org` for a warehouse,
                     `<host>/<namespace>` or `<host>/<namespace>/<channel>`
                     for a prefix.dev conda channel.
      distribution — the distribution name as the producer wrote it.
      version      — the version string.
      subdir       — `linux-64` | `osx-arm64` | `noarch`. A conda channel
                     stores the file under it; a python registry is not sent
                     it (the wheel's platform tag carries it there).
      file_name    — the exact file name the registry sees.

    Layout: an Int and owned Strings. No pointer field."""

    var substrate: Int
    var repo: String
    var distribution: String
    var version: String
    var subdir: String
    var file_name: String

    def __init__(
        out self,
        substrate: Int,
        var repo: String,
        var distribution: String,
        var version: String,
        var subdir: String,
        var file_name: String,
    ):
        self.substrate = substrate
        self.repo = repo^
        self.distribution = distribution^
        self.version = version^
        self.subdir = subdir^
        self.file_name = file_name^

    def describe(self) -> String:
        return (
            self.repo
            + String(" ")
            + self.subdir
            + String("/")
            + self.file_name
            + String(" (")
            + substrate_name(self.substrate)
            + String(")")
        )


struct PackageFile(Movable, Deinitable):
    """The bytes to upload, their coordinate, OUR identity of them, and the
    upload metadata.

    `upload_meta` is the exact text of the wheel's `.dist-info/METADATA`,
    supplied by the producer of the wheel, so the client needs no archive
    reader. The legacy upload form repeats its fields (`core_metadata.mojo`).
    EMPTY for an artifact whose protocol sends no metadata form.

    Layout: owned values only. No pointer field."""

    var coordinate: PackageCoordinate
    var bytes: List[UInt8]
    var identity: ContentIdentity
    var upload_meta: String

    def __init__(
        out self,
        var coordinate: PackageCoordinate,
        var bytes: List[UInt8],
        var upload_meta: String,
    ):
        self.identity = content_identity_of(Span(bytes))
        self.coordinate = coordinate^
        self.bytes = bytes^
        self.upload_meta = upload_meta^


def normalize_distribution_name(name: String) -> String:
    """PEP 503 normalisation: lowercase, and every run of `-`, `_`, `.`
    collapsed to one `-`. The simple index and the JSON API are addressed by
    this form; `kci_pkg_upload` and `Kci.Pkg-Upload` are one project."""
    var out = String("")
    var b = name.as_bytes()
    var in_run = False
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("-")) or c == UInt8(ord("_")) or c == UInt8(ord(".")):
            if not in_run:
                out += String("-")
            in_run = True
            continue
        in_run = False
        if c >= UInt8(65) and c <= UInt8(90):
            c += UInt8(32)
        out += chr(Int(c))
    return out^


def repo_host(repo: String) raises -> String:
    """The host part of a coordinate's `repo` (everything before the first
    `/`). RAISES on a scheme, an empty host, a port, or whitespace — a local
    fault, before any request is sent."""
    _refuse_malformed_repo(repo)
    var slash = repo.find(String("/"))
    if slash < 0:
        return repo.copy()
    return String(repo[byte=:slash])


def repo_path(repo: String) raises -> String:
    """The path part of a coordinate's `repo`, WITH its leading `/` and WITHOUT
    a trailing one, or EMPTY for a bare host."""
    _refuse_malformed_repo(repo)
    var slash = repo.find(String("/"))
    if slash < 0:
        return String("")
    return String(repo[byte=slash:])


def _refuse_malformed_repo(repo: String) raises:
    if repo.byte_length() == 0:
        raise Error("kci_pkg_upload: a coordinate names an EMPTY repo")
    if repo.find(String("://")) >= 0:
        raise Error(
            String("kci_pkg_upload: repo '")
            + repo
            + String(
                "' carries a scheme. A coordinate's repo is HOST/PATH; every"
                " registry is reached over HTTPS, and a plaintext one is not"
                " supported"
            )
        )
    if repo.startswith(String("/")):
        raise Error(
            String("kci_pkg_upload: repo '")
            + repo
            + String("' has an EMPTY host")
        )
    if repo.endswith(String("/")):
        raise Error(
            String("kci_pkg_upload: repo '")
            + repo
            + String("' ends in '/'; write it without the trailing slash")
        )
    var b = repo.as_bytes()
    var slash = repo.find(String("/"))
    var host_end = slash if slash >= 0 else len(b)
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord(" ")) or c == UInt8(ord("\t")) or c == UInt8(
            ord("\n")
        ) or c == UInt8(ord("\r")):
            raise Error(
                String("kci_pkg_upload: repo '")
                + repo
                + String("' contains whitespace")
            )
        if i < host_end and c == UInt8(ord(":")):
            raise Error(
                String("kci_pkg_upload: repo '")
                + repo
                + String(
                    "' names a PORT. Every registry is HTTPS on 443; a port"
                    " is not supported"
                )
            )


def refuse_malformed_file_name(c: PackageCoordinate) raises:
    """A file name is one path segment: never empty, never a `/` or `\\`.
    RAISES (a local fault) naming the coordinate."""
    if c.file_name.byte_length() == 0:
        raise Error(
            String("kci_pkg_upload: EMPTY file name for ") + c.describe()
        )
    if c.file_name.find(String("/")) >= 0 or c.file_name.find(String("\\")) >= 0:
        raise Error(
            String("kci_pkg_upload: file name '")
            + c.file_name
            + String("' is not one path segment")
        )
