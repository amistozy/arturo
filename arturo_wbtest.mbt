// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
test "trailing label stores null" {
  let r = run("x:")
  inspect(r.output, content="")
  inspect(r.value, content="null")
  let env = new_env()
  ignore(run_with(env, "x:"))
  inspect(get_symbol(env, "x").unwrap_or(VNull), content="null")
}

///|
test "label in argument position raises instead of panicking" {
  // a store consumes a stack value (like the reference's storeByIndex),
  // so a label used as a call argument underflows; the evaluator must
  // report it as a runtime error rather than crashing with an
  // out-of-bounds panic
  let r = try run("print ~x:") catch {
    ArturoError::RuntimeError(line~, message~) =>
      "RUNTIME line \{line}: \{message}"
    ArturoError::ParseError(line~, message~) => "PARSE line \{line}: \{message}"
    _ => "OTHER"
  } noraise {
    rr => "ok out=[\{rr.output}]"
  }
  inspect(r, content="RUNTIME line 1: stack underflow")
}
