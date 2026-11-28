# =============================================================================
# name_registry -- interned names: comptime ids and a fixed table.
# =============================================================================
#
# `name_id[name]()` is the compile-time FNV-1a 32-bit id of a string literal;
# `NameRegistry` records each registered name under its id so a drain can turn
# an id back into text. Depends only on `hashing`. Import it flat:
#
#     from name_registry import NameRegistry, name_id
#     var reg = NameRegistry()
#     _ = reg.try_register["engine.segment.execute"]()
#     var text = reg.lookup(name_id["engine.segment.execute"]())
#
# Any number of threads may register at once (each slot is claimed with one
# compare-and-swap); `lookup` once the registrations it must see have
# returned. The full contract is in `registry.mojo`.
# =============================================================================

from .registry import (
    MAX_NAME_BYTES,
    MAX_REGISTERED_NAMES,
    NameRegistry,
    NameRegistryEntry,
    name_id,
    name_id_of,
)
