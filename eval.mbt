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
fn Env::new() -> Env {
  { syms: Map([]), frames: [] }
}

///|
fn Env::set(self : Env, name : String, v : Value) -> Unit {
  if self.frames.length() > 0 {
    let top = self.frames[self.frames.length() - 1]
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
  if self.frames.length() > 0 {
    let top = self.frames[self.frames.length() - 1]
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
  let frame = self.frames.pop().unwrap_or(Map([]))
  for name, prev in frame {
    match prev {
      Some(v) => self.syms[name] = v
      None => self.syms.remove(name)
    }
  }
}

///|
/// The evaluation context: value stack, environment, captured output,
/// in-flight call attributes, and the current line (for errors).
priv struct Ctx {
  stack : Array[Value]
  env : Env
  out : StringBuilder
  pending_attrs : Ref[Array[(String, Value)]?]
  current_attrs : Ref[Array[(String, Value)]]
  line : Ref[Int]
}

///|
fn Ctx::new() -> Ctx {
  {
    stack: [],
    env: Env::new(),
    out: StringBuilder(),
    pending_attrs: Ref(None),
    current_attrs: Ref([]),
    line: Ref(1),
  }
}

///|
fn Ctx::with_env(env : Env) -> Ctx {
  {
    stack: [],
    env,
    out: StringBuilder(),
    pending_attrs: Ref(None),
    current_attrs: Ref([]),
    line: Ref(1),
  }
}

///|
/// Runtime error helpers.
fn rt_err(ctx : Ctx, msg : String) -> ArturoError {
  ArturoError::RuntimeError(line=ctx.line.val, message=msg)
}

///|
fn Ctx::push(self : Ctx, v : Value) -> Unit {
  self.stack.push(v)
}

///|
fn Ctx::pop(self : Ctx) -> Value raise ArturoError {
  match self.stack.pop() {
    Some(v) => v
    None => raise rt_err(self, "stack underflow")
  }
}

///|
fn pop_or_null(ctx : Ctx) -> Value {
  match ctx.stack.pop() {
    Some(v) => v
    None => VNull
  }
}

///|
fn opt_or(v : Value?, d : Value) -> Value {
  match v {
    Some(x) => x
    None => d
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
    "∈" => Some((InfixPrec, "in?"))
    "∧" => Some((InfixPrec, "and?"))
    "∨" => Some((InfixPrec, "or?"))
    "⊻" => Some((InfixPrec, "xor?"))
    "¬" => Some((PrefixPrec, "not?"))
    "∅" => Some((PrefixPrec, "null"))
    "_" => Some((PrefixPrec, "any"))
    "∞" => Some((PrefixPrec, "infinite"))
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
    VFunction(UserFunction(params~, main=_, inline=_)) => params.length()
    VFunction(BuiltinFunction(name~)) => builtin_arity(name)
    _ => 0
  }
}

///|
/// Evaluate a whole block (statement by statement).
fn eval_block(blk : Array[Value], ctx : Ctx) -> Unit raise ArturoError {
  let mut i = 0
  let n = blk.length()
  while i < n {
    i = eval_statement(blk, i, ctx)
  }
}

///|
/// Evaluate one statement: an expression plus any trailing pipe chain.
/// Pushes exactly the chain's final value (pipes are statement-level,
/// exactly like `addPotentialTrailingPipe` in `ast.nim`).
fn eval_statement(
  blk : Array[Value],
  i : Int,
  ctx : Ctx,
) -> Int raise ArturoError {
  let mut idx = eval_expr(blk, i, ctx)
  let n = blk.length()
  while idx < n && blk[idx] is VSymbol(s) && s == "|" {
    idx = idx + 1
    if idx >= n {
      break
    }
    match blk[idx] {
      VWord(_) => idx = form_call(blk, idx, ctx, true)
      _ => {
        // unresolved pipe: push the symbol itself as a constant
        ctx.push(VSymbol("|"))
        idx = idx + 1
      }
    }
  }
  idx
}

///|
/// Evaluate one expression starting at `i`; pushes its value(s) on the
/// stack and returns the index after the expression.
fn eval_expr(blk : Array[Value], i : Int, ctx : Ctx) -> Int raise ArturoError {
  let item = blk[i]
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
      eval_infix_tail(blk, i + 1, ctx)
    }
    VInline(inner) => {
      eval_block(inner, ctx)
      eval_infix_tail(blk, i + 1, ctx)
    }
    VSymbol(s) => eval_symbol(blk, i, ctx, s)
    VWord(w) =>
      if w == "true" {
        ctx.push(VLogical(true))
        eval_infix_tail(blk, i + 1, ctx)
      } else if w == "false" {
        ctx.push(VLogical(false))
        eval_infix_tail(blk, i + 1, ctx)
      } else {
        match ctx.env.get(w) {
          Some(VFunction(_)) => form_call(blk, i, ctx, false)
          Some(v) => {
            ctx.push(v)
            eval_infix_tail(blk, i + 1, ctx)
          }
          None => raise rt_err(ctx, "cannot resolve requested value: " + w)
        }
      }
    VLabel(name) => {
      // store: its value is a full statement (pipes allowed)
      let idx = eval_statement(blk, i + 1, ctx)
      let v = pop_or_null(ctx)
      ctx.env.set(name, v)
      idx
    }
    VPathLabel(parts) => {
      let idx = eval_statement(blk, i + 1, ctx)
      let v = pop_or_null(ctx)
      set_path(parts, v, ctx)
      idx
    }
    VAttribute(name) => {
      match ctx.pending_attrs.val {
        Some(attrs) => attrs.push((name, VLogical(true)))
        None => ()
      }
      eval_infix_tail(blk, i + 1, ctx)
    }
    VAttributeLabel(name) => {
      let idx = eval_expr(blk, i + 1, ctx)
      let v = pop_or_null(ctx)
      match ctx.pending_attrs.val {
        Some(attrs) => attrs.push((name, v))
        None => ()
      }
      eval_infix_tail(blk, idx, ctx)
    }
    VPath(parts) => {
      let v = match fetch_path(parts, ctx) {
        Some(x) => x
        None =>
          raise rt_err(ctx, "cannot resolve path: " + show_value(VPath(parts)))
      }
      ctx.push(v)
      eval_infix_tail(blk, i + 1, ctx)
    }
  }
}

///|
/// After a terminal, check whether the next item is an infix operator
/// (or a pipe — handled by `eval_statement`); if so, form the operator
/// call with the pushed value as its first argument.
fn eval_infix_tail(
  blk : Array[Value],
  i : Int,
  ctx : Ctx,
) -> Int raise ArturoError {
  if i < blk.length() {
    match blk[i] {
      VSymbol(s) =>
        match alias_lookup(s) {
          Some((InfixPrec, name)) => {
            let fun = match ctx.env.get(name) {
              Some(x) => x
              None =>
                raise rt_err(ctx, "cannot resolve requested value: " + name)
            }
            let arity = fun_arity(fun)
            let saved = ctx.pending_attrs.val
            ctx.pending_attrs.val = Some([])
            let mut idx = i + 1
            let to_consume = arity - 1
            let mut consumed = 0
            while consumed < to_consume {
              if idx >= blk.length() {
                raise rt_err(ctx, "not enough arguments for operator " + s)
              }
              if blk[idx] is VAttribute(_) || blk[idx] is VAttributeLabel(_) {
                // attributes attach to the call without consuming a slot
                idx = eval_expr(blk, idx, ctx)
              } else {
                idx = eval_expr(blk, idx, ctx)
                consumed = consumed + 1
              }
            }
            let attrs = match ctx.pending_attrs.val {
              Some(x) => x
              None => []
            }
            ctx.pending_attrs.val = saved
            let args = pop_args(ctx, arity)
            invoke(fun, args, ctx, s, attrs~)
            idx
          }
          _ => i
        }
      _ => i
    }
  } else {
    i
  }
}

///|
/// Pop `n` values and return them in original order.
fn pop_args(ctx : Ctx, n : Int) -> Array[Value] raise ArturoError {
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
  blk : Array[Value],
  i : Int,
  ctx : Ctx,
  s : String,
) -> Int raise ArturoError {
  if s == "->" {
    let (body, idx) = collect_arrow(blk, i + 1, ctx)
    ctx.push(VBlock(body))
    idx
  } else if s == "=>" {
    let (params, sub, idx) = collect_thick_arrow(blk, i + 1, ctx)
    ctx.push(params)
    ctx.push(VBlock(sub))
    idx
  } else if s == "!" {
    // execute the rest of the block
    let rest2 : Array[Value] = blk[i + 1:].to_owned()
    eval_block(rest2, ctx)
    blk.length()
  } else if s == "::" {
    // the rest of the block, as a data block value
    let rest3 : Array[Value] = blk[i + 1:].to_owned()
    ctx.push(VBlock(rest3))
    blk.length()
  } else {
    match alias_lookup(s) {
      None => {
        ctx.push(VSymbol(s))
        i + 1
      }
      Some((_, name)) =>
        match ctx.env.get(name) {
          Some(VFunction(_)) => form_call_by_name(blk, i, ctx, name)
          _ => {
            // constant alias (null, infinite, any)
            ctx.push(opt_or(ctx.env.get(name), VNull))
            eval_infix_tail(blk, i + 1, ctx)
          }
        }
    }
  }
}

///|
/// Form a call for a word at `i`. If `piped`, the top of the stack
/// (the previous expression's value) is the first argument.
fn form_call(
  blk : Array[Value],
  i : Int,
  ctx : Ctx,
  piped : Bool,
) -> Int raise ArturoError {
  match blk[i] {
    VWord(w) => form_call_by_name(blk, i, ctx, w, piped~)
    _ => raise rt_err(ctx, "expected a function name after `|`")
  }
}

///|
fn form_call_by_name(
  blk : Array[Value],
  i : Int,
  ctx : Ctx,
  name : String,
  piped? : Bool = false,
) -> Int raise ArturoError {
  let fun = match ctx.env.get(name) {
    Some(x) => x
    None => raise rt_err(ctx, "cannot resolve requested value: " + name)
  }
  match fun {
    VFunction(_) => ()
    _ =>
      raise rt_err(
        ctx,
        "cannot call a value of type " + type_name(fun) + ": " + name,
      )
  }
  let arity = fun_arity(fun)
  let saved = ctx.pending_attrs.val
  ctx.pending_attrs.val = Some([])
  let mut idx = i + 1
  let to_consume = if piped { arity - 1 } else { arity }
  let mut consumed = 0
  while consumed < to_consume {
    if idx >= blk.length() {
      raise rt_err(ctx, "not enough arguments for " + name)
    }
    if blk[idx] is VAttribute(_) || blk[idx] is VAttributeLabel(_) {
      // attributes attach to the call without consuming a slot
      idx = eval_expr(blk, idx, ctx)
    } else {
      idx = eval_expr(blk, idx, ctx)
      consumed = consumed + 1
    }
  }
  let attrs = match ctx.pending_attrs.val {
    Some(x) => x
    None => []
  }
  ctx.pending_attrs.val = saved
  let args = pop_args(ctx, arity)
  invoke(fun, args, ctx, name, attrs~)
  idx
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
      let saved = ctx.current_attrs.val
      ctx.current_attrs.val = attrs
      invoke_builtin(bname, ctx, args) catch {
        err => {
          ctx.current_attrs.val = saved
          raise err
        }
      }
      ctx.current_attrs.val = saved
    }
    _ =>
      raise rt_err(
        ctx,
        "cannot call value of type " + type_name(fun) + ": " + name,
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
  let mut i = 0
  while i < params.length() && i < args.length() {
    ctx.env.set(params[i], args[i])
    i = i + 1
  }
  let saved_attrs = ctx.current_attrs.val
  ctx.current_attrs.val = attrs
  let before = ctx.stack.length()
  let mut result = VNull
  try {
    eval_block(main, ctx)
    if ctx.stack.length() > before {
      result = ctx.pop()
    }
  } catch {
    ArturoError::ReturnSignal(v) => result = v
    err => {
      ctx.current_attrs.val = saved_attrs
      ctx.env.pop_scope()
      raise err
    }
  }
  ctx.current_attrs.val = saved_attrs
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
  if parts.length() == 0 {
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
            match d.iter().find_first(fn(kv) { kv.0 == k }) {
              Some(kv) => current = kv.1
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
    raise rt_err(ctx, "invalid path for assignment")
  }
  let base_name = match parts[0] {
    VWord(w) | VLiteral(w) | VLabel(w) => w
    _ => ""
  }
  let base = match ctx.env.get(base_name) {
    Some(x) => x
    None => raise rt_err(ctx, "cannot resolve path: " + base_name)
  }
  if parts.length() > 2 {
    raise rt_err(ctx, "nested path assignment is not supported in this subset")
  }
  match (base, parts[1]) {
    (VBlock(items), VInteger(k)) =>
      if k >= 0 && k < items.length() {
        items[k] = v
      } else {
        raise rt_err(ctx, "index out of bounds")
      }
    (VBlock(items), VLiteral(k)) => {
      let parsed = @string.parse_int(k) catch {
        _ => raise rt_err(ctx, "invalid index")
      }
      if parsed >= 0 && parsed < items.length() {
        items[parsed] = v
      } else {
        raise rt_err(ctx, "index out of bounds")
      }
    }
    (VDictionary(d), VLiteral(k)) => {
      let nd : Array[(String, Value)] = []
      let mut inserted = false
      for item in d {
        if item.0 == k {
          nd.push((k, v))
          inserted = true
        } else {
          nd.push(item)
        }
      }
      if !inserted {
        nd.push((k, v))
      }
      ctx.env.set(base_name, VDictionary(nd))
    }
    _ => raise rt_err(ctx, "cannot assign through path")
  }
}

///|
/// Collect the raw items of an arrow body (`->`): one root-level
/// expression, with nested arrows inlined as blocks.
fn collect_arrow(
  blk : Array[Value],
  i : Int,
  ctx : Ctx,
) -> (Array[Value], Int) raise ArturoError {
  let body : Array[Value] = []
  let mut idx = i
  let mut open = 0 // open argument/pipe slots
  let mut done = false
  while idx < blk.length() && !done {
    let item = blk[idx]
    match item {
      VSymbol(s) if s == "->" => {
        let (sub, nxt) = collect_arrow(blk, idx + 1, ctx)
        body.push(VBlock(sub))
        if open > 0 {
          open = open - 1
        }
        idx = nxt
      }
      VSymbol(s) if s == "=>" => {
        let (params, sub, nxt) = collect_thick_arrow(blk, idx + 1, ctx)
        body.push(params)
        body.push(VBlock(sub))
        if open > 0 {
          open = open - 1
        }
        idx = nxt
      }
      VSymbol(s) if s == "|" => {
        body.push(item)
        open = open + 1
        idx = idx + 1
      }
      VWord(w) => {
        body.push(item)
        if w == "true" || w == "false" {
          // a constant word behaves like a terminal
          if idx + 1 < blk.length() {
            match blk[idx + 1] {
              VSymbol(s2) =>
                match alias_lookup(s2) {
                  Some((InfixPrec, name)) => {
                    body.push(blk[idx + 1])
                    let n = fun_arity(opt_or(ctx.env.get(name), VNull))
                    if open > 0 {
                      open = open - 1
                    }
                    open = open + n - 1
                    idx = idx + 1
                  }
                  _ => if open > 0 { open = open - 1 } else { done = true }
                }
              _ => if open > 0 { open = open - 1 } else { done = true }
            }
          } else if open > 0 {
            open = open - 1
          } else {
            done = true
          }
        } else {
          match ctx.env.get(w) {
            Some(VFunction(fun)) =>
              if open > 0 {
                open = open - 1 + fun_arity(VFunction(fun))
              } else {
                open = fun_arity(VFunction(fun))
              }
            _ =>
              if idx + 1 < blk.length() {
                match blk[idx + 1] {
                  VSymbol(s2) =>
                    match alias_lookup(s2) {
                      Some((InfixPrec, name)) => {
                        body.push(blk[idx + 1])
                        let n = fun_arity(opt_or(ctx.env.get(name), VNull))
                        if open > 0 {
                          open = open - 1
                        }
                        open = open + n - 1
                        idx = idx + 1
                      }
                      _ => if open > 0 { open = open - 1 } else { done = true }
                    }
                  _ => if open > 0 { open = open - 1 } else { done = true }
                }
              } else if open > 0 {
                open = open - 1
              } else {
                done = true
              }
          }
        }
        idx = idx + 1
      }
      VLabel(_) | VPathLabel(_) => {
        body.push(item)
        open = open + 1
        idx = idx + 1
      }
      VAttribute(_) => {
        body.push(item)
        idx = idx + 1
      }
      VAttributeLabel(_) => {
        body.push(item)
        open = open + 1
        idx = idx + 1
      }
      VSymbol(s) =>
        match alias_lookup(s) {
          Some((InfixPrec, name)) => {
            // an infix symbol at expression start behaves like a
            // prefix call (e.g. `-5` starts a `sub` call)
            body.push(item)
            let n = fun_arity(opt_or(ctx.env.get(name), VNull))
            if open > 0 {
              open = open - 1 + n
            } else {
              open = n
            }
            idx = idx + 1
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
                idx = idx + 1
              }
              _ => {
                // constant symbol
                body.push(item)
                if open > 0 {
                  open = open - 1
                } else {
                  done = true
                }
                idx = idx + 1
              }
            }
          None => {
            body.push(item)
            if open > 0 {
              open = open - 1
            } else {
              done = true
            }
            idx = idx + 1
          }
        }
      _ => {
        body.push(item)
        if idx + 1 < blk.length() {
          match blk[idx + 1] {
            VSymbol(s2) =>
              match alias_lookup(s2) {
                Some((InfixPrec, name)) => {
                  // the terminal is the operator's first argument
                  body.push(blk[idx + 1])
                  let n = fun_arity(opt_or(ctx.env.get(name), VNull))
                  if open > 0 {
                    open = open - 1
                  }
                  open = open + n - 1
                  idx = idx + 1
                }
                _ => if open > 0 { open = open - 1 } else { done = true }
              }
            _ => if open > 0 { open = open - 1 } else { done = true }
          }
        } else if open > 0 {
          open = open - 1
        } else {
          done = true
        }
        idx = idx + 1
      }
    }
    if open == 0 && idx < blk.length() {
      // a completed expression at the root ends the arrow body
      // (pipes and trailing operators belong to the outer statement)
      done = true
    }
  }
  (body, idx)
}

///|
/// Collect a thick arrow (`=>`): two values — params (a literal or a
/// block) and body (a block) — with `&` placeholders replaced by
/// sequential `_0`, `_1`, ... words.
fn collect_thick_arrow(
  blk : Array[Value],
  i : Int,
  ctx : Ctx,
) -> (Value, Array[Value], Int) {
  if i >= blk.length() {
    return (VBlock([]), [], i)
  }
  match blk[i] {
    VBlock(items) => {
      let names : Ref[Array[String]] = Ref([])
      let sub : Array[Value] = []
      for item in items {
        sub.push(replace_ampersands(item, names))
      }
      let args = names.val
      if args.length() == 1 {
        (VLiteral(args[0]), sub, i + 1)
      } else {
        (VBlock(args.map(fn(a) { VLiteral(a) })), sub, i + 1)
      }
    }
    VWord(w) =>
      match ctx.env.get(w) {
        Some(VFunction(fun)) => {
          let n = fun_arity(VFunction(fun))
          let args : Array[String] = []
          let sub : Array[Value] = [VWord(w)]
          for j in 0..<n {
            let name = "_" + j.to_string()
            args.push(name)
            sub.push(VWord(name))
          }
          (VBlock(args.map(fn(a) { VLiteral(a) })), sub, i + 1)
        }
        _ => (VBlock([]), [blk[i]], i + 1)
      }
    _ => (VBlock([]), [blk[i]], i + 1)
  }
}

///|
fn replace_ampersands(v : Value, names : Ref[Array[String]]) -> Value {
  match v {
    VSymbol(s) if s == "&" => {
      let name = "_" + names.val.length().to_string()
      names.val.push(name)
      VWord(name)
    }
    VBlock(items) => VBlock(items.map(fn(it) { replace_ampersands(it, names) }))
    _ => v
  }
}

///|
/// Evaluate a block as a dictionary: labels become key/value pairs.
fn exec_dictionary(
  blk : Array[Value],
  ctx : Ctx,
) -> Array[(String, Value)] raise ArturoError {
  let out : Array[(String, Value)] = []
  let mut i = 0
  let n = blk.length()
  while i < n {
    match blk[i] {
      VLabel(name) => {
        let idx2 = eval_statement(blk, i + 1, ctx)
        let v = pop_or_null(ctx)
        out.push((name, v))
        i = idx2
      }
      _ => {
        let idx3 = eval_statement(blk, i, ctx)
        ignore(ctx.stack.pop())
        i = idx3
      }
    }
  }
  out
}

///|
fn attr_get(attrs : Array[(String, Value)], name : String) -> Value? {
  let mut found : Value? = None
  for kv in attrs {
    if kv.0 == name {
      found = Some(kv.1)
      break
    }
  }
  found
}

///|
fn attr_has(attrs : Array[(String, Value)], name : String) -> Bool {
  let mut found = false
  for kv in attrs {
    if kv.0 == name {
      found = true
      break
    }
  }
  found
}

///|
/// Evaluate a block and return the values it pushed (in order),
/// without leaving them on the stack.
fn eval_block_values(
  blk : Array[Value],
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
fn eval_block_last(blk : Array[Value], ctx : Ctx) -> Value raise ArturoError {
  let vals = eval_block_values(blk, ctx)
  if vals.length() > 0 {
    vals[vals.length() - 1]
  } else {
    VNull
  }
}
