# Near misses of the refused imports of test 54: none is a finding.
# from komira_plan_ir.physical_plan import SegmentDescPod
from komira_plan_ir.logical_plan import LogicalPlan  # physical_plan
from komira_plan_ir.physical_planner import Planner
from komira_plan_ir.physical_plan_x import X
from komira_plan_ir import logical_plan, physical_planner
from komira_plan_ir import (  # (physical_plan)
    logical_plan,  # physical_plan()
    physical_plan_x,
)
from komira_plan_ir.logical_plan import physical_plan
from komira_a.physical_plan import Y
import komira_plan_ir
import komira_plan_ir.physical_planner as pp
import komira_a, komira_plan_ir.logical_plan
"""A docstring that spells imports at the start of its lines:
from komira_plan_ir.physical_plan import SegmentDescPod
import komira_plan_ir.physical_plan_purity_gate
"""


def f() -> String:
    '''
    import komira_plan_ir.physical_plan
    '''
    var a = "from komira_plan_ir.physical_plan import SegmentDescPod"
    var b = String("import komira_plan_ir.physical_plan")
    var c = 'komira_plan_ir.physical_plan.X # "'
    var d = komira_plan_ir.physical_planner.f()  # komira_plan_ir.physical_plan.X
    var e = x.komira_plan_ir.physical_plan
    return a + b + c


def g(x: Int) -> Int:
    import komira_plan_ir as kp
    from komira_plan_ir import logical_plan as lp
    var s = x .bit_length()
    var t = (x
        .bit_length())
    var u = kp.logical_plan.LogicalPlan
    var v = kp . physical_planner.f()
    var w = lp.physical_plan
    var y = [x,
        x .bit_length()]
    return s + t + y[0] + 1.5
