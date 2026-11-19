# =============================================================================
# csv.quote_styles.quote_style_trait — RE-EXPORT shim.
# =============================================================================
#
# The QuoteStyle trait lives in `arrow.quote_styles` because the
# `Csv[Q: QuoteStyle = Rfc4180]` parametric SerdeFormat marker (in
# `arrow.formats`) needs it, and keeping it in csv would
# form a `the core packages -> csv` cycle. The dependency direction is
# `csv -> the core packages`; this module is a thin re-export so consumers
# can import the trait from `csv`.
# =============================================================================

from arrow.quote_styles import QuoteStyle
