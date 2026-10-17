"""OS-enforced resource containment; not an exploit-proof security sandbox."""
import ctypes
import os
import signal
import subprocess
import threading


class WindowsJob:
    def __init__(self, memory_bytes):
        from ctypes import wintypes as w

        class Basic(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                        ("flags", w.DWORD), ("min_ws", ctypes.c_size_t),
                        ("max_ws", ctypes.c_size_t), ("active", w.DWORD),
                        ("affinity", ctypes.c_size_t), ("priority", w.DWORD),
                        ("scheduling", w.DWORD)]

        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in
                        ("read_ops", "write_ops", "other_ops", "read", "write", "other")]

        class Extended(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", IO),
                        ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                        ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]

        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
        self.api.CreateJobObjectW.restype = w.HANDLE
        self.api.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        self.api.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.api.CloseHandle.argtypes = [w.HANDLE]
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        info = Extended()
        # JOB_MEMORY | ACTIVE_PROCESS | KILL_ON_JOB_CLOSE: one process, all threads.
        info.basic.flags = 0x200 | 0x8 | 0x2000
        info.basic.active = 1
        info.job_memory = memory_bytes
        if not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            self.close()
            raise ctypes.WinError(ctypes.get_last_error())

    def assign(self, process):
        if not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def run(command, request, directory, limits):
    """Returns exit status and bounded diagnostics. Kill and reap on every failure."""
    job = None
    if os.name == 'nt':
        job = WindowsJob(limits.memory_bytes)
    elif os.name != 'posix':
        raise OSError('Resource limits unsupported on this platform')

    def posix_limits():
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (limits.memory_bytes, limits.memory_bytes))
        resource.setrlimit(resource.RLIMIT_CPU, (limits.cpu_seconds, limits.cpu_seconds))
        resource.setrlimit(resource.RLIMIT_FSIZE, (limits.output_bytes, limits.output_bytes))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))

    # Never inherit NODE_OPTIONS, preload hooks, cloud credentials or proxy settings.
    environment = {key: os.environ[key] for key in ('SystemRoot', 'WINDIR', 'PATH') if key in os.environ}
    environment.update({'TEMP': directory, 'TMP': directory, 'TMPDIR': directory})
    environment.update({'MALLOC_ARENA_MAX': '2', 'RAYON_NUM_THREADS': '1', 'UV_THREADPOOL_SIZE': '1'})
    process = None
    reader = None

    def stop_worker():
        if process is None:
            return
        try:
            if os.name == 'posix':
                # The group may still contain children after its leader exits.
                os.killpg(process.pid, signal.SIGKILL)
            elif process.poll() is None:
                process.kill()
        except ProcessLookupError:
            pass

    try:
        captured = bytearray()
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.PIPE, cwd=directory, env=environment,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
                                       start_new_session=os.name == 'posix',
                                       preexec_fn=posix_limits if os.name == 'posix' else None)
        if job:
            job.assign(process)

        def read_errors():
            while True:
                chunk = process.stderr.read(1024)
                if not chunk:
                    break
                captured.extend(chunk[:4096 - len(captured)])
                if len(captured) >= 4096:
                    stop_worker()
                    break

        reader = threading.Thread(target=read_errors, daemon=True)
        reader.start()
        try:
            process.stdin.write(request)
            process.stdin.close()
        except BrokenPipeError:
            pass
        process.wait(timeout=limits.timeout_seconds)
        stop_worker()
        if job:
            job.close()
        reader.join(timeout=1)
        return process.returncode, captured.decode('utf-8', errors='replace')
    finally:
        if job:
            job.close()
        if process is not None:
            stop_worker()
            process.wait()
            if reader:
                reader.join(timeout=1)
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            if process.stderr:
                process.stderr.close()
