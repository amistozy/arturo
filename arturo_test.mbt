///|
/// Blackbox tests against the package's public API.

///|
test "basic arithmetic and print" {
  let r = @arturo.run("print 1 + 2")
  inspect(r.output, content="3\n")
}

///|
test "strings and interpolation" {
  let src =
    #|x: 2
    #|print ~"x: |x|"
    #|
  let r = @arturo.run(src)
  inspect(r.output, content="x: 2\n")
}

///|
test "blocks, labels and prints" {
  let r = @arturo.run("a: 5 print [a a+1]")
  inspect(r.output, content="5 6 \n")
}

///|
test "functions" {
  let src =
    #|f: function [x][ x + 2 ]
    #|print f 10
    #|
  let r = @arturo.run(src)
  inspect(r.output, content="12\n")
}

///|
test "loop over range" {
  let src =
    #|loop 1..3 'x [
    #|    print x
    #|]
    #|
  let r = @arturo.run(src)
  inspect(r.output, content="1\n2\n3\n")
}

///|
test "map and pipes" {
  let r = @arturo.run("1..10 | map 'x -> 2*x | print")
  inspect(r.output, content="2 4 6 8 10 12 14 16 18 20 \n")
}

///|
test "if and switch" {
  let src =
    #|x: 2
    #|if x=2 -> print "yes"
    #|switch x=2 -> print "two" -> print "other"
    #|
  let r = @arturo.run(src)
  inspect(r.output, content="yes\ntwo\n")
}

///|
test "dictionaries" {
  let src =
    #|d: #[name: "John" surname: "Doe"]
    #|print d\name
    #|print d
    #|
  let r = @arturo.run(src)
  inspect(r.output, content="John\n[name:John surname:Doe]\n")
}

///|
test "run returns last value" {
  let r = @arturo.run("1 + 2")
  inspect(r.value, content="3")
}

///|
test "parse errors are reported" {
  let r = try @arturo.run("[1 2") catch {
    @arturo.ArturoError::ParseError(line=_, message=_m) => "parse error"
    _ => "other"
  } noraise {
    _ => "no error"
  }
  inspect(r, content="parse error")
}

///|
test "runtime errors are reported" {
  let r = try @arturo.run("print nope") catch {
    @arturo.ArturoError::RuntimeError(line=_, message=_m) => "runtime error"
    _ => "other"
  } noraise {
    _ => "no error"
  }
  inspect(r, content="runtime error")
}
