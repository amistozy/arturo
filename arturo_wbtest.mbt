// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
test "trailing label stores null" {
  let r = run("x:")
  inspect(r.output, content="")
  inspect(r.value, content="null")
  let env = Env()
  ignore(run_with(env, "x:"))
  inspect(env.get_symbol("x").unwrap_or(VNull), content="null")
}

///|
test "label in argument position raises instead of panicking" {
  // a store consumes a stack value (like the reference's storeByIndex),
  // so a label used as a call argument underflows; the evaluator must
  // report it as a runtime error rather than crashing with an
  // out-of-bounds panic
  let r = try run("print ~x:") catch {
    ArturoError::RuntimeError(message~) => "RUNTIME \{message}"
    ArturoError::ParseError(line~, message~) => "PARSE line \{line}: \{message}"
    _ => "OTHER"
  } noraise {
    rr => "ok out=[\{rr.output}]"
  }
  inspect(r, content="RUNTIME stack underflow")
}

///|
test "non-ascii symbols are skipped by the lexer" {
  // only ASCII symbols are supported; a unicode operator character is
  // treated as an unknown character and skipped
  let toks = match parse("print ∞") {
    VBlock(b) => b
    _ => []
  }
  inspect(
    toks.map(t => "type=\{t.type_name()} show=\{t}").join(" ; "),
    content="type=word show=print",
  )
  let toks2 = match parse("1 ∧ 1") {
    VBlock(b) => b
    _ => []
  }
  inspect(
    toks2.map(t => "type=\{t.type_name()} show=\{t}").join(" ; "),
    content="type=integer show=1 ; type=integer show=1",
  )
}
