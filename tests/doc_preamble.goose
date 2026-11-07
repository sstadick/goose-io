import std;
import os;
import io from "..";
import bstr from "github.com/sstadick/goose-bstr@216c80429b1d9df6ffbd73eaf32b70c1a8e074bf";
import simd_bytes from "github.com/sstadick/goose-simd@e11e34447d9b0f23f2fd0f63bc25f4aee838f175";

// Each example runs as a separate program and removes its file on success.
// Refuse to overwrite a leftover file from an interrupted run.
fn example_path() -> const u8[:] {
    let path = "goose-io-doc-example.tmp";
    assert(!file_exists(path));
    return path;
}
let doc_path = example_path();
