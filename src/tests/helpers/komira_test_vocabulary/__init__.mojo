# =============================================================================
# komira_test_vocabulary — the source scan that keeps a generic package free of
# product vocabulary and of early year-months: 2024 or 2025 with any month, or
# 2026 with month 01 to 08; earlier years are not matched (package marker).
# =============================================================================
#
# A library's welded test calls `scan_library(root, min_files)` over its own
# sources, staged as test data at their repository paths, and asserts the
# report is empty. See vocabulary.mojo for what is matched.
# =============================================================================

from .vocabulary import banned_words, early_date_at, scan_library, scan_text
