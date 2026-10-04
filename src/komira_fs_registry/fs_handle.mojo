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
# `FsHandle` is that type: a private tag and one `Optional` per arm, exactly
# one of them set, the tag saying which. Every constructor takes an arm, so
# no handle exists with neither set; the tag is read through `tag()`.
#
# THE ARMS IN THIS BUILD
#
#   tag 0  FS_SCHEME_FILE   LocalArm   komira_fs's LocalFs[NoopSink]
#   tag 1  FS_SCHEME_S3     S3Arm[C]   komira_objectstore_s3's S3Fs
#   tag 2  FS_SCHEME_GCS    (reserved: no arm in this build)
#   tag 3  FS_SCHEME_AZURE  (reserved: no arm in this build)
#
# THE TAGS. `FS_LOCAL` and `FS_S3` are komira_plan_expr's `FS_SCHEME_FILE` and
# `FS_SCHEME_S3`: that package's `FsDescriptorPod` is the one a plan node
# carries. The scheme codes are also written down twice more, and those are
# COPIES, not the same names: komira_core's `FS_SCHEME_*` (which `S3Fs.SCHEME`
# and the plan wire codec use) and `LocalFs.SCHEME`, a literal. The tests pin
# all three to these tags (test_fs_handle_arms), so a drift reds the build.
# `fs_arm_tag_for_scheme` takes the bare code, so a caller holding either
# package's descriptor can resolve it; `fs_arm_tag_for_descriptor` is the
# komira_plan_expr form.
#
# The GCS and Azure codes stay reserved. A descriptor carrying one of them is
# refused with an error that names the missing arm ("no GCS arm in this
# build"), so a plan that needs an arm this build does not have fails where
# the descriptor is first resolved, not in a dispatch ladder that silently
# falls through to the local arm.
#
# THE S3 ARM'S TYPE. `S3Fs[C, T, K]` is generic over its connector, its
# credential source and its signing clock. A table of handles needs ONE type,
# so the handle fixes the clock to `SystemAwsClock` and the credential source
# to `StaticCredsSource`, the one copyable source (an arm's clone copies its
# source). The connector stays a parameter of `FsHandleOver[C]`, and
# `FsHandle` is the production handle, `FsHandleOver[S3ProdConnector]` with
# `S3ProdConnector = TlsConnector[KernelTcpConnector]`.
#
# Two limits of the production arm follow, and both are deliberate for now:
#
#   * TLS ONLY. komira_http_client sends an https request only over a
#     connector whose streams speak TLS, and refuses an http:// request over
#     one (`HttpError[URL_INVALID]`). The production arm therefore serves
#     https endpoints only; a plaintext S3-compatible endpoint
#     (`S3Config.custom_endpoint(..., "http://...")`) is refused on the first
#     request (test_fs_handle_s3_read). Serving one needs a connector that
#     picks TLS or plaintext per URL scheme, or a second arm.
#   * A FIXED CREDENTIAL. The credential the arm signs with is the one it was
#     given; a temporary credential (an instance role, STS, SSO) is not
#     refreshed, and requests fail once it expires. Refreshing needs a
#     copyable source that shares a refreshing chain, so a clone keeps it.
#
# A test drives the same handle over komira_http_core's ScriptedConnector
# (`FsHandleOver[ScriptedConnector]`), so the S3 arm is read through without a
# socket.
#
# WRAPPING A TYPED FILE SYSTEM. `FsHandleOver[C].from_typed_fs[FS]` (and, for
# the production handle, `fs_handle_from_typed_fs[FS]`) wraps a file system
# whose type is EXACTLY one of the handle's arm types, decided by type
# equality rather than by `FS.SCHEME`: an `S3Fs[ScriptedConnector, ...]`
# advertises `SCHEME == FS_SCHEME_S3` and is not the production arm's type,
# so wrapping it would be a reinterpretation, not a move. Such a file system
# gets `None`, and its caller reads it directly. A wrapped file system is
# MOVED into the arm (`rebind_var`), so an S3 store it has already built
# (`S3Fs.built`) and that store's connections are kept.
#
# Constructing a handle dials nothing: `S3Fs` builds its store on the first
# verb, and `clone()` gives the clone a store of its own, not yet built.
#
# No UnsafePointer, no wildcard origin; every arm is a value field.
# =============================================================================

from std.builtin.rebind import rebind_var

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


def _where(bucket: String, node_id: Int) -> String:
    return (
        "bucket '"
        + bucket
        + "', node "
        + String(node_id)
    )


def fs_arm_tag_for_scheme(scheme: UInt8, bucket: String, node_id: Int) raises -> UInt8:
    """The `FsHandle` tag that serves a descriptor with scheme code `scheme`:
    the code itself, when this build has that arm. `bucket` and `node_id`
    only name the descriptor in the error.

    Raises `fs_registry: no GCS arm in this build ...` for `FS_SCHEME_GCS`,
    `fs_registry: no Azure arm in this build ...` for `FS_SCHEME_AZURE`, and
    `fs_registry: unknown file system scheme ...` for any other code."""
    if scheme == FS_SCHEME_FILE:
        return FS_SCHEME_FILE
    if scheme == FS_SCHEME_S3:
        return FS_SCHEME_S3
    if scheme == FS_SCHEME_GCS:
        raise Error(
            "fs_registry: no GCS arm in this build (descriptor scheme "
            + String(Int(scheme))
            + ", "
            + _where(bucket, node_id)
            + ")"
        )
    if scheme == FS_SCHEME_AZURE:
        raise Error(
            "fs_registry: no Azure arm in this build (descriptor scheme "
            + String(Int(scheme))
            + ", "
            + _where(bucket, node_id)
            + ")"
        )
    raise Error(
        "fs_registry: unknown file system scheme "
        + String(Int(scheme))
        + " ("
        + _where(bucket, node_id)
        + ")"
    )


def fs_arm_tag_for_descriptor(desc: FsDescriptorPod) raises -> UInt8:
    """`fs_arm_tag_for_scheme` for a komira_plan_expr descriptor."""
    return fs_arm_tag_for_scheme(desc.scheme, desc.bucket, desc.node_id)


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

    var _tag: UInt8
    var _local: Optional[LocalArm]
    var _s3: Optional[S3Arm[Self.C]]

    def __init__(out self, *, var local: LocalArm):
        """The local arm, `tag() == FS_LOCAL`."""
        self._tag = Self.FS_LOCAL
        self._local = Optional[LocalArm](local^)
        self._s3 = None

    def __init__(out self, *, var s3: S3Arm[Self.C]):
        """The S3 arm, `tag() == FS_S3`. Dials nothing."""
        self._tag = Self.FS_S3
        self._local = None
        self._s3 = Optional[S3Arm[Self.C]](s3^)

    @staticmethod
    def from_local(var fs: LocalArm) -> Self:
        """The local arm, `tag() == FS_LOCAL`."""
        return Self(local=fs^)

    @staticmethod
    def from_s3(var fs: S3Arm[Self.C]) -> Self:
        """The S3 arm, `tag() == FS_S3`. Dials nothing."""
        return Self(s3=fs^)

    @staticmethod
    def is_arm_type[FS: FileSystem]() -> Bool:
        """True iff `FS` is exactly one of this handle's arm types
        (`LocalArm`, `S3Arm[C]`)."""
        comptime if (FS == LocalArm):
            return True
        elif (FS == S3Arm[Self.C]):
            return True
        else:
            return False

    @staticmethod
    def from_typed_fs[FS: FileSystem](var fs: FS) -> Optional[Self]:
        """`fs` as a handle when `FS` is exactly one of its arm types, else
        `None` (`fs` is then dropped; the caller reads its own file system
        directly). The file system is moved into the arm, not cloned: the
        comptime type equality proves `FS` is the arm type, so `rebind_var`
        is an identity, and an S3 store `fs` has built is kept."""
        comptime if (FS == LocalArm):
            return Optional[Self](Self(local=rebind_var[LocalArm](fs^)))
        elif (FS == S3Arm[Self.C]):
            return Optional[Self](Self(s3=rebind_var[S3Arm[Self.C]](fs^)))
        else:
            _ = fs^
            return Optional[Self](None)

    def clone(self) -> Self:
        """A handle on a clone of the set arm, with the same tag. A cloned
        S3 arm builds its own store on its first verb; nothing is dialed
        here."""
        if self._tag == Self.FS_S3:
            return Self(s3=self._s3.value().clone())
        # FS_LOCAL: both constructors set the arm their tag names, and the tag
        # is private, so a handle's tag is one of the two.
        return Self(local=self._local.value().clone())

    @always_inline
    def tag(self) -> UInt8:
        """The set arm's tag: `FS_LOCAL` or `FS_S3`."""
        return self._tag

    @always_inline
    def is_local(self) -> Bool:
        return self._tag == Self.FS_LOCAL

    @always_inline
    def is_s3(self) -> Bool:
        return self._tag == Self.FS_S3

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
    return FsHandle.is_arm_type[FS]()


def fs_handle_from_typed_fs[FS: FileSystem](var fs: FS) -> Optional[FsHandle]:
    """`fs` as a production `FsHandle` when `FS` is one of its arm types, else
    `None` (`FsHandleOver.from_typed_fs`). `fs` is moved into the arm."""
    return FsHandle.from_typed_fs(fs^)
