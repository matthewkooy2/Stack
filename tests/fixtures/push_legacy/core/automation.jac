"""Pre-MAT-14 persisted node schema; never imported by the application."""
node AgentNotification {
    has key: str, run_id: str, state: str = "queued", receipt: str = "";
}

def:priv seed_legacy_notifications() -> dict[str, str] {
    records: dict[str, str] = {};
    for (state, receipt) in [("sent", "legacy-good,legacy-invalid"),
        ("dispatched", ""), ("sent", ""), ("cancelled", ""), ("queued", "")] {
        key=state+":"+receipt;
        n=root ++> AgentNotification(key=key,run_id=key,state=state,receipt=receipt);
        if type(n).__module__!="core.automation" {
            raise ValueError("Legacy fixture must preserve the deployed core.automation type namespace.");
        }
        if hasattr(n,"initialized") or hasattr(n,"deliveries") {
            raise ValueError("Legacy fixture must omit the new notification fields.");
        }
        records[key]=jid(n);
    }
    commit();return records;
}
