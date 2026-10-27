# =============================================================================
# komira_kg_mode -- the extraction-mode vocabulary the graph spec and the
#   extractor selection share, and nothing else.
# =============================================================================
#
# Two modes: rules (no model, the default) and model (opt-in). A parse of a name
# and a normalisation of a stored integer both fall back to rules; neither
# resolves to model unless the input asked for it. The ordinals are stored in a
# spec and never change meaning.
#
# No dependency beyond the standard library, and no environment read.
# =============================================================================

from .extract_mode_vocab import (
    EXTRACT_MODE_RULES,
    EXTRACT_MODE_MODEL,
    EXTRACT_MODE_COUNT,
    KgExtractMode,
    is_known_extract_mode,
    normalize_extract_mode,
    parse_extract_mode,
    extract_mode_name,
)
