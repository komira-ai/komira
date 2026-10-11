"""`komira_batch_eval`: evaluates SQL expressions over Arrow record batches.

Today it holds the arms the projection and predicate evaluators share: IN
lists, dictionary-to-string materialization, and the typing of a literal
against the column it is compared with. Modules are imported by their
qualified path, for example
`from komira_batch_eval.eval_in_list import _eval_in_list`; this file
re-exports nothing.
"""
