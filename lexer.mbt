///|
/// The Arturo lexer/parser — a MoonBit port of `src/vm/parse.nim`.
///
/// Parsing turns source text into a `:block` of raw `Value` tokens:
/// constants, words, labels, attributes, symbols, nested blocks,
/// dictionaries (`#[...]` is a `#` symbol followed by a block) and
/// inline blocks (`(...)`). Evaluation happens later, in `eval.mbt`.

///|
/// Error type raised by both parsing and evaluation.
pub(all) suberror ArturoError {
  ParseError(line~ : Int, message~ : String)
  RuntimeError(line~ : Int, message~ : String)
  // internal control-flow signals (caught by loops / function calls)
  BreakSignal
  ContinueSignal
  ReturnSignal(Value)
}

///|
priv struct Parser {
  src : String
  mut pos : Int
  mut line : Int
}

///|
fn parser_new(src : String) -> Parser {
  { src, pos: 0, line: 1 }
}

///|
fn eof_char() -> Char {
  '\u{0}'
}

///|
fn is_eof_char(c : Char) -> Bool {
  c.to_int() == 0
}

///|
fn peek(p : Parser, off : Int) -> Char {
  let i = p.pos + off
  if i < p.src.length() {
    p.src[i].unsafe_to_char()
  } else {
    eof_char()
  }
}

///|
fn advance(p : Parser) -> Unit {
  let c = peek(p, 0)
  p.pos += 1
  if c == '\n' {
    p.line += 1
  }
}

///|
/// Remove the common leading whitespace of all non-empty lines
/// (mirrors Nim's `dedent`), then trim.
fn dedent_str(s : String) -> String {
  let lines : Array[String] = []
  let mut current = StringBuilder()
  for c in s {
    if c == '\n' {
      lines.push(current.to_string())
      current = StringBuilder()
    } else {
      current.write_char(c)
    }
  }
  lines.push(current.to_string())
  let common = lines
    .iter()
    .filter(line => line.trim().length() > 0)
    .map(line => {
      line.find_by(c => c != ' ' && c != '\t').unwrap_or(line.length())
    })
    .minimum()
  let out = StringBuilder()
  for line in lines {
    let start = if common is Some(c) { c.min(line.length()) } else { 0 }
    out.write_stringview(line[start:])
    out.write_string("\n")
  }
  out.to_string().trim().to_owned()
}

///|
/// Skip whitespace, `;`-comments and `#!` shebang lines.
fn skip(p : Parser) -> Unit {
  while true {
    match peek(p, 0) {
      ' ' | '\t' | '\r' | '\n' => advance(p)
      ';' => {
        if peek(p, 1) == ';' {
          advance(p)
        }
        advance(p)
        while !is_eof_char(peek(p, 0)) && peek(p, 0) != '\n' {
          advance(p)
        }
      }
      '#' if peek(p, 1) == '!' => {
        advance(p)
        advance(p)
        while !is_eof_char(peek(p, 0)) && peek(p, 0) != '\n' {
          advance(p)
        }
      }
      _ => break
    }
  }
}

///|
/// Parse a `"..."` string. Handles the usual escapes plus `|...|`
/// interpolation markers (kept verbatim; `render` interprets them later).
fn parse_string(p : Parser, stopper : Char) -> String raise ArturoError {
  let sb = StringBuilder()
  advance(p) // opening quote
  let initial_line = p.line
  let mut in_code = false
  let mut done = false
  while !done {
    let c = peek(p, 0)
    if is_eof_char(c) {
      p.line = initial_line
      raise ArturoError::ParseError(line=p.line, message="unterminated string")
    } else if c == stopper {
      advance(p)
      done = true
    } else if c == '|' {
      sb.write_string("|")
      advance(p)
      in_code = !in_code
    } else if c == '\\' && !in_code {
      let e = peek(p, 1)
      match e {
        '\\' | '"' | '\'' | '/' => {
          sb.write_char(e)
          advance(p)
          advance(p)
        }
        'a' => {
          sb.write_char('\u{7}')
          advance(p)
          advance(p)
        }
        'b' => {
          sb.write_char('\b')
          advance(p)
          advance(p)
        }
        'e' => {
          sb.write_char('\u{1b}')
          advance(p)
          advance(p)
        }
        'f' => {
          sb.write_char('\f')
          advance(p)
          advance(p)
        }
        'n' | 'l' => {
          sb.write_string("\n")
          advance(p)
          advance(p)
        }
        'r' | 'c' => {
          sb.write_string("\r")
          advance(p)
          advance(p)
        }
        't' => {
          sb.write_string("\t")
          advance(p)
          advance(p)
        }
        'v' => {
          sb.write_char('\u{b}')
          advance(p)
          advance(p)
        }
        'x' => {
          advance(p)
          advance(p)
          let mut xi = 0
          let mut count = 0
          while count < 2 {
            let h = peek(p, 0)
            if h >= '0' && h <= '9' {
              xi = xi * 16 + (h.to_int() - '0')
            } else if h >= 'a' && h <= 'f' {
              xi = xi * 16 + (h.to_int() - 'a' + 10)
            } else if h >= 'A' && h <= 'F' {
              xi = xi * 16 + (h.to_int() - 'A' + 10)
            } else {
              break
            }
            advance(p)
            count += 1
          }
          sb.write_char(xi.unsafe_to_char())
        }
        _ => {
          sb.write_string("\\")
          sb.write_char(e)
          advance(p)
          advance(p)
        }
      }
    } else if "\n\r".contains_char(c) {
      p.line = initial_line
      raise ArturoError::ParseError(
        line=p.line,
        message="newline in quoted string",
      )
    } else {
      sb.write_char(c)
      advance(p)
    }
  }
  sb.to_string()
}

///|
/// --- multiline string: everything until end of input.
fn parse_multiline_string(p : Parser) -> String {
  let sb = StringBuilder()
  while peek(p, 0) == '-' {
    advance(p)
  }
  while !is_eof_char(peek(p, 0)) {
    sb.write_char(peek(p, 0))
    advance(p)
  }
  dedent_str(sb.to_string())
}

///|
/// `{...}` curly string / `{:...}` verbatim string.
/// (The regex form `{/.../}` is parsed as a plain string in this subset.)
fn parse_curly_string(p : Parser) -> String raise ArturoError {
  let sb = StringBuilder()
  advance(p) // '{'
  let verbatim = match peek(p, 0) {
    ':' => {
      advance(p)
      true
    }
    '!' => {
      // tag: {!md ...} — skip the tag letters
      advance(p)
      while is_ident_start(peek(p, 0)) {
        advance(p)
      }
      false
    }
    _ => false
  }
  let initial_line = p.line
  let mut curlies = 1
  while true {
    let c = peek(p, 0)
    if is_eof_char(c) {
      p.line = initial_line
      raise ArturoError::ParseError(
        line=p.line,
        message="unterminated curly string",
      )
    } else if c == '{' {
      curlies += 1
      sb.write_char(c)
      advance(p)
    } else if c == '}' {
      if verbatim {
        sb.write_char(c)
        advance(p)
      } else if curlies == 1 {
        advance(p)
        break
      } else {
        curlies -= 1
        sb.write_char(c)
        advance(p)
      }
    } else if c == ':' && verbatim && peek(p, 1) == '}' {
      // verbatim strings end with :}
      advance(p)
      advance(p)
      break
    } else {
      sb.write_char(c)
      advance(p)
    }
  }
  if verbatim {
    sb.to_string()
  } else {
    dedent_str(sb.to_string())
  }
}

///|
/// «...» full-line / safe string.
fn parse_guillemet_string(p : Parser) -> String raise ArturoError {
  let sb = StringBuilder()
  advance(p) // «
  if peek(p, 0) == '«' {
    // safe string: read until »»
    advance(p)
    let initial_line = p.line
    while true {
      let c = peek(p, 0)
      if is_eof_char(c) {
        p.line = initial_line
        raise ArturoError::ParseError(
          line=p.line,
          message="unterminated string",
        )
      } else if c == '»' {
        advance(p)
        if peek(p, 0) == '»' {
          advance(p)
          break
        } else {
          sb.write_string("»")
        }
      } else {
        sb.write_char(c)
        advance(p)
      }
    }
    sb.to_string()
  } else {
    // full-line string
    while !is_eof_char(peek(p, 0)) && peek(p, 0) != '\n' {
      sb.write_char(peek(p, 0))
      advance(p)
    }
    sb.to_string().trim().to_owned()
  }
}

///|
fn is_ident_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
fn is_ident_char(c : Char) -> Bool {
  is_ident_start(c) || (c >= '0' && c <= '9')
}

///|
/// Parse an identifier; a trailing single `?` is part of the
/// identifier. The first character is always skipped: with
/// `add_current` it is included in the result (words), otherwise it is
/// the leading marker (`'` literal, `:` type, `.` attribute).
fn parse_identifier(p : Parser, add_current : Bool) -> String {
  let sb = StringBuilder()
  if add_current {
    sb.write_char(peek(p, 0))
  }
  advance(p)
  let initial = p.pos
  while is_ident_char(peek(p, 0)) {
    sb.write_char(peek(p, 0))
    advance(p)
  }
  if peek(p, 0) == '?' && p.pos != initial {
    sb.write_string("?")
    advance(p)
  }
  sb.to_string()
}

///|
/// Parse a number literal: decimal/hex/octal/binary integers,
/// floating point (with or without scientific notation).
fn parse_number(p : Parser) -> Value raise ArturoError {
  let sb = StringBuilder()
  let (num_base, already) = if peek(p, 0) == '0' {
    match peek(p, 1) {
      'x' | 'X' => {
        sb.write_string("0x")
        advance(p)
        advance(p)
        (16, true)
      }
      'b' | 'B' => {
        sb.write_string("0b")
        advance(p)
        advance(p)
        (2, true)
      }
      'o' | 'O' => {
        sb.write_string("0o")
        advance(p)
        advance(p)
        (8, true)
      }
      _ => (10, false)
    }
  } else {
    (10, false)
  }
  if already {
    let mut count = 0
    while (
            num_base == 16 &&
            (
              (peek(p, 0) >= '0' && peek(p, 0) <= '9') ||
              (peek(p, 0) >= 'a' && peek(p, 0) <= 'f') ||
              (peek(p, 0) >= 'A' && peek(p, 0) <= 'F')
            )
          ) ||
          (num_base == 2 && "01".contains_char(peek(p, 0))) ||
          (num_base == 8 && peek(p, 0) >= '0' && peek(p, 0) <= '7') {
      sb.write_char(peek(p, 0))
      advance(p)
      count += 1
    }
    if count == 0 {
      raise ArturoError::ParseError(
        line=p.line,
        message="invalid number literal",
      )
    }
    let text = sb.to_string()
    let digits = text[2:]
    let value = @string.parse_int(digits, base=num_base) catch {
      _ =>
        raise ArturoError::ParseError(
          line=p.line,
          message="invalid number literal",
        )
    }
    return VInteger(value)
  }
  // decimal
  let mut dots = 0
  while peek(p, 0) >= '0' && peek(p, 0) <= '9' {
    sb.write_char(peek(p, 0))
    advance(p)
  }
  if peek(p, 0) == '.' && peek(p, 1) >= '0' && peek(p, 1) <= '9' {
    dots += 1
    sb.write_string(".")
    advance(p)
    while peek(p, 0) >= '0' && peek(p, 0) <= '9' {
      sb.write_char(peek(p, 0))
      advance(p)
    }
    if peek(p, 0) == '.' && peek(p, 1) >= '0' && peek(p, 1) <= '9' {
      dots += 1
      sb.write_string(".")
      advance(p)
      while peek(p, 0) >= '0' && peek(p, 0) <= '9' {
        sb.write_char(peek(p, 0))
        advance(p)
      }
    }
  }
  let text = sb.to_string()
  if dots > 1 {
    // version literal — represented as a string in this subset
    return VString(text)
  }
  // scientific notation
  if "eE".contains_char(peek(p, 0)) &&
    (
      (peek(p, 1) >= '0' && peek(p, 1) <= '9') ||
      ("+-".contains_char(peek(p, 1)) && peek(p, 2) >= '0' && peek(p, 2) <= '9')
    ) {
    sb.write_string("e")
    advance(p)
    if "+-".contains_char(peek(p, 0)) {
      sb.write_char(peek(p, 0))
      advance(p)
    }
    while peek(p, 0) >= '0' && peek(p, 0) <= '9' {
      sb.write_char(peek(p, 0))
      advance(p)
    }
    let ftext = sb.to_string()
    let fval = @string.parse_double(ftext) catch {
      _ =>
        raise ArturoError::ParseError(
          line=p.line,
          message="invalid number literal",
        )
    }
    return VFloating(fval)
  }
  if dots > 0 {
    let fval = @string.parse_double(text) catch {
      _ =>
        raise ArturoError::ParseError(
          line=p.line,
          message="invalid number literal",
        )
    }
    return VFloating(fval)
  }
  if text == "" {
    raise ArturoError::ParseError(line=p.line, message="invalid number literal")
  }
  let ival = @string.parse_int(text) catch {
    _ =>
      raise ArturoError::ParseError(
        line=p.line,
        message="invalid number literal",
      )
  }
  VInteger(ival)
}

///|
/// Parse an operator symbol: read the whole run of symbol characters.
/// Any combination is accepted; evaluation decides what it means
/// (`alias_lookup` in eval.mbt, unknown symbols stay symbols).
fn parse_symbol(p : Parser) -> String {
  let c = peek(p, 0)
  if c == '#' && is_ident_char(peek(p, 1)) {
    // color literal — not supported in this subset
    advance(p)
    while is_ident_char(peek(p, 0)) {
      advance(p)
    }
    return "#color"
  }
  let start = p.pos
  while "+*/%^=<>!?~|&@#$-\\:".contains_char(peek(p, 0)) {
    advance(p)
  }
  let run = p.src[start:p.pos].to_owned()
  // ASCII rendering of the logical-and symbol (the reference spells it `/\`)
  if run == "/\\" {
    "∧"
  } else {
    run
  }
}

///|
/// Parse a backslash path: `a\b`, `a\0`, `\key`, `a\[block]`.
fn parse_path(p : Parser, root : Value) -> Array[Value] raise ArturoError {
  let parts : Array[Value] = [root]
  while peek(p, 0) == '\\' {
    advance(p)
    if is_ident_start(peek(p, 0)) {
      parts.push(VLiteral(parse_identifier(p, true)))
    } else if peek(p, 0) >= '0' && peek(p, 0) <= '9' {
      parts.push(parse_number(p))
    } else if peek(p, 0) == '[' {
      advance(p)
      parts.push(VBlock(parse_block(p, 0, true, false)))
    } else {
      break
    }
  }
  parts
}

///|
fn parse_block(
  p : Parser,
  level : Int,
  is_sub_block : Bool,
  is_sub_inline : Bool,
) -> Array[Value] raise ArturoError {
  let out : Array[Value] = []
  let initial_line = p.line
  while true {
    skip(p)
    let c = peek(p, 0)
    if is_eof_char(c) {
      if level != 0 {
        p.line = initial_line
        if is_sub_block {
          raise ArturoError::ParseError(
            line=p.line,
            message="missing closing `]`",
          )
        } else {
          raise ArturoError::ParseError(
            line=p.line,
            message="missing closing `)`",
          )
        }
      }
      break
    } else if c == '"' {
      let s = parse_string(p, '"')
      if peek(p, 0) == ':' {
        advance(p)
        out.push(VLabel(s))
      } else {
        out.push(VString(s))
      }
    } else if c == '\'' {
      // literal, char or symbol-literal
      let id = parse_identifier(p, false)
      if id == "" {
        if peek(p, 0) == '\\' {
          // '\n style char escapes
          advance(p)
          let e = peek(p, 0)
          let ch = match e {
            'n' => '\n'
            'r' => '\r'
            't' => '\t'
            'b' => '\b'
            'f' => '\f'
            'v' => '\u{b}'
            'a' => '\u{7}'
            'e' => '\u{1b}'
            _ => e
          }
          advance(p)
          if peek(p, 0) == '\'' {
            advance(p)
          }
          out.push(VChar(ch))
        } else {
          // symbol literal: '+' etc.
          out.push(VLiteral(parse_symbol(p)))
        }
      } else if peek(p, 0) == '\\' {
        out.push(VPath(parse_path(p, VLiteral(id))))
      } else if peek(p, 0) == '\'' {
        // char: 'a'
        advance(p)
        out.push(
          VChar(
            if id.length() > 0 {
              Int::unsafe_to_char(id[0].to_int())
            } else {
              '\u{0}'
            },
          ),
        )
      } else {
        out.push(VLiteral(id))
      }
    } else if c >= '0' && c <= '9' {
      let num = parse_number(p)
      if peek(p, 0) == ':' {
        raise ArturoError::ParseError(
          line=p.line,
          message="rational literals are not supported in this subset",
        )
      }
      out.push(num)
    } else if c == ':' {
      let id = parse_identifier(p, false)
      if id == "" {
        if peek(p, 0) == ':' {
          advance(p)
          out.push(VSymbol("::"))
        } else if peek(p, 0) == '=' {
          advance(p)
          out.push(VSymbol(":="))
        } else {
          advance(p)
          out.push(VSymbol(":"))
        }
      } else {
        out.push(VType(id))
      }
    } else if c == '.' {
      if peek(p, 1) == '.' {
        advance(p)
        advance(p)
        if peek(p, 0) == '.' {
          advance(p)
          out.push(VSymbol("..."))
        } else {
          out.push(VSymbol(".."))
        }
      } else if peek(p, 1) == '/' {
        advance(p)
        advance(p)
        out.push(VSymbol("./"))
      } else {
        let id = parse_identifier(p, false)
        if peek(p, 0) == ':' {
          advance(p)
          out.push(VAttributeLabel(id))
        } else {
          out.push(VAttribute(id))
        }
      }
    } else if is_ident_start(c) {
      let id = parse_identifier(p, true)
      if id == "_" {
        out.push(VSymbol("_"))
      } else if peek(p, 0) == ':' {
        advance(p)
        out.push(VLabel(id))
      } else if peek(p, 0) == '\\' {
        let path = parse_path(p, VWord(id))
        if peek(p, 0) == ':' {
          // path label: `d\key: value` stores through the path
          advance(p)
          out.push(VPathLabel(path))
        } else {
          out.push(VPath(path))
        }
      } else {
        out.push(VWord(id))
      }
    } else if c == '\\' {
      if is_ident_start(peek(p, 1)) || peek(p, 1) == '[' {
        let path = parse_path(p, VWord("this"))
        if peek(p, 0) == ':' {
          advance(p)
          out.push(VLabel(path.map(Show::to_string).join("\\")))
        } else {
          out.push(VPath(path))
        }
      } else if peek(p, 1) == '\\' {
        advance(p)
        advance(p)
        out.push(VSymbol("\\\\"))
      } else if peek(p, 1) == '/' {
        advance(p)
        advance(p)
        out.push(VSymbol("∨"))
      } else {
        advance(p)
        out.push(VSymbol("\\"))
      }
    } else if c == '[' {
      advance(p)
      out.push(VBlock(parse_block(p, level + 1, true, false)))
    } else if c == ']' {
      if is_sub_block {
        advance(p)
        break
      } else if is_sub_inline {
        p.line = initial_line
        raise ArturoError::ParseError(
          line=p.line,
          message="missing closing `)`",
        )
      } else {
        raise ArturoError::ParseError(line=p.line, message="stray `]`")
      }
    } else if c == '(' {
      advance(p)
      out.push(VInline(parse_block(p, level + 1, false, true)))
    } else if c == ')' {
      if is_sub_inline {
        advance(p)
        break
      } else if is_sub_block {
        p.line = initial_line
        raise ArturoError::ParseError(
          line=p.line,
          message="missing closing `]`",
        )
      } else {
        raise ArturoError::ParseError(line=p.line, message="stray `)`")
      }
    } else if c == '{' {
      let s = parse_curly_string(p)
      if peek(p, 0) == ':' {
        advance(p)
        out.push(VLabel(s))
      } else {
        out.push(VString(s))
      }
    } else if c == '}' {
      raise ArturoError::ParseError(line=p.line, message="stray `}`")
    } else if c == '«' {
      out.push(VString(parse_guillemet_string(p)))
    } else if "ø∅".contains_char(c) {
      advance(p)
      out.push(VSymbol("∅"))
    } else if c == '∞' {
      advance(p)
      out.push(VSymbol("∞"))
    } else if c == '∧' {
      advance(p)
      out.push(VSymbol("∧"))
    } else if c == '∨' {
      advance(p)
      out.push(VSymbol("∨"))
    } else if c == '⊻' {
      advance(p)
      out.push(VSymbol("⊻"))
    } else if c == '¬' {
      advance(p)
      out.push(VSymbol("¬"))
    } else if c == '∈' {
      advance(p)
      out.push(VSymbol("∈"))
    } else if c == '∑' {
      advance(p)
      out.push(VSymbol("∑"))
    } else if c == '∏' {
      advance(p)
      out.push(VSymbol("∏"))
    } else if c == '-' && peek(p, 1) == '-' && peek(p, 2) == '-' {
      // multiline string
      advance(p)
      out.push(VString(parse_multiline_string(p)))
    } else if "+*/%^=<>!?~|&@#$-".contains_char(c) {
      out.push(VSymbol(parse_symbol(p)))
    } else {
      // unknown character: skip it
      advance(p)
    }
  }
  out
}

///|
/// Parse Arturo source code into a block of raw values.
pub fn parse(source : String) -> Value raise ArturoError {
  let p = parser_new(source)
  VBlock(parse_block(p, 0, false, false))
}
