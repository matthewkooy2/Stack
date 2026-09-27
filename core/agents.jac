"""Deterministic demo adapter. No browser, provider calls, or submissions."""
def _demo_status(created_at: float, now: float) -> str {
    if now - created_at < 3 { return "Queued"; }
    if now - created_at < 8 { return "Preparing"; }
    return "Submitted";
}
