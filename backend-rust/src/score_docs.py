"""Read only owned, confirmed inputs provided by the Rust dispatcher."""
import base64
import json
import time
import os
from pathlib import Path
import sys
import tempfile

root=Path(sys.argv[1]).resolve()
sys.path[:0]=[str(root),str(root/'score-docs')]

def compile_source(request):
    from agents import latex
    started = time.monotonic()
    raw = base64.b64decode(request['raw'], validate=True)
    if request['builtin']:
        from agents.resume_templates import fill
        data = json.loads(raw)
        source = fill(data['template'], data['values'])
        view = {'kind':'builtin','label':request['label'],'template':data['template'],'skipped':[]}
    else:
        source = latex.load(request['name'], raw)
        view = {'kind':'upload','label':'Your LaTeX','file':request['name'],'skipped':source['skipped'][:20]}
    structure = latex.parse(source)
    if not request['builtin'] and not structure['bullets']:
        raise ValueError(r'Stack could not find bullet points. Use \item or \resumeItem bullets, or choose a built-in template.')
    parsed = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='stack-source-') as workspace:
        os.chdir(workspace)
        cache = root/'score-docs'/'tex-cache'
        if not cache.is_dir():
            raise ValueError('The selected resume template renderer is unavailable.')
        Path('.jac').mkdir(mode=0o700)
        Path('.jac/tectonic-cache').symlink_to(cache, target_is_directory=True)
        os.environ['STACK_TECTONIC'] = str(root/'score-docs'/'compile-tex')
        compiled = latex.compile(source)
    view.update(pages=compiled['pages'], summary=latex.summary(structure))
    return {'format':view, 'encoded':latex.encode(source), 'preview':base64.b64encode(compiled['pdf']).decode(),
            'parse_ms':(parsed-started)*1000, 'compile_ms':(time.monotonic()-parsed)*1000}

def run(request):
    if request['operation']=='source':
        return compile_source(request)
    if request['operation']=='check':
        from agents.record_resume import check_documents
        result=check_documents(base64.b64decode(request['pdf']),base64.b64decode(request['docx']),request['records'])
        result.pop('text',None)
        return result
    from agents.bullet_bank import compose
    from agents.record_resume import prepare, documents
    source=compose(request['records'],request['selection'],request['sources'])
    template=request['template']
    source.update(template=template,revision=request['revision'],upload_digest=request['digest'],format='records')
    if request['operation']=='worker_source':
        return source
    if request['operation']=='score':
        from agents import job_score, scoring
        result=job_score.score(source['records'],request['job'],request['as_of'])
        outline=prepare({'records':source['records'],'template':'classic','upload_digest':'','revision':0})['outline']
        return {'job_score':result,'score':job_score.legacy_summary(result,scoring.quality(outline))}
    from agents.template_library import LATEX_RECORD_TEMPLATES
    with tempfile.TemporaryDirectory(prefix='stack-reviewed-') as workspace:
        # Tectonic uses working-directory-relative cache/scratch paths. Mount the
        # warmed cache read-only by symlink and direct temporary outputs here.
        os.chdir(workspace)
        if template in LATEX_RECORD_TEMPLATES:
            cache=root/'score-docs'/'tex-cache'
            engine=root/'score-docs'/'tectonic'
            if not cache.is_dir() or not engine.is_file():
                raise ValueError('The selected resume template renderer is unavailable.')
            Path('.jac').mkdir(mode=0o700)
            Path('.jac/tectonic-cache').symlink_to(cache,target_is_directory=True)
            # Render only fixed templates from the release's package cache.
            os.environ['STACK_TECTONIC']=str(root/'score-docs'/'compile-tex')
        return {'source':source,'preview':documents(source['records'],template)['pdf']}

try:
    print(json.dumps(run(json.load(sys.stdin)),allow_nan=False))
except (ImportError, FileNotFoundError, PermissionError):
    print(json.dumps({'error':'The resume scoring or document renderer is unavailable.'}))
except ValueError as error:
    print(json.dumps({'error':str(error)}))
