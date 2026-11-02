"""Run: jac run tests/job_score_benchmark.py. Writes full JSON and a Markdown comparison."""
import hashlib
import json
import csv
from datetime import date
from pathlib import Path
from agents import scoring, job_score, record_resume
from job_score_benchmark_cases import CASES, PAIRS

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/job-score-eval'
NOW = date(2026, 11, 1)

def faithful_outline(rows):
    """Preserve every record, representing role/education paragraphs as outline headings.
    Skills paragraphs become skill lines. No inference or new facts are added.
    """
    sections = []
    for r in rows:
        if not sections or r['kind'] == 'heading':
            sections.append({'id': r['id'], 'title': r['text'] if r['kind']=='heading' else 'Resume', 'entries': [], 'lines': []})
        s = sections[-1]
        if r['kind'] == 'heading':
            continue
        if s['title'].strip() == 'Skills':
            s['lines'].append({'id': r['id'], 'label': '', 'text': r['text']})
        elif r['kind'] in ('paragraph', 'title') or not s['entries']:
            s['entries'].append({'id': r['id'], 'heading': r['text'], 'movable': True, 'bullets': []})
        else:
            s['entries'][-1]['bullets'].append({'id': r['id'], 'text': r['text']})
    return sections

def old_prediction(result, term):
    if term in ('education', 'experience'):
        c = next((c for c in result['components'] if c['key']==term), None)
        return None if c is None else c['score'] == 100
    if any(m['term'].lower()==term.lower() for m in result['matched']):
        return True
    if any(m['term'].lower()==term.lower() for m in result['missing']):
        return False
    k = next((k for k in result['keywords'] if k['term'].lower()==term.lower()), None)
    return None if k is None else k['found']

def new_prediction(result, term):
    r = next((r for r in result['requirements'] if r['term'].lower()==term.lower() or r['kind']==term), None)
    return None if r is None else (r['credit']==1 if term in ('education', 'experience') else r['credit']>0)

def old_required(result, term):
    if term in ('education', 'experience'):
        return (result['requirements'].get('years' if term=='experience' else term) or {}).get('required', False)
    r = next((r for r in result['matched']+result['missing'] if r['term'].lower()==term.lower()), None)
    return bool(r and r.get('required'))

def run():
    OUT.mkdir(parents=True, exist_ok=True)
    # Persist exact inputs and labels before execution.
    fixture = {'as_of': '2026-11', 'cases': CASES, 'ranking_pairs': PAIRS}
    (OUT/'fixtures.json').write_text(json.dumps(fixture, indent=2), encoding='utf-8')
    results=[]
    for case in CASES:
        rows, job = case['records'], case['job']
        text = '\n'.join(r['text'] for r in rows)
        native = record_resume.prepare({'records':rows, 'template':'classic','upload_digest':'','revision':0})['outline']
        old = scoring.match(faithful_outline(rows),job,now=NOW,text=text)
        old_native = scoring.match(native,job,now=NOW,text=text)
        new = job_score.score(rows,job,'2026-11')
        checks=[]
        for term, expected, required in case['checks']:
            nr=next((r for r in new['requirements'] if r['term'].lower()==term.lower() or r['kind']==term), None)
            checks.append({'term':term,'expected_supported':expected,'expected_required':required,
                'old':old_prediction(old,term),'old_native':old_prediction(old_native,term),'new':new_prediction(new,term),
                'old_required':old_required(old,term),'new_required':bool(nr and nr['required']),
                'new_evidence':nr.get('evidence',[]) if nr else []})
        # Re-run and equivalent-input probes; as_of always fixed.
        repeated=job_score.score(rows,job,'2026-11')
        noisy=[{**r,'text':'  '+r['text'].replace(' ','   ')+'  '} for r in rows]
        spaced=job_score.score(noisy,{**job,'company':'Unrelated Company','salary':'$999,999'},'2026-11')
        old_spaced=scoring.match(faithful_outline(noisy),{**job,'company':'Unrelated Company','salary':'$999,999'},now=NOW,text='\n'.join(r['text'] for r in noisy))
        results.append({'id':case['id'],'old':old,'old_native':old_native,'new':new,'checks':checks,
            'repeat_identical':new==repeated,'new_equivalent_identical':new==spaced,
            'old_equivalent_score':old['score']==old_spaced['score'],
            'old_repeat_identical':old==scoring.match(faithful_outline(rows),job,now=NOW,text=text)})
    by={r['id']:r for r in results}
    rankings=[]
    for better,worse in PAIRS:
        rankings.append({'better':better,'worse':worse,**{m: {'better_score':by[better][m]['score'],'worse_score':by[worse][m]['score'],
            'correct':by[better][m]['score']>by[worse][m]['score'],
            'tie':by[better][m]['score']==by[worse][m]['score']} for m in ('old','old_native','new')}})
    summary={}
    checks=[c for r in results for c in r['checks']]
    for model in ('old','old_native','new'):
        summary[model]={'correct':sum(c[model]==c['expected_supported'] for c in checks), 'total':len(checks),
            'false_positive':sum(c[model] is True and not c['expected_supported'] for c in checks),
            'false_negative':sum(c[model] is False and c['expected_supported'] for c in checks),
            'undetected':sum(c[model] is None for c in checks),
            'ranking_correct':sum(r[model]['correct'] for r in rankings),'ranking_total':len(rankings),
            'ranking_ties':sum(r[model]['tie'] for r in rankings)}
        if model!='old_native':
            summary[model]['requirement_priority_correct']=sum(c[model+'_required']==c['expected_required'] for c in checks)
    source_hashes={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['agents/scoring.jac','agents/job_score.jac','agents/skills.jac','discovery/matching.py','agents/data/skills.json','agents/data/skill_aliases.json','tests/job_score_benchmark_cases.py']}
    data={'baseline_commit':'46d5956','as_of':'2026-11','source_hashes':source_hashes,'summary':summary,'results':results,'rankings':rankings}
    (OUT/'results.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
    with (OUT/'comparison.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.writer(f)
        writer.writerow(['case','old_score','old_existing_record_conversion','new_score','old_correct_checks','new_correct_checks','total_checks'])
        for r in results:
            writer.writerow([r['id'],r['old']['score'],r['old_native']['score'],r['new']['score'],
                sum(c['old']==c['expected_supported'] for c in r['checks']),
                sum(c['new']==c['expected_supported'] for c in r['checks']),len(r['checks'])])
    lines=['# Old versus new job score: synthetic evaluation','',
        'Fixed fictional facts and listings; expectations authored before running. Labels are agent-authored, not independent human ground truth. No absolute numerical score is labeled correct. Baseline: 46d5956; as_of: 2026-11.', '',
        'Old uses a faithful outline of the same confirmed records. Old-native uses the existing record_resume.prepare conversion. New uses confirmed records directly. Algorithm differences should be judged against Old; Old-native also measures conversion effects.', '',
        '| Metric | Old | Old-native | New |','|---|---:|---:|---:|']
    for label,key in [('Evidence decisions correct','correct'),('False positive evidence','false_positive'),('False negative evidence','false_negative'),('Expected requirements undetected','undetected'),('Ranking pairs correct','ranking_correct'),('Ranking ties','ranking_ties')]:
        lines.append('| '+label+' | '+' | '.join(str(summary[m][key]) for m in ('old','old_native','new'))+' |')
    lines+=['',f"{len(CASES)} cases; {len(checks)} evidence checks; {len(PAIRS)} ranking pairs. Undetected requirements count as incorrect, including expected-absent requirements.",'',
        '## Cases','', '| Case | Old | Old-native | New | Incorrect evidence decisions (Old / New) |','|---|---:|---:|---:|---|']
    for r in results:
        failures=['; '.join(c['term']+'='+str(c[m]) for c in r['checks'] if c[m]!=c['expected_supported']) or 'none' for m in ('old','new')]
        lines.append('| '+r['id']+' | '+' | '.join(str(r[m]['score']) for m in ('old','old_native','new'))+' | '+' / '.join(failures)+' |')
    lines+=['','## Requirement priority','',f"Mandatory/preferred classification correct: Old {summary['old']['requirement_priority_correct']}/{len(checks)}; New {summary['new']['requirement_priority_correct']}/{len(checks)}. A missing requirement also fails this check when mandatory.", '',
        '| Case | Requirement | Expected mandatory | Old mandatory | New mandatory |','|---|---|---|---|---|']
    for r in results:
        for c in r['checks']:
            if c['old_required']!=c['expected_required'] or c['new_required']!=c['expected_required']:
                lines.append('| '+r['id']+' | '+c['term']+' | '+str(c['expected_required'])+' | '+str(c['old_required'])+' | '+str(c['new_required'])+' |')
    same=sum(r['old']['score']==r['new']['score'] for r in results)
    lines+=['','## Interpretation','',f"Old and New give exactly the same score in {same}/{len(results)} cases. The six repeated skill families dominate aggregate counts; this is evidence of targeted behavior changes, not broad generalization.", '',
        'New fixes explicit negation, name-line false positives, BSc recognition and sparse-listing refusal. It loses valid evidence for not-only constructions and a genuine claim containing a URL. Both count unrelated tenure toward a domain-specific experience requirement. Neither correctly marks CPA and RN licenses as mandatory in these examples. RN license is not extracted as its own requirement. A synthetic duplicate-keyword claim still earns full skill credit in both; deciding whether bare mentions should count as applied experience needs a separate rubric decision.', '',
        'Recommendation: retain confirmed-input and reproducibility improvements, fix the two demonstrated evidence regressions, and evaluate domain-specific experience and mandatory credentials before treating this as a generally better job-fit score. Review labels independently and add unseen examples before tuning.', '',
        '## Stability','',f"New exact repeats: {sum(r['repeat_identical'] for r in results)}/{len(results)}. Old exact repeats: {sum(r['old_repeat_identical'] for r in results)}/{len(results)}. New whitespace and ignored metadata: {sum(r['new_equivalent_identical'] for r in results)}/{len(results)}. Old equivalent scores: {sum(r['old_equivalent_score'] for r in results)}/{len(results)}.", '',
        '## Reproduce','', 'From this evaluation worktree on Linux/WSL, run `jac run tests/job_score_benchmark.py` (verified with Jac 0.37.21). No database, server or model is required. Fixtures are in `tests/job_score_benchmark_cases.py`; the new scorer is a copied snapshot and baseline files remain at 46d5956. Outputs overwrite only `output/job-score-eval/`. Source hashes in results.json pin exactly what was measured. comparison.csv provides one row per case.', '',
        '## Limits','', 'Small synthetic diagnostic set with repeated skill templates. Counts are descriptive; cases are not statistically independent. It does not establish recruiter agreement, hiring probability, numerical calibration, or broad occupation coverage. Confirmation gating and UI behavior require API/UI checks separately. Use fixtures.json for independent relabeling and add unseen real examples before tuning weights. Full outputs, requirement-priority labels and source hashes are in results.json.']
    (OUT/'report.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print(json.dumps({'cases':len(CASES),'checks':len(checks),'ranking_pairs':len(PAIRS),'summary':summary,'output':str(OUT)},indent=2))

if __name__=='__main__':
    run()
