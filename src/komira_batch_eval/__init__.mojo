"""`komira_batch_eval`: evaluates SQL expressions over Arrow record batches.

The vectorized projection and predicate evaluators an executor host runs
inside its operators, with their CASE, IN-list and dictionary arms, and the
typing of a literal against the column it is compared with. The evaluator
only evaluates: it rewrites no plan.

  - `evaluate_column(expr, batch)`: a projection, one value per row.
  - `evaluate_predicate(expr, batch)`: a predicate, one bit per row; UNKNOWN
    is data 0 with validity 0.

The other modules are imported by their qualified path, for example
`from komira_batch_eval.eval_in_list import _eval_in_list`.
"""

from .evaluate import evaluate_column, evaluate_predicate
