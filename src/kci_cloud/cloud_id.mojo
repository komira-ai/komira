# =============================================================================
# kci_cloud/cloud_id.mojo: the opaque cloud id.
# =============================================================================
#
# Which cloud a stage deploys to comes from its cell (the cell's `cloud`,
# `--cloud=<id>` on the command line), and the id is a string a cloud
# adapter reports about itself (`gcp`, `aws`, `mem`). "Platform" is not this:
# a platform is an OS and a CPU. Nothing may branch on what the id SAYS: the
# only operations are equality (with the clouds built into kci, with a state
# header) and printing. So the type offers exactly those two, and no
# `startswith`, `find` or slicing can be written against it. The conformance
# kit's rename test runs a cloud under a random id and fails any code that
# keyed on the spelling anyway.
# =============================================================================


struct CloudId(Copyable, Movable, Deinitable):
    var _id: String

    def __init__(out self, id: String):
        self._id = id

    def __init__(out self, *, copy: Self):
        self._id = copy._id.copy()

    def __eq__(self, other: Self) -> Bool:
        return self._id == other._id

    def __ne__(self, other: Self) -> Bool:
        return self._id != other._id

    def text(self) -> String:
        """For messages only."""
        return self._id.copy()
