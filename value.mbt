///|
/// The Arturo value model — a faithful MoonBit port of the core
/// value kinds of the reference interpreter (`src/vm/values/types.nim`),
/// restricted to the subset supported by this EDSL.
///
/// Everything in Arturo is a `Value`: constants, words, blocks,
/// dictionaries, ranges and functions are all represented uniformly.
pub(all) enum Value {
  VNull
  VLogical(Bool)
  VInteger(Int)
  VFloating(Double)
  VChar(Char)
  VString(String)
  VWord(String)
  VLiteral(String)
  VLabel(String)
  VAttribute(String)
  VAttributeLabel(String)
  VPath(Array[Value])
  VPathLabel(Array[Value])
  VSymbol(String)
  VBlock(Array[Value])
  VInline(Array[Value])
  VDictionary(Map[String, Value])
  VRange(RangeVal)
  VFunction(FunctionVal)
  VType(String)
}

///|
pub(all) struct RangeVal {
  start : Int
  stop : Int
  step : Int
  infinite : Bool
  numeric : Bool
  forward : Bool
} derive(Eq)

///|
pub(all) enum FunctionVal {
  UserFunction(params~ : Array[String], main~ : Array[Value], inline~ : Bool)
  BuiltinFunction(name~ : String)
}

///|
/// Constructors for the most common values.

///|
pub fn Value::null() -> Value {
  VNull
}

///|
pub fn Value::logical(b : Bool) -> Value {
  VLogical(b)
}

///|
pub fn Value::integer(i : Int) -> Value {
  VInteger(i)
}

///|
pub fn Value::floating(f : Double) -> Value {
  VFloating(f)
}

///|
pub fn Value::string(s : String) -> Value {
  VString(s)
}

///|
pub fn Value::block(items : Array[Value]) -> Value {
  VBlock(items)
}

///|
/// Build a dictionary from key/value pairs. The pairs are inserted in
/// order; later pairs with a duplicate key overwrite earlier ones
/// (like the reference's `OrderedTable`).
pub fn Value::dictionary(items : Array[(String, Value)]) -> Value {
  VDictionary(Map(items))
}

///|
/// Value kind names, mirroring `stringify` in `printable.nim`
/// (lowercase name, used by `type`, `is?` and `inspect`).
pub fn Value::type_name(v : Value) -> String {
  match v {
    VNull => "null"
    VLogical(_) => "logical"
    VInteger(_) => "integer"
    VFloating(_) => "floating"
    VChar(_) => "char"
    VString(_) => "string"
    VWord(_) => "word"
    VLiteral(_) => "literal"
    VLabel(_) => "label"
    VAttribute(_) => "attribute"
    VAttributeLabel(_) => "attributelabel"
    VPath(_) => "path"
    VPathLabel(_) => "pathlabel"
    VSymbol(_) => "symbol"
    VBlock(_) => "block"
    VInline(_) => "inline"
    VDictionary(_) => "dictionary"
    VRange(_) => "range"
    VFunction(_) => "function"
    VType(_) => "type"
  }
}

///|
/// `type` returns a `:type` value; the textual form is `:name`.
pub fn Value::type_of(v : Value) -> Value {
  VType(v.type_name())
}

///|
/// Truthiness used by `if`, `while`, `switch`, ... :
/// only `null` and `false` are falsy (see `isFalse` in `vlogical.nim`).
pub fn is_truthy(v : Value) -> Bool {
  match v {
    VNull => false
    VLogical(b) => b
    _ => true
  }
}

///|
/// Numeric view helpers (used by builtins).
pub fn as_int(v : Value) -> Int? {
  match v {
    VInteger(i) => Some(i)
    VFloating(f) => Some(f.to_int())
    _ => None
  }
}

///|
pub fn as_float(v : Value) -> Double? {
  match v {
    VInteger(i) => Some(i.to_double())
    VFloating(f) => Some(f)
    _ => None
  }
}

///|
pub fn as_string(v : Value) -> String? {
  match v {
    VString(s) => Some(s)
    _ => None
  }
}

///|
/// Nim-style rendering of doubles (`$` in `printable.nim`):
/// integral values keep a trailing `.0`, `nan`/`±∞` get special forms.
fn float_show(f : Double) -> String {
  if f.is_nan() {
    return "nan"
  }
  if f.is_pos_inf() {
    return "∞"
  }
  if f.is_neg_inf() {
    return "-∞"
  }
  let s = f.to_string()
  if f == f.floor() && f.abs() < 1000000000000000.0 {
    return "\{s}.0"
  }
  s
}

///|
fn RangeVal::range_show(r : RangeVal) -> String {
  let start = if r.numeric {
    r.start.to_string()
  } else {
    "'\{r.start.unsafe_to_char()}'"
  }
  let stop = if r.infinite {
    "∞"
  } else if r.numeric {
    r.stop.to_string()
  } else {
    "'\{r.stop.unsafe_to_char()}'"
  }
  let base = "\{start}..\{stop}"
  if r.step != 1 {
    "\{base} (\{r.step})"
  } else {
    base
  }
}

///|
/// Function rendering (the reference prints `<function>[params](addr)`;
/// we omit the address, which is not reproducible).
fn FunctionVal::function_show(f : FunctionVal) -> String {
  match f {
    UserFunction(params~, ..) => "<function>[\{params.join(" ")}]"
    BuiltinFunction(name~) => "<function:builtin:\{name}>"
  }
}

///|
/// `Show` for values renders them exactly like Arturo's `print`
/// (mirrors `$` in `printable.nim`).
pub impl Show for Value with fn to_string(self) {
  match self {
    VNull => "null"
    VLogical(b) => if b { "true" } else { "false" }
    VInteger(i) => i.to_string()
    VFloating(f) => float_show(f)
    VChar(c) => c.to_string()
    VString(s) => s
    VWord(s) => s
    VLiteral(s) => s
    VLabel(s) => s
    VAttribute(s) => s
    VAttributeLabel(s) => s
    VPath(p) => p.map(Show::to_string).join("\\")
    VPathLabel(p) => p.map(Show::to_string).join("\\")
    VSymbol(s) => s
    VBlock(a) => "[\{a.map(Show::to_string).join(" ")}]"
    VInline(a) => "[\{a.map(Show::to_string).join(" ")}]"
    VDictionary(d) => {
      let items : Array[String] = []
      for k, v in d {
        items.push("\{k}:\{v}")
      }
      "[\{items.join(" ")}]"
    }
    VRange(r) => r.range_show()
    VFunction(f) => f.function_show()
    VType(t) => ":\{t}"
  }
}

///|
/// Value equality — mirrors `==` in `comparison.nim`:
/// numeric kinds compare across `:integer`/`:floating`, everything else
/// must have the same kind and equal contents. Dictionaries compare
/// by key (order-insensitive, like the reference's `OrderedTable`).
pub impl Eq for Value with fn equal(self, that) {
  match (self, that) {
    (VNull, VNull) => true
    (VLogical(x), VLogical(y)) => x == y
    (VInteger(x), VInteger(y)) => x == y
    (VFloating(x), VFloating(y)) => x == y
    (VInteger(x), VFloating(y)) => x.to_double() == y
    (VFloating(x), VInteger(y)) => x == y.to_double()
    (VChar(x), VChar(y)) => x == y
    (VString(x), VString(y)) => x == y
    (VWord(x), VWord(y)) => x == y
    (VLiteral(x), VLiteral(y)) => x == y
    (VLabel(x), VLabel(y)) => x == y
    (VAttribute(x), VAttribute(y)) => x == y
    (VAttributeLabel(x), VAttributeLabel(y)) => x == y
    (VPath(x), VPath(y)) => x == y
    (VPathLabel(x), VPathLabel(y)) => x == y
    (VSymbol(x), VSymbol(y)) => x == y
    (VBlock(x), VBlock(y)) => x == y
    (VInline(x), VInline(y)) => x == y
    (VDictionary(x), VDictionary(y)) => x == y
    (VRange(x), VRange(y)) => x == y
    (VType(x), VType(y)) => x == y
    _ => false
  }
}
