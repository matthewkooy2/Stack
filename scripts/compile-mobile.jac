"""Compile Jac screens without Jac's simulator-only build or Bun prebuild."""
import from pathlib { Path }
import shutil;
import subprocess;
import jaclang.client;
import from jaclang.client.targets.mobile_target { MobileTarget }
import from jaclang.client.targets.react_native.build { stage_compiled_entry, write_native_entry }
with entry {
    project = Path.cwd();
    subprocess.run(["node", "native/build-config.js", "--check", ".jac/mobile-rn"], check=True);
    target = MobileTarget();
    (compiler, compiled) = target._compile_native_jac_modules(project / "mobile/main.jac");
    output = project / ".jac/mobile-rn";
    runtime = Path(jaclang.client.__file__).parent;
    for name in ["auth_contract", "endpoint_cache"] {
        artifact = compiler.jac_compiler.compile_module(runtime / (name + ".jac"));
        (compiled / (name + ".js")).write_text(artifact.js);
    }
    stage_compiled_entry(compiled, output, "mobile/main");
    shutil.copyfile(project / "native/device.js", output / "jac-src/mobile/device.js");
    shutil.copyfile(project / "native/browser-viewer.js", output / "jac-src/mobile/browser-viewer.js");
    shutil.copyfile(project / "native/audio-recording.js", output / "jac-src/mobile/audio-recording.js");
    shutil.copyfile(project / "native/adzuna-logo.png", output / "jac-src/mobile/adzuna-logo.png");
    write_native_entry(output);
    subprocess.run(["node", "native/build-config.js", "--write", str(output)], check=True);
}
