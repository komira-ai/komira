"""The state behind a context handle."""


struct Session(Movable):
    """What `komira_ctx_new` creates: the text of the last error.

    The C surface owns a `Session` through an `OwnedPointer` and lends it to
    each call; it is destroyed by `komira_ctx_free`. A later change adds the
    engine's state here without changing the handle's type for the caller.
    """

    var _last_error: String

    def __init__(out self):
        """A session with no error."""
        self._last_error = String()

    def set_error(mut self, var message: String):
        """Replace the last error with `message`."""
        self._last_error = message^

    def clear_error(mut self):
        """Forget the last error."""
        self._last_error = String()

    def has_error(self) -> Bool:
        """Whether an error text is held."""
        return self._last_error.byte_length() > 0

    def last_error(self) -> String:
        """A copy of the last error text; empty when there is none."""
        return self._last_error.copy()
