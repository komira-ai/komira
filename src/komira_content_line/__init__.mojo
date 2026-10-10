# =============================================================================
# komira_content_line -- the content-line layer shared by vCard (RFC 6350
# §3) and iCalendar (RFC 5545 §3.1): unfolding, lexing, folding and TEXT
# escaping. No dependencies.
# =============================================================================
#
# Reading: `unfold(bytes, limits)` gives validated logical lines;
# `parse_content_line(line.text, line.line_number)` splits one into group,
# name, parameters and the still-escaped value; `split_unescaped` and
# `unescape_text` turn a value into fields.
#
# Writing: `escape_text` each field, build a `ContentLine`,
# `format_content_line` it and `fold_line` the result.
#
#     from komira_content_line import unfold, parse_content_line
#     var lines = unfold("FN:Jane Doe\r\n".as_bytes())
#     var cl = parse_content_line(lines[0].text, lines[0].line_number)
# =============================================================================

from .fold import FOLD_OCTETS, fold_line
from .lexer import ContentLine, Param, format_content_line, parse_content_line
from .text import escape_text, split_unescaped, unescape_text
from .unfold import (
    DEFAULT_MAX_INPUT_OCTETS,
    DEFAULT_MAX_LINE_OCTETS,
    ContentLimits,
    Fold,
    LogicalLine,
    unfold,
)
from .utf8 import string_from_utf8, utf8_invalid_at
