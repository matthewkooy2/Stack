"""Collect into an initialized Rust dev catalog; execute from the Stack repository root.

python3 backend-rust/src/jobs_sweep.py DATABASE sweep
python3 backend-rust/src/jobs_sweep.py DATABASE fixture FIXTURE.json
A fixture contains {"source": {"id":..., "name":..., "adapter":...}, "pages":
[{"jobs": [raw listings accepted by discovery.normalize.normalize], "complete": true}]}.
"""
import argparse
import base64
from contextlib import contextmanager, nullcontext
import fcntl
import json
from pathlib import Path
import sqlite3
import sys
import time
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from uuid import uuid4

sys.path.insert(0, str(Path.cwd()))
from discovery.matching import facts
from discovery.normalize import classify, dedupe_bucket, normalize, same_opening
from discovery.sources import collect
from discovery.timeline import analyze

ATS = {'ashby', 'greenhouse', 'lever', 'smartrecruiters'}


def dump(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def schema(db):
    db.executescript("""
        CREATE TABLE IF NOT EXISTS job_source_postings(
            source TEXT NOT NULL, external TEXT NOT NULL, job TEXT NOT NULL REFERENCES catalog_jobs(id) ON DELETE CASCADE,
            PRIMARY KEY(source,external));
        CREATE INDEX IF NOT EXISTS source_postings_job ON job_source_postings(job);
        CREATE TABLE IF NOT EXISTS job_original_urls(
            url TEXT PRIMARY KEY, job TEXT NOT NULL REFERENCES catalog_jobs(id) ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS catalog_unlisted_sources(
            id TEXT PRIMARY KEY REFERENCES catalog_sources(id) ON DELETE CASCADE);
        CREATE INDEX IF NOT EXISTS catalog_canonical ON catalog_jobs(json_extract(data,'$.canonical_url'));
        CREATE INDEX IF NOT EXISTS catalog_bucket ON catalog_jobs(json_extract(data,'$.dedupe_bucket'));
        CREATE TABLE IF NOT EXISTS job_source_config(id TEXT PRIMARY KEY, config TEXT NOT NULL, checkpoint TEXT NOT NULL DEFAULT '{}');
    """)


def load_brands(db):
    directory = Path('discovery')
    for brand in json.loads((directory/'employer_brands.json').read_text('utf-8')):
        domain = brand['domain']
        png = base64.b64encode((directory/'brand_logos'/f'{domain}.png').read_bytes()).decode('ascii')
        db.execute('INSERT INTO catalog_brands VALUES(?,?) ON CONFLICT(domain) DO UPDATE SET png=excluded.png',(domain,png))
        keys = ['domain:'+host for host in brand['domains']] + ['board:'+board for board in brand['boards']]
        db.executemany('INSERT INTO catalog_brand_keys VALUES(?,?) ON CONFLICT(lookup) DO UPDATE SET domain=excluded.domain',((key,domain) for key in keys))

def status(db, source):
    row = db.execute('SELECT data FROM catalog_sources WHERE id=?', (source['id'],)).fetchone()
    if row:
        return json.loads(row[0])
    return {'id':source['id'], 'adapter':source['adapter'], 'name':source['name'], 'sector':source.get('sector', 'Uncategorized'),
            'status':'pending', 'message':'', 'last_success':0.0, 'imported':0, 'unique_added':0}


def persist_status(db, record):
    db.execute('INSERT INTO catalog_sources VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data', (record['id'], dump(record)))


def register(db, source):
    db.execute('INSERT INTO job_source_config(id,config) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET config=excluded.config',
               (source['id'], dump(source)))
    record = status(db, source)
    persist_status(db, record)
    db.execute('DELETE FROM catalog_unlisted_sources WHERE id=?', (source['id'],))
    return record


def listing_url(job):
    url = job['url']
    parsed = urlsplit(url)
    if job['source'] == 'smartrecruiters' and parsed.hostname == 'jobs.smartrecruiters.com' and not parsed.path.startswith('/oneclick-ui/'):
        params = [(k,v) for k,v in parse_qsl(parsed.query, keep_blank_values=True) if k.lower() != 'oga']
        return urlunsplit(parsed._replace(query=urlencode(params)))
    return url


def observe(db, source, data, run):
    source_id = source['id']
    bucket = dedupe_bucket(data)
    row = db.execute('SELECT data FROM catalog_jobs WHERE id=(SELECT job FROM job_source_postings WHERE source=? AND external=?)',
                     (source_id, data['source_job_id'])).fetchone()
    if row is None:
        row = db.execute('SELECT data FROM catalog_jobs WHERE id=? OR json_extract(data,\'$.canonical_url\')=? LIMIT 1',
                         (data['id'], data['canonical_url'])).fetchone()
    if row is None:
        row = db.execute('SELECT j.data FROM job_original_urls u JOIN catalog_jobs j ON j.id=u.job WHERE u.url=?',
                         (data['canonical_url'],)).fetchone()
    if row is None:
        for candidate in db.execute("SELECT data FROM catalog_jobs WHERE json_extract(data,'$.dedupe_bucket')=?", (bucket,)):
            if same_opening(json.loads(candidate[0]), data):
                row = candidate
                break

    previous = json.loads(row[0]) if row else {}
    added = not bool(previous)
    timestamp = time.time()
    sources = {item['source_id']:item for item in previous.get('sources', [])}
    sources[source_id] = {'source_id':source_id, 'name':source['name'], 'adapter':source['adapter'],
                          'source_job_id':data['source_job_id'], 'url':data['url'], 'last_seen':timestamp,
                          'run':run, 'active':True, 'attribution':data.get('attribution', {})}
    # Prefer a direct board's complete job over the listing aggregator's copy.
    if previous.get('source') in ATS and data['source'] not in ATS:
        data = previous.copy()
    data['id'] = previous.get('id', data['id'])
    data['dedupe_bucket'] = bucket
    data['sources'] = list(sources.values())
    data['timeline_analysis'] = analyze(data)
    data['occupation'] = classify(data['title'])
    data['facts'] = facts(data)
    if data['mode'] == 'Unknown' and data['facts'].get('stated_mode'):
        data['mode'] = data['facts']['stated_mode']
    types = [data['employment_type']] if data['employment_type'] != 'Unknown' else data['facts']['employment']
    level = data['seniority'] if data['seniority'] != 'Unknown' else data['facts']['level']
    data['tags'] = list(dict.fromkeys(v for v in [*types,level] if v))
    data.update(active=True, stale=False, first_seen_at=previous.get('first_seen_at',timestamp), last_seen_at=timestamp,
                discovered_at=previous.get('discovered_at',timestamp), checked_at=timestamp, listing_url=listing_url(data))
    db.execute("INSERT INTO catalog_jobs VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", (data['id'], dump(data)))
    observation = sources[source_id]
    db.execute('INSERT INTO job_source_postings VALUES(?,?,?) ON CONFLICT(source,external) DO UPDATE SET job=excluded.job',
               (source_id, observation['source_job_id'], data['id']))
    return added


def deactivate_missing(db, source_id, run):
    # Keep observations from failed/incomplete sources, including cross-posted jobs.
    for key, raw in db.execute('SELECT DISTINCT j.id,j.data FROM job_source_postings p JOIN catalog_jobs j ON j.id=p.job WHERE p.source=?',
                               (source_id,)):
        job = json.loads(raw)
        changed = False
        for obs in job['sources']:
            if obs['source_id'] == source_id and obs['active'] and obs['run'] != run:
                obs['active'] = False
                changed = True
        if changed:
            job['active'] = any(obs['active'] for obs in job['sources'])
            db.execute('UPDATE catalog_jobs SET data=? WHERE id=?', (dump(job), key))


def source_sweep(db, source, run, read_page):
    record = status(db, source)
    if record['status'] == 'disabled':
        return []
    found = []
    approved = set()
    invalid = seen = 0
    checkpoint = {}
    if source['adapter'] in ('github','github_search'):
        checkpoint = json.loads(db.execute('SELECT checkpoint FROM job_source_config WHERE id=?',(source['id'],)).fetchone()[0])
    try:
        for index in range(400):
            page = read_page(source, checkpoint, index)
            invalid += page.get('invalid', 0)
            for pos in range(0, len(page['jobs']), 100):
                with db:
                    for job in page['jobs'][pos:pos+100]:
                        record['unique_added'] += observe(db, source, job, run)
                        record['imported'] += 1
                        seen += 1
                    persist_status(db,record)
            checkpoint = page.get('checkpoint', {})
            for candidate in page.get('candidates', []):
                if candidate.get('approved') and candidate.get('adapter') in ATS and candidate['id'] not in approved:
                    found.append({**candidate, 'found_by':source['id']})
                    approved.add(candidate['id'])
            if page.get('complete'):
                break
        else:
            raise ValueError('Source exceeded the page limit.')
        with db:
            if invalid:
                record.update(status='partial',message='Some listings could not be read; listings missing from this source were kept.')
            elif not seen and source['adapter'] in ATS and record['imported']:
                record.update(status='error',message='The board returned no listings. Previous listings are kept.')
            else:
                deactivate_missing(db,source['id'],run)
                record.update(status='ready',message='',last_success=time.time())
            db.execute('UPDATE job_source_config SET checkpoint=? WHERE id=?',(dump(checkpoint),source['id']))
            persist_status(db,record)
    except (ValueError, KeyError, TypeError, OSError, IndexError) as exc:
        # External collection failures do not expire previously verified observations.
        with db:
            record = status(db,source)
            record.update(status='error', message=f'Source could not be collected ({type(exc).__name__}). Previous listings are kept.')
            persist_status(db,record)
    return found


@contextmanager
def exclusive(database):
    with Path(str(database)+'.catalog.lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX|fcntl.LOCK_NB)
        yield


def run(db, sources, fetcher, include_registered):
    run_id = str(uuid4())
    started = time.time()
    with db:
        db.execute("UPDATE catalog_sweeps SET data=json_set(data,'$.status','failed','$.finished_at',?) WHERE json_extract(data,'$.status')='collecting'",(started,))
        db.execute('INSERT INTO catalog_sweeps VALUES(?,?)',(run_id,dump({'started_at':started,'finished_at':0,'status':'collecting'})))
        for s in sources: register(db,s)
    if include_registered:
        configured = {s['id'] for s in sources}
        for (raw,) in db.execute("SELECT config FROM job_source_config WHERE json_extract(config,'$.found_by') IS NOT NULL"):
            s = json.loads(raw)
            if s['found_by'] in configured: sources.append(s)
    queue = sorted(sources,key=lambda s: (s['adapter'] not in ('github','github_search'),s['id']))
    queued = {s['id'] for s in queue}
    discovered = db.execute("SELECT COUNT(*) FROM job_source_config WHERE json_extract(config,'$.found_by') IS NOT NULL").fetchone()[0]
    for s in queue:
        additions = source_sweep(db,s,run_id,fetcher)
        for new in additions:
            if new['id'] not in queued and discovered < 300:
                with db: register(db,new)
                queue.append(new)
                queued.add(new['id'])
                discovered += 1
    with db:
        db.execute("UPDATE catalog_sweeps SET data=json_set(data,'$.status','done','$.finished_at',?) WHERE id=?",(time.time(),run_id))
    return {'sources':len(queue),'listings':db.execute('SELECT count(*) FROM catalog_jobs').fetchone()[0]}


def manage(db, action, source_id):
    if action == 'rebuild_matches':
        with db:
            db.execute('DELETE FROM job_match_cache')
        return {'saved':True}
    row = db.execute('SELECT data FROM catalog_sources WHERE id=?',(source_id,)).fetchone()
    if row is None:
        raise ValueError('Source not found.')
    record = json.loads(row[0])
    with db:
        if action == 'enable':
            record.update(status='pending',message='')
        elif action in ('disable','purge'):
            record.update(status='disabled',message='Disabled by the operator.')
            if action == 'purge':
                # A revoked source's own description must disappear even on a cross-posted listing.
                rows = db.execute('SELECT DISTINCT j.id,j.data FROM catalog_jobs j JOIN job_source_postings p ON p.job=j.id WHERE p.source=?',(source_id,))
                for key, raw in rows.fetchall():
                    job = json.loads(raw)
                    others = [obs for obs in job['sources'] if obs['source_id'] != source_id]
                    if not others or job['source_id'] == source_id:
                        db.execute('DELETE FROM catalog_jobs WHERE id=?',(key,))
                    else:
                        job['sources'] = others
                        job['active'] = any(o['active'] for o in others)
                        db.execute('UPDATE catalog_jobs SET data=? WHERE id=?',(dump(job),key))
                db.execute('DELETE FROM job_source_postings WHERE source=?',(source_id,))
        else:
            raise ValueError('Use enable, disable, or purge.')
        persist_status(db,record)
    return {'saved':True}


def report(db, limit, after):
    if not 0 <= limit <= 100:
        raise ValueError('Choose a listing page size between 0 and 100.')
    generated = time.time()
    source_query = "SELECT data FROM catalog_sources WHERE json_extract(data,'$.status')!='disabled'"
    if db.execute("SELECT 1 FROM sqlite_schema WHERE name='catalog_unlisted_sources' AND type='table'").fetchone():
        source_query += " AND id NOT IN (SELECT id FROM catalog_unlisted_sources)"
    sources = [json.loads(r[0]) for r in db.execute(source_query + " ORDER BY id")]
    last = db.execute("SELECT data FROM catalog_sweeps ORDER BY json_extract(data,'$.started_at') DESC LIMIT 1").fetchone()
    active, total = db.execute("""SELECT count(*) FILTER(WHERE json_extract(data,'$.active') AND json_extract(data,'$.checked_at')>=?
                              AND (coalesce(json_extract(data,'$.expires_at'),0)=0 OR json_extract(data,'$.expires_at')>?)),
                              count(*) FROM catalog_jobs""", (generated-604800,generated)).fetchone()
    out = {'generated_at':generated,'sources':sources,'sweep':json.loads(last[0]) if last else {},
           'counts':{'active_fresh':active,'total':total},'jobs':[],'next_cursor':''}
    if limit:
        rows = list(db.execute('SELECT id,data FROM catalog_jobs WHERE id>? ORDER BY id LIMIT ?', (after,limit+1)))
        if len(rows)>limit:
            out['next_cursor'] = rows[limit-1][0]
        for _, raw in rows[:limit]:
            job = json.loads(raw)
            for key in ('description','qualifications','requirements','facts','dedupe_bucket'):
                job.pop(key,None)
            expires = job.get('expires_at') or 0
            job['active'] = bool(job['active'] and (not expires or expires>generated))
            job['stale'] = job.get('checked_at',0)<generated-604800
            out['jobs'].append(job)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('database',type=Path)
    sub = parser.add_subparsers(dest='mode',required=True)
    sub.add_parser('sweep')
    fixture = sub.add_parser('fixture')
    fixture.add_argument('file',type=Path)
    admin = sub.add_parser('manage')
    admin.add_argument('action',choices=['enable','disable','purge','rebuild_matches'])
    admin.add_argument('source',nargs='?',default='')
    audit = sub.add_parser('report')
    audit.add_argument('--limit',type=int,default=0)
    audit.add_argument('--after',default='')
    args = parser.parse_args()
    readonly = args.mode == 'report'
    uri = args.database.resolve().as_uri()+('?mode=ro' if readonly else '?mode=rw')
    lock = nullcontext() if readonly else exclusive(args.database)
    with lock, sqlite3.connect(uri,uri=True,timeout=30) as db:
        db.execute('PRAGMA foreign_keys=ON')
        if readonly:
            db.execute('BEGIN')
            print(dump(report(db,args.limit,args.after)))
            return
        schema(db)
        if args.mode == 'manage':
            print(dump(manage(db,args.action,args.source)))
            return
        with db: load_brands(db)
        if args.mode == 'fixture':
            fixture = json.loads(args.file.read_text('utf-8'))
            def read(source, checkpoint, index):
                page = fixture['pages'][index]
                return {**page,'jobs':[normalize(job,source) for job in page['jobs']], 'candidates':[]}
            result = run(db,[fixture['source']],read,False)
        else:
            result = run(db,json.loads(Path('discovery/sources.json').read_text('utf-8')),lambda s,c,i:collect(s,c),True)
        print(dump(result))


if __name__ == '__main__':
    main()
