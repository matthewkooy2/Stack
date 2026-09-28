#!/usr/bin/env python3
"""Compatibility launcher; operator behavior lives in agent-admin.jac."""
import os
from pathlib import Path
import sys

if __name__ == '__main__':
    launcher = Path(__file__).resolve().with_name('jac')
    os.execv(str(launcher), [str(launcher), 'run', '--no-serve', 'scripts/agent-admin.jac', *sys.argv[1:]])
