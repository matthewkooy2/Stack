"""Offline collector regression: observes two independent synthetic sources."""
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path


import jobs_sweep as sweep

class CollectorTest(unittest.TestCase):
    def test_removed_failed_empty_and_reappeared(self):
        with tempfile.TemporaryDirectory() as directory, sqlite3.connect(Path(directory) / 'test.sqlite') as db:
            db.executescript("""
                CREATE TABLE catalog_jobs(id TEXT PRIMARY KEY,data TEXT);
                CREATE TABLE catalog_sources(id TEXT PRIMARY KEY,data TEXT);
                CREATE TABLE catalog_sweeps(id TEXT PRIMARY KEY,data TEXT);
            """)
            db.execute('PRAGMA foreign_keys=ON')
            sweep.schema(db)
            a = {'id':'synthetic-a','name':'Synthetic A','adapter':'greenhouse'}
            b = {'id':'synthetic-b','name':'Synthetic B','adapter':'lever'}
            def job(key):
                return {'title':'Software Engineer','company':'Synthetic','url':f'https://example.invalid/jobs/{key}',
                        'country':'US','source_job_id':key,'description':'Build high quality services.'}
            def apply(source, ids, invalid=0):
                jobs = [sweep.normalize(job(key),source) for key in ids]
                return sweep.run(db,[source],lambda *args:{'jobs':jobs,'invalid':invalid,'complete':True},False)
            def state(key):
                raw = db.execute("SELECT data FROM catalog_jobs WHERE json_extract(data,'$.source_job_id')=?",(key,)).fetchone()[0]
                return json.loads(raw)
            apply(a,['one','two'])
            first = state('one')
            apply(b,['one','three'])
            merged = state('one')
            self.assertEqual(len(merged['sources']),2)
            self.assertEqual(merged['first_seen_at'],first['first_seen_at'])
            apply(a,['two'])
            self.assertTrue(state('one')['active'])
            apply(b,[],0)
            self.assertTrue(state('one')['active'])
            self.assertEqual(sweep.status(db,b)['status'],'error')
            apply(b,['three'],1)
            self.assertTrue(state('one')['active'])
            self.assertEqual(sweep.status(db,b)['status'],'partial')
            sweep.run(db,[b],lambda *args: (_ for _ in ()).throw(OSError()),False)
            self.assertTrue(state('one')['active'])
            apply(b,['three'])
            self.assertFalse(state('one')['active'])
            self.assertEqual(state('one')['last_seen_at'],merged['last_seen_at'])
            apply(a,['one','two'])
            self.assertTrue(state('one')['active'])
            self.assertEqual(state('one')['first_seen_at'],first['first_seen_at'])
            self.assertGreater(state('one')['last_seen_at'],merged['last_seen_at'])
            self.assertEqual(db.execute('SELECT count(*) FROM catalog_jobs').fetchone()[0],3)

            self.assertEqual(sweep.report(db,0,'')['counts'],{'total':3,'active_fresh':3})
            page = sweep.report(db,1,'')
            self.assertNotIn('description',page['jobs'][0])
            self.assertEqual(len(sweep.report(db,10,page['next_cursor'])['jobs']),2)
            sweep.manage(db,'disable',b['id'])
            self.assertEqual(sweep.status(db,b)['status'],'disabled')
            self.assertTrue(state('one')['active'])
            sweep.manage(db,'enable',b['id'])
            self.assertEqual(sweep.status(db,b)['status'],'pending')
            sweep.manage(db,'purge',b['id'])
            self.assertTrue(state('one')['active'])
            self.assertEqual([o['source_id'] for o in state('one')['sources']],[a['id']])
            self.assertEqual(db.execute('SELECT count(*) FROM catalog_jobs').fetchone()[0],2)

if __name__ == '__main__':
    unittest.main()
