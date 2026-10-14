#!/usr/bin/env python3
"""Restore approved signing assets locally; never call Apple provisioning APIs."""
import base64
import datetime as dt
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys

BUNDLE = 'com.matthewkooy.stack'


class SigningError(ValueError):
    """A validation message safe for public CI output."""
    pass


def validate_profile(profile, team, identities, now=None):
    now = now or dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    ent = profile.get('Entitlements', {})
    uuid = profile.get('UUID', '')
    if not re.fullmatch(r'[A-Fa-f0-9-]{36}', uuid):
        raise SigningError('Invalid profile UUID')
    if profile.get('ExpirationDate', now) <= now:
        raise SigningError('Provisioning profile expired')
    if profile.get('TeamIdentifier') != [team] or ent.get('com.apple.developer.team-identifier') != team:
        raise SigningError('Provisioning profile team mismatch')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    if not any(ent.get('application-identifier') == f'{prefix}.{BUNDLE}' for prefix in prefixes):
        raise SigningError('Provisioning profile must match the exact Stack bundle ID')
    if ent.get('get-task-allow') is not False or profile.get('ProvisionedDevices') is not None or profile.get('ProvisionsAllDevices'):
        raise SigningError('An App Store distribution profile is required')
    if 'iOS' not in profile.get('Platform', []):
        raise SigningError('An iOS profile is required')
    matches = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])} & set(identities)
    if len(matches) != 1:
        raise SigningError('Profile must match exactly one valid imported distribution identity with a private key')
    return uuid, matches.pop()


def run(*args):
    # Suppress command output, passwords and profile metadata even on failure.
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise SigningError(f'{args[0]} signing operation failed')
    return result.stdout


def state_dir():
    return Path(os.environ['RUNNER_TEMP']) / 'stack-ios-signing'


def cleanup():
    directory = state_dir()
    keychain = directory / 'signing.keychain-db'
    failed = False
    if keychain.exists():
        try:
            run('security', 'delete-keychain', str(keychain))
        except Exception:
            failed = True
    installed = directory / 'installed-profile'
    if installed.exists():
        try:
            profile = Path(installed.read_text())
            profile.unlink(missing_ok=True)
            installed.unlink()
        except Exception:
            failed = True
    # A failed keychain deletion must not retain decoded secrets or skip profile
    # cleanup. Keep only failed-resource state for a precise owner retry.
    for name in ('distribution.p12', 'app.mobileprovision'):
        try:
            (directory / name).unlink(missing_ok=True)
        except Exception:
            failed = True
    if failed:
        raise SigningError('Temporary signing cleanup incomplete; owner must remove the remaining run-local assets before runner reuse.')
    if directory.exists():
        shutil.rmtree(directory)


def prepare():
    required = ('IOS_DISTRIBUTION_P12_BASE64', 'IOS_DISTRIBUTION_P12_PASSWORD',
                'IOS_APP_STORE_PROFILE_BASE64', 'APPLE_TEAM_ID', 'RUNNER_TEMP', 'GITHUB_ENV')
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SigningError('Missing reusable signing configuration: ' + ', '.join(missing))
    team = os.environ['APPLE_TEAM_ID']
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise SigningError('Invalid Apple team ID')
    directory = state_dir()
    directory.mkdir(mode=0o700)  # Refuse stale state; do not reuse a previous run.
    keychain = directory / 'signing.keychain-db'
    p12 = directory / 'distribution.p12'
    profile_path = directory / 'app.mobileprovision'
    os.umask(0o077)
    for name, path in [('IOS_DISTRIBUTION_P12_BASE64', p12), ('IOS_APP_STORE_PROFILE_BASE64', profile_path)]:
        try:
            path.write_bytes(base64.b64decode(''.join(os.environ[name].split()), validate=True))
        except Exception:
            raise SigningError('Invalid base64 signing asset: ' + name) from None
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(profile_path)))
    password = secrets.token_urlsafe(32)
    run('security', 'create-keychain', '-p', password, str(keychain))
    run('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
    run('security', 'unlock-keychain', '-p', password, str(keychain))
    run('security', 'import', str(p12), '-P', os.environ['IOS_DISTRIBUTION_P12_PASSWORD'],
        '-k', str(keychain), '-t', 'agg', '-T', '/usr/bin/codesign', '-T', '/usr/bin/security')
    run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-k', password, str(keychain))
    # Preserve existing keychains; deleting the temporary one removes it from the search list.
    search = run('security', 'list-keychains', '-d', 'user').decode()
    existing = re.findall(r'"([^"]+)"', search)
    run('security', 'list-keychains', '-d', 'user', '-s', str(keychain), *existing)
    output = run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)).decode()
    identities = re.findall(r'\b([A-F0-9]{40})\s+"(?:Apple Distribution|iPhone Distribution):', output)
    uuid, identity = validate_profile(profile, team, identities)
    profiles = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
    profiles.mkdir(parents=True, exist_ok=True)
    destination = profiles / f'{uuid}.mobileprovision'
    if destination.exists():
        raise SigningError('Refusing to overwrite an existing provisioning profile')
    (directory / 'installed-profile').write_text(str(destination))
    shutil.copyfile(profile_path, destination)
    p12.unlink()
    profile_path.unlink()
    with open(os.environ['GITHUB_ENV'], 'a') as env:
        env.write(f'IOS_SIGNING_KEYCHAIN={keychain}\nIOS_SIGNING_IDENTITY={identity}\nIOS_PROFILE_UUID={uuid}\n')
    print('Approved distribution identity and matching App Store profile restored locally.')


def export_options(path):
    for name in ('APPLE_TEAM_ID', 'IOS_SIGNING_IDENTITY', 'IOS_PROFILE_UUID', 'IOS_SIGNING_KEYCHAIN'):
        if not os.environ.get(name):
            raise SigningError('Reusable signing assets must be restored before archive/export: ' + name)
    with open(path, 'wb') as out:
        plistlib.dump({'method': 'app-store-connect', 'signingStyle': 'manual',
                      'teamID': os.environ['APPLE_TEAM_ID'], 'signingCertificate': os.environ['IOS_SIGNING_IDENTITY'],
                      'provisioningProfiles': {BUNDLE: os.environ['IOS_PROFILE_UUID']},
                      'uploadSymbols': True, 'manageAppVersionAndBuildNumber': False}, out)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['prepare']:
            prepare()
        elif sys.argv[1:] == ['cleanup']:
            cleanup()
        elif len(sys.argv) == 3 and sys.argv[1] == 'export-options':
            export_options(sys.argv[2])
        else:
            raise SigningError('Expected prepare, cleanup, or export-options PATH')
    except Exception as exc:
        # Only known validation messages are safe to display.
        print(str(exc) if isinstance(exc, SigningError) else 'Signing asset operation failed.', file=sys.stderr)
        sys.exit(1)
