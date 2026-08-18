///|
/// Data builtins: collections, strings, numbers, iterators and type
/// functions — ports of `Collections.nim`, `Strings.nim`, `Numbers.nim`,
/// `Iterators.nim` and `Types.nim` (subset).

///|
/// Iterable items for loop/map/select/filter: blocks are raw, ranges
/// are expanded, integers become `1..n`, strings become chars and
/// dictionaries become flattened key/value pairs.
fn iterable_items(v : Value) -> Array[Value] raise ArturoError {
  match v {
    VBlock(items) => items
    VInline(items) => items
    VRange(r) => r.values()
    VInteger(n) => {
      let out : Array[Value] = []
      for i in 1..<=n {
        out.push(VInteger(i))
      }
      out
    }
    VString(s) => {
      let out : Array[Value] = []
      for c in s {
        out.push(VChar(c))
      }
      out
    }
    VDictionary(d) => {
      let out : Array[Value] = []
      for kv in d.iter() {
        out.push(VString(kv.0))
        out.push(kv.1)
      }
      out
    }
    VChar(c) => [VChar(c)]
    _ => []
  }
}

///|
fn RangeVal::values(r : RangeVal) -> Array[Value] raise ArturoError {
  let out : Array[Value] = []
  if r.infinite {
    raise RuntimeError(message="cannot iterate over an infinite range")
  }
  let step = if r.forward { r.step } else { -r.step }
  let mut v = r.start
  if r.forward {
    while v <= r.stop {
      out.push(
        if r.numeric {
          VInteger(v)
        } else {
          VChar(Int::unsafe_to_char(v))
        },
      )
      v = v + step
    }
  } else {
    while v >= r.stop {
      out.push(
        if r.numeric {
          VInteger(v)
        } else {
          VChar(Int::unsafe_to_char(v))
        },
      )
      v = v + step
    }
  }
  out
}

///|
/// Param names for iterators: literal → one var; block → its words.
fn iter_params(params : Value) -> Array[String] {
  match params {
    VLiteral(s) => [s]
    VBlock(items) =>
      items.filter_map(x => {
        match x {
          VWord(w) | VLiteral(w) => Some(w)
          _ => None
        }
      })
    VNull => []
    _ => []
  }
}

///|
/// Run `run` once per group of items, binding `names` (an optional
/// leading index var gets the run counter). Loop vars are restored
/// after the iteration (leakless blocks).
fn iterate_groups(
  collection : Value,
  params : Value,
  ctx : Ctx,
  with_index : Value?,
  run : (Array[Value], Ctx) -> Unit raise ArturoError,
) -> Unit raise ArturoError {
  let items = iterable_items(collection)
  let names = iter_params(params)
  let idx_name = match with_index {
    Some(VLiteral(s)) | Some(VWord(s)) => Some(s)
    _ => None
  }
  let loop_step = if names.is_empty() { 1 } else { names.length() }
  // save & restore loop variables
  let saved : Array[(String, Value?)] = names.map(n => (n, ctx.env.get(n)))
  let mut i = 0
  let mut run_no = 0
  while i < items.length() {
    match idx_name {
      Some(name) => ctx.env.set(name, VInteger(run_no))
      None => ()
    }
    let group : Array[Value] = []
    for j in 0..<loop_step {
      if i + j < items.length() {
        group.push(items[i + j])
      } else {
        group.push(VNull)
      }
    }
    for j in 0..<names.length() {
      if j < group.length() {
        ctx.env.set(names[j], group[j])
      }
    }
    run(group, ctx) catch {
      ArturoError::BreakSignal => i = items.length()
      ArturoError::ContinueSignal => ()
      err => raise err
    }
    i = i + loop_step
    run_no = run_no + 1
  }
  for kv in saved {
    match kv.1 {
      Some(v) => ctx.env.set(kv.0, v)
      None => ctx.env.remove(kv.0)
    }
  }
}

///|
/// Evaluate an action block, returning the last value it pushed.
fn action_result(action : Value, ctx : Ctx) -> Value raise ArturoError {
  match action {
    VBlock(blk) => {
      let before = ctx.stack.length()
      eval_block(blk, ctx)
      let r = ctx.pop_or_null()
      while ctx.stack.length() > before {
        ignore(ctx.stack.pop())
      }
      r
    }
    VInline(blk) => {
      let before = ctx.stack.length()
      eval_block(blk, ctx)
      let r = ctx.pop_or_null()
      while ctx.stack.length() > before {
        ignore(ctx.stack.pop())
      }
      r
    }
    v => v
  }
}

///|
fn Ctx::with_attr(ctx : Ctx) -> Value? {
  attr_get(ctx.current_attrs, "with")
}

///|
/// `loop collection params action`.
fn b_loop(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  iterate_groups(args[0], args[1], ctx, ctx.with_attr(), (_group, ctx2) => {
    match args[2] {
      VBlock(blk) => {
        eval_block(blk, ctx2)
        ignore(ctx2.stack.pop())
      }
      VInline(blk) => {
        eval_block(blk, ctx2)
        ignore(ctx2.stack.pop())
      }
      _ => ()
    }
  })
}

///|
/// `map collection params action`.
fn b_map(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let res : Array[Value] = []
  iterate_groups(args[0], args[1], ctx, ctx.with_attr(), (_group, ctx2) => {
    res.push(action_result(args[2], ctx2))
  })
  ctx.push(VBlock(res))
}

///|
/// `select collection params condition` — keep items where the
/// condition holds; `.first: n` / `.last: n` cap the number of kept
/// items.
fn b_select(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let first_attr = attr_get(ctx.current_attrs, "first")
  let last_attr = attr_get(ctx.current_attrs, "last")
  let res : Array[Value] = []
  iterate_groups(args[0], args[1], ctx, ctx.with_attr(), (group, ctx2) => {
    let v = action_result(args[2], ctx2)
    if v.is_truthy() {
      res.push(group[0])
    }
  })
  match first_attr {
    Some(VLogical(true)) => ctx.push(VBlock(take_items(res, 1)))
    Some(VInteger(n)) => ctx.push(VBlock(take_items(res, n)))
    _ =>
      match last_attr {
        Some(VLogical(true)) =>
          ctx.push(VBlock(take_items(res, res.length() - 1)))
        Some(VInteger(n)) => ctx.push(VBlock(take_items(res, res.length() - n)))
        _ => ctx.push(VBlock(res))
      }
  }
}

///|
/// `filter collection params condition` — omit items where the
/// condition holds.
fn b_filter(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let res : Array[Value] = []
  iterate_groups(args[0], args[1], ctx, ctx.with_attr(), (group, ctx2) => {
    let v = action_result(args[2], ctx2)
    if !v.is_truthy() {
      res.push(group[0])
    }
  })
  ctx.push(VBlock(res))
}

///|
/// `every? collection params condition`.
fn b_everyq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let mut ok = true
  iterate_groups(args[0], args[1], ctx, ctx.with_attr(), (_group, ctx2) => {
    let v = action_result(args[2], ctx2)
    if !v.is_truthy() {
      ok = false
      raise ArturoError::BreakSignal
    }
  })
  ctx.push(VLogical(ok))
}

///|
/// `some? collection params condition`.
fn b_someq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let mut found = false
  iterate_groups(args[0], args[1], ctx, ctx.with_attr(), (_group, ctx2) => {
    let v = action_result(args[2], ctx2)
    if v.is_truthy() {
      found = true
      raise ArturoError::BreakSignal
    }
  })
  ctx.push(VLogical(found))
}

///|
/// `fold collection params action` — left fold with a rolling
/// accumulator bound to the last parameter.
fn b_fold(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let items = iterable_items(args[0])
  let names = iter_params(args[1])
  let seed = attr_get(ctx.current_attrs, "seed")
  let mut acc = match seed {
    Some(v) => v
    None => if !items.is_empty() { items[0] } else { VNull }
  }
  let start = match seed {
    Some(_) => 0
    None => 1
  }
  let loop_step = if names.length() > 1 { names.length() - 1 } else { 1 }
  let mut i = start
  while i < items.length() {
    for j in 0..<names.length() {
      if j == names.length() - 1 {
        ctx.env.set(names[j], acc)
      } else if i + j < items.length() {
        ctx.env.set(names[j], items[i + j])
      }
    }
    acc = action_result(args[2], ctx)
    i = i + loop_step
  }
  ctx.push(acc)
}

///|
/// `size value`.
fn b_size(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VString(s) => ctx.push(VInteger(s.length()))
    VBlock(items) => ctx.push(VInteger(items.length()))
    VInline(items) => ctx.push(VInteger(items.length()))
    VDictionary(d) => ctx.push(VInteger(d.length()))
    VRange(r) =>
      if r.infinite {
        ctx.push(VInteger(0))
      } else {
        ctx.push(VInteger(r.len()))
      }
    VChar(_) => ctx.push(VInteger(1))
    VNull => ctx.push(VInteger(0))
    _ =>
      raise RuntimeError(
        message="wrong argument type: expected collection, got \{args[0].type_name()}",
      )
  }
}

///|
fn RangeVal::len(self : RangeVal) -> Int {
  if self.infinite {
    0
  } else {
    (self.stop - self.start).abs() / self.step.abs() + 1
  }
}

///|
/// `first value` (with optional `.n`).
fn b_first(ctx : Ctx, args : Array[Value]) -> Unit {
  let n = attr_get(ctx.current_attrs, "n")
  match n {
    Some(VInteger(k)) =>
      match args[0] {
        VBlock(items) => ctx.push(VBlock(take_items(items, k)))
        VString(s) => ctx.push(VString(take_string(s, k)))
        _ => ctx.push(args[0])
      }
    _ =>
      match args[0] {
        VBlock(items) =>
          if !items.is_empty() {
            ctx.push(items[0])
          } else {
            ctx.push(VNull)
          }
        VString(s) =>
          if !s.is_empty() {
            ctx.push(VChar(Int::unsafe_to_char(s[0].to_int())))
          } else {
            ctx.push(VNull)
          }
        VRange(r) =>
          if r.numeric && !r.infinite {
            ctx.push(VInteger(r.start))
          } else {
            ctx.push(args[0])
          }
        _ => ctx.push(args[0])
      }
  }
}

///|
fn take_items(items : Array[Value], n : Int) -> Array[Value] {
  if n <= 0 {
    []
  } else if n >= items.length() {
    items
  } else {
    items[0:n].to_owned()
  }
}

///|
fn arr_reverse(a : Array[Value]) -> Unit {
  let mut lo = 0
  let mut hi = a.length() - 1
  while lo < hi {
    let t = a[lo]
    a[lo] = a[hi]
    a[hi] = t
    lo = lo + 1
    hi = hi - 1
  }
}

///|
fn take_string(s : String, k : Int) -> String {
  let sb = StringBuilder()
  for i = 0; i < k && i < s.length(); i = i + 1 {
    sb.write_char(Int::unsafe_to_char(s[i].to_int()))
  }
  sb.to_string()
}

///|
/// `last value` (with optional `.n`).
fn b_last(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let n = attr_get(ctx.current_attrs, "n")
  match n {
    Some(VInteger(k)) =>
      match args[0] {
        VBlock(items) => ctx.push(VBlock(take_items(items, items.length() - k)))
        VString(s) => ctx.push(VString(take_string(s, s.length() - k)))
        _ => ctx.push(args[0])
      }
    _ =>
      match args[0] {
        VBlock(items) =>
          if !items.is_empty() {
            ctx.push(items[items.length() - 1])
          } else {
            ctx.push(VNull)
          }
        VString(s) =>
          if !s.is_empty() {
            ctx.push(VChar(Int::unsafe_to_char(s[s.length() - 1].to_int())))
          } else {
            ctx.push(VNull)
          }
        VRange(r) =>
          if r.numeric && !r.infinite {
            let vals = r.values()
            if !vals.is_empty() {
              ctx.push(vals[vals.length() - 1])
            } else {
              ctx.push(VNull)
            }
          } else {
            ctx.push(args[0])
          }
        _ => ctx.push(args[0])
      }
  }
}

///|
/// In-place update helper: for literal arguments, fetch the symbol,
/// transform and store back; returns whether the argument was a literal.
fn Ctx::maybe_inplace(ctx : Ctx, x : Value, f : (Value) -> Value) -> Bool {
  match x {
    VLiteral(s) | VWord(s) =>
      match ctx.env.get(s) {
        Some(v) => {
          ctx.env.set(s, f(v))
          true
        }
        None => false
      }
    _ => false
  }
}

///|
/// `append x y` (also `++`).
fn b_append(ctx : Ctx, args : Array[Value]) -> Unit {
  if ctx.maybe_inplace(args[0], v => append_value(v, args[1])) {
    return
  }
  ctx.push(append_value(args[0], args[1]))
}

///|
fn append_value(x : Value, y : Value) -> Value {
  match x {
    VBlock(items) =>
      match y {
        VBlock(ys) => VBlock(items + ys)
        _ => VBlock(items + [y])
      }
    VString(s) =>
      match y {
        VChar(c) => VString(s + c.to_string())
        VString(t) => VString(s + t)
        _ => VString(s + y.to_string())
      }
    _ => x
  }
}

///|
/// `prepend x y`.
fn b_prepend(ctx : Ctx, args : Array[Value]) -> Unit {
  if ctx.maybe_inplace(args[0], v => prepend_value(v, args[1])) {
    return
  }
  ctx.push(prepend_value(args[0], args[1]))
}

///|
fn prepend_value(x : Value, y : Value) -> Value {
  match x {
    VBlock(items) => VBlock([y] + items)
    VString(s) =>
      match y {
        VChar(c) => VString(c.to_string() + s)
        VString(t) => VString(t + s)
        _ => VString(y.to_string() + s)
      }
    _ => x
  }
}

///|
/// `pop 'x` — remove and return the last element in place.
fn b_pop(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VLiteral(s) | VWord(s) =>
      match ctx.env.get(s) {
        Some(VBlock(items)) => {
          let popped = items.pop().unwrap_or(VNull)
          ctx.env.set(s, VBlock(items))
          ctx.push(popped)
        }
        Some(VString(st)) => {
          let last = Int::unsafe_to_char(st[st.length() - 1].to_int())
          ctx.env.set(s, VString(take_string(st, st.length() - 1)))
          ctx.push(VChar(last))
        }
        _ => ctx.push(VNull)
      }
    VBlock(items) => ctx.push(items.pop().unwrap_or(VNull))
    VString(st) =>
      if !st.is_empty() {
        ctx.push(VChar(Int::unsafe_to_char(st[st.length() - 1].to_int())))
      } else {
        ctx.push(VNull)
      }
    _ => ctx.push(VNull)
  }
}

///|
/// `remove x y` (also `--`) — remove elements equal to `y` from a
/// block, or the first occurrence of the substring from a string.
fn b_remove(ctx : Ctx, args : Array[Value]) -> Unit {
  if ctx.maybe_inplace(args[0], v => remove_value(v, args[1])) {
    return
  }
  ctx.push(remove_value(args[0], args[1]))
}

///|
fn remove_value(x : Value, y : Value) -> Value {
  match x {
    VBlock(items) => {
      let idx = for i in 0..<items.length() {
        if items[i] == y {
          break i
        }
      } nobreak {
        -1
      }
      let out : Array[Value] = []
      for i in 0..<items.length() {
        if i != idx {
          out.push(items[i])
        }
      }
      VBlock(out)
    }
    VString(s) =>
      match y {
        VString(t) => VString(s.replace_all(old=t, new=""))
        VChar(c) => VString(s.replace_all(old=c.to_string(), new=""))
        _ => x
      }
    _ => x
  }
}

///|
/// `insert collection index value`.
fn b_insert(ctx : Ctx, args : Array[Value]) -> Unit {
  let idx = args[1].as_int().unwrap_or(0)
  match args[0] {
    VBlock(items) => {
      let copy = items
      copy.insert(idx, args[2])
      ctx.push(VBlock(copy))
    }
    _ => ctx.push(args[0])
  }
}

///|
/// `index collection value` — index of the first match.
fn b_index(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VBlock(items) => {
      let found = for i in 0..<items.length() {
        if items[i] == args[1] {
          break i
        }
      } nobreak {
        -1
      }
      ctx.push(VInteger(found))
    }
    VString(s) =>
      match args[1] {
        VChar(c) => {
          let found = for i in 0..<s.length() {
            if Int::unsafe_to_char(s[i].to_int()) == c {
              break i
            }
          } nobreak {
            -1
          }
          ctx.push(VInteger(found))
        }
        _ => ctx.push(VInteger(-1))
      }
    _ => ctx.push(VInteger(-1))
  }
}

///|
/// `keys dict` / `values dict`.
fn b_keys(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VDictionary(d) => ctx.push(VBlock(d.keys().map(k => VString(k)).to_array()))
    _ => ctx.push(VBlock([]))
  }
}

///|
fn b_values(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VDictionary(d) => ctx.push(VBlock(d.values().to_array()))
    _ => ctx.push(VBlock([]))
  }
}

///|
/// `contains? collection value`.
fn b_containsq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VBlock(items) => ctx.push(VLogical(items.iter().any(v => v == args[1])))
    VString(s) =>
      match args[1] {
        VString(t) => ctx.push(VLogical(s.contains(t)))
        VChar(c) => ctx.push(VLogical(s.iter().any(ch => ch == c)))
        _ => ctx.push(VLogical(false))
      }
    VDictionary(d) =>
      match args[1] {
        VString(k) => ctx.push(VLogical(d.contains(k)))
        _ => ctx.push(VLogical(false))
      }
    VRange(r) => {
      let items = r.values()
      ctx.push(VLogical(items.iter().any(v => v == args[1])))
    }
    _ => ctx.push(VLogical(false))
  }
}

///|
/// `in? item collection` — check membership.
fn b_inq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let item = args[0]
  match args[1] {
    VBlock(items) => ctx.push(VLogical(items.iter().any(v => v == item)))
    VString(s) =>
      match item {
        VChar(c) => ctx.push(VLogical(s.iter().any(ch => ch == c)))
        VString(t) => ctx.push(VLogical(s.contains(t)))
        _ => ctx.push(VLogical(false))
      }
    VDictionary(d) =>
      match item {
        VString(k) => ctx.push(VLogical(d.contains(k)))
        _ => ctx.push(VLogical(false))
      }
    VRange(r) => {
      let items = r.values()
      ctx.push(VLogical(items.iter().any(v => v == item)))
    }
    _ => ctx.push(VLogical(false))
  }
}

///|
/// `empty? value` / `one? value` / `zero? value`.
fn b_emptyq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VBlock(items) => ctx.push(VLogical(items.is_empty()))
    VString(s) => ctx.push(VLogical(s.is_empty()))
    VDictionary(d) => ctx.push(VLogical(d.is_empty()))
    VInteger(i) => ctx.push(VLogical(i == 0))
    VNull => ctx.push(VLogical(true))
    _ => ctx.push(VLogical(false))
  }
}

///|
fn b_oneq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VInteger(i) => ctx.push(VLogical(i == 1))
    VBlock(items) => ctx.push(VLogical(items.length() == 1))
    VString(s) => ctx.push(VLogical(s.length() == 1))
    _ => ctx.push(VLogical(false))
  }
}

///|
fn b_zeroq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VInteger(i) => ctx.push(VLogical(i == 0))
    VFloating(f) => ctx.push(VLogical(f == 0.0))
    VBlock(items) => ctx.push(VLogical(items.is_empty()))
    VString(s) => ctx.push(VLogical(s.is_empty()))
    _ => ctx.push(VLogical(false))
  }
}

///|
/// `key? dict key`.
fn b_keyq(ctx : Ctx, args : Array[Value]) -> Unit {
  match (args[0], args[1]) {
    (VDictionary(d), VString(k)) => ctx.push(VLogical(d.contains(k)))
    (VDictionary(d), VLiteral(k)) => ctx.push(VLogical(d.contains(k)))
    _ => ctx.push(VLogical(false))
  }
}

///|
/// `range from to` (also `..`) with optional `.step`.
fn b_range(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let x = args[0]
  let y = args[1]
  let (start, numeric) = match x {
    VInteger(i) => (i, true)
    VChar(c) => (c.to_int(), false)
    _ => raise RuntimeError(message="wrong argument type for range")
  }
  let (stop, infinite) = match y {
    VInteger(i) => (i, false)
    VFloating(f) =>
      if f.is_pos_inf() || f.is_neg_inf() {
        (0, true)
      } else {
        (f.to_int(), false)
      }
    VChar(c) => (c.to_int(), false)
    _ => raise RuntimeError(message="wrong argument type for range")
  }
  let step = match attr_get(ctx.current_attrs, "step") {
    Some(VInteger(s)) =>
      if s == 0 {
        raise RuntimeError(message="range with zero step")
      } else {
        s.abs()
      }
    _ => 1
  }
  let forward = if infinite { true } else { start < stop }
  ctx.push(VRange({ start, stop, step, infinite, numeric, forward }))
}

///|
/// `array value` (also `@`) — evaluate a block, expand a range.
fn b_array(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VRange(r) => ctx.push(VBlock(r.values()))
    VBlock(blk) => {
      let vals = eval_block_values(blk, ctx)
      ctx.push(VBlock(vals))
    }
    VInline(blk) => {
      let vals = eval_block_values(blk, ctx)
      ctx.push(VBlock(vals))
    }
    v => ctx.push(VBlock([v]))
  }
}

///|
/// `dictionary block` (also `#`) — build a dictionary from a block.
fn b_dictionary(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VBlock(blk) => ctx.push(VDictionary(exec_dictionary(blk, ctx)))
    VInline(blk) => ctx.push(VDictionary(exec_dictionary(blk, ctx)))
    VDictionary(d) => ctx.push(VDictionary(d))
    _ => ctx.push(VDictionary(Map([])))
  }
}

///|
/// `repeat value times`.
fn b_repeat(ctx : Ctx, args : Array[Value]) -> Unit {
  let n = args[1].as_int().unwrap_or(0)
  match args[0] {
    VString(s) => ctx.push(VString(s.repeat(n)))
    VBlock(items) => {
      let out : Array[Value] = []
      for _ in 0..<n {
        for item in items {
          out.push(item)
        }
      }
      ctx.push(VBlock(out))
    }
    VInteger(i) => {
      let out : Array[Value] = []
      for _ in 0..<n {
        out.push(VInteger(i))
      }
      ctx.push(VBlock(out))
    }
    _ => ctx.push(args[0])
  }
}

///|
/// `reverse value`.
fn b_reverse(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VBlock(items) => {
      let copy = items
      arr_reverse(copy)
      ctx.push(VBlock(copy))
    }
    VString(s) => {
      let sb = StringBuilder()
      for i = s.length() - 1; i >= 0; i = i - 1 {
        sb.write_char(Int::unsafe_to_char(s[i].to_int()))
      }
      ctx.push(VString(sb.to_string()))
    }
    _ => ctx.push(args[0])
  }
}

///|
/// `flatten value`.
fn b_flatten(ctx : Ctx, args : Array[Value]) -> Unit {
  let out : Array[Value] = []
  match args[0] {
    VBlock(items) => flatten_into(items, out)
    _ => out.push(args[0])
  }
  ctx.push(VBlock(out))
}

///|
fn flatten_into(items : Array[Value], out : Array[Value]) -> Unit {
  for item in items {
    match item {
      VBlock(inner) => flatten_into(inner, out)
      _ => out.push(item)
    }
  }
}

///|
/// `sort value` — sort a block (numbers, then strings).
fn b_sort(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VBlock(items) => {
      let copy = items
      copy.sort_by((a, b) => sort_key(a).compare(sort_key(b)))
      ctx.push(VBlock(copy))
    }
    VString(s) => {
      let chars : Array[Char] = []
      for c in s {
        chars.push(c)
      }
      chars.sort_by((a, b) => a.compare(b))
      let sb = StringBuilder()
      for c in chars {
        sb.write_char(c)
      }
      ctx.push(VString(sb.to_string()))
    }
    _ => ctx.push(args[0])
  }
}

///|
fn sort_key(v : Value) -> String {
  match v {
    VInteger(i) => "0\{pad_num(i, 16)}"
    VFloating(f) => "0\{pad_num(f.to_int(), 16)}"
    _ => "1\{v}"
  }
}

///|
fn pad_num(i : Int, width : Int) -> String {
  let s = i.to_string()
  if s.length() >= width {
    s
  } else {
    "0".repeat(width - s.length()) + s
  }
}

///|
/// `unique value`.
fn b_unique(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VBlock(items) => {
      let out : Array[Value] = []
      for item in items {
        if !out.iter().any(v => v == item) {
          out.push(item)
        }
      }
      ctx.push(VBlock(out))
    }
    _ => ctx.push(args[0])
  }
}

///|
/// `take value n` / `drop value n`.
fn b_take(ctx : Ctx, args : Array[Value]) -> Unit {
  let n = args[1].as_int().unwrap_or(0)
  match args[0] {
    VBlock(items) =>
      ctx.push(
        VBlock(
          if n >= 0 {
            take_items(items, n)
          } else {
            take_items(items, items.length() + n)
          },
        ),
      )
    VString(s) =>
      ctx.push(
        VString(
          if n >= 0 {
            take_string(s, n)
          } else {
            take_string(s, s.length() + n)
          },
        ),
      )
    _ => ctx.push(args[0])
  }
}

///|
fn b_drop(ctx : Ctx, args : Array[Value]) -> Unit {
  let n = args[1].as_int().unwrap_or(0)
  match args[0] {
    VBlock(items) =>
      ctx.push(
        VBlock(
          if n >= 0 {
            items[n:].to_owned()
          } else {
            take_items(items, items.length() + n)
          },
        ),
      )
    VString(s) =>
      ctx.push(
        VString(
          if n >= 0 {
            take_string(s, s.length() - n)
          } else {
            take_string(s, -n)
          },
        ),
      )
    _ => ctx.push(args[0])
  }
}

///|
/// `slice value from to`.
fn b_slice(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let from = args[1].as_int().unwrap_or(0)
  let to = args[2].as_int().unwrap_or(0)
  match args[0] {
    VBlock(items) => {
      let lo = if from < 0 { 0 } else { from }
      let hi = if to > items.length() { items.length() } else { to }
      if lo <= hi {
        ctx.push(VBlock(items[lo:hi].to_owned()))
      } else {
        ctx.push(VBlock([]))
      }
    }
    VString(s) => {
      let lo = if from < 0 { 0 } else { from }
      let hi = if to > s.length() { s.length() } else { to }
      if lo <= hi {
        ctx.push(VString(s[lo:hi].to_owned()))
      } else {
        ctx.push(VString(""))
      }
    }
    VRange(r) => {
      let items = r.values()
      let lo = if from < 0 { 0 } else { from }
      let hi = if to > items.length() { items.length() } else { to }
      ctx.push(VBlock(items[lo:hi].to_owned()))
    }
    _ => ctx.push(args[0])
  }
}

///|
/// `max value` / `min value`.
fn b_max(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let items = iterable_items(args[0])
  if items.is_empty() {
    ctx.push(VNull)
    return
  }
  let best = items[1:].fold(init=items[0], (best, v) => {
    if ctx.cmp_values(v, best) > 0 {
      v
    } else {
      best
    }
  })
  ctx.push(best)
}

///|
fn b_min(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let items = iterable_items(args[0])
  if items.is_empty() {
    ctx.push(VNull)
    return
  }
  let best = items[1:].fold(init=items[0], (best, v) => {
    if ctx.cmp_values(v, best) < 0 {
      v
    } else {
      best
    }
  })
  ctx.push(best)
}

///|
/// `sum value` / `product value`.
fn b_sum(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let items = iterable_items(args[0])
  let (acc, floating) = items
    .iter()
    .fold(init=(0, false), (state, item) => {
      let (acc, floating) = state
      match item.as_float() {
        Some(f) => (acc + f.to_int(), floating || item is VFloating(_))
        None => (acc, floating)
      }
    })
  if floating {
    ctx.push(VFloating(acc.to_double()))
  } else {
    ctx.push(VInteger(acc))
  }
}

///|
fn b_product(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let items = iterable_items(args[0])
  let acc = items
    .iter()
    .fold(init=1, (acc, item) => {
      match item.as_int() {
        Some(i) => acc * i
        None => acc
      }
    })
  ctx.push(VInteger(acc))
}

///|
/// Strings.

///|
fn b_upper(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VString(s) => ctx.push(VString(s.to_upper()))
    VChar(c) => ctx.push(VChar(c.to_ascii_uppercase()))
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_lower(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VString(s) => ctx.push(VString(s.to_lower()))
    VChar(c) => ctx.push(VChar(c.to_ascii_lowercase()))
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_capitalize(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VString(s) =>
      if !s.is_empty() {
        let first = Int::unsafe_to_char(s[0].to_int()).to_ascii_uppercase()
        ctx.push(VString(first.to_string() + take_string(s, s.length() - 1)))
      } else {
        ctx.push(VString(""))
      }
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_strip(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VString(s) => ctx.push(VString(s.trim().to_owned()))
    _ => ctx.push(args[0])
  }
}

///|
/// `join block` — concatenate; `.with: sep` joins with a separator.
fn b_join(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let sep = match attr_get(ctx.current_attrs, "with") {
    Some(VString(s)) => s
    Some(VChar(c)) => c.to_string()
    _ => ""
  }
  match args[0] {
    VBlock(items) => ctx.push(VString(items.map(Show::to_string).join(sep)))
    VRange(r) => ctx.push(VString(r.values().map(Show::to_string).join(sep)))
    _ => ctx.push(VString(args[0].to_string()))
  }
}

///|
/// `split value` — with `.by:`, `.words`, `.every:` attributes.
fn b_split(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VString(s) => {
      let by = attr_get(ctx.current_attrs, "by")
      let words = attr_has(ctx.current_attrs, "words")
      let every = attr_get(ctx.current_attrs, "every")
      if words {
        let parts : Array[Value] = []
        let mut current = StringBuilder()
        for c in s {
          if " \t\n\r".contains_char(c) {
            if current.to_string() != "" {
              parts.push(VString(current.to_string()))
              current = StringBuilder()
            }
          } else {
            current.write_char(c)
          }
        }
        if current.to_string() != "" {
          parts.push(VString(current.to_string()))
        }
        ctx.push(VBlock(parts))
      } else {
        match every {
          Some(VInteger(n)) => {
            let parts : Array[Value] = []
            for i = 0; i < s.length(); i = i + n {
              let hi = if i + n > s.length() { s.length() } else { i + n }
              parts.push(
                VString(
                  take_string(s, hi)[take_string(s, hi).length() - (hi - i):].to_owned(),
                ),
              )
            }
            ctx.push(VBlock(parts))
          }
          _ =>
            match by {
              Some(VString(sep)) => {
                let parts : Array[Value] = []
                let chunks = s.split(sep)
                for chunk in chunks {
                  parts.push(VString(chunk.to_owned()))
                }
                ctx.push(VBlock(parts))
              }
              _ => {
                // default: split into chars
                let parts : Array[Value] = []
                for c in s {
                  parts.push(VChar(c))
                }
                ctx.push(VBlock(parts))
              }
            }
        }
      }
    }
    _ => ctx.push(VBlock([]))
  }
}

///|
/// `pad value width` — pad with spaces (or `.with: char`).
fn b_pad(ctx : Ctx, args : Array[Value]) -> Unit {
  let width = args[1].as_int().unwrap_or(0)
  let fill = match attr_get(ctx.current_attrs, "with") {
    Some(VChar(c)) => c
    _ => ' '
  }
  match args[0] {
    VString(s) =>
      if s.length() < width {
        ctx.push(VString(fill.to_string().repeat(width - s.length()) + s))
      } else {
        ctx.push(VString(s))
      }
    _ => ctx.push(VString(args[0].to_string().pad_start(width, fill)))
  }
}

///|
/// `replace value old new`.
fn b_replace(ctx : Ctx, args : Array[Value]) -> Unit {
  match (args[0], args[1], args[2]) {
    (VString(s), VString(old), VString(new)) =>
      ctx.push(VString(s.replace_all(old~, new~)))
    (VBlock(items), old, new) => {
      let out : Array[Value] = []
      for item in items {
        if item == old {
          out.push(new)
        } else {
          out.push(item)
        }
      }
      ctx.push(VBlock(out))
    }
    _ => ctx.push(args[0])
  }
}

///|
/// Numbers.
fn num1(
  ctx : Ctx,
  args : Array[Value],
  f : (Double) -> Double,
) -> Unit raise ArturoError {
  match args[0] {
    VInteger(i) => ctx.push(VFloating(f(i.to_double())))
    VFloating(x) => ctx.push(VFloating(f(x)))
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_abs(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(i) => ctx.push(VInteger(i.abs()))
    VFloating(f) => ctx.push(VFloating(f.abs()))
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_floor(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(i) => ctx.push(VInteger(i))
    VFloating(f) => ctx.push(VInteger(f.floor().to_int()))
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_ceil(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(i) => ctx.push(VInteger(i))
    VFloating(f) => ctx.push(VInteger(f.ceil().to_int()))
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_round(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(i) => ctx.push(VInteger(i))
    VFloating(f) => ctx.push(VFloating(f.round()))
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_sqrt(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  num1(ctx, args, x => x.sqrt())
}

///|
fn b_exp(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  num1(ctx, args, x => @math.pow(2.718281828459045, x))
}

///|
fn b_sign(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(i) =>
      ctx.push(VInteger(if i > 0 { 1 } else if i < 0 { -1 } else { 0 }))
    VFloating(f) =>
      ctx.push(
        VFloating(if f > 0.0 { 1.0 } else if f < 0.0 { -1.0 } else { 0.0 }),
      )
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_evenq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0].as_int() {
    Some(i) => ctx.push(VLogical(i % 2 == 0))
    None => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_oddq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0].as_int() {
    Some(i) => ctx.push(VLogical(i % 2 != 0))
    None => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_positiveq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0].as_float() {
    Some(f) => ctx.push(VLogical(f > 0.0))
    None => ctx.push(VLogical(false))
  }
}

///|
fn b_negativeq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0].as_float() {
    Some(f) => ctx.push(VLogical(f < 0.0))
    None => ctx.push(VLogical(false))
  }
}

///|
fn b_infiniteq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[0] {
    VFloating(f) => ctx.push(VLogical(f.is_inf()))
    VRange(r) => ctx.push(VLogical(r.infinite))
    _ => ctx.push(VLogical(false))
  }
}

///|
fn b_primeq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0].as_int() {
    Some(n) =>
      if n < 2 {
        ctx.push(VLogical(false))
      } else {
        let prime = for i = 2; i * i <= n; i = i + 1 {
          if n % i == 0 {
            break false
          }
        } nobreak {
          true
        }
        ctx.push(VLogical(prime))
      }
    None => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_factorial(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0].as_int() {
    Some(n) => {
      let acc = for i in 2..<=n; acc = 1 {
        continue acc * i
      } nobreak {
        acc
      }
      ctx.push(VInteger(acc))
    }
    None => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_digits(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0].as_int() {
    Some(n) => {
      let s = n.abs().to_string()
      let out : Array[Value] = []
      for c in s {
        out.push(VInteger(c.to_int() - '0'.to_int()))
      }
      ctx.push(VBlock(out))
    }
    None => raise RuntimeError(message="wrong argument type")
  }
}

///|
fn b_gcd(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match (args[0].as_int(), args[1].as_int()) {
    (Some(a), Some(b)) => {
      let mut x = a.abs()
      let mut y = b.abs()
      while y != 0 {
        let t = y
        y = x % y
        x = t
      }
      ctx.push(VInteger(x))
    }
    _ => raise RuntimeError(message="wrong argument type")
  }
}

///|
/// Types.

///|
/// `to :type value` — convert a value.
fn b_to(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let target = match args[0] {
    VType(t) => t
    _ => ""
  }
  let x = args[1]
  match target {
    "integer" =>
      match x {
        VInteger(i) => ctx.push(VInteger(i))
        VFloating(f) => ctx.push(VInteger(f.to_int()))
        VString(s) => {
          let t = s.trim()
          if t == "true" {
            ctx.push(VInteger(1))
          } else if t == "false" {
            ctx.push(VInteger(0))
          } else {
            let v = @string.parse_int(t) catch {
              _ =>
                raise RuntimeError(message="cannot convert to :integer: \{s}")
            }
            ctx.push(VInteger(v))
          }
        }
        VLogical(b) => ctx.push(VInteger(if b { 1 } else { 0 }))
        VChar(c) => ctx.push(VInteger(c.to_int()))
        VRange(r) =>
          if r.numeric && !r.infinite {
            ctx.push(VBlock(r.values()))
          } else {
            raise RuntimeError(message="cannot convert to :integer")
          }
        _ => raise RuntimeError(message="cannot convert to :integer")
      }
    "floating" =>
      match x {
        VInteger(i) => ctx.push(VFloating(i.to_double()))
        VFloating(f) => ctx.push(VFloating(f))
        VString(s) => {
          let v = @string.parse_double(s.trim()) catch {
            _ => raise RuntimeError(message="cannot convert to :floating: \{s}")
          }
          ctx.push(VFloating(v))
        }
        _ => raise RuntimeError(message="cannot convert to :floating")
      }
    "string" =>
      match x {
        VString(s) => ctx.push(VString(s))
        VChar(c) => ctx.push(VString(c.to_string()))
        _ => ctx.push(VString(x.to_string()))
      }
    "char" =>
      match x {
        VChar(c) => ctx.push(VChar(c))
        VInteger(i) => ctx.push(VChar(Int::unsafe_to_char(i)))
        VString(s) =>
          if !s.is_empty() {
            ctx.push(VChar(Int::unsafe_to_char(s[0].to_int())))
          } else {
            raise RuntimeError(message="cannot convert to :char")
          }
        _ => raise RuntimeError(message="cannot convert to :char")
      }
    "logical" =>
      match x {
        VLogical(b) => ctx.push(VLogical(b))
        VInteger(i) => ctx.push(VLogical(i != 0))
        VString(s) => ctx.push(VLogical(s.trim() == "true" || s.trim() == "1"))
        _ => ctx.push(VLogical(x.is_truthy()))
      }
    "block" =>
      match x {
        VBlock(items) => ctx.push(VBlock(items))
        VRange(r) => ctx.push(VBlock(r.values()))
        VString(s) => {
          let out : Array[Value] = []
          for c in s {
            out.push(VChar(c))
          }
          ctx.push(VBlock(out))
        }
        _ => ctx.push(VBlock([x]))
      }
    "dictionary" =>
      match x {
        VDictionary(d) => ctx.push(VDictionary(d))
        _ => ctx.push(VDictionary(Map([])))
      }
    "range" =>
      match x {
        VRange(r) => ctx.push(VRange(r))
        VBlock(items) =>
          if items.length() == 2 {
            match (items[0].as_int(), items[1].as_int()) {
              (Some(a), Some(b)) =>
                ctx.push(
                  VRange({
                    start: a,
                    stop: b,
                    step: 1,
                    infinite: false,
                    numeric: true,
                    forward: a < b,
                  }),
                )
              _ => raise RuntimeError(message="cannot convert to :range")
            }
          } else {
            raise RuntimeError(message="cannot convert to :range")
          }
        _ => raise RuntimeError(message="cannot convert to :range")
      }
    "type" => ctx.push(VType(x.type_name()))
    _ => raise RuntimeError(message="unknown target type: :\{target}")
  }
}

///|
/// `type value` — the value's type.
fn b_type(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(args[0].type_of())
}

///|
/// `is? value :type` — type check.
fn b_isq(ctx : Ctx, args : Array[Value]) -> Unit {
  match args[1] {
    VType(t) => ctx.push(VLogical(args[0].type_name() == t))
    _ => ctx.push(VLogical(false))
  }
}

///|
/// `defined? value` — whether the value is not null.
fn b_definedq(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(VLogical(!(args[0] is VNull)))
}
