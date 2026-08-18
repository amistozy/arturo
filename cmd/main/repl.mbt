///|
/// The interactive console — a minimal MoonBit port of the reference
/// `src/scripts/console.art`: a persistent environment across inputs,
/// `$>` prompt with `.. ` continuation for lines ending in a space,
/// and the last non-null value echoed as `=> value`.

///|
/// The echo for the last value of an input: `=> value`, or nothing
/// for `null` (like the reference's `unless null? Got -> print ...`).
fn value_echo(v : @arturo.Value) -> String? {
  match v {
    VNull => None
    _ => Some("=> \{v}")
  }
}

///|
/// Multi-line input: a line ending with a space asks for more
/// (reference: `while [suffix? inp " "]`).
fn needs_continuation(line : String) -> Bool {
  line.has_suffix(" ")
}

///|
/// Wrap `s` in the ANSI color `code` unless colors are muted.
fn colored(code : String, s : String, no_color : Bool) -> String {
  if no_color {
    s
  } else {
    "\u001b[\{code}m\{s}\u001b[0m"
  }
}

///|
/// Evaluate one input in the persistent REPL environment and react:
/// print the captured output, echo the last non-null value, or print
/// the rendered error.
async fn repl_step(env : @arturo.Env, source : String, no_color : Bool) -> Unit {
  let outcome = try @arturo.run_with(env, source) catch {
    err => Failed(message=render_cli_error(err, None))
  } noraise {
    r => Ran(result=r)
  }
  match outcome {
    Failed(message~) =>
      @stdio.stdout.write(colored("91", message, no_color) + "\n\n")
    Ran(result~) => {
      @stdio.stdout.write(result.output)
      match value_echo(result.value) {
        Some(echo) => @stdio.stdout.write(colored("90", echo, no_color) + "\n")
        None => ()
      }
      @stdio.stdout.write("\n")
    }
  }
}

///|
/// The REPL loop: read a line, evaluate it in the shared environment,
/// and repeat. A line ending with a space continues on the next
/// (`.. `) line; EOF (Ctrl-D / Ctrl-Z) exits.
async fn repl(no_color : Bool) -> Unit {
  // keep every stdout write on the same (async) path so output stays
  // ordered even when stdout is a pipe
  @stdio.stdout.write(version_text() + "\n")
  let env = env_with_args([])
  let mut done = false
  while !done {
    @stdio.stdout.write("$> ")
    match @stdio.stdin.read_until("\n") {
      None => done = true
      Some(first) => {
        let source = StringBuilder()
        source.write_string(first)
        let mut last = first
        while needs_continuation(last) {
          @stdio.stdout.write(".. ")
          match @stdio.stdin.read_until("\n") {
            None => {
              done = true
              last = ""
            }
            Some(more) => {
              source.write_string("\n")
              source.write_string(more)
              last = more
            }
          }
        }
        if !source.is_empty() {
          repl_step(env, source.to_string(), no_color)
        }
      }
    }
  }
  println("")
}
