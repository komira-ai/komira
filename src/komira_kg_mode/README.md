# `komira_kg_mode`

## Responsibility

The extraction-mode vocabulary that the graph spec and the extractor selection
share, from [the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md). It is a leaf
with no dependencies so that neither side has to depend on the other to agree on
what a mode number means.

There are two modes:

- `rules` (`EXTRACT_MODE_RULES`, 0): extraction by typed rules, no generative
  model, so no document body is sent to one. This is the default.
- `model` (`EXTRACT_MODE_MODEL`, 1): extraction by a model the host injects,
  which reads raw document bodies. It is opt-in.

The ordinals are stored in a graph spec, so their values are fixed. A name is
parsed from a string the host got from a flag; the package reads no environment
and no clock, and no pointer crosses its API.

## API

Everything is exported from `komira_kg_mode`:

- `EXTRACT_MODE_RULES`, `EXTRACT_MODE_MODEL`, `EXTRACT_MODE_COUNT`, and the alias
  `KgExtractMode`.
- `parse_extract_mode(name)`: `"model"` (any ASCII case) gives model; the empty
  string and every other string give rules.
- `normalize_extract_mode(n)`: a known ordinal is returned unchanged; an unknown
  one becomes rules.
- `is_known_extract_mode(n)` and `extract_mode_name(n)` (`"rules"`, `"model"`, or
  `"unknown"`).

## Examples

A name from a flag resolves to a mode. Anything that is not exactly `model`, a
typo included, stays on rules:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg_mode import (
    EXTRACT_MODE_MODEL,
    EXTRACT_MODE_RULES,
    extract_mode_name,
    parse_extract_mode,
)

assert_equal(parse_extract_mode("model"), EXTRACT_MODE_MODEL)
assert_equal(parse_extract_mode("MODEL"), EXTRACT_MODE_MODEL)
assert_equal(parse_extract_mode(""), EXTRACT_MODE_RULES)
assert_equal(parse_extract_mode("modle"), EXTRACT_MODE_RULES)
assert_equal(extract_mode_name(parse_extract_mode("model")), "model")
```

A stored integer is normalised the same way: an ordinal this build does not know
becomes rules, never model.

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg_mode import (
    EXTRACT_MODE_MODEL,
    EXTRACT_MODE_RULES,
    is_known_extract_mode,
    normalize_extract_mode,
)

assert_equal(normalize_extract_mode(EXTRACT_MODE_MODEL), EXTRACT_MODE_MODEL)
assert_equal(normalize_extract_mode(7), EXTRACT_MODE_RULES)
assert_equal(normalize_extract_mode(-1), EXTRACT_MODE_RULES)
assert_false(is_known_extract_mode(2))
assert_true(is_known_extract_mode(0))
```
