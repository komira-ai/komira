# =============================================================================
# komira_secret_env/map_env.mojo: `MapEnv`, the hermetic `EnvReader` double.
# =============================================================================
#
# A name -> bytes map standing in for the process environment, plus a lookup
# count. Like `StaticSecretStore`, it holds plaintext at rest as `List[UInt8]`
# and mints a fresh `SecretValue` per lookup: it is a TEST DOUBLE, never a
# store. The state sits behind an `ArcPointer` so a `share()`d handle reads
# the count after the store has taken the reader.
# =============================================================================

from std.memory import ArcPointer

from komira_secret_store import SecretValue

from komira_secret_env.env_secret_store import EnvReader


struct _MapEnvState(Movable):
    var vars: Dict[String, List[UInt8]]
    var lookup_count: Int

    def __init__(out self):
        self.vars = Dict[String, List[UInt8]]()
        self.lookup_count = 0


struct MapEnv(EnvReader, Movable):
    """An in-memory environment: `set`/`unset` script it, `lookup` reads it."""

    var _p: ArcPointer[_MapEnvState]

    def __init__(out self):
        self._p = ArcPointer[_MapEnvState](_MapEnvState())

    def __init__(out self, *, var _share: ArcPointer[_MapEnvState]):
        self._p = _share^

    def share(self) -> MapEnv:
        """A second handle over the same state (single-threaded test use)."""
        return MapEnv(_share=ArcPointer[_MapEnvState](copy=self._p))

    def set(mut self, name: String, value: String):
        """Set `name` to `value` (an empty `value` is set-but-empty)."""
        var bytes = List[UInt8]()
        var src = value.as_bytes()
        for i in range(len(src)):
            bytes.append(src[i])
        self._p[].vars[name] = bytes^

    def unset(mut self, name: String) raises:
        """Remove `name`; the next lookup of it returns `None`."""
        if name in self._p[].vars:
            _ = self._p[].vars.pop(name)

    def lookup_count(self) -> Int:
        """How many lookups were made, whatever they found."""
        return self._p[].lookup_count

    def lookup(mut self, name: String) raises -> Optional[SecretValue]:
        self._p[].lookup_count += 1
        if name not in self._p[].vars:
            return None
        ref bytes = self._p[].vars[name]
        return SecretValue(Span[UInt8, origin_of(bytes)](bytes))
