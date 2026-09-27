"""Private, optional student timeline. Separate from the service-owned catalog."""
import from discovery.timeline { validate_month }
node CareerTimeline { has graduation_month: str = "", available_from: str = ""; }

def _timeline_preferences() -> dict[str, str] {
    items=[root -->][?:CareerTimeline];
    if items { return {"graduation_month":items[0].graduation_month,"available_from":items[0].available_from}; }
    return {"graduation_month":"","available_from":""};
}
def _save_timeline(graduation_month: str, available_from: str) -> None {
    validate_month(graduation_month);validate_month(available_from);
    items=[root -->][?:CareerTimeline];p=items[0] if items else root ++> CareerTimeline();
    p.graduation_month=graduation_month;p.available_from=available_from;
}
