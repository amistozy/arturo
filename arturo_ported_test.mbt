///|
/// Ported tests from the reference Arturo test suite
/// (`reference/arturo/tests/unittests/`): the original `.art` sources
/// are run through this EDSL and the captured output is compared
/// against the reference `.res` files.

///|
/// Run an Arturo program and compare its output with the expected
/// reference output (whitespace-trimmed on both sides).
fn check_arturo(src : String, expected : String) -> Unit raise {
  try @arturo.run(src) catch {
    _err => fail("arturo error")
  } noraise {
    ok => assert_eq(ok.output.trim().to_owned(), expected.trim().to_owned())
  }
}

///|
test "ported: branching.art" {
  let src =
    #|f: function [][
    #|    print "in f"
    #|    return 10
    #|    print "still in f - ERROR"
    #|]
    #|
    #|print "before calling f"
    #|print f
    #|print "after calling f"
    #|
    #|print "---"
    #|
    #|g: function [x][
    #|    print "in g"
    #|    switch x<5 [
    #|        print "x<5"
    #|        return x
    #|        print "after return - ERROR"
    #|    ][
    #|        print "x>=5"
    #|        return 2*x
    #|        print "after return - ERROR"
    #|    ]
    #|    print "still in g - ERROR"
    #|]
    #|
    #|loop [1 3 5 7] 'i [
    #|    print "before calling g"
    #|    print ["g" i "=" g i]
    #|    print "after calling g"
    #|]
    #|
    #|print "---"
    #|
    #|h: function [z][
    #|    print "in h"
    #|    switch z<5 [
    #|        print "z<5"
    #|        return z
    #|        print "after return - ERROR"
    #|    ][
    #|        if z=5 [
    #|            print "z=5"
    #|            return 3*z
    #|            print "after return - ERROR"
    #|        ]
    #|        print "z>=5"
    #|        return 2*z
    #|        print "after return - ERROR"
    #|    ]
    #|    print "still in h - ERROR"
    #|]
    #|
    #|loop [1 3 5 7] 'j [
    #|    print "before calling h"
    #|    print ["h" j "=" h j]
    #|    print "after calling h"
    #|]
    #|
    #|print "break: before loop"
    #|loop 1..5 'x [
    #|    print ["break: x:" x]
    #|    if x=3 -> break
    #|    print "break: after test"
    #|]
    #|print "break: after loop"
    #|
    #|print "continue: before loop"
    #|loop 1..5 'x [
    #|    print ["continue: x:" x]
    #|    if x=3 -> continue
    #|    print "continue: after test"
    #|]
    #|print "continue: after loop"
    #|
    #|print "nested break: before loop 1"
    #|loop 1..3 'x [
    #|    print ["nested break: x:" x]
    #|    print "nested break: before loop 2"
    #|    loop 0..3 'y [
    #|        print ["nested break: y:" y]
    #|        if y=1 -> break
    #|        print "nested break: after test"
    #|    ]
    #|    print "nested break: after loop 2"
    #|]
    #|print "nested break: after loop 1"
    #|
  let expected =
    #|before calling f
    #|in f
    #|10
    #|after calling f
    #|---
    #|before calling g
    #|in g
    #|x<5
    #|g 1 = 1 
    #|after calling g
    #|before calling g
    #|in g
    #|x<5
    #|g 3 = 3 
    #|after calling g
    #|before calling g
    #|in g
    #|x>=5
    #|g 5 = 10 
    #|after calling g
    #|before calling g
    #|in g
    #|x>=5
    #|g 7 = 14 
    #|after calling g
    #|---
    #|before calling h
    #|in h
    #|z<5
    #|h 1 = 1 
    #|after calling h
    #|before calling h
    #|in h
    #|z<5
    #|h 3 = 3 
    #|after calling h
    #|before calling h
    #|in h
    #|z=5
    #|h 5 = 15 
    #|after calling h
    #|before calling h
    #|in h
    #|z>=5
    #|h 7 = 14 
    #|after calling h
    #|break: before loop
    #|break: x: 1 
    #|break: after test
    #|break: x: 2 
    #|break: after test
    #|break: x: 3 
    #|break: after loop
    #|continue: before loop
    #|continue: x: 1 
    #|continue: after test
    #|continue: x: 2 
    #|continue: after test
    #|continue: x: 3 
    #|continue: x: 4 
    #|continue: after test
    #|continue: x: 5 
    #|continue: after test
    #|continue: after loop
    #|nested break: before loop 1
    #|nested break: x: 1 
    #|nested break: before loop 2
    #|nested break: y: 0 
    #|nested break: after test
    #|nested break: y: 1 
    #|nested break: after loop 2
    #|nested break: x: 2 
    #|nested break: before loop 2
    #|nested break: y: 0 
    #|nested break: after test
    #|nested break: y: 1 
    #|nested break: after loop 2
    #|nested break: x: 3 
    #|nested break: before loop 2
    #|nested break: y: 0 
    #|nested break: after test
    #|nested break: y: 1 
    #|nested break: after loop 2
    #|nested break: after loop 1
    #|
  check_arturo(src, expected)
}

///|
test "ported: loops.art" {
  let src =
    #|loop [1 2 3] 'x [
    #|    print x
    #|]
    #|
    #|loop.with: 'i ["zero" "one" "two" "three"] [x][
    #|    print [i "=>" x]
    #|]
    #|
    #|print "before empty loop"
    #|loop [] 'x [
    #|    print x
    #|]
    #|print "after empty loop"
    #|
  let expected =
    #|1
    #|2
    #|3
    #|0 => zero 
    #|1 => one 
    #|2 => two 
    #|3 => three 
    #|before empty loop
    #|after empty loop
    #|
  check_arturo(src, expected)
}

///|
test "ported: parser.art" {
  let src =
    #|inspect [something?anotherone????]
    #|inspect [something?: something]
    #|inspect ['some?thing??]
    #|
    #|inspect [_ one]
    #|inspect [_two]
    #|inspect [three]
    #|inspect [four:]
    #|inspect [_ five:]
    #|inspect [_six:]
    #|
  let expected =
    #|[ :block
    #|    something? :word
    #|    anotherone? :word
    #|    ?? :symbol
    #|    ? :symbol
    #|]
    #|[ :block
    #|    something? :label
    #|    something :word
    #|]
    #|[ :block
    #|    some? :literal
    #|    thing? :word
    #|    ? :symbol
    #|]
    #|[ :block
    #|    _ :symbol
    #|    one :word
    #|]
    #|[ :block
    #|    _two :word
    #|]
    #|[ :block
    #|    three :word
    #|]
    #|[ :block
    #|    four :label
    #|]
    #|[ :block
    #|    _ :symbol
    #|    five :label
    #|]
    #|[ :block
    #|    _six :label
    #|]
    #|
  check_arturo(src, expected)
}

///|
test "ported: templates.art" {
  let src =
    #|x: 2
    #|print ~"x: |x|"
    #|print render "x: |x|"
    #|
    #|print ~.template "x: <||= x ||>"
    #|print render.template "x: <||= x ||>"
    #|
    #|print render.template {
    #|    rendering the template
    #|    x: <||= x ||>
    #|    <|| switch x>1 [ ||>Yep, x is greater than 1
    #|    <||] [ ||>Nope it's not.<||]||>
    #|}
    #|
  let expected =
    #|x: 2
    #|x: 2
    #|x: 2
    #|x: 2
    #|rendering the template
    #|x: 2
    #|Yep, x is greater than 1
    #|
  check_arturo(src, expected)
}

///|
test "ported: strings.art" {
  let src =
    #|enpiped: function [str][
    #|    "|" ++ str ++ "|"
    #|]
    #|
    #|a: "Hello world"
    #|print enpiped a
    #|
    #|b: « Hello world
    #|print enpiped b
    #|
    #|c: {
    #|    Hello 
    #|    world
    #|}
    #|
    #|print enpiped c
    #|
    #|d: {:
    #|    Hello
    #|    world
    #|:}
    #|
    #|print enpiped d
    #|
    #|e: {!md
    #|    # Hello world!
    #|}
    #|
    #|print enpiped e
    #|
    #|f: ««
    #|This
    #|    is
    #|        a very
    #|    safe
    #|string»»
    #|
    #|print enpiped f
    #|
    #|print
    #|---------------
    #|This is a very long string
    #|    until the end of the
    #|        file
    #|
  let expected =
    #||Hello world|
    #||Hello world|
    #||Hello 
    #|world|
    #||
    #|    Hello
    #|    world
    #||
    #||# Hello world!|
    #||
    #|This
    #|    is
    #|        a very
    #|    safe
    #|string|
    #|This is a very long string
    #|    until the end of the
    #|        file
    #|
  check_arturo(src, expected)
}

///|
test "ported: lib.arithmetic.art (core sections)" {
  let src =
    #|ensure -> 2 = 1 + 1
    #|ensure -> 2 = add 1 1
    #|ensure -> 3 = 1 + 2
    #|ensure -> 3 = add 2 1
    #|a: 2
    #|add 'a 1
    #|ensure -> a = 3
    #|'a + 1
    #|ensure -> a = 4
    #|ensure -> 0 = 1 + (neg 1)
    #|ensure -> 0 = (neg 1) + 1
    #|ensure -> 2.0 = 1 + 1.0
    #|ensure -> 2.0 = 1.0 + 1
    #|a: 2
    #|add 'a 1.0
    #|ensure -> a = 3.0
    #|'a + 1
    #|ensure -> a = 4.0
    #|ensure -> 2 = 5 / 2
    #|ensure -> 2.5 = 5 // 2
    #|ensure -> 1 = 5 % 2
    #|ensure -> 8 = 2 ^ 3
    #|ensure -> 6 = inc 5
    #|ensure -> 4 = dec 5
    #|ensure -> (neg 5) = neg 5
    #|ensure -> 9 = 3 * 3
    #|ensure -> 1 = 3 - 2
    #|print "[+] all arithmetic core tests passed!"
    #|
  check_arturo(src, "[+] all arithmetic core tests passed!")
}

///|
test "ported: lib.collections.art (core sections)" {
  let src =
    #|ensure -> 3 = size [1 2 3]
    #|ensure -> 5 = size "hello"
    #|ensure -> 1 = first [1 2 3]
    #|ensure -> 3 = last [1 2 3]
    #|ensure -> [1 2 3 4] = append [1 2 3] 4
    #|ensure -> "ab" = "a" ++ "b"
    #|ensure -> [3 2 1] = reverse [1 2 3]
    #|ensure -> 3 = max [1 3 2]
    #|ensure -> 1 = min [1 3 2]
    #|ensure -> 6 = sum [1 2 3]
    #|ensure -> 6 = product [1 2 3]
    #|ensure -> true = contains? [1 2 3] 2
    #|ensure -> "hello" = join ["hel" "lo"]
    #|ensure -> "1, 2, 3" = join.with: ", " [1 2 3]
    #|ensure -> 5 = last 1..5
    #|ensure -> [1 2 3 4 5] = @1..5
    #|ensure -> 1 = index [1 2 3] 2
    #|ensure -> true = in? 2 [1 2 3]
    #|ensure -> true = empty? []
    #|ensure -> true = zero? 0
    #|ensure -> true = one? 1
    #|ensure -> [1 2 3] = unique [1 1 2 3 3]
    #|ensure -> [1 2 3 4 5] = flatten [[1 2] [3] [4 5]]
    #|print "[+] all collections core tests passed!"
    #|
  check_arturo(src, "[+] all collections core tests passed!")
}

///|
test "ported: lib.iterators.art (core sections)" {
  let src =
    #|print map 1..5 [x][
    #|    2*x
    #|]
    #|print select 1..10 'x -> odd? x
    #|print filter 1..10 [x][
    #|    even? x
    #|]
    #|print fold 1..10 [x y]-> x + y
    #|print every? 1..10 'x -> x > 0
    #|print some? 1..10 'x -> x > 5
    #|print map.with:'i ["one" "two" "three" "four"] 'x -> (even? i)? -> upper x -> x
    #|
  let expected =
    #|2 4 6 8 10 
    #|1 3 5 7 9 
    #|1 3 5 7 9 
    #|55
    #|true
    #|true
    #|ONE two THREE four 
    #|
  check_arturo(src, expected)
}
