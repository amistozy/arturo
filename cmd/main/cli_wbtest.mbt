///|
/// Whitebox tests for the CLI argument parsing (`cli.mbt`), which
/// declares the command spec with `moonbitlang/core/argparse`.

///|
test "no arguments means repl" {
  debug_inspect(
    parse_cli([]),
    content="Parsed({ action: Repl, no_color: false })",
  )
}

///|
test "script path with no script args" {
  debug_inspect(
    parse_cli(["script.art"]),
    content=(
      #|Parsed(
      #|  {
      #|    action: RunFile(path="script.art", script_args=[]),
      #|    no_color: false,
      #|  },
      #|)
    ),
  )
}

///|
test "everything after the script path is passed to the script" {
  debug_inspect(
    parse_cli(["script.art", "a", "b"]),
    content=(
      #|Parsed(
      #|  {
      #|    action: RunFile(path="script.art", script_args=["a", "b"]),
      #|    no_color: false,
      #|  },
      #|)
    ),
  )
}

///|
test "unknown hyphen tokens after the path become script args" {
  debug_inspect(
    parse_cli(["script.art", "--verbose"]),
    content=(
      #|Parsed(
      #|  {
      #|    action: RunFile(path="script.art", script_args=["--verbose"]),
      #|    no_color: false,
      #|  },
      #|)
    ),
  )
}

///|
test "declared options are parsed even after the script path" {
  debug_inspect(
    parse_cli(["script.art", "--no-color"]),
    content="Parsed({ action: RunFile(path=\"script.art\", script_args=[]), no_color: true })",
  )
}

///|
test "options before the script path" {
  debug_inspect(
    parse_cli(["--no-color", "script.art", "-x"]),
    content=(
      #|Parsed(
      #|  {
      #|    action: RunFile(path="script.art", script_args=["-x"]),
      #|    no_color: true,
      #|  },
      #|)
    ),
  )
}

///|
test "double dash ends option parsing" {
  debug_inspect(
    parse_cli(["--", "-weird.art"]),
    content=(
      #|Parsed(
      #|  {
      #|    action: RunFile(path="-weird.art", script_args=[]),
      #|    no_color: false,
      #|  },
      #|)
    ),
  )
}

///|
test "evaluate consumes the next argument" {
  debug_inspect(
    parse_cli(["-e", "print 1"]),
    content=(
      #|Parsed({ action: Evaluate(code="print 1"), no_color: false })
    ),
  )
}

///|
test "evaluate long form with no-color" {
  debug_inspect(
    parse_cli(["--evaluate", "1 + 2", "--no-color"]),
    content=(
      #|Parsed({ action: Evaluate(code="1 + 2"), no_color: true })
    ),
  )
}

///|
test "evaluate accepts hyphen values" {
  debug_inspect(
    parse_cli(["-e", "-1"]),
    content=(
      #|Parsed({ action: Evaluate(code="-1"), no_color: false })
    ),
  )
}

///|
test "positionals after evaluate are ignored" {
  debug_inspect(
    parse_cli(["-e", "print 1", "extra"]),
    content=(
      #|Parsed({ action: Evaluate(code="print 1"), no_color: false })
    ),
  )
}

///|
test "evaluate without a value fails" {
  match parse_cli(["-e"]) {
    CliFail(message~) =>
      assert_true(
        message.contains(
          "error: a value is required for '-e' but none was supplied",
        ),
      )
    Parsed(_) => fail("expected failure")
  }
}

///|
test "help, version and repl flags" {
  debug_inspect(
    parse_cli(["-h"]),
    content="Parsed({ action: ShowHelp, no_color: false })",
  )
  debug_inspect(
    parse_cli(["--help"]),
    content="Parsed({ action: ShowHelp, no_color: false })",
  )
  debug_inspect(
    parse_cli(["-v"]),
    content="Parsed({ action: ShowVersion, no_color: false })",
  )
  debug_inspect(
    parse_cli(["-r"]),
    content="Parsed({ action: Repl, no_color: false })",
  )
}

///|
test "help wins over version and path" {
  debug_inspect(
    parse_cli(["-v", "-h"]),
    content="Parsed({ action: ShowHelp, no_color: false })",
  )
  debug_inspect(
    parse_cli(["-h", "script.art"]),
    content="Parsed({ action: ShowHelp, no_color: false })",
  )
}

///|
test "unknown option fails with a display-ready message" {
  match parse_cli(["--bogus"]) {
    CliFail(message~) => {
      assert_true(
        message.contains("error: unexpected argument '--bogus' found"),
      )
      assert_true(message.contains("Usage:"))
    }
    Parsed(_) => fail("expected failure")
  }
  match parse_cli(["-x", "script.art"]) {
    CliFail(message~) =>
      assert_true(message.contains("error: unexpected argument '-x' found"))
    Parsed(_) => fail("expected failure")
  }
}

///|
test "help screen is rendered from the command spec" {
  let h = cli_help_text()
  assert_true(h.contains("Usage: arturo"))
  assert_true(h.contains("-e, --evaluate"))
  assert_true(h.contains("-r, --repl"))
  assert_true(h.contains("-h, --help"))
  assert_true(h.contains("-v, --version"))
  assert_true(h.contains("--no-color"))
  assert_true(h.contains("path"))
  assert_true(h.contains("script_args"))
}
