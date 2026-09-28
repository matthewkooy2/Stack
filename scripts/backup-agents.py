#!/usr/bin/env python3
"""Stopped-writer backup plus verification. Restore only into an empty database."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile


def sha(path):
    with path.open('rb') as file: return hashlib.file_digest(file, 'sha256').hexdigest()


def verify(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    for name, digest in manifest['files'].items():
        if Path(name).name != name or sha(directory / name) != digest:
            raise ValueError('Backup verification failed: ' + name)
    subprocess.run(['pg_restore', '--list', str(directory / 'graph.dump')], check=True, stdout=subprocess.DEVNULL)
    return manifest


def main():
    p = argparse.ArgumentParser()
    p.add_argument('action', choices=['backup', 'verify', 'restore'])
    p.add_argument('directory', type=Path)
    p.add_argument('--writers-stopped', action='store_true')
    p.add_argument('--storage', type=Path, default=Path('storage'))
    args = p.parse_args()
    if args.action == 'verify':
        verify(args.directory);print('Archive checksums and PostgreSQL archive verified.');return
    if not args.writers_stopped:
        p.error('Stop API, discovery and agent workers, then pass --writers-stopped.')
    # Libpq environment keeps database credentials out of command arguments/logs.
    if not os.environ.get('PGDATABASE'):
        p.error('Configure PGHOST, PGPORT, PGUSER, PGDATABASE and a private PGPASSFILE.')
    if args.action == 'backup':
        args.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        subprocess.run(['pg_dump', '--format=custom', '--file', str(args.directory / 'graph.dump')], check=True)
        with tarfile.open(args.directory / 'storage.tar', 'w') as archive:
            if args.storage.exists(): archive.add(args.storage, arcname='storage')
        files = {name: sha(args.directory / name) for name in ('graph.dump', 'storage.tar')}
        (args.directory / 'manifest.json').write_text(json.dumps({'version': 1, 'files': files}, indent=2))
        for path in args.directory.iterdir(): path.chmod(0o600)
        verify(args.directory)
        print('Backup verified. Encrypt this private directory before off-host storage.')
    else:
        verify(args.directory)
        tables = subprocess.check_output(['psql', '-Atc', "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"], text=True).strip()
        if tables != '0': p.error('Restore target must be an empty, separate database.')
        if args.storage.exists(): p.error('Restore storage target must not already exist.')
        subprocess.run(['pg_restore', '--exit-on-error', '--no-owner', '--dbname', os.environ['PGDATABASE'], str(args.directory / 'graph.dump')], check=True)
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            with tarfile.open(args.directory / 'storage.tar') as archive: archive.extractall(temporary, filter='data')
            source = Path(temporary) / 'storage'
            if source.exists(): shutil.copytree(source, args.storage)
        print('Restored to separate targets. Run account/PDF/restart checks before cutover.')


if __name__ == '__main__': main()
