# =============================================================================
# kci_platform/platform_id.mojo: the opaque platform id.
# =============================================================================
#
# A platform is chosen by the invocation (`--platform=<id>`), never by a
# file, and the id is a string an adapter set reports about itself. Nothing
# may branch on what the string SAYS: the only operations are equality (with
# the registry, with a state header) and printing. So the type offers exactly
# those two, and no `startswith`, `find` or slicing can be written against it.
# The conformance kit's rename test runs a platform under a random id and
# fails any code that keyed on the spelling anyway.
# =============================================================================


struct PlatformId(Copyable, Movable, Deinitable):
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
