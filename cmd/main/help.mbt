///|
/// Help and version screens, mirroring the reference CLI's texts
/// (`src/arturo.nim`). Commands not supported by this port (bytecode,
/// bundling, packages) are omitted.

///|
fn version_text() -> String {
  "arturo 0.1.0 (MoonBit port)"
}

///|
fn help_text() -> String {
  (
    #|Usage:
    #|    arturo [options] <path>
    #|
    #|Arguments:
    #|    <path>
    #|        Path to the source code file to execute -
    #|        usually with an .art extension
    #|
    #|Commands:
    #|    -e, --evaluate <code>   Evaluate given code string
    #|    -r, --repl              Show repl / interactive console
    #|    -h, --help              Show this help screen
    #|    -v, --version           Show current version
    #|
    #|Options:
    #|    --no-color              Mute all colors from output
    #|
  )
}
