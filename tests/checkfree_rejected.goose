import std;
import io from "..";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";

// Buffered reads retain bounds checks. The diagnostic must name the actual
// check and this call chain, not demand an annotation on the callee.
checkfree fn next_line(reader: io::BufferedReader&) -> const u8[:], io::LineStatus {
    return io::read_line(reader);
}

fn main() {
    let file, opened = io::open_read("");
    assert(!opened);
    let reader = io::buffered_reader(file, 4);
    let line, status = next_line(reader);
    assert(status == io::LineStatus.Error && line.len == 0);
    assert(io::close(reader));
}
