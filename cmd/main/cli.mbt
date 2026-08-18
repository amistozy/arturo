///|
/// Command-line parsing for the Arturo CLI, mirroring the option loop
/// of the reference `src/arturo.nim`:
///
/// - `-e, --evaluate <code>` runs a code string,
/// - `-r, --repl` starts the interactive console,
/// - `-h, --help` and `-v, --version` print the help/version screens,
/// - `--no-color` mutes colors,
/// - the first non-option argument is the script path; everything
///   after it is passed to the script (as the `args` symbol).
///
/// With no command and no path, the REPL starts (like the reference).
/// `--` ends option parsing.

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
/// A problem with the command line itself (as opposed to a problem in
/// the code being run).
enum CliError {
  UnknownOption(option~ : String)
  MissingValue(option~ : String)
} derive(Debug)

///|
enum CliParseResult {
  Parsed(CliOptions)
  CliFail(CliError)
} derive(Debug)

///|
/// An option-looking token: starts with `-` and is longer than a
/// single dash (a lone `-` is treated as a positional, like the
/// reference's parseopt).
fn is_option(arg : String) -> Bool {
  arg.length() > 1 && arg[0] == '-'
}

///|
/// Parse the user arguments (program name already removed).
fn parse_cli(args : ArrayView[String]) -> CliParseResult {
  let mut action : CliAction? = None
  let mut no_color = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--" {
      // end of options: the next argument is the script path
      if i + 1 < args.length() && action is None {
        return Parsed({
          action: RunFile(path=args[i + 1], script_args=args[i + 2:].to_owned()),
          no_color,
        })
      }
      break
    } else if arg == "-h" || arg == "--help" {
      action = Some(ShowHelp)
    } else if arg == "-v" || arg == "--version" {
      action = Some(ShowVersion)
    } else if arg == "-r" || arg == "--repl" {
      action = Some(Repl)
    } else if arg == "-e" || arg == "--evaluate" {
      if i + 1 >= args.length() {
        return CliFail(MissingValue(option=arg))
      }
      action = Some(Evaluate(code=args[i + 1]))
      i = i + 1
    } else if arg == "--no-color" {
      no_color = true
    } else if is_option(arg) {
      return CliFail(UnknownOption(option=arg))
    } else if action is None {
      // first positional argument: the script path; the rest is
      // passed to the script itself
      return Parsed({
        action: RunFile(path=arg, script_args=args[i + 1:].to_owned()),
        no_color,
      })
    }
    // a positional after a command is ignored, like the reference,
    // where the first positional only fills an empty code string
    i = i + 1
  }
  Parsed({ action: action.unwrap_or(Repl), no_color })
}

///|
/// The message for a bad command line, mirroring the reference's
/// command-line errors (`src/vm/errors.nim`).
fn cli_error_message(err : CliError) -> String {
  match err {
    UnknownOption(option~) => "Unrecognized command-line option: \{option}"
    MissingValue(option~) =>
      "Not enough parameters for \{option} - consult the help screen below"
  }
}
