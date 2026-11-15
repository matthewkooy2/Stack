"""Synthetic catalog generation for the isolated browser lab, never production data."""
from typing import Any
import copy
import json
import time
from pathlib import Path
from discovery.normalize import normalize, digest
from discovery.matching import facts, FACTS_VERSION
from discovery.timeline import analyze

FIXTURE_VERSION = 2

ROLES = ['Software Engineer', 'Registered Nurse', 'Accountant', 'Data Analyst', 'Teacher',
         'Mechanical Engineer', 'Product Manager', 'Marketing Specialist', 'Electrician',
         'Sales Representative', 'Financial Analyst', 'UX Designer']
PLACES = ['Detroit, MI', 'New York, NY', 'San Francisco, CA', 'Austin, TX', 'Chicago, IL']
BOARD = {'id': 'greenhouse:jobs-lab', 'adapter': 'greenhouse', 'name': 'Synthetic jobs lab',
         'board': 'jobs-lab', 'sector': 'Technology', 'domain': 'example.com', 'approved': True}

def records(count: int) -> list[dict[str, Any]]:
    now = time.time()
    templates = []
    for role in ROLES:
        for level in ('Junior ', '', 'Senior ', 'Intern '):
            for place in PLACES:
                text = (f'{level}{role} position in {place}. ' +
                        ('Internship for students graduating in 2027. ' if level == 'Intern ' else
                         'Full-time. ' + ('Requires 5 years of experience. ' if level == 'Senior ' else '')) +
                        'Salary: $80,000 - $120,000 per year. ' +
                        'Work with colleagues, communicate progress, and deliver high quality work. ' * 30)
                data = normalize({'title': level + role, 'company': 'Synthetic employer',
                                  'url': 'https://example.com/lab/template', 'country': 'US',
                                  'locations': [place], 'location': place, 'description': text,
                                  'employment_type': 'Internship' if level == 'Intern ' else 'Full-time',
                                  'posted_at': now}, BOARD)
                data['facts'] = facts(data)
                data['timeline_analysis'] = analyze(data)
                templates.append(data)
    result = []
    for i in range(count):
        data = copy.deepcopy(templates[i % len(templates)])
        data.update(id='job_' + digest(f'jobs-lab-{i}'), source_job_id=str(i),
                    company=f'Synthetic employer {i % 1000}', url=f'https://example.com/lab/jobs/{i}',
                    canonical_url=f'https://example.com/lab/jobs/{i}', identity=f'jobs-lab-{i}',
                    posted_at=now - (i % 30) * 86400 - i)
        # More title diversity than the measured production catalog, while retaining
        # meaningful base roles and matching facts. Public production content is not copied.
        data['title'] += f' — Team {i // 2}'
        target = (5000 + (i % 90) * 20) if i % 100 < 90 else (10000 + (i % 10) * 100)
        if i % 1000 == 999:
            target = 24322
        filler = ' Collaborate with your team, communicate progress, document decisions, and deliver quality work.'
        data['description'] = (data['description'] + filler * (target // len(filler) + 1))[:target]
        result.append(data)
    return result

def manifest(count):
    path = Path('storage/jobs-lab/manifest.json')
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {'kind': 'synthetic', 'catalog_jobs': count,
                               'fixture_version': FIXTURE_VERSION, 'roles': ROLES, 'locations': PLACES,
                               'production_count': 12840, 'production_fresh_count': 9544,
                               'production_distinct_titles': 9979, 'production_snapshot_utc': '2026-11-02T01:27:34Z',
                               'note': 'Synthetic stress test sized above measured production catalog. Distribution and hardware differ.'}
    if path.exists():
        previous = json.loads(path.read_text())
        if {key: value for key, value in previous.items() if key != 'generated_at'} == data:
            return
    data['generated_at'] = time.time()
    path.write_text(json.dumps(data, indent=2))


def catalog_namespace() -> str:
    """Use the same namespace as the real prepared main.jac service."""
    from jaclang.runtime.prepared import PreparedApplication, application_namespace
    base = str(Path.cwd().resolve())
    return application_namespace(PreparedApplication(base, str(Path(base) / 'main.jac'))) + '.core.catalog'


def needs_seed(store: Any, count: int) -> bool:
    target = catalog_namespace()
    rows = store.rows("SELECT count(*), min((props->'archetype'->>'checked_at')::float8), "
                      "count(*) FILTER (WHERE arch_module<>:module) FROM anchors WHERE arch_type='CatalogJob'",
                      {'module': target})[0]
    marker = Path('storage/jobs-lab/manifest.json')
    previous = json.loads(marker.read_text()) if marker.exists() else {}
    from core.catalog import MATCH_INDEX_VERSION
    projection = store.rows("SELECT count(*) FROM anchors WHERE arch_type='CatalogTitles' "
                            "AND (props->'archetype'->>'facts_version')::int=:version "
                            "AND (props->'archetype'->>'projection_version')::int=:projection_version AND arch_module=:module",
                            {'version': FACTS_VERSION, 'projection_version': MATCH_INDEX_VERSION, 'module': target})[0][0]
    return not (projection == 1 and rows[0] == count and rows[2] == 0 and (rows[1] or 0) > time.time() - 86400
                and previous.get('fixture_version') == FIXTURE_VERSION)


def bind_catalog(store: Any, prepared: bool) -> None:
    """Only the stopped lab's synthetic catalog types cross this seed/server boundary.

    Raw Jac execution and prepared serving use different module identities in
    0.37.21. Preserve stable IDs, edges and accounts; normalize only when seeding
    is required, then bind back before the API starts. Normal restarts skip it.
    """
    module = catalog_namespace()
    store.rows("UPDATE anchors SET arch_module=:target, "
               "props=jsonb_set(props,'{archetype,__module__}',to_jsonb(CAST(:target AS text))), "
               "version=version+1 WHERE arch_type IN ('CatalogJob','CatalogTitles','JobAlias','CatalogMatchGroup') "
               "AND arch_module IN ('core.catalog',:module) AND arch_module<>:target",
               {'target': module if prepared else 'core.catalog', 'module': module})
    store.commit()


def configure_shared_root() -> None:
    """Match JacAPIServer's guest shared root, rather than the raw CLI super root."""
    from jaclang.runtime.runtime import JacRuntime
    from jaclang.runtime.constants import Constants
    from jaclang.server.identity.user_manager import UserManager
    manager = UserManager(base_path=str(Path.cwd()))
    manager.ensure_internal_user(Constants.GUEST.value, '__no_password__')
    shared = manager.get_root_id(Constants.GUEST.value)
    ctx = JacRuntime.get_context()
    store = ctx.mem.store
    module = catalog_namespace()
    params = {'shared': shared, 'module': module}
    # Adopt only catalog fixtures made by the earlier raw CLI seed. Root edges
    # are normalized store rows; no account roots or personal nodes are moved.
    store.rows("UPDATE anchors SET root_id=CAST(:shared AS uuid), "
               "props=jsonb_set(props,'{root}',to_jsonb(CAST(:shared AS text))),version=version+1 "
               "WHERE arch_type IN ('CatalogJob','CatalogTitles','JobAlias','CatalogMatchGroup') "
               "AND arch_module IN ('core.catalog',:module) "
               "AND root_id='00000000-0000-0000-0000-000000000000'", params)
    store.rows("UPDATE anchors SET root_id=CAST(:shared AS uuid),src=CAST(:shared AS uuid), "
               "props=props || jsonb_build_object('root',CAST(:shared AS text),'source',CAST(:shared AS text)), "
               "version=version+1 WHERE kind='EdgeAnchor' "
               "AND src='00000000-0000-0000-0000-000000000000' AND dst IN "
               "(SELECT id FROM anchors WHERE arch_type IN ('CatalogJob','CatalogTitles','JobAlias','CatalogMatchGroup') "
               "AND arch_module IN ('core.catalog',:module))", params)
    store.commit()
    ctx.mem.abort()
    JacRuntime.set_shared_root_resolver(lambda: shared)
    ctx.set_user_root(shared)
