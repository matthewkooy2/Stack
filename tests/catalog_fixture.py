"""Seeds a disposable catalog through the daily-sweep endpoints, as the sweep itself does."""
import sys
from unittest.mock import patch

BOARD = {'id': 'greenhouse:fixture', 'adapter': 'greenhouse', 'board': 'fixture', 'name': 'Fixture Board',
         'domain': 'example.com', 'sector': 'Technology', 'approved': True}


def catalog_modules():
    # JacTestClient prepares a namespaced application module distinct from ordinary
    # Python imports. Patch that loaded test module, rather than an unused alias.
    return [module for name, module in list(sys.modules.items())
            if name.endswith('core.catalog') and hasattr(module, '_worker_allowed')]


def open_worker_gate(case, sources=(BOARD,)):
    """Allows the fictional worker token and replaces the configured sources for this test only."""
    modules = catalog_modules()
    case.assertTrue(modules, 'Prepared catalog test module must be loaded')
    gates = [patch.object(m, '_configured', return_value=[dict(s) for s in sources]) for m in modules]
    # The API module imports the gate by name, so patch every loaded binding of it.
    gates += [patch.object(m, '_worker_allowed', return_value=True) for m in list(sys.modules.values())
              if getattr(m, '_worker_allowed', None) is not None and hasattr(m, 'jobs_sweep_finish') or m in modules]
    for gate in gates:
        gate.start()
        case.addCleanup(gate.stop)


def sweep(system, pages, finish=True):
    """`pages` maps a source id to its listings, or to an error string. Returns the run id."""
    run = system('jobs_sweep_begin', {})['run']
    for source_id, jobs in pages.items():
        if isinstance(jobs, str):
            system('jobs_sweep_source', {'run': run, 'id': source_id, 'error': jobs})
        else:
            system('jobs_sweep_source', {'run': run, 'id': source_id, 'jobs': jobs, 'complete': True})
    while finish and not system('jobs_sweep_finish', {'run': run})['done']:
        pass
    return run


def publish(system, config, jobs):
    """Publishes `jobs` from one source through the real sweep endpoints. `system` adds the worker token."""
    run = system('jobs_sweep_begin', {'only': [config]})['run']
    return system('jobs_sweep_source', {'run': run, 'id': config['id'], 'jobs': jobs, 'complete': True})


def career(url):
    """A single-page source for synthetic listings, so tests need no real job board."""
    from discovery.normalize import digest
    return {'id': 'career:'+digest(url), 'adapter': 'career', 'name': 'Synthetic', 'url': url,
            'domain': 'example.com', 'sector': 'Technology', 'approved': True}
