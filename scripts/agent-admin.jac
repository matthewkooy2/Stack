"""Local operator tasks; credentials are never accepted through the public gateway."""
import argparse;
import json;
import os;
import from pathlib { Path }
import secrets;
import from agents.worker { call }
with entry:__main__ {
    parser = argparse.ArgumentParser();
    parser.add_argument('action', choices=['init', 'invite', 'status', 'provider']);
    parser.add_argument(
        '--provider', choices=['openai', 'codex-cli', 'claude-cli', 'meta', 'ollama', 'lmstudio']
    );
    parser.add_argument(
        '--owner', help='Stack account ID shown under Agent activity > Rules'
    );
    parser.add_argument('--daily-limit', `type=int, `default=10);
    parser.add_argument('--model', `default='');
    parser.add_argument('--local-model-url', `default='', help='Local inference origin as reached by the worker; omit for loopback defaults');
    args = parser.parse_args();
    directory = Path('storage/agents');
    if (args.action == 'init') {
        directory.mkdir(parents=True, exist_ok=True, mode=448);
        for (name, value) in [
            ('worker-token', secrets.token_urlsafe(48)),
            ('config.json', Path('deploy/agent-config.example.json').read_text())
        ] {
            path = directory / name;
            if not path.exists() {
                path.write_text(value);
                path.chmod(384);
            }
        }
        print(
            'Private files initialized. Budget and outbound actions remain disabled.'
        );
    } elif (args.action == 'invite') {
        token = (
            os.environ.get('STACK_AGENT_WORKER_TOKEN', '')
            or (directory / 'worker-token').read_text().strip()
        );
        print(call('agent_invite', {'token': token})['invite']);
    } elif (args.action == 'provider') {
        import from uuid { UUID }
        import from agents.contracts { CLI_PROVIDERS, LOCAL_PROVIDERS }
        if not args.provider {
            parser.error('provider requires --provider');
        }
        if (args.provider in CLI_PROVIDERS) {
            try {
                owner = str(UUID((args.owner or '')));
            } except ValueError {
                parser.error(
                    'local CLI providers require --owner with your Stack account ID'
                );
            }
            if not (1 <= args.daily_limit <= 100) {
                parser.error('--daily-limit must be between 1 and 100');
            }
        }
        if args.provider in LOCAL_PROVIDERS {
            import from agents.local_model { origin }
            try { origin(args.provider, args.local_model_url); }
            except ValueError as exc { parser.error(str(exc)); }
            if not args.model.strip() { parser.error('local inference requires --model with an installed model identifier'); }
        }
        path = Path(
            os.environ.get('STACK_AGENT_CONFIG', str((directory / 'config.json')))
        );
        raw = json.loads(path.read_text()) if path.exists() else {};
        raw.update(provider=args.provider, model=args.model);
        if args.provider in LOCAL_PROVIDERS { raw['local_model_url'] = args.local_model_url; }
        if (args.provider in CLI_PROVIDERS) {
            raw.update(local_cli_owner=owner, local_cli_daily_limit=args.daily_limit);
        }
        path.parent.mkdir(parents=True, exist_ok=True, mode=448);
        temporary = path.with_suffix('.tmp');
        with temporary.open('x') as output {
            temporary.chmod(384);
            json.dump(raw, output, indent=2);
            output.write('\n');
        }
        temporary.replace(path);
        print(
            'Provider saved. Local inference requires a running service and installed model. CLI sign-in, account permissions, and provider limits still apply. API providers also require credentials, prices, and budgets.'
        );
    } else {
        import from agents.contracts { config }
        c = config();
        print(
            json.dumps(
                {
                    k: c[k]
                    for k in (
                        'provider',
                        'model',
                        'local_model_url',
                        'local_model_timeout',
                        'local_model_context_tokens',
                        'local_cli_owner',
                        'local_cli_daily_limit',
                        'invite_only',
                        'web_url',
                        'monthly_cents',
                        'user_monthly_cents',
                        'action_daily_limits'
                    )
                },
                indent=2
            )
        );
    }
}
