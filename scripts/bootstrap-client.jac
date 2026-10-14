import from pathlib { Path }
import subprocess;
import from jaclang.client.vite_bundler { ViteBundler }
import from jaclang.project.pyvenv { _bundled_runtime_python }

with entry:__main__ {
    project = Path.cwd();
    venv_dir = project / ".jac" / "venv";
    if not (venv_dir / "bin" / "python").exists() {
        runtime = _bundled_runtime_python();
        if runtime is None {
            raise RuntimeError("The pinned standalone Jac bundled Python is required.");
        }
        # Python's bundled ensurepip seeds this venv without Jac's unbounded
        # upgrade of pip/setuptools/wheel. The hashed lock installs those too.
        subprocess.run([runtime, "-m", "venv", str(venv_dir)], check=True);
    }
    ViteBundler(project, entry_path="web.main").create_package_json();
}
