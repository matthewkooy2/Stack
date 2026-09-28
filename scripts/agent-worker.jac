"""Run with the pinned Jac dependency environment; workers never open the graph."""
import from agents.worker { main }
with entry:__main__ { main(); }
