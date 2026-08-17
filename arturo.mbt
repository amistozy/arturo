///|
/// The Arturo EDSL entry points: `run` / `run_with` / `parse`.
///
/// A MoonBit port of the core of the
/// [Arturo language](https://arturo-lang.io) — values, parser and
/// tree-walking evaluator, plus a curated set of builtins. Output of
/// `print`/`inspect` is captured and returned with the final value.

///|
/// Result of running an Arturo program.
pub(all) struct RunResult {
  value : Value
  output : String
}

///|
/// Builtin arities (used when forming calls).
///
/// Note: MoonBit cannot store raising functions as closures, so
/// builtins are dispatched by name in `invoke_builtin` below, and this
/// table only maps names to arities.
let builtin_arities : Map[String, Int] = {
  // core
  "if": 2,
  "unless": 2,
  "switch": 3,
  "while": 2,
  "until": 2,
  "when": 1,
  "case": 2,
  "do": 1,
  "function": 2,
  "return": 1,
  "break": 0,
  "continue": 0,
  "let": 2,
  "var": 1,
  "set?": 1,
  "unset": 1,
  "discard": 1,
  "new": 1,
  "call": 2,
  "ensure": 1,
  "dup": 1,
  "coalesce": 2,
  "print": 1,
  "prints": 1,
  "inspect": 1,
  "render": 1,
  "parse": 1,
  "attr": 1,
  "attr?": 1,
  // operators
  "add": 2,
  "sub": 2,
  "mul": 2,
  "div": 2,
  "fdiv": 2,
  "mod": 2,
  "pow": 2,
  "neg": 1,
  "inc": 1,
  "dec": 1,
  "divmod": 2,
  "equal?": 2,
  "notEqual?": 2,
  "greater?": 2,
  "greaterOrEqual?": 2,
  "less?": 2,
  "lessOrEqual?": 2,
  "same?": 2,
  "and?": 2,
  "or?": 2,
  "xor?": 2,
  "not?": 1,
  "all?": 1,
  "any?": 1,
  "true?": 1,
  "false?": 1,
  "null?": 1,
  // iterators
  "loop": 3,
  "map": 3,
  "select": 3,
  "filter": 3,
  "every?": 3,
  "some?": 3,
  "fold": 3,
  // collections
  "size": 1,
  "first": 1,
  "last": 1,
  "append": 2,
  "prepend": 2,
  "pop": 1,
  "remove": 2,
  "insert": 3,
  "index": 2,
  "keys": 1,
  "values": 1,
  "contains?": 2,
  "in?": 2,
  "empty?": 1,
  "one?": 1,
  "zero?": 1,
  "key?": 2,
  "range": 2,
  "array": 1,
  "dictionary": 1,
  "repeat": 2,
  "reverse": 1,
  "flatten": 1,
  "sort": 1,
  "unique": 1,
  "take": 2,
  "drop": 2,
  "slice": 3,
  "max": 1,
  "min": 1,
  "sum": 1,
  "product": 1,
  // strings
  "upper": 1,
  "lower": 1,
  "capitalize": 1,
  "strip": 1,
  "join": 1,
  "split": 1,
  "pad": 2,
  "replace": 3,
  // numbers
  "abs": 1,
  "floor": 1,
  "ceil": 1,
  "round": 1,
  "sqrt": 1,
  "exp": 1,
  "sign": 1,
  "even?": 1,
  "odd?": 1,
  "positive?": 1,
  "negative?": 1,
  "infinite?": 1,
  "prime?": 1,
  "factorial": 1,
  "digits": 1,
  "gcd": 2,
  // types
  "to": 2,
  "type": 1,
  "is?": 2,
  "defined?": 1,
  "integer?": 1,
  "floating?": 1,
  "string?": 1,
  "char?": 1,
  "logical?": 1,
  "block?": 1,
  "inline?": 1,
  "dictionary?": 1,
  "range?": 1,
  "function?": 1,
  "word?": 1,
  "literal?": 1,
  "label?": 1,
  "attribute?": 1,
  "symbol?": 1,
  "type?": 1,
}

///|
fn builtin_arity(name : String) -> Int {
  match builtin_arities.get(name) {
    Some(n) => n
    None => 0
  }
}

///|
/// Dispatch a builtin call by name.
fn invoke_builtin(
  name : String,
  ctx : Ctx,
  args : Array[Value],
) -> Unit raise ArturoError {
  match name {
    // core
    "if" => b_if(ctx, args)
    "unless" => b_unless(ctx, args)
    "switch" => b_switch(ctx, args)
    "while" => b_while(ctx, args)
    "until" => b_until(ctx, args)
    "when" => b_when(ctx, args)
    "case" => b_case(ctx, args)
    "do" => b_do(ctx, args)
    "function" => b_function(ctx, args)
    "return" => b_return(ctx, args)
    "break" => b_break(ctx, args)
    "continue" => b_continue(ctx, args)
    "let" => b_let(ctx, args)
    "var" => b_var(ctx, args)
    "set?" => b_setq(ctx, args)
    "unset" => b_unset(ctx, args)
    "discard" => b_discard(ctx, args)
    "new" => b_new(ctx, args)
    "call" => b_call(ctx, args)
    "ensure" => b_ensure(ctx, args)
    "dup" => b_dup(ctx, args)
    "coalesce" => b_coalesce(ctx, args)
    "print" => b_print(ctx, args)
    "prints" => b_prints(ctx, args)
    "inspect" => b_inspect(ctx, args)
    "render" => b_render(ctx, args)
    "parse" => b_parse(ctx, args)
    "attr" => b_attr(ctx, args)
    "attr?" => b_attrq(ctx, args)
    // operators
    "add" => b_add(ctx, args)
    "sub" => b_sub(ctx, args)
    "mul" => b_mul(ctx, args)
    "div" => b_div(ctx, args)
    "fdiv" => b_fdiv(ctx, args)
    "mod" => b_mod(ctx, args)
    "pow" => b_pow(ctx, args)
    "neg" => b_neg(ctx, args)
    "inc" => b_inc(ctx, args)
    "dec" => b_dec(ctx, args)
    "divmod" => b_divmod(ctx, args)
    "equal?" => b_equalq(ctx, args)
    "notEqual?" => b_not_equalq(ctx, args)
    "greater?" => b_greaterq(ctx, args)
    "greaterOrEqual?" => b_greater_or_equalq(ctx, args)
    "less?" => b_lessq(ctx, args)
    "lessOrEqual?" => b_less_or_equalq(ctx, args)
    "same?" => b_sameq(ctx, args)
    "and?" => b_andq(ctx, args)
    "or?" => b_orq(ctx, args)
    "xor?" => b_xorq(ctx, args)
    "not?" => b_notq(ctx, args)
    "all?" => b_allq(ctx, args)
    "any?" => b_anyq(ctx, args)
    "true?" => b_trueq(ctx, args)
    "false?" => b_falseq(ctx, args)
    "null?" => b_nullq(ctx, args)
    // iterators
    "loop" => b_loop(ctx, args)
    "map" => b_map(ctx, args)
    "select" => b_select(ctx, args)
    "filter" => b_filter(ctx, args)
    "every?" => b_everyq(ctx, args)
    "some?" => b_someq(ctx, args)
    "fold" => b_fold(ctx, args)
    // collections
    "size" => b_size(ctx, args)
    "first" => b_first(ctx, args)
    "last" => b_last(ctx, args)
    "append" => b_append(ctx, args)
    "prepend" => b_prepend(ctx, args)
    "pop" => b_pop(ctx, args)
    "remove" => b_remove(ctx, args)
    "insert" => b_insert(ctx, args)
    "index" => b_index(ctx, args)
    "keys" => b_keys(ctx, args)
    "values" => b_values(ctx, args)
    "contains?" => b_containsq(ctx, args)
    "in?" => b_inq(ctx, args)
    "empty?" => b_emptyq(ctx, args)
    "one?" => b_oneq(ctx, args)
    "zero?" => b_zeroq(ctx, args)
    "key?" => b_keyq(ctx, args)
    "range" => b_range(ctx, args)
    "array" => b_array(ctx, args)
    "dictionary" => b_dictionary(ctx, args)
    "repeat" => b_repeat(ctx, args)
    "reverse" => b_reverse(ctx, args)
    "flatten" => b_flatten(ctx, args)
    "sort" => b_sort(ctx, args)
    "unique" => b_unique(ctx, args)
    "take" => b_take(ctx, args)
    "drop" => b_drop(ctx, args)
    "slice" => b_slice(ctx, args)
    "max" => b_max(ctx, args)
    "min" => b_min(ctx, args)
    "sum" => b_sum(ctx, args)
    "product" => b_product(ctx, args)
    // strings
    "upper" => b_upper(ctx, args)
    "lower" => b_lower(ctx, args)
    "capitalize" => b_capitalize(ctx, args)
    "strip" => b_strip(ctx, args)
    "join" => b_join(ctx, args)
    "split" => b_split(ctx, args)
    "pad" => b_pad(ctx, args)
    "replace" => b_replace(ctx, args)
    // numbers
    "abs" => b_abs(ctx, args)
    "floor" => b_floor(ctx, args)
    "ceil" => b_ceil(ctx, args)
    "round" => b_round(ctx, args)
    "sqrt" => b_sqrt(ctx, args)
    "exp" => b_exp(ctx, args)
    "sign" => b_sign(ctx, args)
    "even?" => b_evenq(ctx, args)
    "odd?" => b_oddq(ctx, args)
    "positive?" => b_positiveq(ctx, args)
    "negative?" => b_negativeq(ctx, args)
    "infinite?" => b_infiniteq(ctx, args)
    "prime?" => b_primeq(ctx, args)
    "factorial" => b_factorial(ctx, args)
    "digits" => b_digits(ctx, args)
    "gcd" => b_gcd(ctx, args)
    // types
    "to" => b_to(ctx, args)
    "type" => b_type(ctx, args)
    "is?" => b_isq(ctx, args)
    "defined?" => b_definedq(ctx, args)
    _ => type_predicate_match(name, ctx, args)
  }
}

///|
/// The `xxx?` type predicates.
fn type_predicate_match(name : String, ctx : Ctx, args : Array[Value]) -> Unit {
  let t = match name {
    "integer?" => "integer"
    "floating?" => "floating"
    "string?" => "string"
    "char?" => "char"
    "logical?" => "logical"
    "block?" => "block"
    "inline?" => "inline"
    "dictionary?" => "dictionary"
    "range?" => "range"
    "function?" => "function"
    "word?" => "word"
    "literal?" => "literal"
    "label?" => "label"
    "attribute?" => "attribute"
    "symbol?" => "symbol"
    "type?" => "type"
    _ => ""
  }
  if t == "" {
    ctx.push(VLogical(false))
  } else {
    ctx.push(VLogical(type_name(args[0]) == t))
  }
}

///|
/// Seed the environment with the builtins and the constants.
fn seed_env(env : Env) -> Unit {
  for name, _arity in builtin_arities {
    env.syms[name] = VFunction(BuiltinFunction(name~))
  }
  env.syms["null"] = VNull
  env.syms["any"] = VType("any")
  env.syms["infinite"] = VFloating(1.0 / 0.0)
  env.syms["pi"] = VFloating(3.141592653589793)
  env.syms["tau"] = VFloating(6.283185307179586)
  env.syms["epsilon"] = VFloating(2.220446049250313e-16)
}

///|
/// Evaluate a parsed block and return the last pushed value (or null).
fn eval_top(blk : Array[Value], ctx : Ctx) -> Value raise ArturoError {
  let before = ctx.stack.length()
  eval_block(blk, ctx)
  let mut result = VNull
  while ctx.stack.length() > before {
    result = ctx.pop()
  }
  result
}

///|
/// Run an Arturo program (a source string) in a fresh environment,
/// capturing `print` output. The returned value is the value of the
/// last top-level expression.
pub fn run(source : String) -> RunResult raise ArturoError {
  let parsed = parse(source)
  let ctx = Ctx::new()
  seed_env(ctx.env)
  match parsed {
    VBlock(blk) => {
      let value = eval_top(blk, ctx)
      { value, output: ctx.out.to_string() }
    }
    _ => { value: VNull, output: ctx.out.to_string() }
  }
}

///|
/// Run an Arturo program with a pre-populated environment: symbols
/// passed here are visible to the program, and all assignments the
/// program performs (at the top level) are visible afterwards.
pub fn run_with(env : Env, source : String) -> RunResult raise ArturoError {
  let parsed = parse(source)
  let ctx = Ctx::with_env(env)
  seed_env(ctx.env)
  match parsed {
    VBlock(blk) => {
      let value = eval_top(blk, ctx)
      { value, output: ctx.out.to_string() }
    }
    _ => { value: VNull, output: ctx.out.to_string() }
  }
}

///|
/// Create a fresh environment (pre-seeded with the builtins).
pub fn new_env() -> Env {
  let env = Env::new()
  seed_env(env)
  env
}

///|
/// Fetch a symbol from an environment.
pub fn get_symbol(env : Env, name : String) -> Value? {
  env.syms.get(name)
}

///|
/// Set a symbol in an environment.
pub fn set_symbol(env : Env, name : String, v : Value) -> Unit {
  env.syms[name] = v
}
