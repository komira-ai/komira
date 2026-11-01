# =============================================================================
# komira_name_registry -- interned names: comptime ids and a fixed table.
# =============================================================================
#
# `name_id[name]()` is the compile-time FNV-1a 32-bit id of a string literal;
# `NameRegistry` records each registered name under its id so a drain can turn
# an id back into text. Depends only on `komira_hash`. Import it flat:
#
#     from komira_name_registry import NameRegistry, name_id
#     var reg = NameRegistry()
#     _ = reg.try_register["engine.segment.execute"]()
#     var text = reg.lookup(name_id["engine.segment.execute"]())
#
# Register from one thread at a time; once registration is done any number of
# threads may read. The full contract is in `registry.mojo`.
# =============================================================================

from .registry import (
    MAX_NAME_BYTES,
    MAX_REGISTERED_NAMES,
    NameRegistry,
    NameRegistryEntry,
    name_id,
    name_id_of,
)
