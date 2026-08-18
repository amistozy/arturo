# amistozy/arturo

An embedded [Arturo](https://arturo-lang.io) EDSL for MoonBit: a MoonBit port of
the core of the Arturo language — values, lexer/parser, tree-walking
evaluator and a curated set of builtins — so you can run Arturo code from
within MoonBit programs.

The implementation is a faithful port of the reference interpreter
(`reference/arturo`, written in Nim): block evaluation, arity-based calls,
labels, attributes, pipes, arrow functions, ranges, dictionaries, scoping
with per-call undo frames, and `print`/`inspect` output that is captured
instead of written to the terminal.

## Quick start

```mbt check
///|
test {
  let src =
    #|x: 2
    #|print ~"x: |x|"
    #|1..5 | map 'x -> x * 2 | print
    #|
  let r = @arturo.run(src)
  inspect(r.output, content="x: 2\n2 4 6 8 10 \n")
}
```

- `run(source)` parses and evaluates the source in a fresh environment and
  returns a `RunResult` with the final value and the captured output.
- `run_with(env, source)` reuses an environment: symbols set beforehand are
  visible to the program, and top-level assignments survive afterwards.
- `parse(source)` returns the raw block of tokens (no evaluation).
- Values are represented by the `Value` type; helpers such as
  `integer`, `string`, `block`, `show_value` and `equal` are provided.

## The CLI

`cmd/main` ports the reference interpreter's command line
(`reference/arturo/src/arturo.nim`) on top of the EDSL:

```
arturo [options] <path>        run a script file
arturo -e, --evaluate <code>   evaluate a code string
arturo -r, --repl              interactive console
arturo -h, --help              show help
arturo -v, --version           show version
```

Arguments after the script path are available to the script as the `args`
symbol (a block of strings). With no command and no path, the REPL starts.
The REPL keeps one environment across inputs, echoes the last non-null value
as `=> value` (gray, unless `--no-color`), and continues multi-line input on
`.. ` when a line ends with a space. Parse/runtime errors are reported as
`[PARSE ERROR] line N: ...` / `[RUNTIME ERROR] line N: ...` and exit with
status 1.

The command line is declared with `moonbitlang/core/argparse` and the help
screen is rendered from that spec. Options may appear anywhere on the command
line; use `--` to pass option-looking arguments to the script itself
(e.g. `arturo script.art -- --flag`).

Run it from the project root (native target):

```
moon run cmd/main -- examples/hello.art alpha beta
moon run cmd/main -- -e "print 1 + 2"
moon run cmd/main -- -r
```

## What is supported

### Language core

- Values: `null`, logicals, integers, floating point, chars, strings,
  words, literals, labels, attributes, symbols, blocks, inline blocks,
  dictionaries, ranges, functions, types.
- Uniform evaluation: `print 1 + 2`, `x: 5`, `f: function [x][ x + 2 ]`,
  blocks as data, labels as stores.
- Operators: `+ - * / // % ^ = <> < > =< >=` and their word forms
  (`add`, `equal?`, ...), logical `and?`/`or?`/`not?`/`xor?`,
  `?`/`??`/`++`/`--`/`..` (ASCII symbols only).
- Control flow: `if`, `unless`, `switch`, `while`, `until`, `when`, `case`,
  `break`, `continue`, `return`, `do`, `ensure`.
- Functions: `function`/`$`, arrow bodies `x -> expr`, thick arrows
  `=> expr`, recursive calls, scoped parameters with undo on exit.
- Iterators: `loop`, `map`, `select`, `filter`, `fold`, `every?`, `some?`,
  with `.with: 'i` indices and literal/block parameter lists.
- Pipes: `1..10 | map 'x -> x * 2 | print`.
- Dictionaries: `#[key: value ...]`, path access `d\key`, `d\key: value`.
- Strings: `"..."`, `{...}` (dedented), `~"|expr|"` interpolation (via
  `render` or `~`).
- `inspect` produces the reference dump format (`[ :block ... ]`).

### Builtins (subset)

Arithmetic, comparison, logic, collections (`size`, `first`, `last`,
`append`, `prepend`, `pop`, `remove`, `insert`, `index`, `keys`, `values`,
`contains?`, `in?`, `empty?`, `one?`, `zero?`, `key?`, `range`, `array`,
`dictionary`, `repeat`, `reverse`, `flatten`, `sort`, `unique`, `take`,
`drop`, `slice`, `max`, `min`, `sum`, `product`), strings (`upper`,
`lower`, `capitalize`, `strip`, `join`, `split`, `pad`, `replace`), numbers
(`abs`, `floor`, `ceil`, `round`, `sqrt`, `exp`, `sign`, `even?`, `odd?`,
`prime?`, `positive?`, `negative?`, `infinite?`, `factorial`, `digits`,
`gcd`), types (`to`, `type`, `is?`, `integer?`, ...) and reflection
(`attr`, `attr?`, `var`, `set?`, `unset`, `new`, `call`, `parse`, ...).

## Compatibility with the reference implementation

`tests/unittests/`-style cases from the reference repository are ported in
`arturo_ported_test.mbt`: the original `.art` sources are executed and the
captured output is compared byte-for-byte with the reference `.res` files
(`branching`, `loops`, `parser`, `templates`, `strings`, plus core sections
of `lib.arithmetic`, `lib.collections` and `lib.iterators`).

Not supported (yet): quantities, colors, regexes, dates, complex numbers,
modules/objects, bytecode, threads and most I/O builtins.

## Design notes

The evaluator mirrors the reference VM:

- a block of values is evaluated statement by statement; words bound to
  functions consume their declared arity of following expressions;
- infix operators are right-associative (`a - b - c` is `a - (b - c)`),
  exactly like the reference AST builder;
- pipes are statement-level: `x | f` re-routes the previous value into the
  next call;
- `print` on a block evaluates it and joins the pushed values with spaces,
  matching the reference `print` behavior;
- function calls record an undo frame so parameters never leak;
- raising functions cannot be stored in MoonBit data structures, so
  builtins are dispatched by name in `invoke_builtin`.

## Layout

- `value.mbt` — the `Value` model, rendering and equality
- `lexer.mbt` — the parser (tokens → block of values)
- `eval.mbt` — the environment and the tree-walking evaluator
- `builtins_core.mbt`, `builtins_ops.mbt`, `builtins_data.mbt` — builtins
- `arturo.mbt` — public API: `run`, `run_with`, `parse`, `new_env`, ...
- `cmd/main/` — the CLI (`main.mbt`, `cli.mbt`, `runner.mbt`, `repl.mbt`,
  `help.mbt`)
