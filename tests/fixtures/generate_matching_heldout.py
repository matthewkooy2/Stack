"""Author an offline synthetic regression matrix, without employer source text.

Labels below express intended behavior before running the matcher. This is a
regression fixture, not a held-out measurement of real-world accuracy.
"""
import copy
import json
from pathlib import Path


def build():
    personas = {
        "teacher_texas": dict(roles="Teacher", stage="Early career", years=2, education="Bachelor's", location="Texas", modes=[], employment_types=["Full-time"]),
        "swe_new_grad_sf": dict(roles="Software engineer", stage="Recent graduate", years=0, education="Bachelor's", graduation_month="2026-05", location="San Francisco, CA", modes=[], employment_types=["Full-time"], salary_min=120000, salary_period="year"),
        "swe_experienced_sf": dict(roles="Software engineer", stage="Experienced", years=6, education="Bachelor's", location="San Francisco, CA", modes=[], employment_types=["Full-time"], salary_min=200000, salary_period="year"),
        "cook_california": dict(roles="Cook", stage="Experienced", years=4, education="High school", location="California", modes=[], employment_types=["Full-time", "Part-time"], salary_min=18, salary_period="hour"),
        "pm_remote_denver": dict(roles="Product manager", stage="Experienced", years=7, education="Bachelor's", location="Denver, CO", modes=["Remote"], employment_types=["Full-time"], salary_min=150000, salary_period="year"),
        "project_manager_changer_va": dict(roles="Project manager", stage="Career changer", years=2, education="Bachelor's", location="Virginia", modes=[], employment_types=["Full-time"]),
        "account_exec_chicago": dict(roles="Account executive", stage="Early career", years=3, education="Bachelor's", location="Chicago, IL", modes=["Hybrid", "On-site"], employment_types=["Full-time"], salary_min=60000, salary_period="year"),
    }
    groups = [
        ("teacher_texas", "Elementary School Teacher", "Austin, TX", "On-site", 1, None, "Plan classroom exercises and explain number patterns using original worksheets."),
        ("swe_new_grad_sf", "Software Engineer", "San Francisco, CA", "On-site", 0, (125000, 140000, "year"), "Build a fictional library checkout service, review code, and write automated tests."),
        ("cook_california", "Line Cook", "Sacramento, CA", "On-site", 2, (20, 24, "hour"), "Prepare a small seasonal menu, label ingredients, and clean a shared kitchen station."),
        ("pm_remote_denver", "Product Manager", "Remote - US", "Remote", 4, (160000, 180000, "year"), "Prioritize improvements to a fictional scheduling tool and evaluate usability feedback."),
        ("project_manager_changer_va", "Project Manager", "Richmond, VA", "On-site", 1, None, "Coordinate a fictional equipment refresh, track milestones, and record project decisions."),
        ("account_exec_chicago", "Account Executive", "Chicago, IL", "Hybrid", 2, (70000, 85000, "year"), "Explain a fictional inventory product, prepare demonstrations, and record customer questions."),
    ]
    listings, labels = {}, {name: {} for name in personas}

    def record(key, title, location, mode, years, pay, duty):
        requirements = "No experience required." if years == 0 else f"{years}+ years of relevant experience required."
        return dict(title=title, company=f"Synthetic Harbor Employer {key}", location=location,
                    locations=[location] if location else [], country="US", mode=mode,
                    employment_type="Full-time", compensation={} if pay is None else
                    dict(min=pay[0], max=pay[1], unit=pay[2], currency="USD"),
                    description=f"Fictional test vacancy; no applications accepted.\nResponsibilities\n{duty}\nRequirements\n{requirements}",
                    qualifications="", eligibility="", remote_eligibility="", snippet="",
                    posted_at=1790467200, url=f"https://example.invalid/jobs/{key}", group="synthetic")

    for group, (persona, title, location, mode, years, pay, duty) in enumerate(groups):
        for scenario in range(11):
            key = f"S{group * 11 + scenario:02}"
            item = record(key, title, location, mode, years, pay, duty)
            label = "suitable"
            if scenario == 1:
                item["description"] += "\nThe team shares task notes during a short daily meeting."
            elif scenario == 2:
                item.update(location="", locations=[], mode="")
                label = "unknown"
            elif scenario == 3:
                item["employment_type"] = "Unknown"
                label = "unknown"
            elif scenario == 4:
                item["compensation"] = {}
                if pay is None:
                    item["employment_type"] = "Unknown"
                label = "unknown"
            elif scenario == 5:
                item.update(location="Boston, MA", locations=["Boston, MA"], mode="On-site")
                label = "unsuitable"
            elif scenario == 6:
                item["employment_type"] = "Contract"
                label = "unsuitable"
            elif scenario == 7:
                item["description"] = f"Fictional test vacancy.\nResponsibilities\n{duty}\nRequirements\n20+ years of relevant experience required."
                label = "unsuitable"
            elif scenario == 8:
                item["title"] = "Warehouse Inventory Clerk"
                label = "unsuitable"
            elif scenario == 9:
                item["description"] += "\nAdditional training is offered after hiring."
            elif scenario == 10:
                item.update(country="CA", location="Toronto, ON", locations=["Toronto, ON"], mode="On-site")
                label = "unsuitable"
            listings[key] = item
            labels[persona][key] = label
            # An experienced SWE rejects the junior pay range; with missing pay
            # there is no demonstrated conflict and it remains uncertain.
            if persona == "swe_new_grad_sf":
                labels["swe_experienced_sf"][key] = "unknown" if scenario == 4 else "unsuitable"

    listings["S66"] = record("S66", "Senior Software Engineer", "San Francisco, CA", "Hybrid", 5,
                              (220000, 240000, "year"), "Review a fictional queue service and investigate test failures.")
    labels["swe_experienced_sf"]["S66"] = "suitable"
    labels["swe_new_grad_sf"]["S66"] = "unsuitable"
    listings["S67"] = copy.deepcopy(listings["S11"])
    listings["S67"].update(company="Synthetic Harbor Employer S67", url="https://example.invalid/jobs/S67")
    listings["S67"]["description"] += "\nPair with a mentor to review the first implementation."
    labels["swe_new_grad_sf"]["S67"] = "suitable"
    labels["swe_experienced_sf"]["S67"] = "unsuitable"
    return dict(about="Original synthetic regression scenarios. All employers, listings and contacts are fictional. Labels are authored independently of matcher output. The historical filename is retained for CLI compatibility; this is not a real-world held-out benchmark.",
                today="2026-09-27", provenance="Originally authored for Stack; no employer descriptions were copied or paraphrased.",
                personas=personas, listings=listings, labels=labels)


if __name__ == "__main__":
    Path(__file__).with_name("matching_heldout.json").write_text(
        json.dumps(build(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
