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
#   no "://" (a bare path, relative or absolute)  FS_SCHEME_FILE
#   file://                                         FS_SCHEME_FILE
#   s3://  s3a://                                   FS_SCHEME_S3
#   gs://  gcs://                                   FS_SCHEME_GCS
#   az://  abfs://  abfss://                        FS_SCHEME_AZURE
#   https://<account>.blob.core.windows.net/...     FS_SCHEME_AZURE
#   https://<account>.dfs.core.windows.net/...      FS_SCHEME_AZURE
#
# Anything else is refused: another scheme, an https:// URL on any other
# host, and every http:// URL. A plaintext endpoint (an S3 or Azure
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
comptime _AZURE_DFS_SUFFIX = ".dfs.core.windows.net"


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


def _https_host(rest: String) -> String:
    """The host of an https:// URL's remainder `rest` (what follows `://`):
    the authority up to the first `/`, `?` or `#`, without its user
    information (up to the last `@`) or port, ASCII lowercase."""
    var bs = rest.as_bytes()
    var end = len(bs)
    var start = 0
    for i in range(len(bs)):
        var c = bs[i]
        if c == UInt8(ord("/")) or c == UInt8(ord("?")) or c == UInt8(ord("#")):
            end = i
            break
        if c == UInt8(ord("@")):
            start = i + 1
    var authority = _slice(rest, start, end)
    var colon = authority.find(":")
    if colon >= 0:
        authority = _slice(authority, 0, colon)
    return _ascii_lower(authority)


def _is_azure_host(host: String) -> Bool:
    """`<label>.blob.core.windows.net` or `<label>.dfs.core.windows.net`, with
    a non-empty first label."""
    if host.endswith(_AZURE_BLOB_SUFFIX):
        return host.byte_length() > _AZURE_BLOB_SUFFIX.byte_length()
    if host.endswith(_AZURE_DFS_SUFFIX):
        return host.byte_length() > _AZURE_DFS_SUFFIX.byte_length()
    return False


def source_scheme_for_url(url: String) raises -> UInt8:
    """The `FS_SCHEME_*` code of the source `url` names, by its prefix
    (module header for the table). Raises `source_url: ...` for an empty URL,
    an empty scheme, and every prefix the table does not list, naming the
    scheme (or the https:// host) and nothing else of the URL."""
    if url.byte_length() == 0:
        raise Error("source_url: an empty URL names no source")
    var sep = url.find("://")
    if sep < 0:
        return FS_SCHEME_FILE
    if sep == 0:
        raise Error("source_url: a URL's scheme is empty")
    var scheme = _ascii_lower(_slice(url, 0, sep))
    if scheme == "file":
        return FS_SCHEME_FILE
    if scheme == "s3" or scheme == "s3a":
        return FS_SCHEME_S3
    if scheme == "gs" or scheme == "gcs":
        return FS_SCHEME_GCS
    if scheme == "az" or scheme == "abfs" or scheme == "abfss":
        return FS_SCHEME_AZURE
    if scheme == "https":
        var host = _https_host(_slice(url, sep + 3, url.byte_length()))
        if _is_azure_host(host):
            return FS_SCHEME_AZURE
        raise Error(
            "source_url: no source serves https:// URLs on host '"
            + host
            + "' (an Azure Blob URL's host is <account>.blob.core.windows.net"
            " or <account>.dfs.core.windows.net)"
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
