///|
/// Whitebox tests for the CLI argument parsing (`cli.mbt`).

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
  debug_inspect(
    parse_cli(["-e"]),
    content=(
      #|CliFail(MissingValue(option="-e"))
    ),
  )
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
test "unknown option fails" {
  debug_inspect(
    parse_cli(["--bogus"]),
    content=(
      #|CliFail(UnknownOption(option="--bogus"))
    ),
  )
  debug_inspect(
    parse_cli(["-x", "script.art"]),
    content=(
      #|CliFail(UnknownOption(option="-x"))
    ),
  )
}

///|
test "a command flag wins over a later path" {
  debug_inspect(
    parse_cli(["-h", "script.art"]),
    content="Parsed({ action: ShowHelp, no_color: false })",
  )
}

///|
test "cli error messages" {
  inspect(
    cli_error_message(UnknownOption(option="--bogus")),
    content="Unrecognized command-line option: --bogus",
  )
  inspect(
    cli_error_message(MissingValue(option="-e")),
    content="Not enough parameters for -e - consult the help screen below",
  )
}
