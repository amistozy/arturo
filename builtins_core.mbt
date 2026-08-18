///|
/// Core builtins: control flow, functions, I/O, environment — a
/// MoonBit port of `src/library/Core.nim` (+ `Io.nim`/`Reflection.nim`
/// bits) restricted to the subset.

///|
/// `if condition action` — run action if condition is not false/null.
fn b_if(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if args[0].is_truthy() {
    match args[1] {
      VBlock(blk) => {
        eval_block(blk, ctx)
        ignore(ctx.stack.pop())
      }
      VInline(blk) => {
        eval_block(blk, ctx)
        ignore(ctx.stack.pop())
      }
      _ => ()
    }
  }
}

///|
fn b_unless(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if !args[0].is_truthy() {
    match args[1] {
      VBlock(blk) => {
        eval_block(blk, ctx)
        ignore(ctx.stack.pop())
      }
      VInline(blk) => {
        eval_block(blk, ctx)
        ignore(ctx.stack.pop())
      }
      _ => ()
    }
  }
}

///|
/// `switch condition action alternative` (also `?`).
fn b_switch(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if args[0].is_truthy() {
    match args[1] {
      VBlock(blk) => eval_block(blk, ctx)
      v => ctx.push(v)
    }
  } else {
    match args[2] {
      VBlock(blk) => eval_block(blk, ctx)
      v => ctx.push(v)
    }
  }
}

///|
/// `while condition action`.
fn b_while(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let action = args[1]
  let mut cond = args[0]
  while true {
    if !cond.is_truthy() {
      break
    }
    try {
      match action {
        VBlock(blk) => {
          eval_block(blk, ctx)
          ignore(ctx.stack.pop())
        }
        VInline(blk) => {
          eval_block(blk, ctx)
          ignore(ctx.stack.pop())
        }
        _ => ()
      }
    } catch {
      ArturoError::BreakSignal => break
      ArturoError::ContinueSignal => ()
      err => raise err
    }
    cond = match args[0] {
      VBlock(c) => eval_block_last(c, ctx)
      _ => args[0]
    }
  }
}

///|
/// `until action condition`.
fn b_until(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let action = args[0]
  let cond_blk = args[1]
  while true {
    try {
      match action {
        VBlock(blk) => {
          eval_block(blk, ctx)
          ignore(ctx.stack.pop())
        }
        _ => ()
      }
    } catch {
      ArturoError::BreakSignal => break
      ArturoError::ContinueSignal => ()
      err => raise err
    }
    let c = match cond_blk {
      VBlock(cb) => eval_block_last(cb, ctx)
      _ => VNull
    }
    if c.is_truthy() {
      break
    }
  }
}

///|
/// `when [cond1 -> act1 cond2 -> act2 ...]` — first match wins.
fn b_when(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let blk = match args[0] {
    VBlock(b) => b
    _ => []
  }
  let pairs = eval_block_values(blk, ctx)
  let with_any = ctx.current_attrs.contains("any")
  let mut i = 0
  while i + 1 < pairs.length() {
    let cond = match pairs[i] {
      VBlock(c) => eval_block_last(c, ctx)
      v => v
    }
    if cond.is_truthy() {
      match pairs[i + 1] {
        VBlock(a) => {
          eval_block(a, ctx)
          ignore(ctx.stack.pop())
        }
        v => ctx.push(v)
      }
      if !with_any {
        break
      }
    }
    i = i + 2
  }
}

///|
/// `case value matches-block`.
fn b_case(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let x = args[0]
  match args[1] {
    VBlock(blk) => {
      let pairs = eval_block_values(blk, ctx)
      let mut i = 0
      while i + 1 < pairs.length() {
        if x == pairs[i] {
          match pairs[i + 1] {
            VBlock(a) => {
              eval_block(a, ctx)
              ignore(ctx.stack.pop())
            }
            v => ctx.push(v)
          }
          return
        }
        i = i + 2
      }
    }
    VDictionary(d) => {
      let key = match x {
        VString(s) | VWord(s) | VLiteral(s) => s
        _ => x.to_string()
      }
      match d.get(key) {
        Some(v2) =>
          match v2 {
            VBlock(a) => {
              eval_block(a, ctx)
              ignore(ctx.stack.pop())
            }
            v => ctx.push(v)
          }
        None => ()
      }
    }
    _ => ()
  }
}

///|
/// `do code` — evaluate a string or block.
fn b_do(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let times = ctx.current_attrs.get("times")
  let n = match times {
    Some(VInteger(t)) => if t > 0 { t } else { 1 }
    _ => 1
  }
  let mut i = 0
  while i < n {
    match args[0] {
      VBlock(blk) => {
        eval_block(blk, ctx)
        ignore(ctx.stack.pop())
      }
      VInline(blk) => {
        eval_block(blk, ctx)
        ignore(ctx.stack.pop())
      }
      VString(src) => {
        let parsed = parse(src) catch { _ => return }
        match parsed {
          VBlock(blk) => {
            eval_block(blk, ctx)
            ignore(ctx.stack.pop())
          }
          _ => ()
        }
      }
      _ => ()
    }
    i = i + 1
  }
}

///|
/// `function params body` (also `$`) — create a user function.
fn b_function(ctx : Ctx, args : Array[Value]) -> Unit {
  let params : Array[String] = match args[0] {
    VLiteral(s) => [s]
    VBlock(items) =>
      items.filter_map(x => {
        match x {
          VWord(w) | VLiteral(w) => Some(w)
          _ => None
        }
      })
    _ => []
  }
  let body = match args[1] {
    VBlock(b) => b
    VInline(b) => b
    _ => []
  }
  ctx.push(VFunction(UserFunction(params~, main=body, inline=false)))
}

///|
/// `return value` — return from the current function.
fn b_return(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  ctx.push(args[0])
  raise ArturoError::ReturnSignal(args[0])
}

///|
fn b_break(_ctx : Ctx, _args : Array[Value]) -> Unit raise ArturoError {
  raise ArturoError::BreakSignal
}

///|
fn b_continue(_ctx : Ctx, _args : Array[Value]) -> Unit raise ArturoError {
  raise ArturoError::ContinueSignal
}

///|
/// `let` — assign symbol(s) (also the `:` infix form).
fn b_let(ctx : Ctx, args : Array[Value]) -> Unit {
  let x = args[0]
  let y = args[1]
  match x {
    VBlock(symbols) =>
      match y {
        VBlock(values) => {
          let mut i = 0
          while i < symbols.length() && i < values.length() {
            match symbols[i] {
              VWord(w) | VLiteral(w) | VLabel(w) | VString(w) =>
                ctx.env.set(w, values[i])
              VBlock(sub) =>
                if sub.length() == 1 {
                  // slice: [a [b] c]: [1 2 3 4 5]
                  match sub[0] {
                    VWord(w) | VLiteral(w) => {
                      let slice : Array[Value] = values[i + 1:values.length() -
                      (symbols.length() - 1 - i)].to_owned()
                      ctx.env.set(w, VBlock(slice))
                    }
                    _ => ()
                  }
                }
              _ => ()
            }
            i = i + 1
          }
          // assign remaining single values
          let diff = values.length() - symbols.length()
          if diff > 0 && !symbols.is_empty() {
            match symbols[symbols.length() - 1] {
              VBlock(sub) if sub.length() == 1 => ()
              _ => ()
            }
          }
        }
        v =>
          // [a b]: 5  →  a: 5, b: 5
          for item in symbols {
            match item {
              VWord(w) | VLiteral(w) | VLabel(w) | VString(w) =>
                ctx.env.set(w, v)
              _ => ()
            }
          }
      }
    VLiteral(s) => ctx.env.set(s, y)
    VWord(s) => ctx.env.set(s, y)
    VLabel(s) => ctx.env.set(s, y)
    VString(s) => ctx.env.set(s, y)
    _ => ()
  }
}

///|
/// `var 'name` — fetch the value of a symbol by name.
fn b_var(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VLiteral(s) | VWord(s) | VString(s) =>
      ctx.push(ctx.env.get(s).unwrap_or(VNull))
    VPath(parts) => ctx.push(fetch_path(parts, ctx).unwrap_or(VNull))
    _ => ctx.push(VNull)
  }
}

///|
fn b_setq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VLiteral(s) | VWord(s) | VString(s) => ctx.push(VLogical(ctx.env.has(s)))
    _ => ctx.push(VLogical(false))
  }
}

///|
fn b_unset(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VLiteral(s) | VWord(s) | VString(s) => ctx.env.remove(s)
    _ => ()
  }
}

///|
/// `discard value`.
fn b_discard(_ctx : Ctx, args : Array[Value]) -> Unit {
  ignore(args)
}

///|
/// `new value` — a copy (values are immutable in this subset, so it's
/// the identity).
fn b_new(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(args[0])
}

///|
/// `call 'fun [params]`.
fn b_call(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let fun = match args[0] {
    VLiteral(s) | VWord(s) | VString(s) => ctx.env.get(s).unwrap_or(VNull)
    v => v
  }
  let params = match args[1] {
    VBlock(b) => b
    _ => []
  }
  invoke(fun, params, ctx, "call")
}

///|
/// `ensure condition-block` — assert the condition holds.
fn b_ensure(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VBlock(blk) => {
      let v = eval_block_last(blk, ctx)
      if !v.is_truthy() {
        raise RuntimeError(message="assertion failed: \{VBlock(blk)}")
      }
    }
    _ => ()
  }
}

///|
/// `dup value` (also `<=`) — push the value twice.
fn b_dup(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(args[0])
  ctx.push(args[0])
}

///|
/// `coalesce x y` (also `??`).
fn b_coalesce(ctx : Ctx, args : Array[Value]) -> Unit {
  if args[0].is_truthy() {
    ctx.push(args[0])
  } else {
    ctx.push(args[1])
  }
}

///|
/// `print value` — with a newline; blocks are evaluated and their
/// pushed values are joined with spaces.
fn b_print(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let in_lines = ctx.current_attrs.contains("lines")
  match args[0] {
    VBlock(blk) => {
      let vals = eval_block_values(blk, ctx)
      for v in vals {
        ctx.out.write_object(v)
        if in_lines {
          ctx.out.write_string("\n")
        } else {
          ctx.out.write_string(" ")
        }
      }
      if !in_lines {
        ctx.out.write_string("\n")
      }
    }
    v => ctx.out.write_string("\{v}\n")
  }
}

///|
/// `prints value` — without a newline.
fn b_prints(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VBlock(blk) => {
      let vals = eval_block_values(blk, ctx)
      for v in vals {
        ctx.out.write_string("\{v} ")
      }
    }
    v => ctx.out.write_object(v)
  }
}

///|
/// `inspect value` — detailed dump with type annotations
/// (mirrors `dump` in `printable.nim`, muted).
fn b_inspect(ctx : Ctx, args : Array[Value]) -> Unit {
  let sb = ctx.out
  inspect_value(args[0], 0, false, sb)
  sb.write_string("\n")
}

///|
fn indent(out : StringBuilder, level : Int) -> Unit {
  for _ in 0..<level {
    out.write_string("    ")
  }
}

///|
fn inspect_value(
  v : Value,
  level : Int,
  _is_last : Bool,
  out : StringBuilder,
) -> Unit {
  match v {
    VBlock(items) => {
      out.write_string("[ :block\n")
      for i in 0..<items.length() {
        indent(out, level + 1)
        inspect_value(items[i], level + 1, i == items.length() - 1, out)
        if i != items.length() - 1 {
          out.write_string("\n")
        }
      }
      if !items.is_empty() {
        out.write_string("\n")
      }
      indent(out, level)
      out.write_string("]")
    }
    VInline(items) => {
      out.write_string("[ :inline\n")
      for i in 0..<items.length() {
        indent(out, level + 1)
        inspect_value(items[i], level + 1, i == items.length() - 1, out)
        if i != items.length() - 1 {
          out.write_string("\n")
        }
      }
      if !items.is_empty() {
        out.write_string("\n")
      }
      indent(out, level)
      out.write_string("]")
    }
    VDictionary(d) => {
      out.write_string("[ :dictionary\n")
      let entries = d.iter().to_array()
      for i in 0..<entries.length() {
        indent(out, level + 1)
        out.write_string("\{entries[i].0}: ")
        inspect_value(entries[i].1, level + 1, false, out)
        if i != entries.length() - 1 {
          out.write_string("\n")
        }
      }
      if !entries.is_empty() {
        out.write_string("\n")
      }
      indent(out, level)
      out.write_string("]")
    }
    VFunction(_) => out.write_string("\{v} :function")
    _ => out.write_string("\{v} :\{v.type_name()}")
  }
}

///|
/// `render string` (also `~`) — interpolate `|...|` code segments.
fn b_render(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let s = match args[0] {
    VString(s) => s
    _ => ""
  }
  let out = StringBuilder()
  let mut code = false
  let mut codebuf = StringBuilder()
  let mut i = 0
  let len = s.length()
  while i < len {
    if code {
      if s[i] == '|' {
        let src = codebuf.to_string()
        codebuf = StringBuilder()
        code = false
        let vals = eval_code_segments(src, ctx)
        for v in vals {
          out.write_object(v)
        }
        i = i + 1
      } else {
        codebuf.write_char(s[i].unsafe_to_char())
        i = i + 1
      }
    } else if s[i] == '|' {
      code = true
      i = i + 1
    } else {
      out.write_char(s[i].unsafe_to_char())
      i = i + 1
    }
  }
  ctx.push(VString(out.to_string()))
}

///|
fn eval_code_segments(
  src : String,
  ctx : Ctx,
) -> Array[Value] raise ArturoError {
  let parsed = parse(src) catch { _ => return [] }
  match parsed {
    VBlock(blk) => eval_block_values(blk, ctx)
    _ => []
  }
}

///|
/// `parse string` — parse the first value of the given source.
fn b_parse(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VString(src) => {
      let parsed = parse(src)
      match parsed {
        VBlock(blk) =>
          if !blk.is_empty() {
            ctx.push(blk[0])
          } else {
            ctx.push(VNull)
          }
        _ => ctx.push(VNull)
      }
    }
    v => ctx.push(v)
  }
}

///|
/// `attr 'name` — fetch the current call's attribute value (or null).
fn b_attr(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VLiteral(s) | VWord(s) =>
      ctx.push(ctx.current_attrs.get(s).unwrap_or(VNull))
    _ => ctx.push(VNull)
  }
}

///|
fn b_attrq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VLiteral(s) | VWord(s) => ctx.push(VLogical(ctx.current_attrs.contains(s)))
    _ => ctx.push(VLogical(false))
  }
}
