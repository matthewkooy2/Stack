"""Trusted source-only browser image promotion; install independently as root.

No release-supplied Dockerfile, RUN instructions, downloads, mounts or hooks.
The existing controller remains responsible for sandbox/egress launch policy.
"""
import json
from pathlib import Path
import re

from backend_release import canonical, digest
from browser_package import SOURCE_FILES, CONTRACT_FILES

STATE = Path("/var/lib/stack-release")
IMAGE_PATH = Path("/etc/stack/browser-image-id")
BROWSER_STATE = STATE / "browser-state.json"
PROTECTED = (
    "/usr/local/libexec/stack-browser/browser_runtime.py",
    "/usr/local/libexec/stack-browser/browser_policy.py",
    "/etc/systemd/system/stack-browser.service",
    "/etc/stack/browser-seccomp.json", "/etc/stack/browser-network.json",
    "/etc/stack/browser.env",
)
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}\Z")


def isolation(container):
    host = container["HostConfig"]
    assert container["Config"]["User"] == "pwuser"
    assert host["ReadonlyRootfs"] and not host["Privileged"] and not container["Mounts"]
    assert host["CapDrop"] == ["ALL"] and host["CapAdd"] == ["SYS_CHROOT"]
    assert host["Memory"] == 2 * 1024**3 and host["NanoCpus"] == 2 * 10**9 and host["PidsLimit"] == 256
    assert any(s in ("no-new-privileges", "no-new-privileges=true") for s in host["SecurityOpt"])
    assert any(s.startswith("seccomp=") and "unconfined" not in s for s in host["SecurityOpt"])
    return {k: host.get(k) for k in (
        "ReadonlyRootfs", "Privileged", "CapDrop", "CapAdd", "Memory", "NanoCpus",
        "PidsLimit", "SecurityOpt", "Binds", "Tmpfs", "ShmSize", "Sysctls",
        "NetworkMode", "Dns", "PortBindings", "PidMode", "IpcMode",
    )}


def docker_config(image, run):
    output = run(["/usr/bin/docker", "image", "inspect", image])
    obj = json.loads(output)[0]
    assert obj["Id"] == image and obj["Architecture"] == "amd64"
    config = obj["Config"]
    assert config["User"] == "pwuser" and not config.get("OnBuild"), "Unapproved browser base"
    assert not any(e.split("=", 1)[0] in {"STACK_BROWSER_TOKEN", "STACK_BROWSER_SESSION_KEY"}
                   for e in config.get("Env", [])), "Credentials in browser image"
    return obj


def prepare(meta, payload, stage, commit, run, root_file):
    """Verify protected host state and build a candidate before stopping services."""
    state = json.loads(root_file(BROWSER_STATE))
    assert state["format"] == 1 and IMAGE_ID.fullmatch(state["base_image"])
    assert IMAGE_ID.fullmatch(state["image"])
    assert set(state["files"]) <= SOURCE_FILES and set(state["contract"]) == CONTRACT_FILES
    assert set(state["protected"]) == set(PROTECTED)
    assert meta["contract"] == state["contract"], "Browser dependencies/build policy require attended review"
    assert all(digest(root_file(Path(p))) == h for p, h in state["protected"].items()), "Browser runtime/security changed locally"
    assert root_file(IMAGE_PATH).decode().strip() == state["image"], "Browser image changed locally"
    assert set(state["files"]) <= set(meta["files"]), "Browser source deletion requires review"
    # This is provenance/security validation, not an application health check.
    base = docker_config(state["base_image"], run)
    docker_config(state["image"], run)
    container = json.loads(run(["/usr/bin/docker", "container", "inspect", "stack-browser-pc"]))[0]
    assert container["Image"] == state["image"], "Running browser image changed locally"
    assert isolation(container) == state["isolation"], "Browser isolation changed locally"
    plan = {"changed": meta["files"] != state["files"], "image": state["image"], "state": state}
    if not plan["changed"]:
        return plan
    # npm's workspace belongs to stack. Never put a trusted Dockerfile or
    # root-consumed build context below a directory that stack can rename.
    builds = STATE / "browser-build"
    builds.mkdir(mode=0o700, exist_ok=True)
    st = builds.lstat()
    assert not builds.is_symlink() and st.st_uid == 0 and not st.st_mode & 0o077
    context = builds / stage.name
    context.mkdir(mode=0o700)
    for name in sorted(meta["files"]):
        p = context / name
        p.parent.mkdir(parents=True, exist_ok=True)
        parent = p.parent
        while parent != context:
            parent.chmod(0o755)
            parent = parent.parent
        p.write_bytes(payload["browser/source/" + name])
        p.chmod(0o644)
    # A dedicated local tag is checked against the immutable approved image
    # before use. No registry credentials or remote image names are accepted.
    tag = "stack-browser-approved-base:" + state["base_image"][7:]
    run(["/usr/bin/docker", "image", "tag", state["base_image"], tag])
    actual = json.loads(run(["/usr/bin/docker", "image", "inspect", tag]))[0]
    assert actual["Id"] == state["base_image"]
    dockerfile = context / "Dockerfile"
    dockerfile.write_text("FROM " + tag + "\n"
                          "COPY --chown=0:0 agents/ /app/agents/\n"
                          "COPY --chown=0:0 discovery/ /app/discovery/\n"
                          "COPY --chown=0:0 deploy/browser-service.jac /app/deploy/browser-service.jac\n"
                          "USER pwuser\n")
    dockerfile.chmod(0o600)
    config = STATE / "docker"
    config.mkdir(mode=0o700, exist_ok=True)
    iid = context / "image-id"
    run(["/usr/bin/docker", "--config", str(config), "build", "--pull=false", "--network=none",
         "--label", "org.opencontainers.image.revision=" + commit,
         "--label", "stack.browser-source=" + meta["fingerprint"],
         "--tag", "stack-browser-release:" + commit,
         "--iidfile", str(iid), "--file", str(dockerfile), str(context)])
    image = iid.read_text().strip()
    assert IMAGE_ID.fullmatch(image), "Invalid built image identity"
    built = docker_config(image, run)
    assert built["Config"]["Labels"]["org.opencontainers.image.revision"] == commit
    assert built["Config"]["Labels"]["stack.browser-source"] == meta["fingerprint"]
    # Source-only images retain every approved runtime/dependency layer.
    layers = base["RootFS"]["Layers"]
    assert built["RootFS"]["Layers"][:len(layers)] == layers
    state = {**state, "image": image, "files": meta["files"],
             "fingerprint": meta["fingerprint"], "source_commit": commit}
    return {"changed": True, "image": image, "state": state}


def promote(plan, backup, write_atomic):
    """Called with matching backend installed and all affected services stopped."""
    if not plan["changed"]:
        return
    (backup / "browser-state.json").write_bytes(BROWSER_STATE.read_bytes())
    (backup / "browser-image-id").write_bytes(IMAGE_PATH.read_bytes())
    write_atomic(IMAGE_PATH, (plan["image"] + "\n").encode(), 0)
    IMAGE_PATH.chmod(0o600)
    write_atomic(BROWSER_STATE, canonical(plan["state"]), 0)
    BROWSER_STATE.chmod(0o600)
