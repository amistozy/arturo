///|
/// Operator builtins: arithmetic, comparison and logic — ports of
/// `Arithmetic.nim`, `Comparison.nim` and `Logic.nim`.

///|
fn num_args(
  ctx : Ctx,
  args : Array[Value],
) -> (Double, Double) raise ArturoError {
  let a = match as_float(args[0]) {
    Some(x) => x
    None =>
      raise rt_err(
        ctx,
        "wrong argument type: expected number, got \{type_name(args[0])}",
      )
  }
  let b = match as_float(args[1]) {
    Some(x) => x
    None =>
      raise rt_err(
        ctx,
        "wrong argument type: expected number, got \{type_name(args[1])}",
      )
  }
  (a, b)
}

///|
fn int_args(ctx : Ctx, args : Array[Value]) -> (Int, Int) raise ArturoError {
  let a = match as_int(args[0]) {
    Some(x) => x
    None =>
      raise rt_err(
        ctx,
        "wrong argument type: expected integer, got \{type_name(args[0])}",
      )
  }
  let b = match as_int(args[1]) {
    Some(x) => x
    None =>
      raise rt_err(
        ctx,
        "wrong argument type: expected integer, got \{type_name(args[1])}",
      )
  }
  (a, b)
}

///|
/// Numeric promotion: if either operand is floating the result is
/// floating; otherwise integer.
fn bin_num(
  ctx : Ctx,
  args : Array[Value],
  fi : (Int, Int) -> Int,
  ff : (Double, Double) -> Double,
) -> Unit raise ArturoError {
  match (args[0], args[1]) {
    (VInteger(a), VInteger(b)) => ctx.push(VInteger(fi(a, b)))
    _ => {
      let (a, b) = num_args(ctx, args)
      ctx.push(VFloating(ff(a, b)))
    }
  }
}

///|
/// Binary operation on a symbol in place: `add 'a 1` mutates `a`.
fn binop_inplace(
  ctx : Ctx,
  x : Value,
  y : Value,
  f : (Value, Value) -> Value,
) -> Bool {
  match x {
    VLiteral(s) | VWord(s) =>
      match ctx.env.get(s) {
        Some(v) => {
          let res = f(v, y)
          ctx.env.set(s, res)
          ctx.push(res)
          true
        }
        None => false
      }
    _ => false
  }
}

///|
fn b_add(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if binop_inplace(ctx, args[0], args[1], (a, b) => binop_add(a, b)) {
    return
  }
  match (args[0], args[1]) {
    (VChar(c), VInteger(n)) =>
      ctx.push(VChar(Int::unsafe_to_char(c.to_int() + n)))
    _ => bin_num(ctx, args, (a, b) => a + b, (a, b) => a + b)
  }
}

///|
fn binop_add(a : Value, b : Value) -> Value {
  match (a, b) {
    (VInteger(x), VInteger(y)) => VInteger(x + y)
    (VInteger(x), VFloating(y)) => VFloating(x.to_double() + y)
    (VFloating(x), VInteger(y)) => VFloating(x + y.to_double())
    (VFloating(x), VFloating(y)) => VFloating(x + y)
    (VChar(c), VInteger(n)) => VChar(Int::unsafe_to_char(c.to_int() + n))
    _ => a
  }
}

///|
fn b_sub(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if binop_inplace(ctx, args[0], args[1], (a, b) => binop_sub(a, b)) {
    return
  }
  match (args[0], args[1]) {
    (VChar(c), VInteger(n)) =>
      ctx.push(VChar(Int::unsafe_to_char(c.to_int() - n)))
    _ => bin_num(ctx, args, (a, b) => a - b, (a, b) => a - b)
  }
}

///|
fn binop_sub(a : Value, b : Value) -> Value {
  match (a, b) {
    (VInteger(x), VInteger(y)) => VInteger(x - y)
    (VInteger(x), VFloating(y)) => VFloating(x.to_double() - y)
    (VFloating(x), VInteger(y)) => VFloating(x - y.to_double())
    (VFloating(x), VFloating(y)) => VFloating(x - y)
    (VChar(c), VInteger(n)) => VChar(Int::unsafe_to_char(c.to_int() - n))
    _ => a
  }
}

///|
fn b_mul(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if binop_inplace(ctx, args[0], args[1], (a, b) => binop_mul(a, b)) {
    return
  }
  bin_num(ctx, args, (a, b) => a * b, (a, b) => a * b)
}

///|
fn binop_mul(a : Value, b : Value) -> Value {
  match (a, b) {
    (VInteger(x), VInteger(y)) => VInteger(x * y)
    (VInteger(x), VFloating(y)) => VFloating(x.to_double() * y)
    (VFloating(x), VInteger(y)) => VFloating(x * y.to_double())
    (VFloating(x), VFloating(y)) => VFloating(x * y)
    _ => a
  }
}

///|
fn b_div(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if binop_inplace(ctx, args[0], args[1], (a, b) => binop_div(a, b)) {
    return
  }
  bin_num(ctx, args, (a, b) => a / b, (a, b) => a / b)
}

///|
fn binop_div(a : Value, b : Value) -> Value {
  match (a, b) {
    (VInteger(x), VInteger(y)) => VInteger(x / y)
    _ =>
      match (as_float(a), as_float(b)) {
        (Some(x), Some(y)) => VFloating(x / y)
        _ => a
      }
  }
}

///|
fn b_fdiv(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let (a, b) = num_args(ctx, args)
  ctx.push(VFloating(a / b))
}

///|
fn b_mod(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  if binop_inplace(ctx, args[0], args[1], (a, b) => binop_mod(a, b)) {
    return
  }
  bin_num(ctx, args, (a, b) => a % b, (a, b) => a % b)
}

///|
fn binop_mod(a : Value, b : Value) -> Value {
  match (a, b) {
    (VInteger(x), VInteger(y)) => VInteger(x % y)
    _ =>
      match (as_float(a), as_float(b)) {
        (Some(x), Some(y)) => VFloating(x % y)
        _ => a
      }
  }
}

///|
fn b_pow(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match (args[0], args[1]) {
    (VInteger(a), VInteger(b)) => ctx.push(VInteger(int_pow(a, b)))
    _ => {
      let (a, b) = num_args(ctx, args)
      ctx.push(VFloating(@math.pow(a, b)))
    }
  }
}

///|
fn int_pow(a : Int, b : Int) -> Int {
  let mut base = a
  let mut exp = b
  let mut acc = 1
  if exp < 0 {
    return 0
  }
  while exp > 0 {
    if exp % 2 == 1 {
      acc = acc * base
    }
    base = base * base
    exp = exp / 2
  }
  acc
}

///|
fn b_neg(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(a) => ctx.push(VInteger(-a))
    VFloating(a) => ctx.push(VFloating(-a))
    _ =>
      raise rt_err(
        ctx,
        "wrong argument type: expected number, got \{type_name(args[0])}",
      )
  }
}

///|
fn b_inc(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(a) => ctx.push(VInteger(a + 1))
    VFloating(a) => ctx.push(VFloating(a + 1.0))
    VLiteral(s) =>
      match ctx.env.get(s) {
        Some(VInteger(a)) => ctx.env.set(s, VInteger(a + 1))
        Some(VFloating(a)) => ctx.env.set(s, VFloating(a + 1.0))
        _ => raise rt_err(ctx, "wrong argument type")
      }
    _ => raise rt_err(ctx, "wrong argument type")
  }
}

///|
fn b_dec(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  match args[0] {
    VInteger(a) => ctx.push(VInteger(a - 1))
    VFloating(a) => ctx.push(VFloating(a - 1.0))
    VLiteral(s) =>
      match ctx.env.get(s) {
        Some(VInteger(a)) => ctx.env.set(s, VInteger(a - 1))
        Some(VFloating(a)) => ctx.env.set(s, VFloating(a - 1.0))
        _ => raise rt_err(ctx, "wrong argument type")
      }
    _ => raise rt_err(ctx, "wrong argument type")
  }
}

///|
fn b_divmod(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let (a, b) = int_args(ctx, args)
  ctx.push(VBlock([VInteger(a / b), VInteger(a % b)]))
}

///|
/// Comparison.
fn cmp_values(ctx : Ctx, a : Value, b : Value) -> Int raise ArturoError {
  match (as_float(a), as_float(b)) {
    (Some(x), Some(y)) => x.compare(y)
    _ =>
      match (a, b) {
        (VChar(x), VChar(y)) => x.compare(y)
        (VString(x), VString(y)) => compare_strings(x, y)
        _ =>
          raise rt_err(
            ctx,
            "cannot compare \{type_name(a)} with \{type_name(b)}",
          )
      }
  }
}

///|
fn compare_strings(x : String, y : String) -> Int {
  if x < y {
    -1
  } else if x > y {
    1
  } else {
    0
  }
}

///|
fn b_equalq(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(VLogical(args[0] == args[1]))
}

///|
fn b_not_equalq(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(VLogical(args[0] != args[1]))
}

///|
fn b_greaterq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  ctx.push(VLogical(cmp_values(ctx, args[0], args[1]) > 0))
}

///|
fn b_greater_or_equalq(
  ctx : Ctx,
  args : Array[Value],
) -> Unit raise ArturoError {
  ctx.push(VLogical(cmp_values(ctx, args[0], args[1]) >= 0))
}

///|
fn b_lessq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  ctx.push(VLogical(cmp_values(ctx, args[0], args[1]) < 0))
}

///|
fn b_less_or_equalq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  ctx.push(VLogical(cmp_values(ctx, args[0], args[1]) <= 0))
}

///|
fn b_sameq(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(VLogical(args[0] == args[1]))
}

///|
/// Logic.
fn eval_maybe_block(v : Value, ctx : Ctx) -> Value raise ArturoError {
  match v {
    VBlock(blk) => eval_block_last(blk, ctx)
    VInline(blk) => eval_block_last(blk, ctx)
    _ => v
  }
}

///|
fn b_andq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let x = eval_maybe_block(args[0], ctx)
  if !is_truthy(x) {
    ctx.push(VLogical(false))
    return
  }
  let y = eval_maybe_block(args[1], ctx)
  ctx.push(VLogical(is_truthy(y)))
}

///|
fn b_orq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let x = eval_maybe_block(args[0], ctx)
  if is_truthy(x) {
    ctx.push(VLogical(true))
    return
  }
  let y = eval_maybe_block(args[1], ctx)
  ctx.push(VLogical(is_truthy(y)))
}

///|
fn b_xorq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let x = eval_maybe_block(args[0], ctx)
  let y = eval_maybe_block(args[1], ctx)
  ctx.push(VLogical(is_truthy(x) != is_truthy(y)))
}

///|
fn b_notq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let x = eval_maybe_block(args[0], ctx)
  ctx.push(VLogical(!is_truthy(x)))
}

///|
fn b_allq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let items = match args[0] {
    VBlock(b) => b
    _ => []
  }
  let mut ok = true
  for item in items {
    let v = eval_maybe_block(item, ctx)
    if !(v is VLogical(b) && b) {
      ok = false
      break
    }
  }
  ctx.push(VLogical(ok))
}

///|
fn b_anyq(ctx : Ctx, args : Array[Value]) -> Unit raise ArturoError {
  let items = match args[0] {
    VBlock(b) => b
    _ => []
  }
  let mut ok = false
  for item in items {
    let v = eval_maybe_block(item, ctx)
    if v is VLogical(b) && b {
      ok = true
      break
    }
  }
  ctx.push(VLogical(ok))
}

///|
fn b_trueq(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(VLogical(args[0] is VLogical(b) && b))
}

///|
fn b_falseq(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(VLogical(args[0] is VLogical(b) && !b))
}

///|
fn b_nullq(ctx : Ctx, args : Array[Value]) -> Unit {
  ctx.push(VLogical(args[0] is VNull))
}
