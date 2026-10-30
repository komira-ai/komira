"""`komira_pipeline_exec` -- the driver that runs the segments of a physical plan.

A ready-set scheduler over `SegmentDescPod` segments, and for each segment the
fork-join run of `source -> operators -> sink` over the traits of
`komira_morsel` on a `ParallelDispatch`, with cancellation and a first-error
slot. The source, operator and sink of a segment are closed variants, so no
function pointer or erased box is involved. Import each module by name; the
package root exports nothing.
"""
