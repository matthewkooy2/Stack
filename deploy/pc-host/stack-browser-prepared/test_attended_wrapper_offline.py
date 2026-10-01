"""Exercise the real wrapper with a fake sudo command and temporary artifacts."""
import json,os,pathlib,subprocess,tempfile,unittest
P=pathlib.Path
HERE=P(__file__).resolve().parent
SOURCE=(HERE.parent/'run_stack_browser_install.sh').read_text()
TASK_LINE='task_dir=/mnt/c/Users/Ryan/Documents/Codex/2026-09-30/task'

class WrapperTests(unittest.TestCase):
    def exercise(self,status=0,archive_failure=False):
        with tempfile.TemporaryDirectory(prefix='stack-browser-wrapper-test-') as tmp:
            root=P(tmp);task=root/'task';task.mkdir();binary=root/'bin';binary.mkdir()
            audit=root/'audit'
            sudo=binary/'sudo'
            sudo.write_text('#!/bin/sh\nprintf "synthetic_sudo_called\\n" >> "$FAKE_AUDIT"\nexit "$FAKE_RETURN"\n');sudo.chmod(0o700)
            previous={'stack-browser-installation-result.json':'{"status":"held","phase":"old_attempt"}\n',
                      'stack-browser-install-exit.txt':'99\n','stack-browser-install-stage.txt':'finished\n'}
            for name,value in previous.items():(task/name).write_text(value)
            if archive_failure:(task/'stack-browser-install-attempts').write_text('synthetic collision\n')
            script=root/'wrapper.sh';self.assertEqual(SOURCE.count(TASK_LINE),1)
            script.write_text(SOURCE.replace(TASK_LINE,'task_dir='+str(task)))
            env={'PATH':str(binary)+':/usr/bin:/bin','LANG':'C.UTF-8','FAKE_AUDIT':str(audit),'FAKE_RETURN':str(status)}
            q=subprocess.run(['/bin/bash',str(script)],input='\n',capture_output=True,text=True,timeout=10,env=env)
            if archive_failure:
                self.assertEqual(q.returncode,1);self.assertFalse(audit.exists());return
            self.assertEqual(q.returncode,status)
            self.assertEqual(audit.read_text(),'synthetic_sudo_called\n')
            self.assertEqual((task/'stack-browser-install-exit.txt').read_text(),str(status)+'\n')
            self.assertEqual((task/'stack-browser-install-stage.txt').read_text(),'finished\n')
            self.assertFalse((task/'stack-browser-installation-result.json').exists())
            archives=list((task/'stack-browser-install-attempts').iterdir());self.assertEqual(len(archives),1)
            for name,value in previous.items():self.assertEqual((archives[0]/name).read_text(),value)
    def test_success_archives_old_markers_without_false_terminal_result(self):self.exercise(0)
    def test_hold_exit_status_is_preserved(self):self.exercise(1)
    def test_archive_failure_stops_before_any_sudo_command(self):self.exercise(0,True)

if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(WrapperTests))
    report={'testsRun':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful(),
            'fakeSudoOnly':True,'realPrivilegedCommandsRun':False,'liveArtifactsModified':False,'passwordsCaptured':False}
    (HERE/'offline-wrapper-result.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)
