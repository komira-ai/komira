"""From the files of a change to the targets it affects (`change_map`).

`rules`: the widening and inert patterns (the data file `rules.txt`).
`cells`, `labels`: the cell table of `.buckconfig` and the spelling of labels.
`graph`: the questions the mapping asks of the repository (`Graph`) and the
answer to each from buck2 and git (`BuckGraph`).
`plan`: the mapping itself, a pure function over a `Graph`. `units`: the
answer in kci's protocol. `report`: text and JSON. `process`: one process, its
two streams captured.

The mapping never under-approximates: a file it cannot map widens the answer
to every target and says why, and a change that maps to nothing is refused.
"""
