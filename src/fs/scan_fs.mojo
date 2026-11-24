# =============================================================================
# scan_fs -- the file system a scan on a store other than the local disk reads
# =============================================================================
#
# A plan names the store a Parquet scan reads by a scheme code and a bucket
# (`plan_expr.FsDescriptorPod`), never by a file system type. The engine that
# runs the plan is handed a `ScanFsOpener`: a value holding what reaching the
# store takes (the endpoint, the region, the credentials, the connector) that
# opens one file system per bucket a scan names. Its `FS` is the file system
# type the remote Parquet source is built over, so the engine is compiled for
# exactly one remote file system and names none.
#
# An opener refuses a scheme it does not serve with `SCAN_FS_UNSERVED`
# (`scan_fs_unserved`), naming the store; so does the engine when it was
# given no opener at all. The scheme codes are `plan_expr`'s `FS_SCHEME_*`,
# which this package cannot import (see `FileSystem.SCHEME`): the opener's
# caller passes the descriptor's code and bucket as they are.

from fs.file_system import FileSystem

comptime SCAN_FS_UNSERVED = "SCAN_FS_UNSERVED"
"""Refusal: a scan names a store no file system of this run reads."""


def scan_fs_unserved(location: String) -> Error:
    """The refusal of a scan on `location` (a store's URL prefix, such as
    `s3://lake`) that no file system of this run reads."""
    return Error(
        String(SCAN_FS_UNSERVED)
        + ": no file system of this run reads "
        + location
    )


trait ScanFsOpener(Movable, Deinitable):
    """Opens the file system a scan of one bucket reads (module header)."""

    comptime FS: FileSystem
    """The file system type every scan this opener serves is read through."""

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        """A file system on `bucket` of the store `scheme` names. Nothing
        need be dialed here; the first read may be the first request.

        Raises:
            `SCAN_FS_UNSERVED` when this opener does not serve `scheme`, or
            the opener's own error when `bucket` is not one it can open.
        """
        ...
