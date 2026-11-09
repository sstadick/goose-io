import std;
import os;
import io from "..";
import bstr from "github.com/sstadick/goose-bstr@v0.3.1";
import simd_bytes from "github.com/sstadick/goose-simd@v0.2.0";

// Each example runs as a separate program and removes its file on success.
// Refuse to overwrite a leftover file from an interrupted run.
fn example_path() -> const u8[:] {
    let path = "goose-io-doc-example.tmp";
    assert(!file_exists(path));
    return path;
}
let doc_path = example_path();
