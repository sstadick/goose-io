import std;
import os;
import goosio from "..";
import goostr from "github.com/sstadick/goostr@bdf6eb74faddca0ef62092c2034589f4dd11fab1";
import goosimd from "github.com/sstadick/goosimd@main";

// Each example runs as a separate program and removes its file on success.
// Refuse to overwrite a leftover file from an interrupted run.
fn example_path() -> const u8[:] {
    let path = "goosio-doc-example.tmp";
    assert(!file_exists(path));
    return path;
}
let doc_path = example_path();
