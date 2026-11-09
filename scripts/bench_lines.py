#!/usr/bin/env python3
"""Compare working-tree read_line throughput against a Git revision.

Uses real, warm-cache file reads with an 8192-byte buffer. Builds both versions
with identical flags, checks line counts and a length/edge-byte checksum against
Python-generated expectations, and alternates execution order across rounds.
Compilation, fixture generation, and process startup are outside the timer.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import std;
import os;
import io from "PACKAGE";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";

fn main() {
    let argv = args();
    let passes, ok = parse_int(argv[2]);
    assert(ok && passes > 0);
    var lines: i64 = 0;
    var checksum: i64 = 0;
    let start = clock_ns();
    for _ in passes {
        let file, opened = io::open_read(argv[1]);
        assert(opened);
        let reader = io::buffered_reader(file);
        loop {
            let line, status = io::read_line(reader);
            if status == io::LineStatus.Eof { break; }
            assert(status == io::LineStatus.Line);
            lines += 1;
            checksum += line.len;
            if line.len > 0 { checksum += line[0]; checksum += line[line.len - 1]; }
        }
        assert(io::close(reader));
    }
    let elapsed = clock_ns() - start;
    print(elapsed, " ", lines, " ", checksum);
}
'''


def score(data):
    lines = data.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    # All benchmark patterns end in LF. The tail is scored separately.
    lines = [line.removesuffix(b"\r") for line in lines]
    return len(lines), sum(len(line) + (line[0] + line[-1] if line else 0) for line in lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="HEAD", help="Git revision before the change")
    parser.add_argument("--goose", default=os.environ.get("GOOSE", "goose"))
    parser.add_argument("--cc", nargs="+", default=["clang"])
    parser.add_argument("--mib", type=int, default=32, help="approximate fixture size")
    parser.add_argument("--passes", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--output", type=Path, help="save environment and raw samples as JSON")
    args = parser.parse_args()
    if min(args.mib, args.passes, args.rounds) < 1:
        parser.error("mib, passes, and rounds must be positive")
    goose = shutil.which(args.goose)
    if not goose:
        parser.error(f"Goose compiler not found: {args.goose}")
    revision = subprocess.check_output(
        ["git", "rev-parse", args.baseline], cwd=ROOT, text=True).strip()
    report = {"baseline": revision, "platform": platform.platform(),
              "goose": subprocess.check_output([goose, "--version"], text=True).strip(),
              "source_sha256": hashlib.sha256((ROOT / "io.goose").read_bytes()).hexdigest(),
              "options": vars(args) | {"output": str(args.output)}, "results": []}
    print(f"Baseline {revision}; {report['goose']}; {report['platform']}", flush=True)
    with tempfile.TemporaryDirectory(prefix="goose-io-bench-") as directory:
        work = Path(directory)
        baseline = work / "baseline"
        baseline.mkdir()
        # Extract only the package's sources, never run scripts from the revision.
        names = subprocess.check_output(
            ["git", "ls-tree", "--name-only", revision], cwd=ROOT, text=True).splitlines()
        entry = "io" if "io.goose" in names else "goosio"
        for name in (f"{entry}.goose", f"{entry}.build", "include/goosio.h", "src/goosio.c"):
            destination = baseline / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(subprocess.check_output(
                ["git", "show", f"{revision}:{name}"], cwd=ROOT))
        fixtures = []
        patterns = {
            "empty-lines": b"\n",
            "2-byte-lines": b"a\n",
            "16-byte-lines": b"abcdefghijklmno\n",
            "80-byte-CRLF": b"a" * 78 + b"\r\n",
            "1-KiB-lines": b"b" * 1023 + b"\n",
            "20-KiB-lines": b"c" * 20002 + b"\n",
            "1-MiB-lines": b"d" * (1024 * 1024 - 1) + b"\n",
            "mixed-binary": b"\nalpha\r\nx\0\xff\n" + b"z" * 997 + b"\nlast\r\n",
        }
        for name, pattern in patterns.items():
            repeats = max(1, args.mib * 1024 * 1024 // len(pattern))
            tail = b"unterminated\0\xff\r"
            path = work / name
            path.write_bytes(pattern * repeats + tail)
            count, checksum = score(pattern)
            expected = ((count * repeats + 1) * args.passes,
                        (checksum * repeats + len(tail) + tail[0] + tail[-1]) * args.passes)
            fixtures.append((name, path, expected))
        for cc in args.cc:
            executables = {}
            for label, package in (("before", baseline), ("after", ROOT)):
                source = work / f"{label}.goose"
                harness = HARNESS.replace("PACKAGE", package.as_posix())
                package_entry = entry if label == "before" else "io"
                package_source = (package / f"{package_entry}.goose").read_text()
                dependency = re.search(r'^import (?:bstr|goostr) from "[^"]+";',
                                       package_source, re.M).group()
                harness = re.sub(r'^import bstr from "[^"]+";',
                                 lambda _: dependency, harness, flags=re.M)
                if package_entry == "goosio":
                    # Historical entries require historical namespaces, not the
                    # migrated identifiers at revisions that lack those files.
                    harness = harness.replace("import io ", "import goosio ").replace("io::", "goosio::")
                    harness = re.sub(r'^import simd_bytes from "[^"]+";',
                                     'import goosimd from "github.com/sstadick/goosimd@983f3bb2bfee95affd09f4f5530be249d7d6040b";',
                                     harness, flags=re.M)
                source.write_text(harness)
                exe = work / f"{label}-{Path(cc).stem}{'.exe' if os.name == 'nt' else ''}"
                subprocess.run([goose, "build", str(source), "--cc", cc,
                                "--standalone", "-O2", "-o", str(exe)], check=True)
                executables[label] = exe
            for name, path, expected in fixtures:
                def sample(label):
                    output = subprocess.check_output(
                        [str(executables[label]), str(path), str(args.passes)], text=True)
                    ns, count, checksum = map(int, output.split())
                    assert (count, checksum) == expected, (label, name, output, expected)
                    return ns / 1e9

                for label in executables:
                    sample(label)  # Warm the page cache and both code paths.
                samples = {label: [] for label in executables}
                for round_number in range(args.rounds):
                    order = list(executables)
                    if round_number % 2:
                        order.reverse()
                    for label in order:
                        samples[label].append(sample(label))
                medians = {label: statistics.median(values) for label, values in samples.items()}
                mib = path.stat().st_size * args.passes / 1024**2
                speedup = medians["before"] / medians["after"]
                print(f"{cc:8} {name:16} {mib / medians['before']:8.1f} -> "
                      f"{mib / medians['after']:8.1f} MiB/s  {speedup:.2f}x", flush=True)
                report["results"].append({"cc": cc, "case": name, "bytes": path.stat().st_size,
                                          "expected": expected, "seconds": samples,
                                          "median_seconds": medians, "speedup": speedup})
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
