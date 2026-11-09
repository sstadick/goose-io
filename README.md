# goose-io

Synchronous file I/O for [Goose](https://github.com/aardappel/goose): raw file
handles, buffered readers and writers, and borrowed line reads.

**[API reference and examples](API.md)** · [CI](https://github.com/sstadick/goose-io/actions/workflows/ci.yml)

## Get started

Save this as `main.goose`. Goose downloads the package automatically.
This example creates or overwrites `hello.txt` in the current directory:

```goose
import std;
import io from "github.com/sstadick/goose-io@main";
import bstr from "github.com/sstadick/goose-bstr@216c80429b1d9df6ffbd73eaf32b70c1a8e074bf";
import simd_bytes from "github.com/sstadick/goose-simd@e11e34447d9b0f23f2fd0f63bc25f4aee838f175";

fn main() {
    let output, created = io::open_write("hello.txt");
    assert(created);
    let writer = io::buffered_writer(output);
    assert(io::write(writer, "hello\nworld\n") == 12);
    assert(io::close(writer)); // Flushes, then closes the file.

    let input, opened = io::open_read("hello.txt");
    assert(opened);
    let reader = io::buffered_reader(input);
    loop {
        let line, status = io::read_line(reader);
        if status == io::LineStatus.Eof { break; }
        assert(status == io::LineStatus.Line);
        print(line); // Use the borrowed bytes before the next reader operation.
    }
    assert(io::close(reader));
}
```

```sh
goose run main.goose
goose build main.goose --cc clang -O2 -o demo
```

Use a Goose compiler with package `c_headers` support. CI pins
[`f4637bfb`](https://github.com/aardappel/goose/commit/f4637bfb342fb70d42bea0474eab9e62a3c99d68)
(`goose v2026.4-17-gf4637bfb`, runtime `d521138194f1`), built Debug with
`GOOSE_BUILTIN_LIBS` empty; the v2026.3 release is too old. No `--include` flag
or separate library build is needed. The import follows `main`; use a full
commit SHA instead for a reproducible dependency. The API is early and may change.

Line searches use goose-bstr, which uses goose-simd. Declare both dependencies in
the program's root file as above; Goose requires root-level package declarations.

## Borrow lines without allocating a string per line

`read_line(reader)` returns `const u8[:]` and `LineStatus`:

| Status | Meaning |
| --- | --- |
| `LineStatus.Line` | A line, which can be empty. |
| `LineStatus.Eof` | No bytes remain; the slice is empty. |
| `LineStatus.Error` | I/O failure or a closed reader; the slice is empty. |

LF and CRLF are removed. A lone CR is preserved, including at EOF. A final
unterminated line is returned once; a trailing newline does not create an
extra line. Contents are bytes: NUL and invalid UTF-8 are preserved.

**The slice borrows the reader's buffer and expires at the next operation
on that reader.** Do not store it for later use without copying it:

```goose
// Inside main(), with an open reader:
let line, status = io::read_line(reader);
assert(status == io::LineStatus.Line);
var saved: u8[>..] = [];
saved.append(line); // Own these bytes before reading again.
```

Lines already in the buffer are returned without copying. A line spanning
refills is compacted into the buffer, which grows geometrically if needed.
There is no fixed line-length limit; memory usage follows the longest line.
The default initial capacity is 8192 bytes; pass a positive size as the
second argument to `buffered_reader(file, capacity)` to change it.

`read(reader, destination)` copies available bytes into your slice, refilling
as needed for one read. It can return less than requested. Mixing it with
`read_line` preserves unread buffered bytes. Reader I/O errors are sticky;
close the reader after an error rather than treating it as EOF.

## Buffer writes and check the flush

`buffered_writer(file, capacity = 8192)` uses a fixed-size buffer. `write`
returns how many input bytes it accepted, including bytes still in memory.
It flushes when it needs space. `flush(writer)` sends buffered bytes to the
OS, retrying partial writes. **Always check `flush` or `close`, even when
every `write` succeeded.** Neither operation promises disk durability.

If `write` returns a short count, retry only the unaccepted input suffix.
A result of `-1` means no input was accepted before an error. On a failed
flush, the writer keeps the unwritten suffix, allowing a later flush retry
without duplicating bytes already sent. `close(writer)` attempts a flush and
then closes even on failure; it returns false if either operation fails and
discards any bytes that could not be written.

## Raw handles and ownership

| Operation | Result |
| --- | --- |
| `open_read(path)` | Existing file opened for reading; handle and success flag. |
| `open_write(path)` | File created or truncated for writing; handle and success flag. |
| `read(file, buffer)` | Byte count, 0 at EOF, or -1 on error. |
| `write(file, bytes)` | Byte count, possibly partial, or -1 on error. |
| `close(file)` | Success flag; invalidates the handle even on failure. |

An empty read or write on an open handle returns 0. Files are binary on all
platforms. Paths need no NUL terminator; empty paths and embedded NULs are
rejected. Windows paths are decoded as UTF-8, while POSIX passes path bytes
through. Parent directories must already exist.

Close every successfully opened handle explicitly. Do not copy a live
`FileHandle`, construct one from an arbitrary descriptor, or use a default
value as a closed handle. Both buffered constructors **transfer ownership**:
they invalidate the original handle, and you must close the wrapper instead.
Do not access the wrapper's file separately or modify its internal fields.
Closing an already closed handle or wrapper succeeds.

There is no seeking, append mode, asynchronous I/O, or automatic close.
For whole-file reads/writes, Goose's `os` module may be enough; goose-io is for
incremental I/O. For byte-string processing, see
[goose-bstr](https://github.com/sstadick/goose-bstr).

## Contributing

Run from the repository root with Python 3 and a compatible Goose compiler:

```sh
python3 tests/run.py --cc gcc clang       # Linux
python3 tests/run.py --cc clang           # macOS
python3 tests/run.py --cc msvc clang-cl   # Windows
```

Set `GOOSE=/path/to/goose` to select a compiler. Tests use temporary working
directories and cover binary and Unicode paths, truncation, EOF/errors,
buffer boundaries, long lines, mixed byte/line reads, and flush/close.

Compare working-tree line-reading throughput with an earlier Git revision:

```sh
python3 scripts/bench_lines.py --baseline HEAD --cc gcc clang
```

The benchmark uses warm-cache file reads, an 8192-byte buffer, seven alternating
rounds, and matching optimized builds. It checks line counts and checksums on
empty, short, long, CRLF, and binary lines. `--output results.json` saves raw
timings; `--baseline` should name the pre-change revision after committing.
Pre-migration baselines retain their `goosio`/`goostr` imports and use the
pre-migration SIMD commit `983f3bb2bfee95affd09f4f5530be249d7d6040b`;
the runner does not import new module names from old revisions.
Search setup can cost more than a scalar scan for very short nonempty lines;
the benchmark includes one-byte payloads so that tradeoff stays visible.

Edit API documentation in source comments, not `API.md`. With
[goose-doc](https://github.com/sstadick/goose-doc/commit/f7292c9ee395596fa39eb709f90dc71ef124a0eb)
checked out at `../goose-doc`:

```sh
scripts/docs.sh
scripts/docs.sh --check
scripts/doctest.sh
scripts/doctest.sh --cc gcc
scripts/doctest.sh --cc clang
```

Set `GOOSE_DOC=/path/to/goose-doc/main.goose` for another location. Each supported
declaration and overload needs an executable example. The
[example preamble](tests/doc_preamble.goose) supplies `std`, `os`, the local
package import, and `doc_path`, a disposable filename. Run doctests serially
from the root; they refuse to overwrite a leftover example file.

CI runs TinyCC, native builds, docs checks, and examples on Linux x86-64/ARM64
(GCC and Clang), macOS ARM64 (Clang), and Windows x86-64 (MSVC and clang-cl).
Pushing a `vMAJOR.MINOR.PATCH` tag publishes a source release only after the
entire matrix passes, attaching an API reference with commit-pinned links.

## Migration from goosio

The repository is now [sstadick/goose-io](https://github.com/sstadick/goose-io).
Replace `import goosio from "github.com/sstadick/goosio@<ref>";` with
`import io from "github.com/sstadick/goose-io@<migration-or-later-ref>";`
and change `goosio::` to `io::`. The entry file is `io.goose`.
Function and type names are unchanged; owned-struct UFCS remains supported.
Old release tags retain the old entry file and namespace, so do not use the
new import identifier with a pre-migration revision. No compatibility wrapper
is provided.

Dependencies below are exact coordinated migration commits. Until they are
merged/published, remote builds require those commits to be made available
(or local package source overrides). Existing release tags do not contain
the new namespaces. The documentation scripts use `GOOSE_DOC`, defaulting
to `../goose-doc/main.goose`.

- `goose-doc`: `f7292c9ee395596fa39eb709f90dc71ef124a0eb`
- `goose-simd`: `e11e34447d9b0f23f2fd0f63bc25f4aee838f175`
- `goose-bstr`: `216c80429b1d9df6ffbd73eaf32b70c1a8e074bf`

## License

MIT; see [LICENSE](LICENSE).
