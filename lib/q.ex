defmodule Q do
  @moduledoc """
  Build pipelines of named steps, in the spirit of `Ecto.Multi`, and run them with `execute/1`.

  Every step's result is stored in a state map under the step's name. When a step returns an error,
  `execute/1` returns the failing step's name and error together with the state built so far.

  ## Writing a pipeline

  Pipelines are written with `queue/1`, where every step is a binding:

      import Q

      queue do
        input = data                       # stores a value
        trimmed = String.trim(input)       # a function that can't fail
        decoded <- Base.decode64(trimmed)  # a function that can fail
        notified <- Notifier.notify(decoded)
      end
      |> execute()

  A step's inputs are the earlier steps its expression uses; other variables are captured
  as in any closure. `if`, `unless`, `case` and `cond` around steps choose which steps run
  from earlier results. The block only builds the queue; `execute/1` runs it. See `queue/1`
  for all the rules.

  The block is checked when your code compiles. For pipelines built from data there is a
  functional API, checked when each step is added; see "The functional API" below.

  ## Results

  A step written with `<-` must return one of:

    * `{:ok, value}` - stores `value` under the step's name and continues
    * `{:error, reason}` - stops; `execute/1` returns `{:error, name, reason, state}`
    * `:error` - same as `{:error, :error}`, for functions such as `Base.decode64/1`
    * `{:halt, value}` - stores `value` and stops the pipeline; `execute/1` returns `{:ok, state}`
    * `{:halt, value, propagate: false}` - like `{:halt, value}`, but when the queue runs as
      a child (see below) only the child stops
    * a queue - runs it as a child, see below

  Any other return value raises. A step written with `=` stores its value as is.

  Exceptions raised by step functions propagate unchanged, including exceptions in child
  queues. They aren't converted into error tuples, and Q doesn't attach accumulated state
  to them. This applies to both `run/4` (`<-`) and `let/4` (`=`) steps.

  Q does not automatically roll back completed operations. Stopping a queue after an error,
  exception or halt leaves earlier side effects in place. Applications must manage their
  own transaction boundaries or compensating actions where required.

  ## Child queues

  A function that returns a queue runs it as a child, with its own state starting empty,
  and the child's result map is stored under the step's name. The child's step names stay
  separate from the parent's, so a queue built by a function can be reused anywhere:

      queue do
        user <- Accounts.fetch_user(id)
        billing <- billing_steps(user)
        shipping <- shipping_steps(user)
        confirmation <- confirm(billing.invoice, shipping.tracking)
      end

  If a child step fails, the parent step fails with the child's error tuple as the reason:
  `{:error, :billing, {:error, :charge, :declined, %{...}}, %{user: ...}}`. A halt in a
  child stops the parent too, unless it is `{:halt, value, propagate: false}`; then the
  parent stores the child's partial results and continues. To store a queue as a value
  instead of running it, use `=` or return `{:ok, queue}`.

  ## The functional API

  `queue/1` compiles to these functions, which are also public:

    * `put/3` stores a value.
    * `run/4` runs a function that can fail, like `<-`.
    * `let/4` runs a function that can't fail, like `=`.
    * `debug/2` prints the state.

  Both build the same queue, run with `execute/1`, and share the result and error shapes,
  child queues and halts. A queue built either way can be a child step of the other.

  The DSL gives compile-time checks (a misspelled step reference, a step bound twice, a
  malformed conditional), inputs inferred from the expression, branching with `if` and
  `case`, and inline nesting.

  The functional API gives what a block can't: a step per item, named after the item
  (`Q.run(q, {:invite, id}, fn -> invite(id) end, [])` inside `Enum.reduce/3`); names that
  aren't variables; steps chosen from data; queues built across functions or on a condition
  known when the queue is built; and explicit control over inputs. A step function receives
  the values of the keys listed in its `params`. Omitting `params` passes the whole state as
  one argument; explicit `[]` passes no queue inputs. These rules apply to both functions
  and MFAs. See `run/4` for `{module, function, args}`.

  The functional API is checked when the step is added: a wrong arity, an unknown param, an
  invalid name or a duplicate name raise `ArgumentError` before anything runs, but only once
  that code runs. Use the DSL whenever the pipeline is written out in code.

  Every step has a unique name and stores its successful result. Names are atoms, such as
  `:user`, or tuples, such as `{:invite, user_id}`. The atoms `nil`, `true`, `false` and `:_`
  are not allowed. Names starting with `_`, such as `:_notified`, follow the same rules.
  """

  alias __MODULE__
  defstruct operations: [], names: MapSet.new()
  @opaque t :: %__MODULE__{operations: [operation], names: MapSet.t()}
  @type state :: map
  @typedoc """
  An atom or tuple identifying a step. The atoms `nil`, `true`, `false` and `:_` are excluded.
  """
  @type name :: atom | tuple
  @type result ::
          {:ok, any}
          | {:error, any}
          | :error
          | {:halt, any}
          | {:halt, any, [propagate: boolean]}
          | t
  @type step_fun :: (... -> result)
  @type fun_mfa :: {module, atom, [any]} | {module, atom}
  @type params :: [name] | {[name], [order: :prepend | :append]}
  @typep kind :: :put | :run | :let | :branch | :debug
  @type error :: {:error, name, any, state}
  @typep input :: :none | :state | {:keys, [name]}
  @typep call :: {:fun, function, input} | {:mfa, module, atom, [any], input, :prepend | :append}
  @typep operation ::
           {:step, name, :put, any}
           | {:step, name, :run | :let, call}
           | {:branch, call}
           | {:debug, Keyword.t()}
           | {:debug, {:deferred, call}}

  @doc """
  Creates and returns a new, empty `Q` struct.

  The resulting queue can be used as a starting point for queue operations,
  such as `put/3` and `run/4`.

  ## Example
      iex> Q.new() |> Q.operations()
      []
  """
  @doc group: "Functional API"
  @spec new :: t
  def new do
    %Q{names: MapSet.new()}
  end

  @doc """
  Adds a value to the state so far under the given name.

  This function modifies the queue by associating the given `name` with a `value`.
  If the operation is successful, the `name` will become a key in the queue's internal
  state map, and `value` will be its associated value.

  ## Params

  - `queue`: The queue to add the value to.
  - `name`: A unique atom or tuple to associate with the value. See `t:name/0` for exclusions.
  - `value`: The value to add to the queue.

  ## Errors

  Raises `ArgumentError` if `name` is invalid or is already present in the queue.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:params, %{foo: "bar"})
      ...> |> Q.execute()
      {:ok, %{params: %{foo: "bar"}}}
  """
  @doc group: "Functional API"
  @spec put(t, name, any) :: t
  def put(%Q{} = queue, name, value) do
    add_op(queue, {:step, name, :put, value})
  end

  # Lists the queue's operations in order as `{kind, name}` tuples, with `name` nil for
  # branches and debug calls. Internal: used by the tests to check what a queue block
  # compiles to. Users get step names from operations/1.
  @doc false
  @spec __to_list__(t) :: [{kind, name | nil}]
  def __to_list__(%Q{operations: operations}) do
    operations
    |> Enum.reverse()
    |> Enum.map(fn
      {:step, name, kind, _} -> {kind, name}
      {:branch, _call} -> {:branch, nil}
      {:debug, _opts} -> {:debug, nil}
    end)
  end

  @doc """
  Returns a list of operation names stored in the queue, in the order they were added.

  This function can be used to review the sequence of operations added to the queue.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:init, "foo")
      ...> |> Q.run(:test, fn text -> {:ok, text} end, [:init])
      ...> |> Q.operations()
      [:init, :test]
  """
  @doc group: "Inspecting a queue"
  @spec operations(t) :: [name]
  def operations(%Q{operations: operations}) do
    for {:step, name, _kind, _} <- Enum.reverse(operations), do: name
  end

  @doc """
  Adds an operation to the queue that, when executed, prints the current state of the queue.

  Inline conditionals share their enclosing queue's accumulated state. Named child queues
  have their own state. Printing or filtering never changes the pipeline's results.

  The printing is performed using Elixir's `IO.inspect/2`. The Q-specific `:only` option
  selects one valid step name or a list of names; `only: []` prints an empty map. Valid
  names that aren't present are omitted. Remaining options, such as `:label`, are passed
  to `IO.inspect/2` after removing `:only`.

  In a `queue/1` block, options are evaluated once whenever execution reaches the debug
  statement, can reference earlier steps, and aren't evaluated in skipped branches or
  after an error or halt. Functional options are validated when added with `debug/2`;
  DSL options are validated when evaluated. Invalid options or selections raise
  `ArgumentError`.

  ## Params

  - `queue`: The queue to debug.
  - `opts`: A keyword list of inspection options and optional `:only` selection. Step names
    follow `t:name/0`; `nil`, `true`, `false`, `:_` and non-name terms aren't selections.

  """
  @doc group: "Functional API"
  @spec debug(t, Keyword.t()) :: t
  def debug(%Q{} = queue, opts \\ []) do
    add_op(queue, {:debug, validate_debug_opts!(opts)})
  end

  # The DSL evaluates the options expression only when this operation is reached.
  @doc false
  def __debug__(%Q{} = queue, fun, params) do
    add_op(queue, {:debug, {:deferred, build_call!(queue, fun, params)}})
  end

  @doc """
  Executes the queue, running all operations in the order they were added.

  Each operation is provided with the state of the queue as of the start of the operation.
  If an operation function returns an error, execution stops and the error tuple includes
  the accumulated results. Exceptions propagate unchanged, including from child queues;
  Q does not convert them into error tuples or attach accumulated results to them.

  Completed side effects are not automatically rolled back after an error, exception or
  halt. Applications must provide any required transactions or compensating actions.

  ## Example
      iex> Q.new()
      ...> |> Q.run(:write, fn _ -> {:ok, "Hello world!"} end)
      ...> |> Q.execute()
      {:ok, %{write: "Hello world!"}}
  """
  @doc group: "Writing a pipeline"
  @spec execute(t) :: {:ok, state} | error
  def execute(%Q{operations: operations}) do
    case run_ops(Enum.reverse(operations), %{}) do
      {:halted, state, _propagate} -> {:ok, state}
      result -> result
    end
  end

  @doc """
  Adds a step whose function receives the whole accumulated state as one argument.

  MFA fixed arguments follow the state. Use `run/4` with `[]` for no queue inputs, or
  with a list of names to receive specific results. See `run/4` for the return contract.
  """
  @doc group: "Functional API"
  @spec run(t, name, step_fun | fun_mfa) :: t
  def run(%Q{} = queue, name, fun) do
    add_op(queue, {:step, name, :run, resolve_call!(fun, :state, nil)})
  end

  @doc """
  Adds a function to be executed as part of the queue.

  This function enables adding operations to the queue that are executed when `execute/1` is called.
  The operations can be anonymous functions or functions in a module.

  The function should return either `{:ok, value}` if the operation was successful or
  `{:error, value}` if the operation failed. Functions can also return `{:halt, value}` to
  halt execution at any point, or a queue to run it as a child with its results stored under
  `name`. See the module documentation for the complete contract.

  ## Params

  - `queue`: The queue to which the function should be added.
  - `name`: A unique atom or tuple for this operation, used as a key in the state. See `t:name/0` for exclusions.
  - `fun`: The function to be run. It can be an anonymous function, a `{module, function}` tuple
    or a `{module, function, args}` tuple.
  - `params` (optional): A list of keys in the queue's internal state that should be passed to the
    function as arguments, or a `{keys, opts}` tuple. Omitting it passes the whole state;
    explicit `[]` passes no queue inputs.

  ## Function input

  - Without `params`, the function receives the whole state as one argument.
  - With `[]` (or `{[], opts}`), no queue inputs are passed.
  - With named `params`, the function receives the values of those keys, in order.
  - These rules apply to both functions and MFAs. `{module, function, args}` functions
    receive `args` as well; see the `:order` option. With `[]`, only these fixed arguments
    are passed.

  The function's arity is checked when the step is added, and `ArgumentError` is raised if it
  doesn't match, or if a module function doesn't exist.

  ## Options

  - `:order` - for `{module, function, args}` steps, whether the values of `keys` go before
    (`:prepend`, the default) or after (`:append`) `args`. Passing it with a function or
    capture raises `ArgumentError`: a function receives its inputs in the order of `keys`.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:key, :b)
      ...> |> Q.run(:value, {Map, :fetch, [%{a: 1, b: 2}]}, {[:key], order: :append})
      ...> |> Q.execute()
      {:ok, %{key: :b, value: 2}}
  """
  @doc group: "Functional API"
  @spec run(t, name, step_fun | fun_mfa, params) :: t
  def run(%Q{} = queue, name, fun, params) do
    add_op(queue, {:step, name, :run, build_call!(queue, fun, params)})
  end

  @doc """
  Adds a plain-value step whose function receives the whole accumulated state.

  The return value is stored unchanged. MFA fixed arguments follow the state. Use
  `let/4` with `[]` for no queue inputs, or with names to receive specific results.
  """
  @doc group: "Functional API"
  @spec let(t, name, (... -> any) | fun_mfa) :: t
  def let(%Q{} = queue, name, fun) do
    add_op(queue, {:step, name, :let, resolve_call!(fun, :state, nil)})
  end

  @doc """
  Adds a step whose function returns a plain value, for functions that can't fail.

  The value is stored under `name` as is, including a queue. `fun` and `params` work as in
  `run/4`. Use `run/4` when the function returns `{:ok, value}` or `{:error, reason}`.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:text, "hello")
      ...> |> Q.let(:upper, &String.upcase/1, [:text])
      ...> |> Q.execute()
      {:ok, %{text: "hello", upper: "HELLO"}}
  """
  @doc group: "Functional API"
  @spec let(t, name, (... -> any) | fun_mfa, params) :: t
  def let(%Q{} = queue, name, fun, params) do
    add_op(queue, {:step, name, :let, build_call!(queue, fun, params)})
  end

  # Runs the steps of a conditional in a queue/1 block: the branch taken builds a
  # queue, whose results are added to the state as if its steps were written
  # inline. Only the DSL calls this.
  @doc false
  def __branch__(%Q{} = queue, fun, params) do
    add_op(queue, {:branch, build_call!(queue, fun, params)})
  end

  @doc """
  Builds a queue from a block of steps.

  Each statement is one of:

    * `name = expr` - a step storing the value of `expr`, for values and functions that
      can't fail (compiles to `let/4`)
    * `name <- expr` - a step for functions returning `{:ok, value}`, `{:error, reason}`,
      `:error` or `{:halt, value}` (compiles to `run/4`)
    * `debug()` or `debug(opts)` - prints the state, see `debug/2`
    * `if`, `unless`, `case` or `cond` containing steps - the branch taken adds its steps

  Rules:

    * The step is named after the variable, and its inputs are the earlier steps `expr`
      uses. Other variables are captured as in any closure.
    * The left side is a single named variable, and a name is bound once. Every successful
      result is stored, including names starting with `_`. Bare `_` is not allowed.
    * A step bound inside a branch is in the result, but can't be used after the conditional.
    * A `<-` step whose expression returns a queue runs it as a child, and stores the child's
      results as a map under the step's name. `name <- queue do ... end` nests a block inline.
    * Expressions are evaluated when the queue runs, not when it's built.

  Breaking a rule is a compile error. The block returns the queue without running it, so a
  function can build a queue and its caller decides when to run it, or runs it as a child
  step. Run it with `execute/1`.

  ## Example
      iex> import Q
      iex> queue do
      ...>   input = "aGVsbG8="
      ...>   decoded <- Base.decode64(input)
      ...>   if decoded == "hello", do: greeting = true
      ...> end
      ...> |> execute()
      {:ok, %{input: "aGVsbG8=", decoded: "hello", greeting: true}}
  """
  @doc group: "Writing a pipeline"
  defmacro queue(do: block) do
    Q.DSL.compile(block, __CALLER__)
  end

  defp add_op(%Q{}, {:step, :_, _kind, _}) do
    raise ArgumentError, "every step must have a name; _ cannot name a step"
  end

  defp add_op(%Q{} = queue, {:step, name, _kind, _} = op) do
    unless valid_name?(name) do
      raise ArgumentError,
            "expected a step name to be an atom other than nil, true, false or :_, or a tuple, got: #{Kernel.inspect(name)}"
    end

    if MapSet.member?(queue.names, name) do
      raise ArgumentError, "#{Kernel.inspect(name)} is already a member of the Q"
    end

    %{queue | operations: [op | queue.operations], names: MapSet.put(queue.names, name)}
  end

  defp add_op(%Q{} = queue, op), do: %{queue | operations: [op | queue.operations]}

  defp valid_name?(name),
    do: (is_atom(name) and name not in [nil, true, false, :_]) or is_tuple(name)

  defp validate_debug_opts!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "debug options must be a keyword list, got: #{Kernel.inspect(opts)}"
    end

    case Keyword.fetch(opts, :only) do
      :error ->
        :ok

      {:ok, selection} ->
        keys = if is_list(selection), do: selection, else: [selection]

        unless valid_debug_keys?(keys) do
          raise ArgumentError,
                "debug :only must be a valid step name or a list of valid step names, got: #{Kernel.inspect(selection)}"
        end
    end

    opts
  end

  defp valid_debug_keys?([]), do: true
  defp valid_debug_keys?([name | rest]), do: valid_name?(name) and valid_debug_keys?(rest)
  defp valid_debug_keys?(_other), do: false

  # Resolves a step function and its params into a call, so that mistakes are
  # caught when the step is added rather than when the queue runs.
  defp build_call!(%Q{names: names}, fun, params) do
    {keys, order} = normalize_params!(params)
    check_params_existence(names, keys)
    input = if keys == [], do: :none, else: {:keys, keys}
    resolve_call!(fun, input, order)
  end

  # `order` is nil unless the :order option was given; it places the inputs relative to
  # an MFA's fixed arguments, so a function has nothing for it to order.
  defp resolve_call!(fun, input, nil) when is_function(fun),
    do: {:fun, fun, fun_input!(fun, input)}

  defp resolve_call!(fun, _input, _order) when is_function(fun) do
    raise ArgumentError,
          "the :order option only applies to {module, function, args} steps; " <>
            "a function receives its inputs in the order of its params list"
  end

  defp resolve_call!({mod, fun}, input, order) when is_atom(mod) and is_atom(fun),
    do: mfa_call!(mod, fun, [], input, order || :prepend)

  defp resolve_call!({mod, fun, args}, input, order)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: mfa_call!(mod, fun, args, input, order || :prepend)

  defp resolve_call!(other, _input, _order) do
    raise ArgumentError,
          "expected a function, {module, function} or {module, function, args}, got: #{Kernel.inspect(other)}"
  end

  defp normalize_params!(keys) when is_list(keys), do: {keys, nil}

  defp normalize_params!({keys, opts}) when is_list(keys) and is_list(opts) do
    case Keyword.keys(opts) -- [:order] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown params options #{Kernel.inspect(unknown)}, the only supported option is :order"
    end

    case Keyword.fetch(opts, :order) do
      :error ->
        {keys, nil}

      {:ok, order} when order in [:prepend, :append] ->
        {keys, order}

      {:ok, order} ->
        raise ArgumentError,
              "expected the :order option to be :prepend or :append, got: #{Kernel.inspect(order)}"
    end
  end

  defp normalize_params!(params) do
    raise ArgumentError,
          "expected params to be a list of names or a {names, opts} tuple, got: #{Kernel.inspect(params)}"
  end

  defp fun_input!(fun, input) do
    {:arity, arity} = Function.info(fun, :arity)
    expected = input_arity(input)

    if arity != expected do
      context =
        case input do
          :state -> "to receive the whole state (pass [] for no queue inputs)"
          :none -> "for params []"
          {:keys, keys} -> "for params #{Kernel.inspect(keys)}"
        end

      raise ArgumentError,
            "expected a function of arity #{expected} #{context}, got a function of arity #{arity}"
    end

    input
  end

  defp input_arity(:none), do: 0
  defp input_arity(:state), do: 1
  defp input_arity({:keys, keys}), do: length(keys)

  defp mfa_call!(mod, fun, args, input, order) do
    arity = input_arity(input) + length(args)
    Code.ensure_loaded(mod)

    if not function_exported?(mod, fun, arity) do
      raise ArgumentError, "#{Exception.format_mfa(mod, fun, arity)} is undefined or private"
    end

    {:mfa, mod, fun, args, input, order}
  end

  defp check_params_existence(names, keys) do
    for key <- keys, not MapSet.member?(names, key) do
      raise ArgumentError, "The parameter #{Kernel.inspect(key)} does not exist in the queue."
    end

    :ok
  end

  defp run_ops(ops, state), do: Enum.reduce_while(ops, {:ok, state}, &run_op/2)

  defp run_op({:debug, {:deferred, call}}, {:ok, state}),
    do: print_debug(state, validate_debug_opts!(call(call, state)))

  defp run_op({:debug, opts}, {:ok, state}), do: print_debug(state, opts)

  defp run_op({:step, name, :put, value}, {:ok, state}) do
    {:cont, {:ok, store!(state, name, value)}}
  end

  defp run_op({:step, name, :let, call}, {:ok, state}) do
    {:cont, {:ok, store!(state, name, call(call, state))}}
  end

  # A branch shares its enclosing queue's state, including earlier results.
  defp run_op({:branch, call}, {:ok, state}) do
    %Q{operations: operations} = call(call, state)

    case run_ops(Enum.reverse(operations), state) do
      {:ok, _state} = result -> {:cont, result}
      result -> {:halt, result}
    end
  end

  defp run_op({:step, name, :run, call}, {:ok, state}) do
    case call(call, state) do
      {:ok, value} ->
        {:cont, {:ok, store!(state, name, value)}}

      {:halt, value} ->
        {:halt, {:halted, store!(state, name, value), true}}

      {:halt, value, [propagate: propagate]} when is_boolean(propagate) ->
        {:halt, {:halted, store!(state, name, value), propagate}}

      {:error, reason} ->
        {:halt, {:error, name, reason, state}}

      :error ->
        {:halt, {:error, name, :error, state}}

      %Q{operations: operations} ->
        run_child(name, operations, state)

      {:error, _name, _reason, _state} = executed ->
        raise "expected operation `#{Kernel.inspect(name)}` to return a queue, not the result " <>
                "of executing one, got: #{Kernel.inspect(executed)}; return the queue instead " <>
                "of executing it, so it runs as a child"

      other ->
        raise "expected operation `#{Kernel.inspect(name)}` to return {:ok, value}, {:halt, value}, {:halt, value, propagate: boolean}, {:error, value}, :error or a queue, got: #{Kernel.inspect(other)}"
    end
  end

  # A child queue runs with its own state and its result map is stored under the
  # step's name. Its halt stops the parent too, unless the halt doesn't propagate.
  defp run_child(name, operations, state) do
    case run_ops(Enum.reverse(operations), %{}) do
      {:ok, child} ->
        {:cont, {:ok, store!(state, name, child)}}

      {:halted, child, true} ->
        {:halt, {:halted, store!(state, name, child), true}}

      {:halted, child, false} ->
        {:cont, {:ok, store!(state, name, child)}}

      {:error, child_name, reason, child} ->
        {:halt, {:error, name, {:error, child_name, reason, child}, state}}
    end
  end

  defp call({:fun, fun, input}, state), do: apply(fun, input_args(input, state))

  defp call({:mfa, mod, fun, args, input, :prepend}, state),
    do: apply(mod, fun, input_args(input, state) ++ args)

  defp call({:mfa, mod, fun, args, input, :append}, state),
    do: apply(mod, fun, args ++ input_args(input, state))

  defp input_args(:none, _state), do: []
  defp input_args(:state, state), do: [state]

  defp input_args({:keys, keys}, state), do: Enum.map(keys, &Map.fetch!(state, &1))

  # Names are unique within a queue and the compiler rejects duplicates across
  # branches, so a clash here means a branch function was built by hand.
  defp store!(state, name, value) do
    if Map.has_key?(state, name) do
      raise ArgumentError,
            "step #{Kernel.inspect(name)} conflicts with a step of the same name from a branch"
    end

    Map.put(state, name, value)
  end

  defp print_debug(state, opts) do
    selected =
      case Keyword.fetch(opts, :only) do
        :error -> state
        {:ok, keys} when is_list(keys) -> Map.take(state, keys)
        {:ok, key} -> Map.take(state, [key])
      end

    # credo:disable-for-next-line Credo.Check.Warning.IoInspect
    IO.inspect(selected, Keyword.delete(opts, :only))
    {:cont, {:ok, state}}
  end
end
