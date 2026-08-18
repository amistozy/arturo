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
  RuntimeError(message~ : String)
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
fn Parser::Parser(src : String) -> Parser {
  { src, pos: 0, line: 1 }
}

///|
fn eof_char() -> Char {
  '\u{0}'
}

///|
fn is_eof_char(c : Char) -> Bool {
  c == '\u{0}'
}

///|
fn Parser::peek(p : Parser, off : Int) -> Char {
  let i = p.pos + off
  if i < p.src.length() {
    p.src[i].unsafe_to_char()
  } else {
    eof_char()
  }
}

///|
fn Parser::advance(p : Parser) -> Unit {
  let c = p.peek(0)
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
    .filter(line => !line.trim().is_empty())
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
fn Parser::skip(p : Parser) -> Unit {
  while true {
    match p.peek(0) {
      ' ' | '\t' | '\r' | '\n' => p.advance()
      ';' => {
        if p.peek(1) == ';' {
          p.advance()
        }
        p.advance()
        while !is_eof_char(p.peek(0)) && p.peek(0) != '\n' {
          p.advance()
        }
      }
      '#' if p.peek(1) == '!' => {
        p.advance()
        p.advance()
        while !is_eof_char(p.peek(0)) && p.peek(0) != '\n' {
          p.advance()
        }
      }
      _ => break
    }
  }
}

///|
/// Parse a `"..."` string. Handles the usual escapes plus `|...|`
/// interpolation markers (kept verbatim; `render` interprets them later).
fn Parser::parse_string(p : Parser, stopper : Char) -> String raise ArturoError {
  let sb = StringBuilder()
  p.advance() // opening quote
  let initial_line = p.line
  let mut in_code = false
  let mut done = false
  while !done {
    let c = p.peek(0)
    if is_eof_char(c) {
      p.line = initial_line
      raise ParseError(line=p.line, message="unterminated string")
    } else if c == stopper {
      p.advance()
      done = true
    } else if c == '|' {
      sb.write_string("|")
      p.advance()
      in_code = !in_code
    } else if c == '\\' && !in_code {
      let e = p.peek(1)
      match e {
        '\\' | '"' | '\'' | '/' => {
          sb.write_char(e)
          p.advance()
          p.advance()
        }
        'a' => {
          sb.write_char('\u{7}')
          p.advance()
          p.advance()
        }
        'b' => {
          sb.write_char('\b')
          p.advance()
          p.advance()
        }
        'e' => {
          sb.write_char('\u{1b}')
          p.advance()
          p.advance()
        }
        'f' => {
          sb.write_char('\f')
          p.advance()
          p.advance()
        }
        'n' | 'l' => {
          sb.write_string("\n")
          p.advance()
          p.advance()
        }
        'r' | 'c' => {
          sb.write_string("\r")
          p.advance()
          p.advance()
        }
        't' => {
          sb.write_string("\t")
          p.advance()
          p.advance()
        }
        'v' => {
          sb.write_char('\u{b}')
          p.advance()
          p.advance()
        }
        'x' => {
          p.advance()
          p.advance()
          let mut xi = 0
          let mut count = 0
          while count < 2 {
            let h = p.peek(0)
            if h >= '0' && h <= '9' {
              xi = xi * 16 + (h.to_int() - '0')
            } else if h >= 'a' && h <= 'f' {
              xi = xi * 16 + (h.to_int() - 'a' + 10)
            } else if h >= 'A' && h <= 'F' {
              xi = xi * 16 + (h.to_int() - 'A' + 10)
            } else {
              break
            }
            p.advance()
            count += 1
          }
          sb.write_char(xi.unsafe_to_char())
        }
        _ => {
          sb.write_string("\\")
          sb.write_char(e)
          p.advance()
          p.advance()
        }
      }
    } else if "\n\r".contains_char(c) {
      p.line = initial_line
      raise ParseError(line=p.line, message="newline in quoted string")
    } else {
      sb.write_char(c)
      p.advance()
    }
  }
  sb.to_string()
}

///|
/// `{...}` curly string (dedented).
/// (The verbatim form `{:...:}` is not supported in this subset.)
fn Parser::parse_curly_string(p : Parser) -> String raise ArturoError {
  let sb = StringBuilder()
  p.advance() // '{'
  let initial_line = p.line
  let mut curlies = 1
  while true {
    let c = p.peek(0)
    if is_eof_char(c) {
      p.line = initial_line
      raise ParseError(line=p.line, message="unterminated curly string")
    } else if c == '{' {
      curlies += 1
      sb.write_char(c)
      p.advance()
    } else if c == '}' {
      if curlies == 1 {
        p.advance()
        break
      } else {
        curlies -= 1
        sb.write_char(c)
        p.advance()
      }
    } else {
      sb.write_char(c)
      p.advance()
    }
  }
  dedent_str(sb.to_string())
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
fn Parser::parse_identifier(p : Parser, add_current : Bool) -> String {
  let sb = StringBuilder()
  if add_current {
    sb.write_char(p.peek(0))
  }
  p.advance()
  let initial = p.pos
  while is_ident_char(p.peek(0)) {
    sb.write_char(p.peek(0))
    p.advance()
  }
  if p.peek(0) == '?' && p.pos != initial {
    sb.write_string("?")
    p.advance()
  }
  sb.to_string()
}

///|
/// Parse a number literal: decimal/hex/octal/binary integers,
/// floating point (with or without scientific notation).
fn Parser::parse_number(p : Parser) -> Value raise ArturoError {
  let sb = StringBuilder()
  let (num_base, already) = if p.peek(0) == '0' {
    match p.peek(1) {
      'x' | 'X' => {
        sb.write_string("0x")
        p.advance()
        p.advance()
        (16, true)
      }
      'b' | 'B' => {
        sb.write_string("0b")
        p.advance()
        p.advance()
        (2, true)
      }
      'o' | 'O' => {
        sb.write_string("0o")
        p.advance()
        p.advance()
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
              (p.peek(0) >= '0' && p.peek(0) <= '9') ||
              (p.peek(0) >= 'a' && p.peek(0) <= 'f') ||
              (p.peek(0) >= 'A' && p.peek(0) <= 'F')
            )
          ) ||
          (num_base == 2 && "01".contains_char(p.peek(0))) ||
          (num_base == 8 && p.peek(0) >= '0' && p.peek(0) <= '7') {
      sb.write_char(p.peek(0))
      p.advance()
      count += 1
    }
    if count == 0 {
      raise ParseError(line=p.line, message="invalid number literal")
    }
    let text = sb.to_string()
    let digits = text[2:]
    let value = @string.parse_int(digits, base=num_base) catch {
      _ => raise ParseError(line=p.line, message="invalid number literal")
    }
    return VInteger(value)
  }
  // decimal
  let mut dots = 0
  while p.peek(0) >= '0' && p.peek(0) <= '9' {
    sb.write_char(p.peek(0))
    p.advance()
  }
  if p.peek(0) == '.' && p.peek(1) >= '0' && p.peek(1) <= '9' {
    dots += 1
    sb.write_string(".")
    p.advance()
    while p.peek(0) >= '0' && p.peek(0) <= '9' {
      sb.write_char(p.peek(0))
      p.advance()
    }
    if p.peek(0) == '.' && p.peek(1) >= '0' && p.peek(1) <= '9' {
      dots += 1
      sb.write_string(".")
      p.advance()
      while p.peek(0) >= '0' && p.peek(0) <= '9' {
        sb.write_char(p.peek(0))
        p.advance()
      }
    }
  }
  let text = sb.to_string()
  if dots > 1 {
    // version literal — represented as a string in this subset
    return VString(text)
  }
  // scientific notation
  if "eE".contains_char(p.peek(0)) &&
    (
      (p.peek(1) >= '0' && p.peek(1) <= '9') ||
      ("+-".contains_char(p.peek(1)) && p.peek(2) >= '0' && p.peek(2) <= '9')
    ) {
    sb.write_string("e")
    p.advance()
    if "+-".contains_char(p.peek(0)) {
      sb.write_char(p.peek(0))
      p.advance()
    }
    while p.peek(0) >= '0' && p.peek(0) <= '9' {
      sb.write_char(p.peek(0))
      p.advance()
    }
    let ftext = sb.to_string()
    let fval = @string.parse_double(ftext) catch {
      _ => raise ParseError(line=p.line, message="invalid number literal")
    }
    return VFloating(fval)
  }
  if dots > 0 {
    let fval = @string.parse_double(text) catch {
      _ => raise ParseError(line=p.line, message="invalid number literal")
    }
    return VFloating(fval)
  }
  if text == "" {
    raise ParseError(line=p.line, message="invalid number literal")
  }
  let ival = @string.parse_int(text) catch {
    _ => raise ParseError(line=p.line, message="invalid number literal")
  }
  VInteger(ival)
}

///|
/// Parse an operator symbol: read the whole run of ASCII symbol
/// characters. Any combination is accepted; evaluation decides what it
/// means (`alias_lookup` in eval.mbt, unknown symbols stay symbols).
fn Parser::parse_symbol(p : Parser) -> String {
  let c = p.peek(0)
  if c == '#' && is_ident_char(p.peek(1)) {
    // color literal — not supported in this subset
    p.advance()
    while is_ident_char(p.peek(0)) {
      p.advance()
    }
    return "#color"
  }
  let start = p.pos
  while "+*/%^=<>!?~|&@#$-\\:.".contains_char(p.peek(0)) {
    p.advance()
  }
  p.src[start:p.pos].to_owned()
}

///|
/// Parse a backslash path: `a\b`, `a\0`, `\key`, `a\[block]`.
fn Parser::parse_path(
  p : Parser,
  root : Value,
) -> Array[Value] raise ArturoError {
  let parts : Array[Value] = [root]
  while p.peek(0) == '\\' {
    p.advance()
    if is_ident_start(p.peek(0)) {
      parts.push(VLiteral(p.parse_identifier(true)))
    } else if p.peek(0) >= '0' && p.peek(0) <= '9' {
      parts.push(p.parse_number())
    } else if p.peek(0) == '[' {
      p.advance()
      parts.push(VBlock(p.parse_block(0, true, false)))
    } else {
      break
    }
  }
  parts
}

///|
fn Parser::parse_block(
  p : Parser,
  level : Int,
  is_sub_block : Bool,
  is_sub_inline : Bool,
) -> Array[Value] raise ArturoError {
  let out : Array[Value] = []
  let initial_line = p.line
  while true {
    p.skip()
    let c = p.peek(0)
    if is_eof_char(c) {
      if level != 0 {
        p.line = initial_line
        if is_sub_block {
          raise ParseError(line=p.line, message="missing closing `]`")
        } else {
          raise ParseError(line=p.line, message="missing closing `)`")
        }
      }
      break
    } else if c == '"' {
      let s = p.parse_string('"')
      if p.peek(0) == ':' {
        p.advance()
        out.push(VLabel(s))
      } else {
        out.push(VString(s))
      }
    } else if c == '\'' {
      // literal, char or symbol-literal
      let id = p.parse_identifier(false)
      if id == "" {
        if p.peek(0) == '\\' {
          // '\n style char escapes
          p.advance()
          let e = p.peek(0)
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
          p.advance()
          if p.peek(0) == '\'' {
            p.advance()
          }
          out.push(VChar(ch))
        } else {
          // symbol literal: '+' etc.
          out.push(VLiteral(p.parse_symbol()))
        }
      } else if p.peek(0) == '\\' {
        out.push(VPath(p.parse_path(VLiteral(id))))
      } else if p.peek(0) == '\'' {
        // char: 'a'
        p.advance()
        out.push(
          VChar(
            if !id.is_empty() {
              id[0].to_int().unsafe_to_char()
            } else {
              '\u{0}'
            },
          ),
        )
      } else {
        out.push(VLiteral(id))
      }
    } else if c >= '0' && c <= '9' {
      let num = p.parse_number()
      if p.peek(0) == ':' {
        raise ParseError(
          line=p.line,
          message="rational literals are not supported in this subset",
        )
      }
      out.push(num)
    } else if c == ':' {
      // `:ident` is a type; otherwise the whole run (`::`, `:=`, ...)
      // is a symbol, parsed by `parse_symbol` from the colon itself
      if is_ident_start(p.peek(1)) {
        out.push(VType(p.parse_identifier(false)))
      } else {
        out.push(VSymbol(p.parse_symbol()))
      }
    } else if c == '.' {
      // only `.ident` / `.ident: value` are attributes; every other
      // dot-prefixed run (`..`, `...`, `./`, ...) is a symbol
      if is_ident_start(p.peek(1)) {
        let id = p.parse_identifier(false)
        if p.peek(0) == ':' {
          p.advance()
          out.push(VAttributeLabel(id))
        } else {
          out.push(VAttribute(id))
        }
      } else {
        out.push(VSymbol(p.parse_symbol()))
      }
    } else if is_ident_start(c) {
      let id = p.parse_identifier(true)
      if id == "_" {
        out.push(VSymbol("_"))
      } else if p.peek(0) == ':' {
        p.advance()
        out.push(VLabel(id))
      } else if p.peek(0) == '\\' {
        let path = p.parse_path(VWord(id))
        if p.peek(0) == ':' {
          // path label: `d\key: value` stores through the path
          p.advance()
          out.push(VPathLabel(path))
        } else {
          out.push(VPath(path))
        }
      } else {
        out.push(VWord(id))
      }
    } else if c == '\\' {
      if is_ident_start(p.peek(1)) || p.peek(1) == '[' {
        let path = p.parse_path(VWord("this"))
        if p.peek(0) == ':' {
          p.advance()
          out.push(VLabel(path.map(Show::to_string).join("\\")))
        } else {
          out.push(VPath(path))
        }
      } else {
        out.push(VSymbol(p.parse_symbol()))
      }
    } else if c == '[' {
      p.advance()
      out.push(VBlock(p.parse_block(level + 1, true, false)))
    } else if c == ']' {
      if is_sub_block {
        p.advance()
        break
      } else if is_sub_inline {
        p.line = initial_line
        raise ParseError(line=p.line, message="missing closing `)`")
      } else {
        raise ParseError(line=p.line, message="stray `]`")
      }
    } else if c == '(' {
      p.advance()
      out.push(VInline(p.parse_block(level + 1, false, true)))
    } else if c == ')' {
      if is_sub_inline {
        p.advance()
        break
      } else if is_sub_block {
        p.line = initial_line
        raise ParseError(line=p.line, message="missing closing `]`")
      } else {
        raise ParseError(line=p.line, message="stray `)`")
      }
    } else if c == '{' {
      let s = p.parse_curly_string()
      if p.peek(0) == ':' {
        p.advance()
        out.push(VLabel(s))
      } else {
        out.push(VString(s))
      }
    } else if c == '}' {
      raise ParseError(line=p.line, message="stray `}`")
    } else if "+*/%^=<>!?~|&@#$-\\:.".contains_char(c) {
      out.push(VSymbol(p.parse_symbol()))
    } else {
      // unknown character: skip it
      p.advance()
    }
  }
  out
}

///|
/// Parse Arturo source code into a block of raw values.
pub fn parse(source : String) -> Value raise ArturoError {
  let p = Parser(source)
  VBlock(p.parse_block(0, false, false))
}
