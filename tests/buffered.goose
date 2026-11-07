import std;
import os;
import io from "..";
import bstr from "github.com/sstadick/goose-bstr@216c80429b1d9df6ffbd73eaf32b70c1a8e074bf";
import simd_bytes from "github.com/sstadick/goose-simd@e11e34447d9b0f23f2fd0f63bc25f4aee838f175";

const path = "buffered.tmp";

fn expect_line(reader: io::BufferedReader&, expected: const u8[:]) {
    let line, status = reader.read_line();
    assert(status == io::LineStatus.Line);
    assert(line == expected);
}

fn expect_eof(reader: io::BufferedReader&) {
    for i in 2 {
        let line, status = io::read_line(reader);
        assert(status == io::LineStatus.Eof && line.len == 0);
    }
}

fn lines(capacity: i64) {
    // CRLF split across refills, empty lines, binary bytes, bare CR, and
    // unterminated tails must not depend on the buffer size.
    assert(write_file(path, "\nalpha\r\n\r\nx\0\xFF\nlast\r"));
    let file, ok = io::open_read(path);
    assert(ok);
    let reader = io::buffered_reader(file, capacity);
    assert(io::close(file));
    expect_line(reader, "");
    expect_line(reader, "alpha");
    expect_line(reader, "");
    expect_line(reader, "x\0\xFF");
    expect_line(reader, "last\r");
    expect_eof(reader);
    assert(io::close(reader));
    assert(io::close(reader));
    let line, status = io::read_line(reader);
    assert(status == io::LineStatus.Error && line.len == 0);
    var bytes: u8[1] = [0];
    assert(io::read(reader, bytes) == -1);
    assert(delete_file(path));

    for text in ["", "a\n", "\r", "\r\n", "\n\n"] {
        assert(write_file(path, text));
        let input, opened = io::open_read(path);
        assert(opened);
        let r = io::buffered_reader(input, capacity);
        if text == "a\n" { expect_line(r, "a"); }
        if text == "\r" { expect_line(r, "\r"); }
        if text == "\r\n" { expect_line(r, ""); }
        if text == "\n\n" { expect_line(r, ""); expect_line(r, ""); }
        expect_eof(r);
        assert(io::close(r));
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
    let file, ok = io::open_read(path);
    assert(ok);
    let reader = io::buffered_reader(file, capacity);
    expect_line(reader, "prefix");
    let borrowed, status = io::read_line(reader);
    assert(status == io::LineStatus.Line && borrowed == long);
    var saved: u8[>..] = [];
    saved.append(borrowed);
    expect_line(reader, "end");
    expect_line(reader, long);
    expect_eof(reader);
    assert(saved == long);
    assert(io::close(reader));
    assert(delete_file(path));
}

fn mixed_reads(capacity: i64) {
    assert(write_file(path, "abCDE\r\nrest\n"));
    let file, ok = io::open_read(path);
    assert(ok);
    let reader = io::buffered_reader(file, capacity);
    var byte: u8[1] = [0];
    assert(io::read(reader, byte[..0]) == 0);
    assert(io::read(reader, byte) == 1 && byte[0] == 'a');
    assert(io::read(reader, byte) == 1 && byte[0] == 'b');
    expect_line(reader, "CDE");
    assert(io::read(reader, byte) == 1 && byte[0] == 'r');
    expect_line(reader, "est");
    assert(io::read(reader, byte) == 0);
    expect_eof(reader);
    assert(io::close(reader));
    assert(delete_file(path));
}

fn writes(capacity: i64) {
    let file, ok = io::open_write(path);
    assert(ok);
    let writer = file.buffered_writer(capacity);
    assert(io::close(file));
    assert(writer.write("") == 0);
    assert(writer.flush());
    var expected: u8[>..] = [];
    for chunk in ["a", "b\0\r\n", "0123456789abcdef", "tail"] {
        assert(io::write(writer, chunk) == chunk.len);
        expected.append(chunk);
    }
    assert(io::flush(writer));
    assert(io::flush(writer));
    var visible: u8[>..] = [];
    assert(read_file(path, visible) && visible == expected);
    assert(io::write(writer, "!") == 1);
    assert(io::close(writer));
    assert(io::close(writer));
    assert(!io::flush(writer));
    assert(io::write(writer, "x") == -1);
    expected.push('!');
    var final: u8[>..] = [];
    assert(read_file(path, final) && final == expected);
    assert(delete_file(path));
}

fn errors() {
    // A real OS error, not EOF: attempt to read a write-only descriptor.
    let output, ok = io::open_write(path);
    assert(ok);
    let reader = io::buffered_reader(output, 2);
    for i in 2 {
        let line, status = io::read_line(reader);
        assert(status == io::LineStatus.Error && line.len == 0);
    }
    var bytes: u8[1] = [0];
    assert(io::read(reader, bytes) == -1);
    assert(io::close(reader));

    // Buffer acceptance is not successful flushing. A failed flush is
    // retriable without accepting more data into an already full buffer.
    let input, opened = io::open_read(path);
    assert(opened);
    let writer = io::buffered_writer(input, 3);
    assert(io::write(writer, "abcde") == 3);
    assert(io::write(writer, "de") == -1);
    assert(!io::flush(writer));
    assert(!io::close(writer));
    assert(io::close(writer));
    assert(io::write(writer, "") == -1);
    var unchanged: u8[>..] = [];
    assert(read_file(path, unchanged) && unchanged.len == 0);
    assert(delete_file(path));

    let missing, found = io::open_read("");
    assert(!found);
    let closed = io::buffered_writer(missing);
    assert(io::write(closed, "a") == -1);
    assert(!io::flush(closed));
    assert(io::close(closed));
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
