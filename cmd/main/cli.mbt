///|
/// Command-line parsing for the Arturo CLI, declared declaratively
/// with `moonbitlang/core/argparse`, mirroring the reference
/// `src/arturo.nim`:
///
/// - `-e, --evaluate <code>` runs a code string,
/// - `-r, --repl` starts the interactive console,
/// - `-h, --help` and `-v, --version` print the help/version screens,
/// - `--no-color` mutes colors,
/// - the first positional is the script path; everything after it is
///   passed to the script (as the `args` symbol).
///
/// With no command and no path, the REPL starts (like the reference).
/// Options may appear anywhere on the command line; use `--` to pass
/// option-looking arguments to the script itself.

///|
/// The CLI command specification. Help text is rendered from this
/// spec (`render_help`); the built-in help/version flags are disabled
/// so that `-v` can follow the reference's convention.
fn cli_command() -> @argparse.Command {
  Command(
    "arturo",
    about="A MoonBit port of the Arturo programming language interpreter",
    disable_help_flag=true,
    disable_version_flag=true,
    flags=[
      FlagArg("help", short='h', long="help", about="Show this help screen"),
      FlagArg(
        "version",
        short='v',
        long="version",
        about="Show current version",
      ),
      FlagArg(
        "repl",
        short='r',
        long="repl",
        about="Show repl / interactive console",
      ),
      FlagArg("no-color", long="no-color", about="Mute all colors from output"),
    ],
    options=[
      OptionArg(
        "evaluate",
        short='e',
        long="evaluate",
        about="Evaluate given code string",
        allow_hyphen_values=true,
      ),
    ],
    positionals=[
      PositionArg("path", about="Path to the source code file to execute"),
      PositionArg(
        "script_args",
        num_args=ValueRange(lower=0),
        about="Arguments passed to the script",
        allow_hyphen_values=true,
      ),
    ],
  )
}

///|
/// The help screen, rendered from the command specification.
fn cli_help_text() -> String {
  cli_command().render_help()
}

///|
/// What the CLI is asked to do.
enum CliAction {
  RunFile(path~ : String, script_args~ : Array[String])
  Evaluate(code~ : String)
  Repl
  ShowHelp
  ShowVersion
} derive(Debug)

///|
/// The parsed command line.
struct CliOptions {
  action : CliAction
  no_color : Bool
} derive(Debug)

///|
/// The outcome of parsing: the options, or display-ready error text
/// (which already includes the rendered help).
enum CliParseResult {
  Parsed(CliOptions)
  CliFail(message~ : String)
} derive(Debug)

///|
fn flag_on(flags : Map[String, Bool], name : String) -> Bool {
  flags.get(name).unwrap_or(false)
}

///|
fn first_value(values : Map[String, Array[String]], name : String) -> String? {
  match values.get(name) {
    Some(vs) => if vs.is_empty() { None } else { Some(vs[0]) }
    None => None
  }
}

///|
/// Turn parsed matches into a CLI action. Precedence: help, version,
/// evaluate, repl, script path — so `arturo -h script.art` shows the
/// help screen, while `arturo script.art -e "x"` evaluates `x`
/// (options may appear anywhere; `--` protects script arguments).
fn parse_matches(matches : @argparse.Matches) -> CliParseResult {
  let flags = matches.flags
  let values = matches.values
  let no_color = flag_on(flags, "no-color")
  let action = if flag_on(flags, "help") {
    ShowHelp
  } else if flag_on(flags, "version") {
    ShowVersion
  } else if first_value(values, "evaluate") is Some(code) {
    Evaluate(code~)
  } else if flag_on(flags, "repl") {
    Repl
  } else {
    match first_value(values, "path") {
      Some(path) =>
        RunFile(path~, script_args=values.get("script_args").unwrap_or([]))
      None => Repl
    }
  }
  Parsed({ action, no_color })
}

///|
/// Parse the user arguments (program name already removed). Parse
/// failures carry display-ready text from argparse.
fn parse_cli(args : ArrayView[String]) -> CliParseResult {
  let outcome = try cli_command().parse(argv=args) catch {
    err => CliFail(message=err.to_string())
  } noraise {
    m => parse_matches(m)
  }
  outcome
}
