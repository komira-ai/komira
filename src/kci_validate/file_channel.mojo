# =============================================================================
# src/kci_validate/file_channel.mojo -- a LOCAL channel: the reads of check 1
#   answered from a directory on this machine, so a release can be validated
#   BEFORE it is published (kci run --channel file:///<dir>).
# =============================================================================
#
# `FileChannelTransport[T]` is a `PkgTransport` over another one (`inner`,
# the HTTPS transport in the kci binary). A request with NO host is a read of
# a `file:///` channel (channel_index.mojo's `ChannelUrl` gives a file://
# location the host ""): a GET of `<path>` answers
#
#   200 with the file's bytes   a regular file at that absolute path
#   404                         nothing there
#
# and it RAISES (a transport fault, which every caller turns into a row)
# for any other method, a path that is not absolute or holds a `.` or `..`
# segment, and a path that names something other than a regular file. A
# request WITH a host goes to `inner` unchanged, so the hosts the network
# probe asks and the compiler channel are read exactly as without a local
# channel. An https:// location always has a host, so nothing published is
# ever read from the disk.
#
# The directory is what `komira_pack conda-index` writes from a release
# directory (`<subdir>/repodata.json` and the `.conda` files beside it).
# Which runs may name one is kci_cli's (a validation-only run, never under
# GitHub Actions); this file only reads.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os.path import exists, isfile

from komira_http_core.codec.types import HTTP_METHOD_GET

from kci_pkg_upload import PkgRequest, PkgResponse, PkgTransport

from .channel_index import has_dot_segment


struct FileChannelTransport[T: PkgTransport](PkgTransport, Deinitable):
    """A host-less GET is a file read; anything else goes to `inner` (file
    header).

    Layout: the inner transport, owned. No pointer field."""

    var inner: Self.T

    def __init__(out self, var inner: Self.T):
        self.inner = inner^

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        if req.host.byte_length() > 0:
            return self.inner.exchange(req)
        if req.method != HTTP_METHOD_GET:
            raise Error(String("a local channel is only read: ") + req.path + String(" was not a GET"))
        if not req.path.startswith(String("/")) or has_dot_segment(req.path):
            raise Error(
                String("a local channel read of '") + req.path
                + String("' is not an absolute path without `.` or `..` segments")
            )
        if not exists(req.path):
            return PkgResponse(404)
        if not isfile(req.path):
            raise Error(String("a local channel read of '") + req.path + String("' is not a regular file"))
        var f = open(req.path, "r")
        var body = f.read_bytes()
        f.close()
        var r = PkgResponse(200)
        r.with_body(body^)
        return r^
