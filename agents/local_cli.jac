"""Structured, tool-free requests through locally signed-in provider CLIs."""
import json;
import os;
import from pathlib { Path }
import selectors;
import shutil;
import signal;
import subprocess;
import tempfile;
import time;
import from typing { BinaryIO }
def environment() -> dict[str, str] {
    # Keep CLI login available without forwarding API keys or worker secrets.
    return {
        k: v
        for (k, v) in os.environ.items()
        if (
            k
            in (
                'PATH',
                'HOME',
                'USER',
                'TMPDIR',
                'LANG',
                'LC_ALL',
                'CODEX_HOME',
                'SSL_CERT_FILE',
                'SSL_CERT_DIR',
                'CODEX_CA_CERTIFICATE'
            )
        )
    };
}
def run(
    command: list[str],
    directory: str,
    prompt: str = '',
    seconds: float = 90,
    limit: int = 2000000,
    merge_stderr: bool = False
) -> tuple[int, str] {
    with tempfile.TemporaryFile() as incoming {
        incoming.write(prompt.encode());
        incoming.seek(0);
        try {
            proc = subprocess.Popen(
                command,
                cwd=directory,
                env=environment(),
                stdin=incoming,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL,
                start_new_session=True
            );
        } except OSError {
            raise ValueError(
                'The local CLI could not start. Check its installation in the worker environment.'
            ) from None;
        }
        selector = selectors.DefaultSelector();
        stream = proc.stdout as BinaryIO;
        selector.register(stream, selectors.EVENT_READ);
        output = bytearray();
        deadline = time.monotonic() + seconds;
        try {
            while selector.get_map() {
                if (time.monotonic() >= deadline) {
                    raise ValueError(
                        'The local CLI timed out. Check its login and subscription limits.'
                    );
                }
                for (key, _) in selector.select(0.1) {
                    chunk = os.read(key.fd, 8192);
                    if not chunk {
                        selector.unregister(key.fileobj);
                    } else {
                        output.extend(chunk);
                        if (len(output) > limit) {
                            raise ValueError(
                                'The local CLI exceeded its output limit.'
                            );
                        }
                    }
                }
            }
            status = proc.wait(timeout=max(0.1, (deadline - time.monotonic())));
            return (status, output.decode(errors='replace'));
        } except subprocess.TimeoutExpired {
            raise ValueError('The local CLI timed out.') from None;
        } finally {
            selector.close();
            try {
                os.killpg(proc.pid, signal.SIGKILL as int);
            } except ProcessLookupError {
                ;
            }
            proc.wait();
            stream.close();
        }
    }
}
def generate(
    provider: str, model: str, system: str, prompt: str, schema: dict[str, any], observe: any = None, record_response: any = None
) -> dict[str, any] {
    executable = shutil.which('codex' if (provider == 'codex-cli') else 'claude');
    if not executable {
        raise ValueError(
            ('Install and sign in to ' + provider + ' in the environment running Stack.')
        );
    }
    with tempfile.TemporaryDirectory(prefix='stack-model-') as tmp {
        directory = Path(tmp);
        if (provider == 'codex-cli') {
            # Codex owns authentication; Stack never reads its credential store.
            (status, login) = run(
                [executable, 'login', 'status'], tmp, seconds=10, merge_stderr=True
            );
            if (status or ('Logged in using ChatGPT' not in login)) {
                raise ValueError(
                    'Sign in in the worker environment with codex login before running this agent.'
                );
            }
            schema_path = directory / 'schema.json';
            schema_path.write_text(json.dumps(schema));
            result_path = directory / 'result.json';
            command = [
                executable,
                '-a',
                'never',
                'exec',
                '--ignore-user-config',
                '--ephemeral',
                '--skip-git-repo-check',
                '--sandbox',
                'read-only',
                '--json',
                '-c',
                'forced_login_method="chatgpt"',
                '-c',
                'web_search="disabled"',
                '-c',
                'project_doc_max_bytes=0',
                '--output-schema',
                str(schema_path),
                '--output-last-message',
                str(result_path)
            ];
            if not schema {
                command.remove('--output-schema');command.remove(str(schema_path));
            }
            for feature in (
                'shell_tool',
                'unified_exec',
                'code_mode_host',
                'plugins',
                'apps',
                'browser_use',
                'computer_use',
                'image_generation',
                'multi_agent',
                'skill_search',
                'workspace_dependencies'
            ) {
                command += ['--disable', feature];
            }
            if model {
                command += ['--model', model];
            }
            command += ['-'];
            (status, _) = run(
                command, tmp, (system + ('\nReturn only the requested JSON.\n' if schema else '\nRespond in plain text.\n') + prompt)
            );
            raw = None;
            if (result_path.exists() and (result_path.stat().st_size <= 131072)) {
                raw = result_path.read_text();
                if (record_response is not None) {
                    record_response(raw, 'model_json');
                }
            }
            if (status or not result_path.exists()) {
                if observe { observe("model_response", {"exit_code":status,"response":"","reported_models":[]}); }
                raise ValueError(
                    'Codex could not complete the request. Check ChatGPT sign-in and usage limits; no API fallback was attempted.'
                );
            }
            if (result_path.stat().st_size > 131072) {
                raise ValueError('The local CLI result exceeded its output limit.');
            }
            text = raw;
            if observe { observe("model_response", {"exit_code":status,"text":text,"reported_models":[]}); }
            return json.loads(text as str) if schema else {'text': text};
        }
        (status, login) = run([executable, 'auth', 'status'], tmp, seconds=10);
        auth = json.loads(login) if not status else {};
        if (
            not auth.get('loggedIn')
            or (auth.get('authMethod') not in ('oauth', 'claude.ai'))
            or (auth.get('apiProvider') != 'firstParty')
        ) {
            raise ValueError(
                'Sign in to your Claude subscription in the worker environment with claude auth login.'
            );
        }
        command = [
            executable,
            '-p',
            '--safe-mode',
            '--restricted',
            '--tools',
            '',
            '--strict-mcp-config',
            '--mcp-config',
            '{"mcpServers":{}}',
            '--disable-slash-commands',
            '--no-chrome',
            '--no-session-persistence',
            '--permission-mode',
            'dontAsk',
            '--output-format',
            'json',
            '--json-schema',
            json.dumps(schema),
            '--system-prompt',
            system
        ];
        if not schema { command.remove('--json-schema');command.remove(json.dumps(schema)); }
        if model {
            command += ['--model', model];
        }
        (status, output) = run(command, tmp, prompt);
        if (record_response is not None) {
            record_response(output, 'provider_json');
        }
        if observe { observe("model_response", {"exit_code":status,"text":output}); }
        if status {
            raise ValueError(
                'Claude could not complete the request. Check subscription sign-in and usage limits; no API fallback was attempted.'
            );
        }
        result = json.loads(output);
        if not schema {
            if result.get('is_error') { raise ValueError('Claude could not complete the request.'); }
            return {'text': result.get('result', '')};
        }
        if (result.get('is_error') or ('structured_output' not in result)) {
            raise ValueError('Claude did not return a completed structured result.');
        }
        return result['structured_output'];
    }
}
