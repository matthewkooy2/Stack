"""Run synthetic release runtime tests using the pinned embedded interpreter."""
import os;
import sys;
import unittest;
with entry:__main__ {
    if os.environ.get('JAC_DB_URL') { raise RuntimeError('External database forbidden for release tests.'); }
    os.environ['JAC_DB_SCRATCH']='1';
    suite=unittest.TestSuite();
    for pattern in ['test_release_runtime.py','test_browser_service.py'] {
        suite.addTests(unittest.defaultTestLoader.discover('tests',pattern=pattern));
    }
    result=unittest.TextTestRunner(verbosity=2).run(suite);
    if not result.wasSuccessful() { sys.exit(1); }
}
