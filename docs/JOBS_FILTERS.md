# Jobs search contract

`save_search(query, filters)` persists per-account overrides and returns the stored
query and filters. Restore these from `bootstrap.saved_search`. Pass them to
`search_jobs` for every page; changing a filter or sort requires a new cursor.
Preserve unrelated filter keys when editing a single control or applying a preset.
Profile edits supersede older overrides only for the values the user changed.

Suggested entry-level software search:

```json
{
  "query": "Software engineer",
  "filters": {
    "levels": ["Entry-level"],
    "employment_types": ["Full-time"],
    "confirmed_level": true
  }
}
```

Internships are a separate search: use `levels: ["Internship"]` and
`employment_types: ["Internship"]`. Applying either preset should clear an
incompatible occupation override and `any_role`, while preserving location, pay,
sort, graduation timeline, employer exclusions and other user choices.

`confirmed_level` is a boolean, false by default. With explicit selected levels
(or a level in the role query), true excludes listings whose level is unknown.
It does not demand confirmation of work arrangement, pay or other preferences.
With no selected or query-implied level it has no effect. Existing
`confirmed_only` applies to all required unknown details and is a separate choice.

Graduation filtering uses the saved profile's `graduation_month` and
`available_from`. `timeline: "compatible"` includes unknown timing but excludes
explicit mismatches. `"confirmed"` requires explicit listing evidence matching
the saved graduation date; without that date it returns no jobs and a notice to
set the date. `"all"` includes mismatches. A junior or new-grad title alone does
not establish 2027 eligibility. Availability applies to non-internship roles.
Surface each card's timeline status and wording accurately.

Role, level, timeline and other required filters are evaluated over all fresh
active catalog entries before ranking and the 25-result pagination boundary.
`criteria` describes effective profile/search inputs, including `confirmed_level`;
`excluded` summarizes requirement conflicts; `total` counts all matching jobs.
Empty results should invite a filter or timeline edit, without silently broadening
the search or reapplying defaults. Blank target roles intentionally search all
professions; personalization must never purge the shared all-role catalog.
