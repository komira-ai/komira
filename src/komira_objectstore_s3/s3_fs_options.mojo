# =============================================================================
# komira_objectstore_s3/s3_fs_options.mojo -- S3FsOptions, what an S3Fs
# decides beyond its store's S3Config
# =============================================================================
#
# Every setting is a constructor argument, checked there and read through an
# accessor; the defaults are S3's standard. How S3Fs uses each one is in
# s3_fs.mojo's header. Nothing reads the environment.
# =============================================================================

from komira_objectstore.store import PREFETCH_DEPTH_S3_STANDARD


comptime S3_FS_ALL_RANGES = 0
"""`S3FsOptions` `prefetch_max_inflight` for "every range of one
`read_ranges_prefetched` call"."""

comptime S3_MIN_PART_BYTES = 5 * 1024 * 1024
"""S3's smallest part, for every part of a multipart upload but the last."""

comptime S3_MAX_PART_BYTES = 5 * 1024 * 1024 * 1024
"""S3's largest part."""

comptime S3_FS_DEFAULT_PART_BYTES = 8 * 1024 * 1024
"""The part size an `S3Fs` writes unless told otherwise."""

comptime S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT = 8
"""The parts one upload may have in flight unless told otherwise."""

comptime S3_FS_UPLOAD_MAX_INFLIGHT_CAP = 16
"""The most parts one upload may have in flight: each pins a part buffer."""


@fieldwise_init
struct _S3FsDefaults(Copyable, Movable):
    """Selects `S3FsOptions`'s defaults constructor."""

    pass


struct S3FsOptions(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """What an `S3Fs` decides beyond its store's `S3Config`. Every setting is
    a constructor argument, checked there, and read through its accessor;
    the defaults are S3's standard.

    - `prefetch_max_inflight`: the requests one `read_ranges_prefetched` call
      may have in flight: `S3_FS_ALL_RANGES` (0) for one per range of the
      call, or a bound K >= 1. Clamped to `S3Config.max_inflight`, it is the
      most requests of one call in flight at once (module header).
    - `prefetch_depth`: what `prefetch_depth()` reports, the depth of the
      reader's prefetch ring (`PREFETCH_DEPTH_S3_STANDARD`, 64, by default).
    - `upload_part_bytes`: the size of every part of a multipart upload but
      the last, `S3_MIN_PART_BYTES` to `S3_MAX_PART_BYTES` (8 MiB by
      default). An object smaller than one part is one PutObject.
    - `upload_max_inflight`: the parts one upload may have in flight, 1 to
      `S3_FS_UPLOAD_MAX_INFLIGHT_CAP` (8 by default): K parts are buffered
      and then sent at once (module header), so a write holds up to K part
      buffers.
    """

    var _prefetch_max_inflight: Int
    var _prefetch_depth: Int
    var _upload_part_bytes: Int
    var _upload_max_inflight: Int

    def __init__(
        out self,
        *,
        prefetch_max_inflight: Int = S3_FS_ALL_RANGES,
        prefetch_depth: Int = PREFETCH_DEPTH_S3_STANDARD,
        upload_part_bytes: Int = S3_FS_DEFAULT_PART_BYTES,
        upload_max_inflight: Int = S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT,
    ) raises:
        """Refuses a setting out of its range (above), naming it."""
        if prefetch_max_inflight < 0:
            raise Error(
                String("S3FsOptions: prefetch_max_inflight must be >= 0 (0 for every range), got ")
                + String(prefetch_max_inflight)
            )
        if prefetch_depth < 1:
            raise Error(
                String("S3FsOptions: prefetch_depth must be >= 1, got ")
                + String(prefetch_depth)
            )
        if upload_part_bytes < S3_MIN_PART_BYTES or upload_part_bytes > S3_MAX_PART_BYTES:
            raise Error(
                String("S3FsOptions: upload_part_bytes must be ")
                + String(S3_MIN_PART_BYTES)
                + " to "
                + String(S3_MAX_PART_BYTES)
                + ", got "
                + String(upload_part_bytes)
            )
        if upload_max_inflight < 1 or upload_max_inflight > S3_FS_UPLOAD_MAX_INFLIGHT_CAP:
            raise Error(
                String("S3FsOptions: upload_max_inflight must be 1 to ")
                + String(S3_FS_UPLOAD_MAX_INFLIGHT_CAP)
                + ", got "
                + String(upload_max_inflight)
            )
        self._prefetch_max_inflight = prefetch_max_inflight
        self._prefetch_depth = prefetch_depth
        self._upload_part_bytes = upload_part_bytes
        self._upload_max_inflight = upload_max_inflight

    def __init__(out self, _defaults: _S3FsDefaults):
        """The defaults, without the checks (`standard`): it takes no
        value, so it cannot make options the checks would refuse."""
        self._prefetch_max_inflight = S3_FS_ALL_RANGES
        self._prefetch_depth = PREFETCH_DEPTH_S3_STANDARD
        self._upload_part_bytes = S3_FS_DEFAULT_PART_BYTES
        self._upload_max_inflight = S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT

    @staticmethod
    def standard() -> S3FsOptions:
        """The defaults, as `S3FsOptions()` gives them, without `raises`."""
        return S3FsOptions(_S3FsDefaults())

    @always_inline
    def prefetch_max_inflight(self) -> Int:
        return self._prefetch_max_inflight

    @always_inline
    def prefetch_depth(self) -> Int:
        return self._prefetch_depth

    @always_inline
    def upload_part_bytes(self) -> Int:
        return self._upload_part_bytes

    @always_inline
    def upload_max_inflight(self) -> Int:
        return self._upload_max_inflight

    def prefetch_window(self, num_ranges: Int) -> Int:
        """The in-flight bound of a call reading `num_ranges` ranges: all of
        them, or the bound when it is smaller. 1 at least. S3Fs clamps it to
        `S3Config.max_inflight`."""
        var window = num_ranges
        if self._prefetch_max_inflight != S3_FS_ALL_RANGES:
            window = min(window, self._prefetch_max_inflight)
        return max(1, window)
