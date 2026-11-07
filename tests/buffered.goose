import std;
import os;
import goosio from "..";
import goostr from "github.com/sstadick/goostr@bdf6eb74faddca0ef62092c2034589f4dd11fab1";
import goosimd from "github.com/sstadick/goosimd@main";

const path = "buffered.tmp";

fn expect_line(reader: goosio::BufferedReader&, expected: const u8[:]) {
    let line, status = goosio::read_line(reader);
    assert(status == goosio::LineStatus.Line);
    assert(line == expected);
}

fn expect_eof(reader: goosio::BufferedReader&) {
    for i in 2 {
        let line, status = goosio::read_line(reader);
        assert(status == goosio::LineStatus.Eof && line.len == 0);
    }
}

fn lines(capacity: i64) {
    // CRLF split across refills, empty lines, binary bytes, bare CR, and
    // unterminated tails must not depend on the buffer size.
    assert(write_file(path, "\nalpha\r\n\r\nx\0\xFF\nlast\r"));
    let file, ok = goosio::open_read(path);
    assert(ok);
    let reader = goosio::buffered_reader(file, capacity);
    assert(goosio::close(file));
    expect_line(reader, "");
    expect_line(reader, "alpha");
    expect_line(reader, "");
    expect_line(reader, "x\0\xFF");
    expect_line(reader, "last\r");
    expect_eof(reader);
    assert(goosio::close(reader));
    assert(goosio::close(reader));
    let line, status = goosio::read_line(reader);
    assert(status == goosio::LineStatus.Error && line.len == 0);
    var bytes: u8[1] = [0];
    assert(goosio::read(reader, bytes) == -1);
    assert(delete_file(path));

    for text in ["", "a\n", "\r", "\r\n", "\n\n"] {
        assert(write_file(path, text));
        let input, opened = goosio::open_read(path);
        assert(opened);
        let r = goosio::buffered_reader(input, capacity);
        if text == "a\n" { expect_line(r, "a"); }
        if text == "\r" { expect_line(r, "\r"); }
        if text == "\r\n" { expect_line(r, ""); }
        if text == "\n\n" { expect_line(r, ""); expect_line(r, ""); }
        expect_eof(r);
        assert(goosio::close(r));
        assert(delete_file(path));
    }
}

fn long_lines(capacity: i64) {
    var long: u8[>..] = [];
    for i in 20003 { long.push(('a' + i % 23) as u8); }
    var data: u8[>..] = [];
    data.append("prefix\n");
    data.append(long);
    data.append("\r\nend\n");
    data.append(long);
    assert(write_file(path, data));
    let file, ok = goosio::open_read(path);
    assert(ok);
    let reader = goosio::buffered_reader(file, capacity);
    expect_line(reader, "prefix");
    let borrowed, status = goosio::read_line(reader);
    assert(status == goosio::LineStatus.Line && borrowed == long);
    var saved: u8[>..] = [];
    saved.append(borrowed);
    expect_line(reader, "end");
    expect_line(reader, long);
    expect_eof(reader);
    assert(saved == long);
    assert(goosio::close(reader));
    assert(delete_file(path));
}

fn mixed_reads(capacity: i64) {
    assert(write_file(path, "abCDE\r\nrest\n"));
    let file, ok = goosio::open_read(path);
    assert(ok);
    let reader = goosio::buffered_reader(file, capacity);
    var byte: u8[1] = [0];
    assert(goosio::read(reader, byte[..0]) == 0);
    assert(goosio::read(reader, byte) == 1 && byte[0] == 'a');
    assert(goosio::read(reader, byte) == 1 && byte[0] == 'b');
    expect_line(reader, "CDE");
    assert(goosio::read(reader, byte) == 1 && byte[0] == 'r');
    expect_line(reader, "est");
    assert(goosio::read(reader, byte) == 0);
    expect_eof(reader);
    assert(goosio::close(reader));
    assert(delete_file(path));
}

fn writes(capacity: i64) {
    let file, ok = goosio::open_write(path);
    assert(ok);
    let writer = goosio::buffered_writer(file, capacity);
    assert(goosio::close(file));
    assert(goosio::write(writer, "") == 0);
    assert(goosio::flush(writer));
    var expected: u8[>..] = [];
    for chunk in ["a", "b\0\r\n", "0123456789abcdef", "tail"] {
        assert(goosio::write(writer, chunk) == chunk.len);
        expected.append(chunk);
    }
    assert(goosio::flush(writer));
    assert(goosio::flush(writer));
    var visible: u8[>..] = [];
    assert(read_file(path, visible) && visible == expected);
    assert(goosio::write(writer, "!") == 1);
    assert(goosio::close(writer));
    assert(goosio::close(writer));
    assert(!goosio::flush(writer));
    assert(goosio::write(writer, "x") == -1);
    expected.push('!');
    var final: u8[>..] = [];
    assert(read_file(path, final) && final == expected);
    assert(delete_file(path));
}

fn errors() {
    // A real OS error, not EOF: attempt to read a write-only descriptor.
    let output, ok = goosio::open_write(path);
    assert(ok);
    let reader = goosio::buffered_reader(output, 2);
    for i in 2 {
        let line, status = goosio::read_line(reader);
        assert(status == goosio::LineStatus.Error && line.len == 0);
    }
    var bytes: u8[1] = [0];
    assert(goosio::read(reader, bytes) == -1);
    assert(goosio::close(reader));

    // Buffer acceptance is not successful flushing. A failed flush is
    // retriable without accepting more data into an already full buffer.
    let input, opened = goosio::open_read(path);
    assert(opened);
    let writer = goosio::buffered_writer(input, 3);
    assert(goosio::write(writer, "abcde") == 3);
    assert(goosio::write(writer, "de") == -1);
    assert(!goosio::flush(writer));
    assert(!goosio::close(writer));
    assert(goosio::close(writer));
    assert(goosio::write(writer, "") == -1);
    var unchanged: u8[>..] = [];
    assert(read_file(path, unchanged) && unchanged.len == 0);
    assert(delete_file(path));

    let missing, found = goosio::open_read("");
    assert(!found);
    let closed = goosio::buffered_writer(missing);
    assert(goosio::write(closed, "a") == -1);
    assert(!goosio::flush(closed));
    assert(goosio::close(closed));
}

fn main() {
    for capacity in [1, 2, 3, 7, 8, 15, 16, 17, 31, 32, 33, 1023, 1024, 1025, 8192] {
        lines(capacity);
        long_lines(capacity);
        mixed_reads(capacity);
        writes(capacity);
    }
    errors();
}
