"""The rules of the python_closure fixtures (BUCK): a stand-in for a Python
rule, which the check knows by its kind's name (`python_stand_in` holds
`python`), and a target that runs a tool, given as an exec dependency.
Nothing here builds anything or runs Python: the check reads the graph.
"""

def _impl(_ctx):
    return [DefaultInfo()]

python_stand_in = rule(impl = _impl, attrs = {})

uses_tool = rule(
    impl = _impl,
    attrs = {"tool": attrs.option(attrs.exec_dep(), default = None)},
)
