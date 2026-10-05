# =============================================================================
# komira_csv.quote_styles.quote_style_trait — RE-EXPORT shim.
# =============================================================================
#
# The QuoteStyle trait lives in `komira_arrow.quote_styles` because the
# `Csv[Q: QuoteStyle = Rfc4180]` parametric SerdeFormat marker (in
# `komira_arrow.formats`) needs it, and keeping it in komira_csv would
# form a `komira_core -> komira_csv` cycle. The dependency direction is
# `komira_csv -> komira_core`; this module is a thin re-export so consumers
# can import the trait from `komira_csv`.
# =============================================================================

from komira_arrow.quote_styles import QuoteStyle
