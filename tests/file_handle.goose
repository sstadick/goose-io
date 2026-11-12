import std;
import os;
import io from "..";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";

fn main() {
    let path = "goose-io-café-文件.tmp";
    assert(!file_exists(path));

    let output, opened = io::open_write(path);
    assert(opened);
    assert(io::write(output, "") == 0);
    assert(output.write("hello from goosio") == 17);
    assert(output.close());
    assert(io::close(output));
    assert(io::write(output, "x") == -1);

    let input, reopened = io::open_read(path);
    assert(reopened);
    var buffer: u8[32] = [0; 32];
    assert(io::read(input, buffer[..0]) == 0);
    assert(input.read(buffer[..5]) == 5);
    assert(buffer[..5] == "hello");
    assert(io::read(input, buffer) == 12);
    assert(buffer[..12] == " from goosio");
    assert(io::read(input, buffer) == 0);
    assert(io::seek(input, 6) == 6);
    assert(io::read(input, buffer[..4]) == 4 && buffer[..4] == "from");
    assert(io::seek(input, (1 << 32) + 17) == (1 << 32) + 17);
    assert(io::read(input, buffer) == 0);
    assert(io::seek(input, 0) == 0);
    assert(io::read(input, buffer[..5]) == 5 && buffer[..5] == "hello");
    assert(io::seek(input, -1) == -1);
    assert(io::close(input));
    assert(io::read(input, buffer) == -1);
    assert(io::seek(input, 0) == -1);

    // Opening for writing truncates, and binary data survives unchanged.
    let truncated, writable = io::open_write(path);
    assert(writable);
    assert(io::write(truncated, "a\0\xFF\r\n") == 5);
    assert(io::close(truncated));
    var contents: u8[>..] = [];
    assert(read_file(path, contents) && contents == "a\0\xFF\r\n");
    assert(delete_file(path));

    for invalid in ["", "missing-parent/file", "invalid\0suffix"] {
        let file, ok = io::open_read(invalid);
        assert(!ok);
        assert(io::read(file, buffer) == -1);
        assert(io::close(file));
        let out, created = io::open_write(invalid);
        assert(!created);
        assert(io::write(out, "x") == -1);
        assert(io::close(out));
    }
    let absent, found = io::open_read(path);
    assert(!found);
    assert(io::close(absent));
}
