"""Compile Jac screens without Jac's simulator-only build or Bun prebuild."""
import from pathlib { Path }
import shutil;
import subprocess;
import jaclang.client;
import from jaclang.runtime.runtime { JacRuntime as Jac }
import from jaclang.client.vite_client_bundle { ViteClientBundleBuilder }
import from jaclang.client.targets.react_native.build { stage_compiled_entry, write_native_entry, stage_native_image_assets }
with entry {
    project = Path.cwd();
    subprocess.run(["node", "native/build-config.js", "--check", ".jac/mobile-rn"], check=True);
    # Anchor project discovery in source when .jac outputs live on another path.
    builder = Jac.get_client_bundle_builder();
    if not isinstance(builder, ViteClientBundleBuilder) { raise RuntimeError("Native client compiler unavailable."); }
    builder.vite_package_json = project / ".jac/client/configs/package.json";
    builder._compiler = None;
    compiler = builder._get_compiler().jac_client_compiler;
    compiled = compiler.compiled_dir;
    if compiled is None { raise RuntimeError("Native compiled output unavailable."); }
    compiled.mkdir(parents=True, exist_ok=True);
    compiler.compile(None, project / "mobile/main.jac", native=True);
    # Prep is embedded by a source-owned JS controller, outside Jac import discovery.
    compiler.compile(None, project / "mobile/components/Prep.jac", native=True);
    compiler.compile(None, project / "mobile/components/Transcription.jac", native=True);
    output = project / ".jac/mobile-rn";
    runtime = Path(jaclang.client.__file__).parent;
    for name in ["auth_contract", "endpoint_cache"] {
        artifact = compiler.jac_compiler.compile_module(runtime / (name + ".jac"));
        (compiled / (name + ".js")).write_text(artifact.js);
    }
    stage_compiled_entry(compiled, output, "mobile/main");
    shutil.copyfile(project / "native/device.js", output / "jac-src/mobile/device.js");
    shutil.copyfile(project / "native/google-auth.js", output / "jac-src/mobile/google-auth.js");
    shutil.copyfile(project / "native/browser-viewer.js", output / "jac-src/mobile/browser-viewer.js");
    shutil.copyfile(project / "native/audio-recording.js", output / "jac-src/mobile/audio-recording.js");
    shutil.copyfile(project / "native/adzuna-logo.png", output / "jac-src/mobile/adzuna-logo.png");
    shutil.copytree(project / "native/modules/stack-speech", output / "modules/stack-speech", dirs_exist_ok=True);
    write_native_entry(output);
    subprocess.run(["node", "native/build-config.js", "--write", str(output)], check=True);
    subprocess.run(["node", "scripts/stage-mobui.cjs"], check=True);
    stage_native_image_assets(output / "jac-src", output);
}
