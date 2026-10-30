# Dropping the file cache before a cold run. The runner does not know how a
# host does it, so it asks a `CacheDropper`. `NoCacheDropper` says it cannot;
# `ProcDropCaches` writes to the kernel's drop-caches control file, which only
# a privileged process may do.

from std.pathlib import Path


trait CacheDropper(Movable, Deinitable):
    def can_drop(self) -> Bool:
        """False when this dropper does nothing and cold runs cannot be
        measured with it."""
        ...

    def drop(mut self, files: List[String]) raises:
        """Make the next read of `files` come from storage. Raises when it
        could not."""
        ...


struct NoCacheDropper(CacheDropper):
    """The dropper of a host with no way to drop the cache: cold runs are
    not measured."""

    def __init__(out self):
        pass

    def can_drop(self) -> Bool:
        return False

    def drop(mut self, files: List[String]) raises:
        raise Error("no cache dropper is configured")


struct ProcDropCaches(CacheDropper):
    """Writes `3` (page cache, dentries and inodes) to `control_path`, the
    kernel's drop-caches control file. It needs the privilege to write there."""

    var control_path: String

    def __init__(out self, var control_path: String):
        self.control_path = control_path^

    def can_drop(self) -> Bool:
        return True

    def drop(mut self, files: List[String]) raises:
        Path(self.control_path).write_text("3\n")
