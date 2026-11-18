"""Prepare the existing public landing pages for the Rust gateway."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agents import app_links

out = Path(sys.argv[1])
(out / "open").mkdir(parents=True, exist_ok=True)
for path, data in {
    "association.json": app_links.association(),
    "privacy": app_links.privacy_page(),
    "support": app_links.support_page(),
    "about": app_links.page(home=True),
    "open/index": app_links.page(),
    "signin-success": app_links.page(success=True, callback_state="S" * 43),
    "signin-failure": app_links.page(success=False, callback_state="S" * 43),
    **{"open/" + dest: app_links.page(destination=dest) for dest in app_links.DESTINATIONS},
}.items():
    (out / path).write_bytes(data)
