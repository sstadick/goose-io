// Small, synchronous file IO for Goose.
//
// A read returns the number of bytes placed in `buffer`: 0 means EOF and -1
// means an error. A write returns the number of bytes written, which can be
// smaller than the buffer length, or -1 on error.
//
// FileHandle values own their descriptor by convention. Do not copy them, and
// close each successfully opened handle when it is no longer needed.

namespace io;

import std;
import bstr from "github.com/sstadick/goose-bstr@216c80429b1d9df6ffbd73eaf32b70c1a8e074bf";

// An owned file descriptor. Obtain it from open_read/open_write, check their
// bool result, and close it explicitly. Do not copy a live handle or construct
// one from an arbitrary fd; a default-initialized handle is not a closed handle.
//
// ```goose
// let file, ok = io::open_read("");
// assert(!ok);
// assert(io::close(file)); // A failed open is safe to close.
// ```
struct FileHandle { fd: i32 }

extern fn open_raw(path: const u8[:], mode: i32) -> i32 = "goosio_open";
extern fn read_raw(fd: i32, buffer: u8[:]) -> i64 = "goosio_read";
extern fn write_raw(fd: i32, buffer: const u8[:]) -> i64 = "goosio_write";
extern fn close_raw(fd: i32) -> i32 = "goosio_close";

// Open an existing file for reading. Return a handle and success flag.
// Empty paths and paths containing NUL fail. Paths are UTF-8 on Windows;
// POSIX passes non-NUL bytes through to the OS. No trailing NUL is required.
//
// ```goose
// assert(write_file(doc_path, "hello"));
// let file, ok = io::open_read(doc_path);
// assert(ok);
// assert(io::close(file));
// assert(delete_file(doc_path));
// ```
inline fn open_read(path: const u8[:]) -> FileHandle, bool {
    let fd = open_raw(path, 0);
    return FileHandle { fd: fd }, fd >= 0;
}

// Create or truncate a file and open it for binary writing. Return a handle
// and success flag. Parent directories must already exist. On POSIX, new
// files use mode 0666 modified by the process umask. Path rules match open_read.
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// assert(io::write(file, "hello") == 5);
// assert(io::close(file));
// assert(delete_file(doc_path));
// ```
inline fn open_write(path: const u8[:]) -> FileHandle, bool {
    let fd = open_raw(path, 1);
    return FileHandle { fd: fd }, fd >= 0;
}

// Read up to buffer.len bytes, advancing the file position. Return a byte
// count, 0 at EOF (or for an empty buffer), or -1 on error/closed handle.
// Short reads are allowed; only buffer[..count] is initialized by the read.
//
// ```goose
// assert(write_file(doc_path, "abc"));
// let file, ok = io::open_read(doc_path);
// assert(ok);
// var bytes: u8[8] = [0; 8];
// assert(io::read(file, bytes) == 3);
// assert(bytes[..3] == "abc");
// assert(io::read(file, bytes) == 0);
// assert(io::close(file));
// assert(delete_file(doc_path));
// ```
inline fn read(file: const FileHandle&, buffer: u8[:]) -> i64 {
    if file.fd < 0 { return -1; }
    return read_raw(file.fd, buffer);
}

// Write up to buffer.len bytes, advancing the file position. Return the byte
// count, or -1 on error/closed handle. Writes can be partial; retry the unwritten
// suffix. An empty write to an open handle returns 0. No newline translation.
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// assert(io::write(file, "a\0b\r\n") == 5);
// assert(io::close(file));
// var bytes: u8[>..] = [];
// assert(read_file(doc_path, bytes));
// assert(bytes == "a\0b\r\n");
// assert(delete_file(doc_path));
// ```
inline fn write(file: const FileHandle&, buffer: const u8[:]) -> i64 {
    if file.fd < 0 { return -1; }
    return write_raw(file.fd, buffer);
}

// Close and invalidate a handle. Closing an already closed handle succeeds.
// The handle is invalidated even if the OS close fails; do not retry the raw
// descriptor. This is not a durability guarantee (there is no fsync here).
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// assert(io::close(file));
// assert(io::close(file));
// assert(io::write(file, "x") == -1);
// assert(delete_file(doc_path));
// ```
inline fn close(file: FileHandle&) -> bool {
    if file.fd < 0 { return true; }
    let fd = file.fd;
    file.fd = -1;
    return close_raw(fd) == 0;
}

// An owning buffered reader. Construct with buffered_reader; do not copy it
// or access its file separately. Borrowed lines expire on the next reader
// operation. Buffer storage grows to accommodate the longest line read.
//
// ```goose
// assert(write_file(doc_path, "first\nsecond\n"));
// let file, ok = io::open_read(doc_path);
// assert(ok);
// let reader = io::buffered_reader(file);
// let line, status = io::read_line(reader);
// assert(status == io::LineStatus.Line && line == "first");
// assert(io::close(reader));
// assert(delete_file(doc_path));
// ```
struct BufferedReader {
    file: FileHandle,
    start: i64,
    end: i64,
    failed: bool,
    buffer: u8[>..]
}

// Transfer file ownership into a reader, invalidating the original handle.
// Capacity must be positive; defaults to 8192 bytes. The file must have been
// opened for reading. Transferring a closed handle yields a closed reader.
//
// ```goose
// assert(write_file(doc_path, "abc"));
// let file, ok = io::open_read(doc_path);
// assert(ok);
// let reader = io::buffered_reader(file, 2);
// assert(io::close(file)); // Ownership has moved; reader is still open.
// let line, status = io::read_line(reader);
// assert(status == io::LineStatus.Line && line == "abc");
// assert(io::close(reader));
// assert(delete_file(doc_path));
// ```
fn buffered_reader(file: FileHandle&, capacity: i64 = 8192) -> BufferedReader {
    assert(capacity > 0);
    var reader = BufferedReader { file: file, start: 0, end: 0, failed: false, buffer: [] };
    file.fd = -1;
    reader.buffer.resize(capacity, 0);
    return reader;
}

// Read buffered bytes, refilling once if necessary. Return a byte count,
// 0 at EOF (or for an empty destination), or -1 on error/closed reader.
// May return fewer bytes than requested. Can be mixed with read_line without
// losing prefetched data. An I/O error is sticky until close.
//
// ```goose
// assert(write_file(doc_path, "abc\ndef"));
// let file, ok = io::open_read(doc_path);
// assert(ok);
// let reader = io::buffered_reader(file);
// var bytes: u8[2] = [0; 2];
// assert(io::read(reader, bytes) == 2 && bytes == "ab");
// let line, status = io::read_line(reader);
// assert(status == io::LineStatus.Line && line == "c");
// assert(io::close(reader));
// assert(delete_file(doc_path));
// ```
fn read(reader: BufferedReader&, buffer: u8[:]) -> i64 {
    if reader.file.fd < 0 || reader.failed { return -1; }
    if buffer.len == 0 { return 0; }
    if reader.start == reader.end {
        let count = read(reader.file, reader.buffer);
        if count < 0 { reader.failed = true; return -1; }
        reader.start = 0;
        reader.end = count;
    }
    let count = min(buffer.len, reader.end - reader.start);
    for i in count { buffer[i] = reader.buffer[reader.start + i]; }
    reader.start += count;
    return count;
}

// The outcome of read_line: Line includes empty lines, Eof means no bytes
// remain, and Error means a closed reader or an I/O failure. Line bytes are
// empty for Eof and Error; an incomplete line is not returned on failure.
//
// ```goose
// assert(write_file(doc_path, "\n"));
// let file, ok = io::open_read(doc_path);
// assert(ok);
// let reader = io::buffered_reader(file);
// let line, status = io::read_line(reader);
// assert(status == io::LineStatus.Line && line.len == 0);
// let end, ended = io::read_line(reader);
// assert(ended == io::LineStatus.Eof && end.len == 0);
// assert(io::close(reader));
// assert(delete_file(doc_path));
// ```
enum LineStatus { Line, Eof, Error }

// Borrow the next line directly from the reader's buffer, without copying
// lines already buffered. Strip LF and a CR immediately before it; preserve
// a lone CR and return a final unterminated line. No UTF-8 validation occurs.
// Lines spanning refills are compacted and the buffer grows as needed.
// The slice is valid only until the next operation on reader; copy it into
// your own storage to retain it. I/O errors are sticky until close.
//
// ```goose
// assert(write_file(doc_path, "first\r\nsecond"));
// let file, ok = io::open_read(doc_path);
// assert(ok);
// let reader = io::buffered_reader(file, 4);
// let line, status = io::read_line(reader);
// assert(status == io::LineStatus.Line && line == "first");
// var saved: u8[>..] = [];
// saved.append(line); // Retain a copy before reading again.
// let next, next_status = io::read_line(reader);
// assert(next_status == io::LineStatus.Line && next == "second");
// assert(saved == "first");
// assert(io::close(reader));
// assert(delete_file(doc_path));
// ```
fn read_line(reader: BufferedReader&) -> const u8[:], LineStatus {
    if reader.file.fd < 0 || reader.failed { return "", LineStatus.Error; }
    // Already-buffered empty lines need no search setup.
    if reader.start < reader.end && reader.buffer[reader.start] == '\n' {
        let line = reader.buffer[reader.start..reader.start];
        reader.start += 1;
        return line, LineStatus.Line;
    }
    var scan = reader.start;
    loop {
        let offset = bstr::find_byte(reader.buffer[scan..reader.end], '\n');
        if offset >= 0 {
            let newline = scan + offset;
            var end = newline;
            if end > reader.start && reader.buffer[end - 1] == '\r' { end -= 1; }
            let line = reader.buffer[reader.start..end];
            reader.start = newline + 1;
            return line, LineStatus.Line;
        }
        // Preserve only the unfinished line. Scan each byte once, even when
        // the line is much larger than the original buffer.
        let remaining = reader.end - reader.start;
        if reader.start > 0 {
            for i in remaining { reader.buffer[i] = reader.buffer[reader.start + i]; }
        }
        reader.start = 0;
        reader.end = remaining;
        scan = remaining;
        if remaining == reader.buffer.len { reader.buffer.resize(reader.buffer.len * 2, 0); }
        let count = read(reader.file, reader.buffer[remaining..]);
        if count < 0 { reader.failed = true; return "", LineStatus.Error; }
        if count == 0 {
            reader.start = remaining;
            if remaining == 0 { return "", LineStatus.Eof; }
            return reader.buffer[..remaining], LineStatus.Line;
        }
        reader.end += count;
    }
}

// Close the reader, discarding unread buffered bytes and invalidating all
// borrowed lines. Closing an already closed reader succeeds.
//
// ```goose
// let file, ok = io::open_read("");
// assert(!ok);
// let reader = io::buffered_reader(file);
// assert(io::close(reader));
// assert(io::close(reader));
// let line, status = io::read_line(reader);
// assert(status == io::LineStatus.Error);
// ```
fn close(reader: BufferedReader&) -> bool {
    reader.start = 0;
    reader.end = 0;
    return close(reader.file);
}

// An owning buffered writer. Construct with buffered_writer; do not copy it
// or use its file separately. Flush or close explicitly and check the result:
// accepting bytes into memory does not mean the OS has received them.
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// let writer = io::buffered_writer(file);
// assert(io::write(writer, "hello") == 5);
// assert(io::close(writer));
// assert(delete_file(doc_path));
// ```
struct BufferedWriter { file: FileHandle, used: i64, buffer: u8[>..] }

// Transfer file ownership into a writer, invalidating the original handle.
// Capacity must be positive; defaults to 8192 bytes. The file must have been
// opened for writing. Transferring a closed handle yields a closed writer.
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// let writer = io::buffered_writer(file, 3);
// assert(io::close(file));
// assert(io::write(writer, "abcdefg") == 7);
// assert(io::close(writer));
// assert(delete_file(doc_path));
// ```
fn buffered_writer(file: FileHandle&, capacity: i64 = 8192) -> BufferedWriter {
    assert(capacity > 0);
    var writer = BufferedWriter { file: file, used: 0, buffer: [] };
    file.fd = -1;
    writer.buffer.resize(capacity, 0);
    return writer;
}

// Flush buffered bytes to the OS, retrying short writes. Return false on an
// error, zero-progress write, or closed writer. On failure, retain only the
// unwritten suffix so a retry does not duplicate data. This is not fsync.
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// let writer = io::buffered_writer(file);
// assert(io::write(writer, "visible") == 7);
// assert(io::flush(writer));
// var bytes: u8[>..] = [];
// assert(read_file(doc_path, bytes) && bytes == "visible");
// assert(io::close(writer));
// assert(delete_file(doc_path));
// ```
fn flush(writer: BufferedWriter&) -> bool {
    if writer.file.fd < 0 { return false; }
    var sent: i64 = 0;
    while sent < writer.used {
        let count = write(writer.file, writer.buffer[sent..writer.used]);
        if count <= 0 {
            let remaining = writer.used - sent;
            for i in remaining { writer.buffer[i] = writer.buffer[sent + i]; }
            writer.used = remaining;
            return false;
        }
        sent += count;
    }
    writer.used = 0;
    return true;
}

// Buffer bytes, flushing whenever space is needed. Return the number accepted
// (buffered or sent), or -1 if an error occurs before any are accepted.
// After a short result, retry only the unaccepted input suffix. Always check
// flush/close as well: a successful write can leave data buffered in memory.
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// let writer = io::buffered_writer(file, 2);
// assert(io::write(writer, "ab") == 2);
// assert(io::write(writer, "c\n") == 2);
// assert(io::close(writer));
// var bytes: u8[>..] = [];
// assert(read_file(doc_path, bytes) && bytes == "abc\n");
// assert(delete_file(doc_path));
// ```
fn write(writer: BufferedWriter&, buffer: const u8[:]) -> i64 {
    if writer.file.fd < 0 { return -1; }
    var accepted: i64 = 0;
    while accepted < buffer.len {
        if writer.used == writer.buffer.len && !flush(writer) {
            return if accepted == 0 { -1 } else { accepted };
        }
        let count = min(buffer.len - accepted, writer.buffer.len - writer.used);
        let dst = writer.buffer[writer.used..writer.used + count];
        let src = buffer[accepted..accepted + count];
        for i in dst.len { dst[i] = src[i]; }
        writer.used += count;
        accepted += count;
    }
    return accepted;
}

// Flush and close the writer, returning false if either operation fails.
// Always close the file, even after a flush failure; unwritten bytes are then
// discarded. To retry a failed flush, call flush before close instead.
// Closing an already closed writer succeeds.
//
// ```goose
// let file, ok = io::open_write(doc_path);
// assert(ok);
// let writer = io::buffered_writer(file);
// assert(io::write(writer, "saved on close") == 14);
// assert(io::close(writer));
// assert(io::close(writer));
// var bytes: u8[>..] = [];
// assert(read_file(doc_path, bytes) && bytes == "saved on close");
// assert(delete_file(doc_path));
// ```
fn close(writer: BufferedWriter&) -> bool {
    if writer.file.fd < 0 { return true; }
    let flushed = flush(writer);
    let closed = close(writer.file);
    writer.used = 0;
    return flushed && closed;
}
