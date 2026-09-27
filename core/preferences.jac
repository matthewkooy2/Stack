"""Private matching preferences. Search overrides live in SavedSearch; these are the defaults."""
import from discovery.matching { validate_preferences }
import from core.timeline { _timeline_preferences }

node MatchPreferences {
    has roles: str = "", location: str = "", modes: list[str] = [], stage: str = "", years: float | None = None, education: str = "",
        employment_types: list[str] = [], salary_min: float = 0.0, salary_period: str = "year",
        exclude_companies: list[str] = [], exclude_terms: list[str] = [], soft: list[str] = [];
}

glob PREFERENCE_KEYS: list[str] = ["roles","location","modes","stage","years","education","employment_types","salary_min","salary_period","exclude_companies","exclude_terms","soft"];

def _match_node() -> MatchPreferences | None {
    items=[root -->][?:MatchPreferences];
    return items[0] if items else None;
}
def _match_preferences() -> dict[str, any] {
    p=_match_node();
    result={"roles":"","location":"","modes":[],"stage":"","years":None,"education":"","employment_types":[],"salary_min":0.0,"salary_period":"year","exclude_companies":[],"exclude_terms":[],"soft":[]};
    if p is not None {
        result={"roles":p.roles,"location":p.location,"modes":list(p.modes),"stage":p.stage,"years":p.years,"education":p.education,"employment_types":list(p.employment_types),
            "salary_min":p.salary_min,"salary_period":p.salary_period,"exclude_companies":list(p.exclude_companies),"exclude_terms":list(p.exclude_terms),"soft":list(p.soft)};
    }
    return {**result,**_timeline_preferences()};
}
"""Validate and store. Returns the keys whose values changed."""
def _save_match_preferences(roles: str, location: str, preferences: dict[str, any]) -> list[str] {
    clean=validate_preferences(preferences);
    before=_match_preferences();
    p=_match_node();
    if p is None { p=root ++> MatchPreferences(); }
    p.roles=roles.strip();p.location=location.strip();p.modes=clean["modes"];p.stage=clean["stage"];p.years=clean["years"];p.education=clean["education"];
    p.employment_types=clean["employment_types"];p.salary_min=clean["salary_min"];p.salary_period=clean["salary_period"];
    p.exclude_companies=clean["exclude_companies"];p.exclude_terms=clean["exclude_terms"];p.soft=clean["soft"];
    after=_match_preferences();
    return [k for k in PREFERENCE_KEYS if before[k]!=after[k]];
}
