"""Run installed Jac against isolated public copies; no model/network/account IO."""
import json,os,pathlib,subprocess,tempfile
P=pathlib.Path
HERE=P(__file__).resolve().parent
source=HERE.parent/'stack-policy-evaluation-source'
with tempfile.TemporaryDirectory(prefix='stack-agent-policy-native-') as tmp:
    root=P(tmp);(root/'agents').mkdir()
    for name in ('contracts.jac','experience.jac'):(root/'agents'/name).write_bytes((source/'agents'/name).read_bytes())
    (root/'permissions_checks.jac').write_bytes((HERE/'permissions_checks.jac').read_bytes())
    (root/'jac.toml').write_text('[project]\nname="StackPermissionChecks"\nversion="0.1.0"\njac-version="==0.37.21"\n')
    # Only the fixture config can be read; no Codex auth or account config exists
    # in this project. Offline flags prevent dependency downloads.
    config=root/'synthetic-config.json';config.write_text(json.dumps({'provider':'codex-cli','local_cli_owner':'1'*32,'local_cli_daily_limit':2}))
    env={'PATH':'/usr/local/bin:/usr/bin:/bin','LANG':'C.UTF-8','HOME':str(root),'JAC_CACHE_HOME':str(root/'cache'),
         'JAC_TEST_JOBS':'0','STACK_AGENT_CONFIG':str(config),'PYTHONDONTWRITEBYTECODE':'1',
         'UV_OFFLINE':'1','PIP_NO_INDEX':'1','PIP_DISABLE_PIP_VERSION_CHECK':'1'}
    commands=[]
    for args in (['check','permissions_checks.jac'],['test','permissions_checks.jac','-v']):
        q=subprocess.run(['/usr/local/bin/jac',*args],capture_output=True,text=True,timeout=60,cwd=root,env=env)
        commands.append({'command':args[0],'exitCode':q.returncode})
        print(q.stdout);print(q.stderr)
        if q.returncode:break
    report={'passed':len(commands)==2 and all(c['exitCode']==0 for c in commands),'commands':commands,
            'publicSourceCopiesOnly':True,'productionGraphOrDatabaseUsed':False,'modelCallsMade':False,
            'credentialsRead':False,'externalActionsMade':False,'dependencyDownloadsAllowed':False,
            'liveBackendFilesEdited':False}
    (HERE/'offline-native-permission-result.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(0 if report['passed'] else 1)
