#!/usr/bin/env python3
"""Run file and buffered I/O tests with TinyCC and native C compilers."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose", default=os.environ.get("GOOSE", "goose"))
    parser.add_argument("--cc", nargs="+", required=True, help="native C compilers to test")
    args = parser.parse_args()
    goose = shutil.which(args.goose)
    if not goose:
        parser.error(f"Goose compiler not found: {args.goose}")
    goose = str(Path(goose).resolve())
    print(f"Testing {platform.system()} {platform.machine()}", flush=True)
    # All I/O fixtures and executables live outside the checkout and are
    # removed on failure too. Independent invocations cannot share files.
    with tempfile.TemporaryDirectory(prefix="goosio-tests-") as directory:
        def run(*command):
            print("+", " ".join(map(str, command)), flush=True)
            subprocess.run(list(map(str, command)), cwd=directory, check=True, timeout=120)

        exe = Path(directory) / ("test.exe" if os.name == "nt" else "test")
        for suite in ("file_handle", "buffered"):
            source = ROOT / "tests" / f"{suite}.goose"
            for level in (0, 2):
                run(goose, "run", source, "--debug", f"-O{level}")
            for cc in args.cc:
                run(goose, "build", source, "--cc", cc, "--debug", "-O2", "-o", exe)
                run(exe)
                run(goose, "build", source, "--cc", cc, "--standalone", "-O2", "-o", exe)
                run(exe)


if __name__ == "__main__":
    main()
