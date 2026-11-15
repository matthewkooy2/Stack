"""Retired. Jobs are collected once a day by `scripts/jobs-sweep.jac` (stack-jobs-sweep.timer).

Kept so a host that still has the old always-on collector enabled stops it cleanly instead of restarting it."""
with entry:__main__ {
    print("The always-on collector is retired; enable stack-jobs-sweep.timer instead.",flush=True);
}
