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
    with tempfile.TemporaryDirectory(prefix="goose-io-tests-") as directory:
        def run(*command):
            print("+", " ".join(map(str, command)), flush=True)
            subprocess.run(list(map(str, command)), cwd=directory, check=True, timeout=120)

        exe = Path(directory) / ("test.exe" if os.name == "nt" else "test")
        for suite in ("file_handle", "buffered", "checkfree"):
            source = ROOT / "tests" / f"{suite}.goose"
            for level in (0, 2):
                run(goose, "run", source, "--debug", f"-O{level}")
            for cc in args.cc:
                run(goose, "build", source, "--cc", cc, "--debug", "-O2", "-o", exe)
                run(exe)
                run(goose, "build", source, "--cc", cc, "--standalone", "-O2", "-o", exe)
                run(exe)

        source = ROOT / "tests" / "checkfree_rejected.goose"
        for level in (0, 2):
            command = [goose, "check", str(source), "--debug", f"-O{level}",
                       "--color", "never"]
            print("+", " ".join(command), "(expected rejection)", flush=True)
            result = subprocess.run(command, cwd=directory, capture_output=True,
                                    text=True, encoding="utf-8", timeout=120)
            diagnostic = "checkfree fn next_line calls io::read_line, which keeps a bounds check"
            if result.returncode != 1 or diagnostic not in result.stderr:
                raise RuntimeError(f"Expected a transitive bounds-check diagnostic:\n{result.stdout}\n{result.stderr}")

        # Disabling BCE must explicitly warn that it disables this guarantee.
        command = [goose, "run", str(source), "--debug", "--no-bce", "--color", "never"]
        print("+", " ".join(command), "(expected warning)", flush=True)
        result = subprocess.run(command, cwd=directory, capture_output=True,
                                text=True, encoding="utf-8", timeout=120)
        if result.returncode != 0 or "checkfree is not verified under --no-bce" not in result.stderr:
            raise RuntimeError(f"Expected the checkfree bypass warning:\n{result.stdout}\n{result.stderr}")


if __name__ == "__main__":
    main()
