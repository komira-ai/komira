# =============================================================================
# komira_source_url/source_url.mojo -- the source a URL names, by its prefix
# =============================================================================
#
# A logical plan names the exact source each scan reads: its scan node
# carries komira_plan_expr's `FsDescriptorPod`, whose scheme code
# (`FS_SCHEME_FILE`, `FS_SCHEME_S3`, `FS_SCHEME_GCS`, `FS_SCHEME_AZURE`) says
# which file system serves it. A surface (SQL, a DataFrame API) takes a URL
# from its user and has to pick that code before it builds the plan; this is
# the one mapping every surface calls for it, so two surfaces never disagree
# about what `abfss://` or a bare path means. Once the plan names the code,
# a compiled physical plan is built over exactly that one file system.
#
# THE PREFIXES (`source_scheme_for_url`; the scheme compared ASCII
# case-insensitively, RFC 3986 section 3.1):
#
#   a bare path, relative or absolute               FS_SCHEME_FILE
#   file://                                         FS_SCHEME_FILE
#   s3://  s3a://                                   FS_SCHEME_S3
#   gs://  gcs://                                   FS_SCHEME_GCS
#   az://  abfs://  abfss://                        FS_SCHEME_AZURE
#   https://<account>.blob.core.windows.net/...     FS_SCHEME_AZURE
#
# A scheme is what precedes the first "://" when it is scheme-shaped (RFC
# 3986 section 3.1: a letter, then letters, digits, '+', '-' or '.'). A
# string with no "://", or whose text before it is not scheme-shaped
# ("/data/x://y"), is a bare path. Text before it that is empty is refused.
#
# The https:// row is the Blob service's resource URI as komira_azure_blob's
# `parse_azure_url` reads it: the authority is the host alone, with no user
# information or port, and the host is a blob one. A `.dfs.` host is named
# through abfs[s]://, which parse_azure_url reads on either host.
#
# Anything else is refused: another scheme, an https:// URL on any other
# host (a `.dfs.` one included) or with user information or a port on an
# Azure Blob host, and every http:// URL. A plaintext endpoint (an S3 or Azure
# emulator) is not something a prefix can name: the surface that holds that
# endpoint in its configuration picks the source for it. A refusal names the
# scheme, or for https:// the host, and never echoes the rest of the URL, so
# a credential pasted into the user information or a query string is not
# repeated in an error.
#
# Only the prefix is read here. What follows it is the source's own syntax
# and is parsed by the package that owns that source: komira_azure_blob's
# `parse_azure_url` for the Azure forms, komira_objectstore's URI parser for
# a bucket and key, komira_fs for a local path.
#
# `check_source_scheme` is the other direction: a scheme code a plan already
# carries (from a descriptor, or off the wire) is one of the four codes above,
# or it is refused naming the descriptor.
#
# This package is for surfaces. A physical-plan package does not depend on it:
# by the time a plan is compiled its source is named.
#
# Nothing here reads the environment. No UnsafePointer, no wildcard origin.
# =============================================================================

from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)


comptime _AZURE_BLOB_SUFFIX = ".blob.core.windows.net"


def _ascii_lower(s: String) -> String:
    var out = String("")
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var c = Int(bs[i])
        if c >= ord("A") and c <= ord("Z"):
            c += 32
        out += chr(c)
    return out^


def _slice(s: String, start: Int, end: Int) -> String:
    return String(s[byte=start:end])


def _is_scheme(s: String) -> Bool:
    """RFC 3986 section 3.1: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )."""
    var bs = s.as_bytes()
    if len(bs) == 0:
        return False
    for i in range(len(bs)):
        var c = bs[i]
        var alpha = (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or (
            c >= UInt8(ord("A")) and c <= UInt8(ord("Z"))
        )
        if alpha:
            continue
        if i == 0:
            return False
        var digit = c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        if not (
            digit
            or c == UInt8(ord("+"))
            or c == UInt8(ord("-"))
            or c == UInt8(ord("."))
        ):
            return False
    return True


def _https_authority(rest: String) -> String:
    """The authority of an https:// URL's remainder `rest` (what follows
    `://`): everything up to the first `/`, `?` or `#`."""
    var bs = rest.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        if c == UInt8(ord("/")) or c == UInt8(ord("?")) or c == UInt8(ord("#")):
            return _slice(rest, 0, i)
    return rest


def _host_of(authority: String) -> String:
    """`authority` without its user information (up to the last `@`) or
    port, ASCII lowercase."""
    var bs = authority.as_bytes()
    var start = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("@")):
            start = i + 1
    var host = _slice(authority, start, len(bs))
    var colon = host.find(":")
    if colon >= 0:
        host = _slice(host, 0, colon)
    return _ascii_lower(host)


def _is_azure_blob_host(host: String) -> Bool:
    """`<account>.blob.core.windows.net`: one non-empty account label with no
    dot before the suffix, the only host parse_azure_url reads over https."""
    if not host.endswith(_AZURE_BLOB_SUFFIX):
        return False
    var n = host.byte_length() - _AZURE_BLOB_SUFFIX.byte_length()
    if n <= 0:
        return False
    return host.find(".") == n


def source_scheme_for_url(url: String) raises -> UInt8:
    """The `FS_SCHEME_*` code of the source `url` names, by its prefix
    (module header for the table). Raises `source_url: ...` for an empty URL,
    an empty scheme, and every prefix the table does not list, naming the
    scheme (or the https:// host) and nothing else of the URL. Text before
    "://" that is not scheme-shaped makes `url` a bare path."""
    if url.byte_length() == 0:
        raise Error("source_url: an empty URL names no source")
    var sep = url.find("://")
    if sep < 0:
        return FS_SCHEME_FILE
    if sep == 0:
        raise Error("source_url: a URL's scheme is empty")
    var prefix = _slice(url, 0, sep)
    if not _is_scheme(prefix):
        return FS_SCHEME_FILE
    var scheme = _ascii_lower(prefix)
    if scheme == "file":
        return FS_SCHEME_FILE
    if scheme == "s3" or scheme == "s3a":
        return FS_SCHEME_S3
    if scheme == "gs" or scheme == "gcs":
        return FS_SCHEME_GCS
    if scheme == "az" or scheme == "abfs" or scheme == "abfss":
        return FS_SCHEME_AZURE
    if scheme == "https":
        var authority = _https_authority(_slice(url, sep + 3, url.byte_length()))
        var host = _host_of(authority)
        if _is_azure_blob_host(host):
            if _ascii_lower(authority) == host:
                return FS_SCHEME_AZURE
            raise Error(
                "source_url: an Azure Blob https:// URL's authority is the host"
                " alone, <account>.blob.core.windows.net, with no user"
                " information or port"
            )
        raise Error(
            "source_url: no source serves https:// URLs on host '"
            + host
            + "' (an Azure Blob URL's host is <account>.blob.core.windows.net;"
            " abfs[s]:// names a .dfs. host)"
        )
    if scheme == "http":
        raise Error(
            "source_url: an http:// URL names no source by its prefix; a"
            " plaintext endpoint is the surface's configuration"
        )
    raise Error("source_url: no source serves '" + scheme + "://' URLs")


def _where(bucket: String, node_id: Int) -> String:
    return "bucket '" + bucket + "', node " + String(node_id)


def check_source_scheme(scheme: UInt8, bucket: String, node_id: Int) raises -> UInt8:
    """`scheme` when it is one of the codes `source_scheme_for_url` returns
    (`FS_SCHEME_FILE`, `FS_SCHEME_S3`, `FS_SCHEME_GCS`, `FS_SCHEME_AZURE`).
    `bucket` and `node_id` only name the descriptor in the error.

    Raises `source_url: unknown file system scheme <code> (bucket '<bucket>',
    node <node_id>)` for any other code."""
    if (
        scheme == FS_SCHEME_FILE
        or scheme == FS_SCHEME_S3
        or scheme == FS_SCHEME_GCS
        or scheme == FS_SCHEME_AZURE
    ):
        return scheme
    raise Error(
        "source_url: unknown file system scheme "
        + String(Int(scheme))
        + " ("
        + _where(bucket, node_id)
        + ")"
    )


def check_source_descriptor(desc: FsDescriptorPod) raises -> UInt8:
    """`check_source_scheme` for a komira_plan_expr descriptor."""
    return check_source_scheme(desc.scheme, desc.bucket, desc.node_id)
