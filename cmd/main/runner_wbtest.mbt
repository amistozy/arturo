///|
/// Whitebox tests for the runner and REPL helpers (`runner.mbt`,
/// `repl.mbt`, `help.mbt`).

///|
test "running source returns captured output and last value" {
  match run_source_outcome("print 1 + 2", [], None) {
    Ran(result~) => {
      inspect(result.output, content="3\n")
      inspect(
        result.value,
        content=(
          #|null
        ),
      )
    }
    Failed(message~) => fail("expected success, got: \{message}")
  }
}

///|
test "script arguments are visible as the args symbol" {
  match run_source_outcome("print args", ["a", "b"], None) {
    Ran(result~) => {
      inspect(
        result.output,
        content=(
          #|a b 
          #|
        ),
      )
      inspect(
        result.value,
        content=(
          #|null
        ),
      )
    }
    Failed(message~) => fail("expected success, got: \{message}")
  }
}

///|
test "runtime errors are rendered with the line number" {
  match run_source_outcome("print nope", [], None) {
    Failed(message~) =>
      inspect(
        message,
        content="[RUNTIME ERROR] line 1: cannot resolve requested value: nope",
      )
    Ran(result~) => fail("expected failure, got: \{result.output}")
  }
}

///|
test "parse errors are rendered with the line number" {
  match run_source_outcome("[\n1 2", [], None) {
    Failed(message~) =>
      inspect(
        message,
        content=(
          #|[PARSE ERROR] line 1: missing closing `]`
        ),
      )
    Ran(result~) => fail("expected failure, got: \{result.output}")
  }
}

///|
test "io errors are rendered like the reference script-not-exists error" {
  let err = @fs.IOError("cannot read")
  inspect(
    render_cli_error(err, Some("missing.art")),
    content="Given script doesn't exist:\n    missing.art",
  )
  inspect(render_cli_error(err, None), content="[I/O ERROR]")
}

///|
test "value echo skips null" {
  debug_inspect(value_echo(@arturo.null()), content="None")
  debug_inspect(value_echo(@arturo.integer(42)), content="Some(\"=> 42\")")
}

///|
test "repl continuation detection" {
  inspect(needs_continuation("print 1 "), content="true")
  inspect(needs_continuation("print 1"), content="false")
}

///|
test "help and version texts" {
  inspect(version_text(), content="arturo 0.1.0 (MoonBit port)")
  let h = help_text()
  assert_true(h.contains("Usage:"))
  assert_true(h.contains("-e, --evaluate"))
  assert_true(h.contains("-r, --repl"))
  assert_true(h.contains("--no-color"))
}

///|
test "colored wraps in ansi when colors are on" {
  inspect(colored("90", "=> 1", false), content="\u001b[90m=> 1\u001b[0m")
  inspect(colored("90", "=> 1", true), content="=> 1")
}
