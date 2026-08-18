///|
/// Running Arturo source through the EDSL (`@arturo.run_with`) from
/// the CLI: script files, `-e` code strings, and error rendering.

///|
/// Environment for running source: the standard seed plus `args`, a
/// block of strings with the script arguments (like the reference
/// VM's `sys\args`).
fn env_with_args(args : Array[String]) -> @arturo.Env {
  let env = @arturo.Env()
  env.set_symbol("args", @arturo.Value::block(args.map(@arturo.Value::string)))
  env
}

///|
/// Run Arturo source with the given script arguments, returning the
/// captured `print` output and the final value.
fn run_source(
  source : String,
  script_args : Array[String],
) -> @arturo.RunResult raise @arturo.ArturoError {
  @arturo.run_with(env_with_args(script_args), source)
}

///|
/// Read a script file and run it.
fn run_script_file(
  path : String,
  script_args : Array[String],
) -> @arturo.RunResult raise {
  let source = @fs.read_file_to_string(path)
  run_source(source, script_args)
}

///|
/// The outcome of running source in the CLI: the result, or a
/// rendered failure message.
enum RunOutcome {
  Ran(result~ : @arturo.RunResult)
  Failed(message~ : String)
}

///|
/// Run source, catching EDSL and I/O errors. `path` is only used to
/// produce the reference's "script doesn't exist" message when the
/// error is an I/O error.
fn run_source_outcome(
  source : String,
  script_args : Array[String],
  path : String?,
) -> RunOutcome {
  try run_source(source, script_args) catch {
    err => Failed(message=render_cli_error(err, path))
  } noraise {
    r => Ran(result=r)
  }
}

///|
/// Render an error that escaped to the CLI level.
///
/// Parse and runtime errors carry their source line; I/O errors (a
/// missing or unreadable script) get the reference's
/// `Error_ScriptNotExists`-style message when a path is known.
fn render_cli_error(err : Error, path : String?) -> String {
  match err {
    @fs.IOError(_) =>
      match path {
        Some(p) => "Given script doesn't exist:\n    \{p}"
        None => "[I/O ERROR]"
      }
    @arturo.ArturoError::ParseError(line~, message~) =>
      "[PARSE ERROR] line \{line}: \{message}"
    @arturo.ArturoError::RuntimeError(line~, message~) =>
      "[RUNTIME ERROR] line \{line}: \{message}"
    // BreakSignal / ContinueSignal / ReturnSignal should never
    // escape to the top level
    _ => "[INTERNAL ERROR] unexpected control-flow signal"
  }
}
