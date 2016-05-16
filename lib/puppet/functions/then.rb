# Call a [lambda](https://docs.puppet.com/puppet/latest/reference/lang_lambdas.html)
# with the given argument unless the argument is undef. Return undef if argument is
# undef, and otherwise the result of giving the argument to the lambda.
#
# This is useful to process a sequence of operations where an intermediate
# result may be undef (which makes the entire sequence undef).
# The `then` function is especially useful with the function `dig` which
# performs in a similar way "digging out" a value in a complex structure.
#
# @example Using `then`
#
# ~~~ puppet
# $data = {a => { b => [{x => 10, y => 20}, {x => 100, y => 200}]}}
# notice $data.dig(a, b, 1, x).then |$x| { $x * 2 }
# ~~~
#
# Would notice the value 200
#
# Contrast this with:
#
# ~~~ puppet
# $data = {a => { b => [{x => 10, y => 20}, {ex => 100, why => 200}]}}
# notice $data.dig(a, b, 1, x).then |$x| { $x * 2 }
# ~~~
#
# Which would notice undef since the last lookup of 'x' results in `undef` which
# is returned (without calling the block).
#
# As a result there was no need for conditional logic or a temporary (non local) 
# variable as the result is now either the wanted value (x) multiplied
# by 2 or `undef`.
#
# Calls to `then` can be chained. In the next example, a structure is using an offset that
# is using 1 as the index to the first element (instead of 0 which is used in the language).
# We are not sure if user input actually contains an index at all, or if it is
# outside the range of available names.
#
# ~~~ puppet
# # Names to choose from
# $names = ['Ringo', 'Paul', 'George', 'John']
#
# # structure where 'beatle 2' is wanted (but where the number refers
# # to 'Paul' because input comes from a source using 1 for the first
# # element).
#
# $data = [202, { beatle => 2 }]
# $picked = assert_type(String,
#   # the data we are interested in is the second in the array,
#   # a hash, where we want the value of the key 'beatle'
#   $data.dig(1, 'beatle')
#     # and we want the index in $names before the given index
#     .then |$x| { $names[$x-1] }
#     # so we can construct a string with that beatle's name
#     .then |$x| { "Picked Beatle '${x}'" }
# )
#
# ~~~ puppet
#
# Would notice "Picked Beatle 'Paul'", and would raise an error if the result
# was not a String.
#
# @since 4.5.0
#
Puppet::Functions.create_function(:then) do
  dispatch :then do
    param 'Any', :arg
    block_param 'Callable[1,1]', :block
  end

  def then(arg)
    return nil if arg.nil?
    yield(arg)
  end
end