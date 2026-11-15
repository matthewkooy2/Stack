"""Daily jobs sweep, started by `stack-jobs-sweep.timer`. Collects every swept source once, stores matches, exits."""
import from pathlib { Path }
import from discovery.sweep { sweep }
with entry:__main__ {
    token=Path("storage/discovery/worker-token").read_text().strip();
    sweep(token);
}
