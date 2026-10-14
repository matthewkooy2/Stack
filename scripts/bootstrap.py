"""Project-local, verified Linux/WSL toolchain and locked dependency setup."""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import tomllib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from urllib.request import Request, urlopen

JAC_VERSION = "0.37.21"
NODE_VERSION = "22.22.0"
TECTONIC_VERSION = "0.17.0"
POSTGRES_VERSION = "18.6.0"
# Jac/Tectonic: official GitHub release asset SHA256 digests. Node: official
# https://nodejs.org/dist/v22.22.0/SHASUMS256.txt. PostgreSQL: official Maven
# Central release .jar.sha256 sidecars. Never execute an installer.
DIGESTS = {
    "x86_64": {
        "postgres": "008ee189eaa7ca2b58bd01dd950291e638b998392cf982297acd4779ec898ac1",
        "jac": "1f4385aca73182f90ca0bf2dd887713df6e0530115e0835dc09e396256a7333d",
        "node": "9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37",
        "tectonic": "8533d07f9ccbd7a65824b9e0459041bca34af1eb33daba48f59215593753a3b7",
    },
    "aarch64": {
        "postgres": "5f54e016723afa6213925a8acb939bac52944b1d348f65c7a20f0cd2928c31be",
        "jac": "9f7cc107519243ee5fc16f642606ed79e94ca024f28b269745d208b2d142d692",
        "node": "1bf1eb9ee63ffc4e5d324c0b9b62cf4a289f44332dfef9607cea1a0d9596ba6f",
        "tectonic": "b10954a95404f3ab2328d2fa59a5ebab8e657f893fab096f98be8db7c0c979b8",
    },
}


def architecture() -> str:
    machine = platform.machine().lower()
    return {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)


def environment(root: Path) -> dict[str, str]:
    """Use only this clone's tools/cache; do not inherit production settings."""
    root = root.resolve()
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("STACK_", "JAC_", "PIP_", "NPM_CONFIG_", "npm_config_"))
        and key not in {"OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
                       "GOOGLE_APPLICATION_CREDENTIALS", "GITHUB_TOKEN", "GH_TOKEN",
                       "ADZUNA_APP_ID", "ADZUNA_APP_KEY", "THEIRSTACK_API_KEY",
                       "USAJOBS_API_KEY", "USAJOBS_EMAIL", "NPM_TOKEN", "NODE_AUTH_TOKEN"}
    }
    env["PATH"] = str(root / ".jac/tools/bin") + os.pathsep + env.get("PATH", "")
    env["JAC_CACHE_HOME"] = str(root / ".jac/tool-cache")
    env["JAC_PG_DIST"] = str(root / ".jac/tools/postgres")
    env["JAC_PG_VERSION"] = POSTGRES_VERSION
    env["JAC_DB_URL"] = ""
    env["PYTHON_DOTENV_DISABLED"] = "1"
    env["TMPDIR"] = str(temporary_directory(root))
    env["PIP_CONFIG_FILE"] = os.devnull
    env["PIP_INDEX_URL"] = "https://pypi.org/simple"
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    env["PIP_CACHE_DIR"] = str(root / ".jac/pip-cache")
    env["NPM_CONFIG_USERCONFIG"] = os.devnull
    env["NPM_CONFIG_GLOBALCONFIG"] = str(root / ".jac/npm-global-empty.conf")
    env["NPM_CONFIG_REGISTRY"] = "https://registry.npmjs.org"
    env["NPM_CONFIG_CACHE"] = str(root / ".jac/npm-cache")
    env["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
    return env


def temporary_directory(root: Path) -> Path:
    # PostgreSQL uses Unix sockets; long clone/worktree names exceed 108 bytes.
    local = root / ".jac/tmp"
    target = local if len(os.fsencode(local)) < 65 else Path("/tmp") / (
        "stack-" + str(os.getuid()) + "-" + hashlib.sha256(os.fsencode(root)).hexdigest()[:16]
    )
    if target.is_symlink():
        raise RuntimeError("Stack temporary directory must not be a symbolic link.")
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    if target.stat().st_uid != os.getuid():
        raise RuntimeError("Stack temporary directory belongs to another user.")
    target.chmod(0o700)
    return target


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, target: Path, expected: str) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink():
        raise RuntimeError("Tool download cache must not contain symbolic links.")
    if target.exists() and sha256(target) == expected:
        return target
    partial = target.with_suffix(target.suffix + ".part")
    partial.unlink(missing_ok=True)
    try:
        print("Downloading " + target.name, flush=True)
        with urlopen(Request(url, headers={"User-Agent": "Stack-contributor-setup"}), timeout=90) as response:
            with partial.open("xb") as stream:
                shutil.copyfileobj(response, stream)
        if sha256(partial) != expected:
            raise RuntimeError("SHA256 verification failed for " + target.name)
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)
    return target


def matching_file(source: Path, target: Path, mode: int | None = None) -> bool:
    if source.is_symlink():
        return target.is_symlink() and os.readlink(source) == os.readlink(target)
    if target.is_symlink() or not target.is_file():
        return False
    expected_mode = source.stat().st_mode & 0o777 if mode is None else mode
    return target.stat().st_mode & 0o777 == expected_mode and sha256(source) == sha256(target)


def install_file(source: Path, target: Path, mode: int | None = None) -> None:
    """Keep identical files (including running binaries); replace changes atomically."""
    if matching_file(source, target, mode):
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".stack-tool-", dir=target.parent, delete=False) as temporary:
        staging = Path(temporary.name)
    try:
        if source.is_symlink():
            staging.unlink()
            staging.symlink_to(os.readlink(source))
        else:
            shutil.copyfile(source, staging)
            staging.chmod(source.stat().st_mode & 0o777 if mode is None else mode)
        staging.replace(target)
    finally:
        staging.unlink(missing_ok=True)


def install_archive(archive: tarfile.TarFile, target: Path) -> None:
    """Verify extracted contents against installed bytes without rewriting live tools."""
    target.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".stack-extract-", dir=target.parent) as directory:
        staging = Path(directory)
        archive.extractall(staging, filter="data")
        paths = sorted(staging.rglob("*"), key=lambda path: len(path.relative_to(staging).parts))
        for source in paths:
            relative = source.relative_to(staging)
            destination = target / relative
            # A prior installed file cannot redirect extraction outside this tool.
            for ancestor in destination.parents:
                if ancestor == target.parent:
                    break
                if ancestor.is_symlink():
                    raise RuntimeError("Installed tool directories must not be symbolic links.")
            if source.is_dir() and not source.is_symlink():
                if destination.is_symlink():
                    raise RuntimeError("Installed tool directories must not be symbolic links.")
                destination.mkdir(parents=True, exist_ok=True)
            else:
                install_file(source, destination)

def install_tools(root: Path) -> None:
    arch = architecture()
    if platform.system() != "Linux" or arch not in DIGESTS:
        raise RuntimeError("Core setup supports Linux/WSL2 x86_64 or aarch64. Use scripts/setup --ios on macOS.")
    tools = root / ".jac/tools"
    binaries = tools / "bin"
    downloads = tools / "downloads"
    binaries.mkdir(parents=True, exist_ok=True)
    jac_name = f"jac-{JAC_VERSION}-linux-{arch}"
    jac = download(f"https://github.com/jaseci-labs/jac/releases/download/v{JAC_VERSION}/{jac_name}",
                   downloads / jac_name, DIGESTS[arch]["jac"])
    install_file(jac, binaries / "jac", mode=0o755)
    node_arch = "x64" if arch == "x86_64" else "arm64"
    node_name = f"node-v{NODE_VERSION}-linux-{node_arch}"
    node = download(f"https://nodejs.org/dist/v{NODE_VERSION}/{node_name}.tar.xz",
                    downloads / (node_name + ".tar.xz"), DIGESTS[arch]["node"])
    with tarfile.open(node) as archive:
        install_archive(archive, tools)
    for executable in ("node", "npm", "npx"):
        link = binaries / executable
        link.unlink(missing_ok=True)
        link.symlink_to(Path("..") / node_name / "bin" / executable)
    tectonic_name = f"tectonic-{TECTONIC_VERSION}-{arch}-unknown-linux-musl.tar.gz"
    tectonic = download(f"https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40{TECTONIC_VERSION}/{tectonic_name}",
                        downloads / tectonic_name, DIGESTS[arch]["tectonic"])
    with tarfile.open(tectonic) as archive:
        members = [member for member in archive.getmembers() if member.isfile() and Path(member.name).name == "tectonic"]
        if len(members) != 1:
            raise RuntimeError("Pinned Tectonic archive does not contain one executable.")
        with tempfile.TemporaryDirectory(prefix=".stack-tectonic-", dir=tools) as directory:
            extracted = Path(directory) / "tectonic"
            with archive.extractfile(members[0]) as source, extracted.open("wb") as destination:
                shutil.copyfileobj(source, destination)
            install_file(extracted, binaries / "tectonic", mode=0o755)
    # Pin Jac's database distribution too: its default Maven resolver chooses
    # the newest available minor release and can fall back to another major.
    pg_arch = "amd64" if arch == "x86_64" else "arm64v8"
    pg_name = f"embedded-postgres-binaries-linux-{pg_arch}"
    postgres = download(f"https://repo1.maven.org/maven2/io/zonky/test/postgres/{pg_name}/{POSTGRES_VERSION}/{pg_name}-{POSTGRES_VERSION}.jar",
                        downloads / f"{pg_name}-{POSTGRES_VERSION}.jar", DIGESTS[arch]["postgres"])
    with zipfile.ZipFile(postgres) as distribution:
        payloads = [name for name in distribution.namelist() if name.endswith(".txz")]
        if len(payloads) != 1:
            raise RuntimeError("Pinned PostgreSQL distribution does not contain one archive.")
        with tarfile.open(fileobj=io.BytesIO(distribution.read(payloads[0])), mode="r:xz") as archive:
            install_archive(archive, tools / "postgres")


def run(root: Path, env: dict[str, str], command: list[str]) -> None:
    subprocess.run(command, cwd=root, env=env, check=True)


def setup(root: Path) -> None:
    root = root.resolve()
    if sys.version_info < (3, 12):
        raise RuntimeError("Setup needs Python 3.12 or newer (Ubuntu 24.04 includes it).")
    if (root / ".jac").is_symlink():
        raise RuntimeError("The local .jac directory must not be a symbolic link.")
    for relative in ("tools", "tools/bin", "tools/downloads", "tools/postgres", "tool-cache", "venv", "client", "client/configs"):
        if (root / ".jac" / relative).is_symlink():
            raise RuntimeError("Generated setup directories must not be symbolic links.")
    for name in ("jac", "tectonic"):
        if (root / ".jac/tools/bin" / name).is_symlink():
            raise RuntimeError("Project tool executables must not be symbolic links.")
    manifest = tomllib.loads((root / "jac.toml").read_text())
    locked_python = dict(re.findall(r"(?m)^([\w-]+)==([^\s]+)", (root / "dependencies/python.lock").read_text()))
    for section in ("dependencies", "dev-dependencies"):
        for name, version in manifest.get(section, {}).items():
            if isinstance(version, str) and version != "==" + locked_python.get(name, ""):
                raise RuntimeError("Backend dependency inputs changed; update dependencies/python.lock before setup.")
    install_tools(root)
    env = environment(root)
    jac = str(root / ".jac/tools/bin/jac")
    # Create the bundled-Python project venv without unbounded seed upgrades.
    run(root, env, [jac, "run", "--no-serve", "scripts/bootstrap-client.jac"])
    python = str(root / ".jac/venv/bin/python")
    run(root, env, [python, "-m", "pip", "install", "--require-hashes", "--only-binary=:all:",
                    "--no-deps", "-r", "dependencies/python.lock"])
    run(root, env, [python, "-m", "pip", "check"])
    client = root / ".jac/client"
    generated = client / "configs/package.json"
    locked = root / "dependencies/web/package.json"
    generated_data, locked_data = json.loads(generated.read_text()), json.loads(locked.read_text())
    for key in ("dependencies", "devDependencies"):
        if generated_data.get(key, {}) != locked_data.get(key, {}):
            raise RuntimeError("Browser dependency inputs changed; update dependencies/web/package.json and its lockfile before setup.")
    shutil.copyfile(locked, client / "package.json")
    shutil.copyfile(root / "dependencies/web/package-lock.json", client / "package-lock.json")
    run(client, env, [str(root / ".jac/tools/bin/npm"), "ci", "--no-audit", "--no-fund"])
    (client / "node_modules/.jac-deps-hash").write_text(sha256(generated), encoding="utf-8")
    # Jac owns its transient manifest; the dependency hash prevents an
    # automatic Bun re-resolution during the build.
    (client / "package.json").unlink(missing_ok=True)
    run(root, env, [jac, "build", "--as", "client", "workspace"])
    print("Project tools and locked backend/browser dependencies are ready.", flush=True)
