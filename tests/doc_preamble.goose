import std;
import os;
import goosio from "..";

// Each example runs as a separate program and removes its file on success.
// Refuse to overwrite a leftover file from an interrupted run.
fn example_path() -> const u8[:] {
    let path = "goosio-doc-example.tmp";
    assert(!file_exists(path));
    return path;
}
let doc_path = example_path();
