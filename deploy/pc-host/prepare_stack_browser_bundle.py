"""Prepare an explicit source-only browser build context; never install or deploy."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FILES = ('deploy/browser.Dockerfile', 'deploy/browser.jac.toml',
         'deploy/browser-entrypoint', 'deploy/browser-service.jac',
         'deploy/install-browser.jac', 'agents/browser_service.jac',
         'agents/browser.jac', 'agents/browser_control.py',
         'agents/browser_stream.py', 'agents/linkedin.jac',
         'agents/contracts.jac', 'discovery/transport.py')


def prepare(source, output):
    source, output = Path(source).resolve(), Path(output).resolve()
    # A new destination keeps historical reviewed bundles and private runtime files intact.
    if output.exists():
        raise ValueError('Choose a new output directory; existing bundles are preserved.')
    names = (*FILES, 'deploy/browser-seccomp.json')
    content = {}
    for name in names:
        path = source / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(source):
            raise ValueError('Expected a regular source file: ' + name)
        content[name] = path.read_bytes()
    output.mkdir(parents=True)
    manifest = []
    for name in FILES:
        dest = output / 'context' / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content[name])
        # The Docker ENTRYPOINT uses sh; preserving source mode also supports direct use.
        shutil.copymode(source / name, dest)
        manifest.append({'path': name, 'sha256': hashlib.sha256(content[name]).hexdigest()})
    seccomp = content['deploy/browser-seccomp.json']
    (output / 'browser-seccomp.json').write_bytes(seccomp)
    result = dict(prepared=True, files=manifest,
                  seccompSha256=hashlib.sha256(seccomp).hexdigest(),
                  privateFilesCopied=False, imagesBuilt=False,
                  dependenciesInstalled=False, credentialsCreated=False,
                  networkChanged=False, servicesChanged=False)
    (output / 'preparation-metadata.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.output)
    print(json.dumps({k: v for k, v in result.items() if k not in ('files', 'seccompSha256')}))
