import std;
import os;
import io from "..";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";

// The raw I/O functions deliberately have no checkfree annotations.
checkfree fn raw_io(path: const u8[:]) {
    let output, opened = io::open_write(path);
    assert(opened);
    assert(io::write(output, "") == 0);
    assert(io::write(output, "a\0\xFF\r\n") == 5);
    assert(io::close(output));
    assert(io::close(output));
    assert(io::write(output, "x") == -1);

    let input, reopened = io::open_read(path);
    assert(reopened);
    var bytes: u8[5] = [0; 5];
    assert(io::read(input, bytes[..0]) == 0);
    assert(io::read(input, bytes) == 5);
    assert(bytes == "a\0\xFF\r\n");
    assert(io::read(input, bytes) == 0);
    assert(io::seek(input, 1) == 1);
    assert(io::read(input, bytes[..1]) == 1 && bytes[0] == 0);
    assert(io::seek(input, -1) == -1);
    assert(io::close(input));
    assert(io::read(input, bytes) == -1);
    assert(io::seek(input, 0) == -1);

    let missing, found = io::open_read("");
    assert(!found);
    assert(io::close(missing));
}

fn main() {
    let path = "checkfree.tmp";
    assert(!file_exists(path));
    raw_io(path);
    assert(delete_file(path));
}
