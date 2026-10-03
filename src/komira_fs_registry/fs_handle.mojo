# =============================================================================
# komira_fs_registry/fs_handle.mojo -- FsHandle, the closed sum of the
# registry's concrete file systems
# =============================================================================
#
# A plan names its sources' file systems by DESCRIPTOR (komira_plan_expr's
# `FsDescriptorPod`: a scheme code, a bucket and a node id), because the
# packages a plan lives in cannot name a concrete file system. Something above
# them has to hold the live file system each descriptor stands for, and that
# something has to be ONE type, so that a table of them is a plain list.
# `FsHandle` is that type: a hand-rolled tag and one `Optional` per arm, exactly
# one of them set, the tag saying which.
#
# THE ARMS IN THIS BUILD
#
#   tag 0  FS_SCHEME_FILE   LocalArm   komira_fs's LocalFs[NoopSink]
#   tag 1  FS_SCHEME_S3     S3Arm[C]   komira_objectstore_s3's S3Fs
#   tag 2  FS_SCHEME_GCS    (reserved: no arm in this build)
#   tag 3  FS_SCHEME_AZURE  (reserved: no arm in this build)
#
# The tag IS the scheme code: `FS_LOCAL` and `FS_S3` are defined as
# komira_plan_expr's `FS_SCHEME_FILE` and `FS_SCHEME_S3`, by name, so the two
# cannot drift, and a resolver may branch on either. The GCS and Azure codes
# stay reserved. A descriptor carrying one of them is refused by
# `fs_arm_tag_for_descriptor` with an error that names the missing arm ("no
# GCS arm in this build"), so a plan that needs an arm this build does not
# have fails where the descriptor is first resolved, not in a dispatch ladder
# that silently falls through to the local arm.
#
# THE S3 ARM'S TYPE. `S3Fs[C, T, K]` is generic over its connector, its
# credential source and its signing clock. A table of handles needs ONE type,
# so the handle fixes the credential source to `StaticCredsSource` (the
# copyable source: a clone of the file system copies it) and the clock to
# `SystemAwsClock`. The connector stays a parameter of `FsHandleOver[C]`, and
# `FsHandle` is the production handle, `FsHandleOver[S3ProdConnector]` with
# `S3ProdConnector = TlsConnector[KernelTcpConnector]`: komira_http_client
# sends an https request only over a connector whose streams speak TLS. A
# test drives the same handle over komira_http_core's ScriptedConnector
# (`FsHandleOver[ScriptedConnector]`), so the S3 arm is read through without a
# socket.
#
# `fs_handle_from_typed_fs[FS]` and `fs_is_registry_arm[FS]` answer for the
# production handle only, by TYPE EQUALITY rather than by `FS.SCHEME`: an
# `S3Fs[ScriptedConnector, ...]` advertises `SCHEME == FS_SCHEME_S3` and is
# not the arm's type, so wrapping it would be a reinterpretation, not a move.
# Such a file system gets `None`, and its caller reads it directly.
#
# Constructing a handle dials nothing: `S3Fs` builds its store on the first
# verb, and `clone()` gives the clone a store of its own, not yet built.
#
# No UnsafePointer, no wildcard origin; every arm is a value field.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_aws_core import StaticCredsSource, SystemAwsClock
from komira_fs.file_system import FileSystem
from komira_fs.local_fs import LocalFs
from komira_http_client.tls_connector import TlsConnector
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_objectstore_s3 import S3Fs
from komira_plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)


# The production S3 arm's connector: TLS over a kernel TCP dial.
comptime S3ProdConnector = TlsConnector[KernelTcpConnector]

# The local arm: komira_fs's `LocalFs` with no waker sink.
comptime LocalArm = LocalFs[NoopSink]

# The S3 arm over connector `C`, with a static credential and the process's
# wall clock for signing.
comptime S3Arm[C: Connector] = S3Fs[C, StaticCredsSource, SystemAwsClock]

# The production handle: its S3 arm speaks TLS.
comptime FsHandle = FsHandleOver[S3ProdConnector]


def _no_arm(cloud: String, desc: FsDescriptorPod) -> Error:
    return Error(
        "fs_registry: no "
        + cloud
        + " arm in this build (descriptor scheme "
        + String(Int(desc.scheme))
        + ", bucket '"
        + desc.bucket
        + "', node "
        + String(desc.node_id)
        + ")"
    )


def fs_arm_tag_for_descriptor(desc: FsDescriptorPod) raises -> UInt8:
    """The `FsHandle` tag that serves `desc`: its scheme code, when this build
    has that arm.

    Raises `fs_registry: no GCS arm in this build ...` for `FS_SCHEME_GCS`,
    `fs_registry: no Azure arm in this build ...` for `FS_SCHEME_AZURE`, and
    `fs_registry: unknown file system scheme ...` for any other code."""
    if desc.scheme == FS_SCHEME_FILE:
        return FS_SCHEME_FILE
    if desc.scheme == FS_SCHEME_S3:
        return FS_SCHEME_S3
    if desc.scheme == FS_SCHEME_GCS:
        raise _no_arm("GCS", desc)
    if desc.scheme == FS_SCHEME_AZURE:
        raise _no_arm("Azure", desc)
    raise Error(
        "fs_registry: unknown file system scheme "
        + String(Int(desc.scheme))
        + " (bucket '"
        + desc.bucket
        + "', node "
        + String(desc.node_id)
        + ")"
    )


struct FsHandleOver[C: Connector](Movable, Deinitable):
    """One live file system of the registry: a tag and the arm it names
    (module header). `FsHandle` is `FsHandleOver[S3ProdConnector]`.

        var h = FsHandle.from_local(LocalFs[NoopSink].new())
        if h.is_local():
            ref fs = h.local_ref().value()
            var file = fs.open(path)
    """

    comptime FS_LOCAL: UInt8 = FS_SCHEME_FILE
    comptime FS_S3: UInt8 = FS_SCHEME_S3

    var tag: UInt8
    var _local: Optional[LocalArm]
    var _s3: Optional[S3Arm[Self.C]]

    def __init__(out self, tag: UInt8):
        """A handle with no arm set; the `from_*` constructors set one."""
        self.tag = tag
        self._local = None
        self._s3 = None

    @staticmethod
    def from_local(var fs: LocalArm) -> Self:
        """The local arm, `tag == FS_LOCAL`."""
        var h = Self(Self.FS_LOCAL)
        h._local = Optional[LocalArm](fs^)
        return h^

    @staticmethod
    def from_s3(var fs: S3Arm[Self.C]) -> Self:
        """The S3 arm, `tag == FS_S3`. Dials nothing."""
        var h = Self(Self.FS_S3)
        h._s3 = Optional[S3Arm[Self.C]](fs^)
        return h^

    def clone(self) -> Self:
        """A handle on a clone of the set arm, with the same tag. A cloned
        S3 arm builds its own store on its first verb; nothing is dialed
        here."""
        var h = Self(self.tag)
        if self.tag == Self.FS_S3:
            h._s3 = Optional[S3Arm[Self.C]](self._s3.value().clone())
        else:
            h._local = Optional[LocalArm](self._local.value().clone())
        return h^

    @always_inline
    def is_local(self) -> Bool:
        return self.tag == Self.FS_LOCAL

    @always_inline
    def is_s3(self) -> Bool:
        return self.tag == Self.FS_S3

    # The accessors borrow the whole Optional field: `Optional.value()`
    # returns a ref rooted at Optional's private storage, which cannot be
    # named as an origin from here. The caller takes `.value()`.

    def local_ref(self) -> ref [self._local] Optional[LocalArm]:
        """The local arm's Optional; set iff `is_local()`."""
        return self._local

    def s3_ref(self) -> ref [self._s3] Optional[S3Arm[Self.C]]:
        """The S3 arm's Optional; set iff `is_s3()`."""
        return self._s3


def fs_is_registry_arm[FS: FileSystem]() -> Bool:
    """True iff `FS` is exactly one of the production handle's arm types
    (`LocalArm`, `S3Arm[S3ProdConnector]`): the test `fs_handle_from_typed_fs`
    wraps by, without building a handle."""
    comptime if (FS == LocalArm):
        return True
    elif (FS == S3Arm[S3ProdConnector]):
        return True
    else:
        return False


def fs_handle_from_typed_fs[FS: FileSystem](var fs: FS) -> Optional[FsHandle]:
    """`fs` as a production `FsHandle` when `FS` is one of its arm types, else
    `None` (`fs` is then dropped; the caller reads its own file system
    directly).

    `rebind` is an identity here: the comptime equality above it proves `FS`
    is the arm type. A rebound value is a borrowed view, so the arm is a
    clone of `fs` (a `String` copy for the local arm; for S3, the same
    bucket, configuration and credential with a store of its own)."""
    comptime if (FS == LocalArm):
        var h = FsHandle.from_local(rebind[LocalArm](fs).clone())
        _ = fs^
        return Optional[FsHandle](h^)
    elif (FS == S3Arm[S3ProdConnector]):
        var h = FsHandle.from_s3(rebind[S3Arm[S3ProdConnector]](fs).clone())
        _ = fs^
        return Optional[FsHandle](h^)
    else:
        _ = fs^
        return Optional[FsHandle](None)
