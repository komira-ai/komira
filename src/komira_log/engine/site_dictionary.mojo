# =============================================================================
# komira_log.engine.site_dictionary — comptime site-ID + decoder dictionary.
# =============================================================================
#
# A sparse-32-bit-digest site dictionary. The hot-path emit computes `comptime site_id = fnv1a(fmt)` (a literal at the call site, zero
# runtime hash); the record carries ONLY the 32-bit id. The decoder holds this
# dictionary, mapping `site_id → fmt` and `module_id → module` so it can
# reconstruct the human line — the NanoLog "format string lives in the binary;
# the record carries only the id" property, with ZERO new comptime capability
# beyond what `komira_trace/tracer.mojo` already ships (`fnv1a_compute`).
#
# Why a runtime-built dictionary (not a comptime global): Mojo has no
# const-evaluable mutable module-global, so each site that wants to be decodable
# calls `dict.register[fmt, module]()` (the SAME comptime digest as the emit
# side → keys match by construction). The decoder builds its dictionary from
# the same StringLiterals the binary already contains.
#
# Encapsulation: the dictionary is plain `List[DictEntry]` /
# `List[ModuleEntry]` (owned heap, NOT a byte-slab of heap-owning records — the
# entries hold `String`s but the List itself is the owner, never stored in a
# wildcard-cast byte slab). No `UnsafePointer`, no wildcard origin. The records
# on the RING carry only the u32 ids (POD); the strings live only here, on the
# decode side.
# =============================================================================


# -----------------------------------------------------------------------------
# FNV-1a 32-bit — the comptime site-ID seed. The same hash as the tracer's
# span-ID hash (`komira_hash`, which the tracer's name registry also uses), so the
# digest matches exactly.
# -----------------------------------------------------------------------------

from komira_hash import FNV1A_32_OFFSET_BASIS, FNV1A_32_PRIME


def fnv1a_32(name: StringLiteral) -> UInt32:
    """FNV-1a 32-bit digest of a StringLiteral. Resolves at COMPILE time when
    called via `comptime h = fnv1a_32(fmt)` (the hot-path shape)."""
    var h = FNV1A_32_OFFSET_BASIS
    var s = String(name)
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = (h ^ UInt32(b[i])) * FNV1A_32_PRIME
    return h


# -----------------------------------------------------------------------------
# Dictionary entries — sparse-key (digest) → text. POD-of-String; the List is
# the owner.
# -----------------------------------------------------------------------------


@fieldwise_init
struct DictEntry(Copyable, Movable):
    var site_id: UInt32
    var fmt: String


@fieldwise_init
struct ModuleEntry(Copyable, Movable):
    var module_id: UInt32
    var module: String


struct SiteDictionary(Movable):
    """Decoder-side dictionary: `site_id → fmt`, `module_id → module`.

    Built by `register[fmt, module]()` calls that use the SAME comptime
    digests the emit path computes, so keys match by construction. Lookups
    are linear (sparse-key set semantics); at realistic site
    counts (~few thousand) this is sub-millisecond and only runs on the drain.
    """

    var sites: List[DictEntry]
    var modules: List[ModuleEntry]

    def __init__(out self):
        self.sites = List[DictEntry]()
        self.modules = List[ModuleEntry]()

    @always_inline
    def register[fmt: StringLiteral, module: StringLiteral](mut self):
        """Register a (fmt, module) site for decoding. Idempotent on both keys.

        PERF: this runs on EVERY admitted emit (the facade calls it to
        keep the decoder dictionary populated). The COMMON case is "already
        registered" — so we scan by `site_id` / `module_id` FIRST and only
        materialize `String(fmt)` / `String(module)` when actually appending a
        NEW entry. The prior shape built both Strings unconditionally (~40 ns of
        per-emit heap alloc) even when the idempotent scan immediately returned.
        """
        comptime site_id = fnv1a_32(fmt)
        comptime module_id = fnv1a_32(module)
        if not self._has_site(site_id):
            self.sites.append(DictEntry(site_id, String(fmt)))
        if not self._has_module(module_id):
            self.modules.append(ModuleEntry(module_id, String(module)))

    @always_inline
    def _has_site(self, site_id: UInt32) -> Bool:
        for i in range(len(self.sites)):
            if self.sites[i].site_id == site_id:
                return True
        return False

    @always_inline
    def _has_module(self, module_id: UInt32) -> Bool:
        for i in range(len(self.modules)):
            if self.modules[i].module_id == module_id:
                return True
        return False

    @always_inline
    def register_dynamic(
        mut self,
        site_id: UInt32,
        fmt: StaticString,
        module_id: UInt32,
        module: StaticString,
    ):
        """RUNTIME-keyed twin of `register[fmt, module]` — the ERASED emit
        path's registration (logger_erased.mojo).

        Same dictionary, same idempotence, same digests: the caller computes
        `site_id` with `fnv1a_32_dyn`, which is `fnv1a_32` with its loop run at
        runtime, so a site registered here and the same `fmt` registered through
        the comptime path collide onto ONE entry rather than making two.

        PERF: takes `StaticString`, not `String`, and scans by id BEFORE
        materializing anything — so the common already-registered case allocates
        NOTHING, exactly as `register`'s PERF note above requires.
        """
        if not self._has_site(site_id):
            self.sites.append(DictEntry(site_id, String(fmt)))
        if not self._has_module(module_id):
            self.modules.append(ModuleEntry(module_id, String(module)))

    def register_module[module: StringLiteral](mut self):
        """Register a module name alone (for modules whose sites are all
        comptime-floor-deleted but whose name still appears)."""
        comptime module_id = fnv1a_32(module)
        self._register_module(module_id, String(module))

    def _register_site(mut self, site_id: UInt32, fmt: String):
        for i in range(len(self.sites)):
            if self.sites[i].site_id == site_id:
                return
        self.sites.append(DictEntry(site_id, fmt))

    def _register_module(mut self, module_id: UInt32, module: String):
        for i in range(len(self.modules)):
            if self.modules[i].module_id == module_id:
                return
        self.modules.append(ModuleEntry(module_id, module))

    def lookup_fmt(self, site_id: UInt32) -> Optional[String]:
        for i in range(len(self.sites)):
            if self.sites[i].site_id == site_id:
                return Optional[String](self.sites[i].fmt)
        return Optional[String]()

    def lookup_module(self, module_id: UInt32) -> Optional[String]:
        for i in range(len(self.modules)):
            if self.modules[i].module_id == module_id:
                return Optional[String](self.modules[i].module)
        return Optional[String]()
