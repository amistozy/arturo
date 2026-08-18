///|
/// The evaluator — a tree-walking port of the Arturo VM
/// (`src/vm/ast.nim` + `src/vm/exec.nim` semantics).
///
/// Arturo evaluates blocks of values left to right. Words bound to
/// functions become calls that consume their declared arity of
/// following expressions; labels store values; symbols form
/// infix/prefix operator calls; pipes re-route the previous value into
/// the next call; arrows build raw body blocks.
///
/// The evaluator keeps an explicit value stack (`Ctx.stack`) exactly
/// like the bytecode VM, so builtins such as `print` can evaluate a
/// block and collect everything it pushed.

///|
/// The symbol table with per-call undo frames (like `Syms` +
/// `ScopeStack` in `globals.nim`): assignments are visible globally,
/// but a function call records the previous values of every symbol it
/// touches and restores them on exit.
struct Env {
  syms : Map[String, Value]
  frames : Array[Map[String, Value?]]
}

///|
fn Env::empty() -> Env {
  { syms: Map([]), frames: [] }
}

///|
fn Env::set(self : Env, name : String, v : Value) -> Unit {
  if self.frames is [.., top] {
    if !top.contains(name) {
      top[name] = self.syms.get(name)
    }
  }
  self.syms[name] = v
}

///|
fn Env::get(self : Env, name : String) -> Value? {
  self.syms.get(name)
}

///|
fn Env::has(self : Env, name : String) -> Bool {
  self.syms.contains(name)
}

///|
fn Env::remove(self : Env, name : String) -> Unit {
  if self.frames is [.., top] {
    if !top.contains(name) {
      top[name] = self.syms.get(name)
    }
  }
  self.syms.remove(name)
}

///|
fn Env::push_scope(self : Env) -> Unit {
  self.frames.push(Map([]))
}

///|
fn Env::pop_scope(self : Env) -> Unit {
  guard self.frames.pop() is Some(frame) else {  }
  for name, prev in frame {
    match prev {
      Some(v) => self.syms[name] = v
      None => self.syms.remove(name)
    }
  }
}

///|
/// The evaluation context: value stack, environment, captured output,
/// in-flight call attributes.
priv struct Ctx {
  stack : Array[Value]
  env : Env
  out : StringBuilder
  mut pending_attrs : Array[(String, Value)]?
  mut current_attrs : Array[(String, Value)]
}

///|
fn Ctx::Ctx() -> Ctx {
  {
    stack: [],
    env: Env::empty(),
    out: StringBuilder(),
    pending_attrs: None,
    current_attrs: [],
  }
}

///|
fn Ctx::with_env(env : Env) -> Ctx {
  {
    stack: [],
    env,
    out: StringBuilder(),
    pending_attrs: None,
    current_attrs: [],
  }
}

///|
fn Ctx::push(self : Ctx, v : Value) -> Unit {
  self.stack.push(v)
}

///|
fn Ctx::pop(self : Ctx) -> Value raise ArturoError {
  match self.stack.pop() {
    Some(v) => v
    None => raise RuntimeError(message="stack underflow")
  }
}

///|
fn Ctx::pop_or_null(ctx : Ctx) -> Value {
  match ctx.stack.pop() {
    Some(v) => v
    None => VNull
  }
}

///|
/// Alias table: symbol text -> (precedence, function/constant name),
/// mirroring the `Aliases` table of the reference VM.
priv enum Prec {
  InfixPrec
  PrefixPrec
}

///|
fn alias_lookup(sym : String) -> (Prec, String)? {
  match sym {
    "+" => Some((InfixPrec, "add"))
    "-" => Some((InfixPrec, "sub"))
    "*" => Some((InfixPrec, "mul"))
    "/" => Some((InfixPrec, "div"))
    "//" => Some((InfixPrec, "fdiv"))
    "/%" => Some((InfixPrec, "divmod"))
    "%" => Some((InfixPrec, "mod"))
    "^" => Some((InfixPrec, "pow"))
    "++" => Some((InfixPrec, "append"))
    "--" => Some((InfixPrec, "remove"))
    ".." => Some((InfixPrec, "range"))
    "=" => Some((InfixPrec, "equal?"))
    "<>" => Some((InfixPrec, "notEqual?"))
    "<" => Some((InfixPrec, "less?"))
    ">" => Some((InfixPrec, "greater?"))
    "=<" => Some((InfixPrec, "lessOrEqual?"))
    ">=" => Some((InfixPrec, "greaterOrEqual?"))
    "?" => Some((InfixPrec, "switch"))
    "??" => Some((InfixPrec, "coalesce"))
    "_" => Some((PrefixPrec, "any"))
    "$" => Some((PrefixPrec, "function"))
    "@" => Some((PrefixPrec, "array"))
    "#" => Some((PrefixPrec, "dictionary"))
    "~" => Some((PrefixPrec, "render"))
    "<=" => Some((PrefixPrec, "dup"))
    _ => None
  }
}

///|
/// Arity of a function value.
fn fun_arity(fun : Value) -> Int {
  match fun {
    VFunction(UserFunction(params~, ..)) => params.length()
    VFunction(BuiltinFunction(name~)) => builtin_arity(name)
    _ => 0
  }
}

///|
/// Evaluate a whole block (statement by statement).
fn eval_block(blk : ArrayView[Value], ctx : Ctx) -> Unit raise ArturoError {
  for rest = blk; rest is [_, ..]; rest = eval_statement(rest, ctx) {

  }
}

///|
/// Evaluate one statement: an expression plus any trailing pipe chain.
/// Pushes exactly the chain's final value (pipes are statement-level,
/// exactly like `addPotentialTrailingPipe` in `ast.nim`).
fn eval_statement(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> ArrayView[Value] raise ArturoError {
  for rest = eval_expr(blk, ctx); rest is [VSymbol("|"), .. rest]; {
    guard rest is [value, .. rest] else { break [] }
    match value {
      VWord(w) => continue form_call_by_name(rest, ctx, w, piped=true)
      _ => {
        // unresolved pipe: push the symbol itself as a constant
        ctx.push(VSymbol("|"))
        continue rest
      }
    }
  } nobreak {
    rest
  }
}

///|
/// Evaluate one expression; pushes its value(s) on the stack and
/// returns the rest of the block after the expression.
fn eval_expr(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> ArrayView[Value] raise ArturoError {
  guard blk is [item, .. rest] else {
    raise RuntimeError(message="evaluation reached the end of the block")
  }
  match item {
    VNull
    | VLogical(_)
    | VInteger(_)
    | VFloating(_)
    | VChar(_)
    | VString(_)
    | VType(_)
    | VLiteral(_)
    | VBlock(_)
    | VDictionary(_)
    | VRange(_)
    | VFunction(_) => {
      ctx.push(item)
      eval_infix_tail(rest, ctx)
    }
    VInline(inner) => {
      eval_block(inner[:], ctx)
      eval_infix_tail(rest, ctx)
    }
    VSymbol(s) => eval_symbol(blk, ctx, s)
    VWord(w) =>
      if w == "true" {
        ctx.push(VLogical(true))
        eval_infix_tail(rest, ctx)
      } else if w == "false" {
        ctx.push(VLogical(false))
        eval_infix_tail(rest, ctx)
      } else {
        match ctx.env.get(w) {
          Some(VFunction(_)) => form_call(blk, ctx, false)
          Some(v) => {
            ctx.push(v)
            eval_infix_tail(rest, ctx)
          }
          None =>
            raise RuntimeError(message="cannot resolve requested value: \{w}")
        }
      }
    VLabel(name) =>
      // store: its value is a full statement (pipes allowed);
      // a trailing label (nothing after `:`) stores null
      match rest {
        [] => {
          ctx.env.set(name, VNull)
          []
        }
        _ => {
          let rest2 = eval_statement(rest, ctx)
          let v = ctx.pop_or_null()
          ctx.env.set(name, v)
          rest2
        }
      }
    VPathLabel(parts) =>
      match rest {
        [] => {
          set_path(parts, VNull, ctx)
          []
        }
        _ => {
          let rest2 = eval_statement(rest, ctx)
          let v = ctx.pop_or_null()
          set_path(parts, v, ctx)
          rest2
        }
      }
    VAttribute(name) => {
      match ctx.pending_attrs {
        Some(attrs) => attrs.push((name, VLogical(true)))
        None => ()
      }
      eval_infix_tail(rest, ctx)
    }
    VAttributeLabel(name) =>
      match rest {
        [] => {
          // a trailing attribute-label records null
          match ctx.pending_attrs {
            Some(attrs) => attrs.push((name, VNull))
            None => ()
          }
          []
        }
        _ => {
          let rest2 = eval_expr(rest, ctx)
          let v = ctx.pop_or_null()
          match ctx.pending_attrs {
            Some(attrs) => attrs.push((name, v))
            None => ()
          }
          eval_infix_tail(rest2, ctx)
        }
      }
    VPath(parts) => {
      let v = match fetch_path(parts, ctx) {
        Some(x) => x
        None =>
          raise RuntimeError(message="cannot resolve path: \{VPath(parts)}")
      }
      ctx.push(v)
      eval_infix_tail(rest, ctx)
    }
  }
}

///|
/// After a terminal, check whether the next item is an infix operator
/// (or a pipe — handled by `eval_statement`); if so, form the operator
/// call with the pushed value as its first argument.
fn eval_infix_tail(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> ArrayView[Value] raise ArturoError {
  guard blk is [VSymbol(s), .. rest] else { blk }
  guard alias_lookup(s) is Some((InfixPrec, name)) else { blk }
  let fun = match ctx.env.get(name) {
    Some(x) => x
    None =>
      raise RuntimeError(message="cannot resolve requested value: \{name}")
  }
  let arity = fun_arity(fun)
  let saved = ctx.pending_attrs
  ctx.pending_attrs = Some([])
  let args_rest = for args_rest = rest, consumed = 0; consumed < arity - 1; {
    match args_rest {
      [] => raise RuntimeError(message="not enough arguments for operator \{s}")
      [VAttribute(_) | VAttributeLabel(_), ..] =>
        // attributes attach to the call without consuming a slot
        continue eval_expr(args_rest, ctx), consumed
      [_, ..] => continue eval_expr(args_rest, ctx), consumed + 1
    }
  } nobreak {
    args_rest
  }
  let attrs = ctx.pending_attrs.unwrap_or([])
  ctx.pending_attrs = saved
  let args = ctx.pop_args(arity)
  invoke(fun, args, ctx, s, attrs~)
  args_rest
}

///|
/// Pop `n` values and return them in original order.
fn Ctx::pop_args(ctx : Ctx, n : Int) -> Array[Value] raise ArturoError {
  let args : Array[Value] = []
  for _ in 0..<n {
    args.push(ctx.pop())
  }
  arr_reverse(args)
  args
}

///|
/// Evaluate a symbol expression (arrow, pipe target, operator call...).
fn eval_symbol(
  blk : ArrayView[Value],
  ctx : Ctx,
  s : String,
) -> ArrayView[Value] raise ArturoError {
  if s == "->" {
    let (body, rest) = collect_arrow(blk[1:], ctx)
    ctx.push(VBlock(body))
    rest
  } else if s == "=>" {
    let (params, sub, rest) = collect_thick_arrow(blk[1:], ctx)
    ctx.push(params)
    ctx.push(VBlock(sub))
    rest
  } else if s == "!" {
    // execute the rest of the block
    eval_block(blk[1:], ctx)
    blk[blk.length():]
  } else if s == "::" {
    // the rest of the block, as a data block value
    ctx.push(VBlock(blk[1:].to_owned()))
    blk[blk.length():]
  } else {
    match alias_lookup(s) {
      None => {
        ctx.push(VSymbol(s))
        blk[1:]
      }
      Some((_, name)) =>
        match ctx.env.get(name) {
          Some(VFunction(_)) => form_call_by_name(blk[1:], ctx, name)
          _ => {
            // constant alias (null, infinite, any)
            ctx.push(ctx.env.get(name).unwrap_or(VNull))
            eval_infix_tail(blk[1:], ctx)
          }
        }
    }
  }
}

///|
/// Form a call for a word at the start of `blk`. If `piped`, the top of
/// the stack (the previous expression's value) is the first argument.
fn form_call(
  blk : ArrayView[Value],
  ctx : Ctx,
  piped : Bool,
) -> ArrayView[Value] raise ArturoError {
  match blk {
    [VWord(w), .. rest] => form_call_by_name(rest, ctx, w, piped~)
    _ => raise RuntimeError(message="expected a function name after `|`")
  }
}

///|
fn form_call_by_name(
  blk : ArrayView[Value],
  ctx : Ctx,
  name : String,
  piped? : Bool = false,
) -> ArrayView[Value] raise ArturoError {
  let fun = match ctx.env.get(name) {
    Some(x) => x
    None =>
      raise RuntimeError(message="cannot resolve requested value: \{name}")
  }
  match fun {
    VFunction(_) => ()
    _ =>
      raise RuntimeError(
        message="cannot call a value of type \{fun.type_name()}: \{name}",
      )
  }
  let arity = fun_arity(fun)
  let saved = ctx.pending_attrs
  ctx.pending_attrs = Some([])
  let to_consume = if piped { arity - 1 } else { arity }
  let rest = for rest = blk, consumed = 0; consumed < to_consume; {
    match rest {
      [] => raise RuntimeError(message="not enough arguments for \{name}")
      [VAttribute(_) | VAttributeLabel(_), ..] =>
        // attributes attach to the call without consuming a slot
        continue eval_expr(rest, ctx), consumed
      [_, ..] => continue eval_expr(rest, ctx), consumed + 1
    }
  } nobreak {
    rest
  }
  let attrs = match ctx.pending_attrs {
    Some(x) => x
    None => []
  }
  ctx.pending_attrs = saved
  let args = ctx.pop_args(arity)
  invoke(fun, args, ctx, name, attrs~)
  rest
}

///|
/// Call a function value with given args and attributes; pushes the
/// result.
fn invoke(
  fun : Value,
  args : Array[Value],
  ctx : Ctx,
  name : String,
  attrs? : Array[(String, Value)] = [],
) -> Unit raise ArturoError {
  match fun {
    VFunction(UserFunction(params~, main~, inline=_)) =>
      call_user(params, main, args, ctx, attrs)
    VFunction(BuiltinFunction(name=bname)) => {
      let saved = ctx.current_attrs
      ctx.current_attrs = attrs
      invoke_builtin(bname, ctx, args) catch {
        err => {
          ctx.current_attrs = saved
          raise err
        }
      }
      ctx.current_attrs = saved
    }
    _ =>
      raise RuntimeError(
        message="cannot call value of type \{fun.type_name()}: \{name}",
      )
  }
}

///|
/// Call a user function: bind params with an undo frame, run the body,
/// catch `return`, restore the environment and push the result.
fn call_user(
  params : Array[String],
  main : Array[Value],
  args : Array[Value],
  ctx : Ctx,
  attrs : Array[(String, Value)],
) -> Unit raise ArturoError {
  ctx.env.push_scope()
  for i = 0; i < params.length() && i < args.length(); i = i + 1 {
    ctx.env.set(params[i], args[i])
  }
  let saved_attrs = ctx.current_attrs
  ctx.current_attrs = attrs
  let before = ctx.stack.length()
  let result = try {
    eval_block(main, ctx)
    if ctx.stack.length() > before {
      ctx.pop()
    } else {
      VNull
    }
  } catch {
    ArturoError::ReturnSignal(v) => v
    err => {
      ctx.current_attrs = saved_attrs
      ctx.env.pop_scope()
      raise err
    }
  }
  ctx.current_attrs = saved_attrs
  ctx.env.pop_scope()
  // keep only the result
  while ctx.stack.length() > before {
    ignore(ctx.stack.pop())
  }
  ctx.push(result)
}

///|
/// Path access: `a\b`, `a\0`, `\key` (base `this`).
fn fetch_path(parts : Array[Value], ctx : Ctx) -> Value? {
  if parts.is_empty() {
    return None
  }
  let base = match parts[0] {
    VWord(w) | VLiteral(w) | VLabel(w) => ctx.env.get(w)
    _ => None
  }
  match base {
    None => None
    Some(start) => {
      let mut current = start
      let mut idx = 1
      while idx < parts.length() {
        match (current, parts[idx]) {
          (VBlock(items), VInteger(k)) =>
            if k >= 0 && k < items.length() {
              current = items[k]
            } else {
              return None
            }
          (VBlock(items), VLiteral(k)) => {
            let parsed = @string.parse_int(k) catch { _ => return None }
            if parsed >= 0 && parsed < items.length() {
              current = items[parsed]
            } else {
              return None
            }
          }
          (VDictionary(d), VLiteral(k)) =>
            match d.get(k) {
              Some(v2) => current = v2
              None => return None
            }
          (VString(s), VInteger(k)) =>
            if k >= 0 && k < s.length() {
              current = VChar(Int::unsafe_to_char(s[k].to_int()))
            } else {
              return None
            }
          _ => return None
        }
        idx = idx + 1
      }
      Some(current)
    }
  }
}

///|
/// Assignment through a path: `d\key: value`, `b\0: value`.
/// The base symbol is re-bound to the updated value.
fn set_path(
  parts : Array[Value],
  v : Value,
  ctx : Ctx,
) -> Unit raise ArturoError {
  if parts.length() < 2 {
    raise RuntimeError(message="invalid path for assignment")
  }
  let base_name = match parts[0] {
    VWord(w) | VLiteral(w) | VLabel(w) => w
    _ => ""
  }
  let base = match ctx.env.get(base_name) {
    Some(x) => x
    None => raise RuntimeError(message="cannot resolve path: \{base_name}")
  }
  if parts.length() > 2 {
    raise RuntimeError(
      message="nested path assignment is not supported in this subset",
    )
  }
  match (base, parts[1]) {
    (VBlock(items), VInteger(k)) =>
      if k >= 0 && k < items.length() {
        items[k] = v
      } else {
        raise RuntimeError(message="index out of bounds")
      }
    (VBlock(items), VLiteral(k)) => {
      let parsed = @string.parse_int(k) catch {
        _ => raise RuntimeError(message="invalid index")
      }
      if parsed >= 0 && parsed < items.length() {
        items[parsed] = v
      } else {
        raise RuntimeError(message="index out of bounds")
      }
    }
    (VDictionary(d), VLiteral(k)) =>
      // dictionaries are mutable (like the reference's OrderedTable):
      // assign in place, keeping the original insertion position
      d[k] = v
    _ => raise RuntimeError(message="cannot assign through path")
  }
}

///|
/// Collect the raw items of an arrow body (`->`): one root-level
/// expression, with nested arrows inlined as blocks.
fn collect_arrow(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> (Array[Value], ArrayView[Value]) raise ArturoError {
  let body : Array[Value] = []
  let mut rest = blk
  let mut open = 0 // open argument/pipe slots
  let mut done = false
  while !rest.is_empty() && !done {
    let item = rest[0]
    let after = rest[1:]
    match item {
      VSymbol(s) if s == "->" => {
        let (sub, nxt) = collect_arrow(after, ctx)
        body.push(VBlock(sub))
        if open > 0 {
          open = open - 1
        }
        rest = nxt
      }
      VSymbol(s) if s == "=>" => {
        let (params, sub, nxt) = collect_thick_arrow(after, ctx)
        body.push(params)
        body.push(VBlock(sub))
        if open > 0 {
          open = open - 1
        }
        rest = nxt
      }
      VSymbol(s) if s == "|" => {
        body.push(item)
        open = open + 1
        rest = after
      }
      VWord(w) => {
        body.push(item)
        if w == "true" || w == "false" {
          // a constant word behaves like a terminal
          if !after.is_empty() {
            match after[0] {
              VSymbol(s2) =>
                match alias_lookup(s2) {
                  Some((InfixPrec, name)) => {
                    body.push(after[0])
                    let n = fun_arity(ctx.env.get(name).unwrap_or(VNull))
                    if open > 0 {
                      open = open - 1
                    }
                    open = open + n - 1
                    rest = after[1:]
                  }
                  _ => {
                    if open > 0 {
                      open = open - 1
                    } else {
                      done = true
                    }
                    rest = after
                  }
                }
              _ => {
                if open > 0 {
                  open = open - 1
                } else {
                  done = true
                }
                rest = after
              }
            }
          } else if open > 0 {
            open = open - 1
            rest = after
          } else {
            done = true
            rest = after
          }
        } else {
          match ctx.env.get(w) {
            Some(VFunction(fun)) => {
              if open > 0 {
                open = open - 1 + fun_arity(VFunction(fun))
              } else {
                open = fun_arity(VFunction(fun))
              }
              rest = after
            }
            _ =>
              if !after.is_empty() {
                match after[0] {
                  VSymbol(s2) =>
                    match alias_lookup(s2) {
                      Some((InfixPrec, name)) => {
                        body.push(after[0])
                        let n = fun_arity(ctx.env.get(name).unwrap_or(VNull))
                        if open > 0 {
                          open = open - 1
                        }
                        open = open + n - 1
                        rest = after[1:]
                      }
                      _ => {
                        if open > 0 {
                          open = open - 1
                        } else {
                          done = true
                        }
                        rest = after
                      }
                    }
                  _ => {
                    if open > 0 {
                      open = open - 1
                    } else {
                      done = true
                    }
                    rest = after
                  }
                }
              } else if open > 0 {
                open = open - 1
                rest = after
              } else {
                done = true
                rest = after
              }
          }
        }
      }
      VLabel(_) | VPathLabel(_) => {
        body.push(item)
        open = open + 1
        rest = after
      }
      VAttribute(_) => {
        body.push(item)
        rest = after
      }
      VAttributeLabel(_) => {
        body.push(item)
        open = open + 1
        rest = after
      }
      VSymbol(s) =>
        match alias_lookup(s) {
          Some((InfixPrec, name)) => {
            // an infix symbol at expression start behaves like a
            // prefix call (e.g. `-5` starts a `sub` call)
            body.push(item)
            let n = fun_arity(ctx.env.get(name).unwrap_or(VNull))
            if open > 0 {
              open = open - 1 + n
            } else {
              open = n
            }
            rest = after
          }
          Some((PrefixPrec, name)) =>
            match ctx.env.get(name) {
              Some(VFunction(fun)) => {
                body.push(item)
                if open > 0 {
                  open = open - 1 + fun_arity(VFunction(fun))
                } else {
                  open = fun_arity(VFunction(fun))
                }
                rest = after
              }
              _ => {
                // constant symbol
                body.push(item)
                if open > 0 {
                  open = open - 1
                } else {
                  done = true
                }
                rest = after
              }
            }
          None => {
            body.push(item)
            if open > 0 {
              open = open - 1
            } else {
              done = true
            }
            rest = after
          }
        }
      _ => {
        body.push(item)
        if !after.is_empty() {
          match after[0] {
            VSymbol(s2) =>
              match alias_lookup(s2) {
                Some((InfixPrec, name)) => {
                  // the terminal is the operator's first argument
                  body.push(after[0])
                  let n = fun_arity(ctx.env.get(name).unwrap_or(VNull))
                  if open > 0 {
                    open = open - 1
                  }
                  open = open + n - 1
                  rest = after[1:]
                }
                _ => {
                  if open > 0 {
                    open = open - 1
                  } else {
                    done = true
                  }
                  rest = after
                }
              }
            _ => {
              if open > 0 {
                open = open - 1
              } else {
                done = true
              }
              rest = after
            }
          }
        } else if open > 0 {
          open = open - 1
          rest = after
        } else {
          done = true
          rest = after
        }
      }
    }
    if open == 0 && !rest.is_empty() {
      // a completed expression at the root ends the arrow body
      // (pipes and trailing operators belong to the outer statement)
      done = true
    }
  }
  (body, rest)
}

///|
/// Collect a thick arrow (`=>`): two values — params (a literal or a
/// block) and body (a block) — with `&` placeholders replaced by
/// sequential `_0`, `_1`, ... words.
fn collect_thick_arrow(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> (Value, Array[Value], ArrayView[Value]) {
  match blk {
    [] => (VBlock([]), [], [])
    [VBlock(items), .. rest] => {
      let names : Ref[Array[String]] = Ref([])
      let sub : Array[Value] = []
      for item in items {
        sub.push(replace_ampersands(item, names))
      }
      let args = names.val
      if args.length() == 1 {
        (VLiteral(args[0]), sub, rest)
      } else {
        (VBlock(args.map(a => VLiteral(a))), sub, rest)
      }
    }
    [VWord(w), .. rest] =>
      match ctx.env.get(w) {
        Some(VFunction(fun)) => {
          let n = fun_arity(VFunction(fun))
          let args : Array[String] = []
          let sub : Array[Value] = [VWord(w)]
          for j in 0..<n {
            let name = "_\{j}"
            args.push(name)
            sub.push(VWord(name))
          }
          (VBlock(args.map(a => VLiteral(a))), sub, rest)
        }
        _ => (VBlock([]), [VWord(w)], rest)
      }
    [item, .. rest] => (VBlock([]), [item], rest)
  }
}

///|
fn replace_ampersands(v : Value, names : Ref[Array[String]]) -> Value {
  match v {
    VSymbol(s) if s == "&" => {
      let name = "_\{names.val.length()}"
      names.val.push(name)
      VWord(name)
    }
    VBlock(items) => VBlock(items.map(it => replace_ampersands(it, names)))
    _ => v
  }
}

///|
/// Evaluate a block as a dictionary: labels become key/value pairs.
/// Re-assigning the same key replaces the previous value while keeping
/// its original insertion position (MoonBit's `Map` is a linked hash
/// map, exactly like the reference's `OrderedTable`).
fn exec_dictionary(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> Map[String, Value] raise ArturoError {
  let out : Map[String, Value] = Map([])
  for rest = blk; rest is [_, ..]; {
    match rest[0] {
      VLabel(name) => {
        let rest2 = eval_statement(rest[1:], ctx)
        let v = ctx.pop_or_null()
        out[name] = v
        continue rest2
      }
      _ => {
        let rest2 = eval_statement(rest, ctx)
        ignore(ctx.stack.pop())
        continue rest2
      }
    }
  } nobreak {
    ()
  }
  out
  // let mut rest = blk
  // while !rest.is_empty() {
  //   match rest[0] {
  //     VLabel(name) => {
  //       rest = eval_statement(rest[1:], ctx)
  //       let v = ctx.pop_or_null()
  //       out[name] = v
  //     }
  //     _ => {
  //       rest = eval_statement(rest, ctx)
  //       ignore(ctx.stack.pop())
  //     }
  //   }
  // }
}

///|
fn attr_get(attrs : Array[(String, Value)], name : String) -> Value? {
  match attrs.iter().find_first(kv => kv.0 == name) {
    Some(kv) => Some(kv.1)
    None => None
  }
}

///|
fn attr_has(attrs : Array[(String, Value)], name : String) -> Bool {
  attrs.iter().any(kv => kv.0 == name)
}

///|
/// Evaluate a block and return the values it pushed (in order),
/// without leaving them on the stack.
fn eval_block_values(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> Array[Value] raise ArturoError {
  let before = ctx.stack.length()
  eval_block(blk, ctx)
  let out : Array[Value] = []
  while ctx.stack.length() > before {
    out.push(ctx.pop())
  }
  arr_reverse(out)
  out
}

///|
fn eval_block_last(
  blk : ArrayView[Value],
  ctx : Ctx,
) -> Value raise ArturoError {
  let vals = eval_block_values(blk, ctx)
  if !vals.is_empty() {
    vals[vals.length() - 1]
  } else {
    VNull
  }
}
