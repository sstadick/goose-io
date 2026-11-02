import std;
import os;
import goosio from "..";

fn main() {
    let path = "goosio-café-文件.tmp";
    assert(!file_exists(path));

    let output, opened = goosio::open_write(path);
    assert(opened);
    assert(goosio::write(output, "") == 0);
    assert(goosio::write(output, "hello from goosio") == 17);
    assert(goosio::close(output));
    assert(goosio::close(output));
    assert(goosio::write(output, "x") == -1);

    let input, reopened = goosio::open_read(path);
    assert(reopened);
    var buffer: u8[32] = [0; 32];
    assert(goosio::read(input, buffer[..0]) == 0);
    assert(goosio::read(input, buffer[..5]) == 5);
    assert(buffer[..5] == "hello");
    assert(goosio::read(input, buffer) == 12);
    assert(buffer[..12] == " from goosio");
    assert(goosio::read(input, buffer) == 0);
    assert(goosio::close(input));
    assert(goosio::read(input, buffer) == -1);

    // Opening for writing truncates, and binary data survives unchanged.
    let truncated, writable = goosio::open_write(path);
    assert(writable);
    assert(goosio::write(truncated, "a\0\xFF\r\n") == 5);
    assert(goosio::close(truncated));
    var contents: u8[>..] = [];
    assert(read_file(path, contents) && contents == "a\0\xFF\r\n");
    assert(delete_file(path));

    for invalid in ["", "missing-parent/file", "invalid\0suffix"] {
        let file, ok = goosio::open_read(invalid);
        assert(!ok);
        assert(goosio::read(file, buffer) == -1);
        assert(goosio::close(file));
        let out, created = goosio::open_write(invalid);
        assert(!created);
        assert(goosio::write(out, "x") == -1);
        assert(goosio::close(out));
    }
    let absent, found = goosio::open_read(path);
    assert(!found);
    assert(goosio::close(absent));
}
