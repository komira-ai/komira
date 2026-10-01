# =============================================================================
# komira_objectstore/objectstore_uri.mojo — full-URI parser
# =============================================================================
#
# Parses a user-facing object-storage URI into `(scheme, authority, Path)`.
# The user-facing URI is what `ctx.read_parquet("s3://bucket/key")` accepts;
# the backend later builds a fully-resolved HTTPS request URL FROM the
# `(authority, Path)` plus the endpoint (the HTTP client's parsed `Url`
# type is a different concept).
#
# Schemes supported (a pure parser, no network):
#   s3       — AWS S3
#   gs       — Google Cloud Storage
#   az       — Azure Blob (canonical)
#   abfs     — Azure DataLakeGen2 (alias for az; same authority shape)
#   file     — local filesystem (file:///abs/path or file://host/abs/path)
#
# Authority semantics:
#   s3://bucket/key     -> authority = "bucket"
#   gs://bucket/key     -> authority = "bucket"
#   az://account/container/blob  -> authority = "account" (container/blob is Path)
#   abfs://account/container/blob -> same as az
#   file:///abs/path    -> authority = "" (empty host); Path = "abs/path"
#   file://host/abs/path -> authority = "host"; Path = "abs/path"
#
# Encapsulation discipline:
#   * ZERO UnsafePointer anywhere.
#   * ZERO wildcard origins.
#   * Internal byte ops use `s.as_bytes()` (`Span[Byte, _]`) only.
# =============================================================================

from komira_objectstore.path import Path


# -----------------------------------------------------------------------------
# Scheme tagged enum (Movable+Copyable POD).
# -----------------------------------------------------------------------------

comptime SCHEME_S3 = UInt8(1)
comptime SCHEME_GS = UInt8(2)
comptime SCHEME_AZ = UInt8(3)
comptime SCHEME_ABFS = UInt8(4)
comptime SCHEME_FILE = UInt8(5)


@fieldwise_init
struct Scheme(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Tagged URI scheme. Use the `SCHEME_*` aliases for arms."""

    var tag: UInt8

    @always_inline
    def is_s3(self) -> Bool:
        return self.tag == SCHEME_S3

    @always_inline
    def is_gs(self) -> Bool:
        return self.tag == SCHEME_GS

    @always_inline
    def is_az(self) -> Bool:
        return self.tag == SCHEME_AZ

    @always_inline
    def is_abfs(self) -> Bool:
        return self.tag == SCHEME_ABFS

    @always_inline
    def is_file(self) -> Bool:
        return self.tag == SCHEME_FILE

    @always_inline
    def is_remote(self) -> Bool:
        """True for any cloud scheme (everything except file://)."""
        return self.tag != SCHEME_FILE

    def _write_name[W: Writer](self, mut writer: W):
        """WRITE what `name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

        The arms live here so no string constant is ever SELECTED and
        returned. A literal-returning ladder lowers to two parallel
        (pointer, length) constant arrays whose two call-site references
        an `--emit shared-lib` link can bind INDEPENDENTLY; a shared
        library has been seen to bind such a pair CROSSED, which crashed
        the host interpreter."""
        if self.tag == SCHEME_S3:
            writer.write(String("s3"))
            return
        if self.tag == SCHEME_GS:
            writer.write(String("gs"))
            return
        if self.tag == SCHEME_AZ:
            writer.write(String("az"))
            return
        if self.tag == SCHEME_ABFS:
            writer.write(String("abfs"))
            return
        if self.tag == SCHEME_FILE:
            writer.write(String("file"))
            return
        writer.write(String("unknown"))
        return

    def name(self) -> String:
        var out = String()
        self._write_name(out)
        return out^

    def __eq__(self, other: Scheme) -> Bool:
        return self.tag == other.tag


# -----------------------------------------------------------------------------
# Parsed URI: (scheme, authority, path)
# -----------------------------------------------------------------------------


@fieldwise_init
struct ObjectStoreUri(Movable, Deinitable):
    """A parsed object-storage URI.

    Field layout:
      var scheme: Scheme        — one of the SCHEME_* arms
      var authority: String     — bucket / account / host (may be empty for file://)
      var path: Path            — normalized Path (may be root for `s3://bucket`)
    """

    var scheme: Scheme
    var authority: String
    var path: Path


# -----------------------------------------------------------------------------
# parse() — the entry point
# -----------------------------------------------------------------------------


def parse(uri: String) raises -> ObjectStoreUri:
    """Parse a full object-storage URI.

    Accepts:
      s3://bucket/a/b/c.parquet
      s3://bucket/
      s3://bucket
      gs://bucket/key
      az://account/container/blob
      abfs://account/container/blob
      file:///abs/path
      file://host/abs/path

    Raises on:
      * unknown scheme
      * missing `://`
      * missing authority on a cloud URI (e.g. `s3:///key` — empty bucket)
      * `.` / `..` segments in the path (Path.parse rejects these)
    """
    var bs = uri.as_bytes()
    var n = len(bs)
    if n == 0:
        raise Error("ObjectStoreUri: empty URI")

    # Locate `://`.
    var sep = _find_scheme_sep(bs)
    if sep < 0:
        raise Error("ObjectStoreUri: missing '://' in: " + uri)

    # Extract scheme as ASCII string from bytes[0, sep).
    var scheme_str = _bytes_to_str(bs, 0, sep)
    var scheme = _parse_scheme(scheme_str)

    # `rest` starts after `://`.
    var rest_start = sep + 3

    # Split authority vs path on the first `/` in `rest`.
    var slash = UInt8(ord("/"))
    var slash_pos = rest_start
    while slash_pos < n and bs[slash_pos] != slash:
        slash_pos += 1

    var authority: String
    var path_str: String
    if slash_pos >= n:
        # No `/` in rest — everything is authority, path is root.
        authority = _bytes_to_str(bs, rest_start, n)
        path_str = String("")
    else:
        authority = _bytes_to_str(bs, rest_start, slash_pos)
        # Preserve the path WITH its leading slash so Path.parse strips it
        # (and trailing-slash semantics flow through).
        path_str = _bytes_to_str(bs, slash_pos, n)

    # Cloud URIs require a non-empty authority. file:// allows empty
    # (file:///abs/path is the standard "no host" form).
    if scheme.is_remote() and authority.byte_length() == 0:
        raise Error(
            "ObjectStoreUri: cloud URI requires non-empty authority, got: "
            + uri
        )

    var p = Path.parse(path_str)
    return ObjectStoreUri(scheme, authority^, p^)


# -----------------------------------------------------------------------------
# Private helpers (no UnsafePointer; byte-spans only)
# -----------------------------------------------------------------------------


def _find_scheme_sep[
    bs_origin: Origin[mut=False]
](bs: Span[Byte, bs_origin]) -> Int:
    """Return the index of the `:` in `://`, or -1 if not present."""
    var n = len(bs)
    var colon = UInt8(ord(":"))
    var slash = UInt8(ord("/"))
    var i = 0
    while i + 2 < n:
        if bs[i] == colon and bs[i + 1] == slash and bs[i + 2] == slash:
            return i
        i += 1
    return -1


def _bytes_to_str[
    bs_origin: Origin[mut=False]
](bs: Span[Byte, bs_origin], start: Int, end: Int) -> String:
    """Build a String from `bs[start, end)` BYTE-EXACTLY.

    ⛔ NOT `out += chr(Int(bs[i]))`, and ⛔ NOT named `_bytes_to_ascii`.

    A URI's PATH component is the customer's OBJECT KEY and was never
    ASCII-only — `s3://bucket/données/x.parquet` is a legal key. `chr` maps a
    CODE POINT to its UTF-8 ENCODING, so a stored byte >= 0x80 was not
    reproduced but RE-ENCODED into two (`é` C3 A9 -> C3 83 C2 A9). A mojibaked
    key sent to the SDK's cloud read and write paths makes a read 404 on an
    object that exists and a write land at a key nobody asked for.

    ⚠ The name says BYTES on purpose: a function named for ASCII invites a
    `chr`-based copy.
    """
    var out_bytes = List[UInt8]()
    for i in range(start, end):
        out_bytes.append(bs[i])
    return String(StringSlice(unsafe_from_utf8=Span(out_bytes)))


def _parse_scheme(s: String) raises -> Scheme:
    """Map a scheme string to a Scheme tag. Raises on unknown scheme."""
    if s == "s3":
        return Scheme(SCHEME_S3)
    if s == "gs":
        return Scheme(SCHEME_GS)
    if s == "az":
        return Scheme(SCHEME_AZ)
    if s == "abfs":
        return Scheme(SCHEME_ABFS)
    if s == "file":
        return Scheme(SCHEME_FILE)
    raise Error(
        "ObjectStoreUri: unsupported scheme '"
        + s
        + "' (supported: s3, gs, az, abfs, file)"
    )
