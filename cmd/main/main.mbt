///|
/// The Arturo CLI — a MoonBit port of the reference `src/arturo.nim`
/// main loop, driving the Arturo EDSL (`@arturo.run_with`) from the
/// command line.
///
/// ```
/// arturo [options] <path>        run a script file
/// arturo -e, --evaluate <code>   evaluate a code string
/// arturo -r, --repl              interactive console
/// arturo -h, --help              show help
/// arturo -v, --version           show version
/// ```
///
/// Run with: `moon run cmd/main -- [options] <path>` (native target).

///|
async fn main {
  let argv = @env.args()
  // native argv includes the program name as its first element
  let args = if !argv.is_empty() { argv[1:].to_owned() } else { [] }
  match parse_cli(args[:]) {
    CliFail(message~) => {
      @stdio.stderr.write(message + "\n")
      @sys.exit(1)
    }
    Parsed(options) =>
      match options.action {
        ShowHelp => println(cli_help_text())
        ShowVersion => println(version_text())
        Repl => repl(options.no_color)
        Evaluate(code~) => run_and_report(code, [], None)
        RunFile(path~, script_args~) =>
          run_and_report_from_file(path, script_args)
      }
  }
}

///|
/// Run source (from `-e` or a script) and handle the outcome: print
/// the captured output, or report the error to stderr and exit with a
/// non-zero status.
async fn run_and_report(
  source : String,
  script_args : Array[String],
  path : String?,
) -> Unit {
  match run_source_outcome(source, script_args, path) {
    Ran(result~) => @stdio.stdout.write(result.output)
    Failed(message~) => {
      @stdio.stderr.write(message + "\n")
      @sys.exit(1)
    }
  }
}

///|
async fn run_and_report_from_file(
  path : String,
  script_args : Array[String],
) -> Unit {
  let outcome = try run_script_file(path, script_args) catch {
    err => Failed(message=render_cli_error(err, Some(path)))
  } noraise {
    r => Ran(result=r)
  }
  match outcome {
    Ran(result~) => @stdio.stdout.write(result.output)
    Failed(message~) => {
      @stdio.stderr.write(message + "\n")
      @sys.exit(1)
    }
  }
}
