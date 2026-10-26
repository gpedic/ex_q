defmodule Q do
  @moduledoc """
  A `with` that remembers: a chain of named steps, run with `execute/1`, that keeps every
  step's result.

  Each step's result is stored under the step's name. When a step fails, `execute/1` returns
  the step's name, its error and the results of every step before it.

  ## Writing a pipeline

  Pipelines are written with `queue/2`, where every step is a binding:

      import Q

      queue bind: [data] do
        trimmed = String.trim(data)        # a function that can't fail
        decoded <- Base.decode64(trimmed)  # a function that can fail
        notified <- Notifier.notify(decoded)
      end
      |> execute()

  A block is a scope of its own, like `quote`: a step's expression can use earlier steps,
  which become its inputs, but not variables from outside the block. Outside values come in
  through `bind:`, which makes them the queue's first steps. The block only builds the
  queue; `execute/1` runs it. See `queue/2` for all the rules.

  The block is checked when your code compiles. For pipelines built from data there is a
  functional API, checked when each step is added; see "The functional API" below.

  ## Results

  A step written with `<-` must return one of:

    * `{:ok, value}` - stores `value` under the step's name and continues
    * `{:error, reason}` - stops; `execute/1` returns `{:error, step, reason, results}`
    * `:error` - same as `{:error, :error}`, for functions such as `Base.decode64/1`
    * `{:halt, value}` - stores `value` and stops the queue it's written in; `execute/1`
      returns `{:ok, results}`
    * a queue - runs it as a child, see below
    * any other value - stores it under the step's name as is

  So `<-` works for functions that return plain values too. Returning the error tuple of
  a failed `execute/1` instead of the queue itself raises: return the queue, so it runs as
  a child.

  A step written with `=` can't fail or halt: whatever its expression returns is stored as
  is, without unwrapping, so `{:ok, 1}` is stored as `{:ok, 1}`. Only an exception stops it.
  Use `=` for values and for calls whose result you want exactly as it is, and `<-` when
  the result decides what happens next. Reading a block, `<-` marks the steps that can
  fail.

  Exceptions raised by step functions propagate unchanged, including exceptions in child
  queues. They aren't converted into error tuples, and Q doesn't attach the results to
  them. This applies to both `run/4` (`<-`) and `let/4` (`=`) steps.

  Q doesn't roll back completed steps. After an error, exception or halt, the side effects
  of earlier steps stay in place, and undoing them is up to you.

  ## Child queues

  A function that returns a queue runs it as a child, starting with no results, and the
  child's results are stored as a map under the step's name. The child's step names stay
  separate from the parent's, so a queue built by a function can be reused anywhere:

      queue bind: [id] do
        user <- Accounts.fetch_user(id)
        billing <- billing_steps(user)
        shipping <- shipping_steps(user)
        confirmation <- confirm(billing.invoice, shipping.tracking)
      end

  If a child step fails, the parent step fails with the child's error tuple as the reason:
  `{:error, :billing, {:error, :invoice, :declined, %{...}}, %{id: ..., user: ...}}`. A halt
  stops the queue it's written in, as `{:halt, acc}` stops the `Enum.reduce_while/3` it's
  in: a halt in a child ends the child, and the parent stores the child's results so far,
  continues, and can halt in turn based on them. To store a queue as a value instead of
  running it, use `=` or return `{:ok, queue}`.

  ## The functional API

  A `queue` block compiles to these functions, which are also public:

    * `put/3` stores a value.
    * `run/4` runs a function that can fail, like `<-`.
    * `let/4` runs a function that can't fail, like `=`.
    * `debug/2` prints the results so far.

  Both build the same queue, run with `execute/1`, and share the result and error shapes,
  child queues and halts. A queue built either way can be a child step of the other.

  The `queue` block gives compile-time checks (a misspelled step reference, an outside variable that
  wasn't bound, a step bound twice), inputs inferred from the expression, and inline
  nesting.

  The functional API gives what a block can't: a step per item, named after the item
  (`Q.run(q, {:invite, id}, fn -> invite(id) end, [])` inside `Enum.reduce/3`); names that
  aren't variables; steps chosen from data; queues built across functions or on a condition
  known when the queue is built; and explicit control over inputs. A step function receives
  the results of the steps listed in its `params`. Omitting `params` passes all results so
  far as one map; explicit `[]` passes no queue inputs. These rules apply to both functions
  and MFAs. See `run/4` for `{module, function, args}`.

  The functional API is checked when the step is added: a wrong arity, an unknown param, an
  invalid name or a duplicate name raise `ArgumentError` before anything runs, but only once
  that code runs. Use a `queue` block whenever the pipeline is written out in code.

  Every step has a unique name and stores its successful result. Names are atoms, such as
  `:user`, or tuples, such as `{:invite, user_id}`. The atoms `nil`, `true`, `false` and `:_`
  are not allowed. Names starting with `_`, such as `:_notified`, follow the same rules.
  """

  alias __MODULE__
  defstruct operations: [], names: MapSet.new()
  @opaque t :: %__MODULE__{operations: [operation], names: MapSet.t()}
  @typedoc "The results: each step's result, stored under the step's name."
  @type state :: map
  @typedoc """
  An atom or tuple identifying a step. The atoms `nil`, `true`, `false` and `:_` are excluded.
  """
  @type name :: atom | tuple
  @typedoc """
  The return values a `run/4` step treats specially. Any other value is stored as is.
  """
  @type result ::
          {:ok, any}
          | {:error, any}
          | :error
          | {:halt, any}
          | t
  @type step_fun :: (... -> result | any)
  @type fun_mfa :: {module, atom, [any]} | {module, atom}
  @type params :: [name] | {[name], [order: :prepend | :append]}
  @typep kind :: :put | :run | :let | :debug
  @type error :: {:error, name, any, state}
  @typep input :: :none | :state | {:keys, [name]}
  @typep call :: {:fun, function, input} | {:mfa, module, atom, [any], input, :prepend | :append}
  @typep operation ::
           {:step, name, :put, any}
           | {:step, name, :run | :let, call}
           | {:debug, Keyword.t()}
           | {:debug, {:deferred, call}}

  @doc """
  Returns an empty queue, to add steps to with `put/3`, `run/4`, `let/4` and `debug/2`.

  ## Example
      iex> Q.new() |> Q.operations()
      []
  """
  @doc group: "Functional API"
  @spec new :: t
  # MapSet.new() is compiled into a literal %MapSet{}, which OTP 28's Dialyzer reports as
  # building MapSet's opaque internals in this module. The value is a normal MapSet.
  @dialyzer {:no_contracts, new: 0}
  def new do
    %Q{names: MapSet.new()}
  end

  @doc """
  Adds a step that stores `value` under `name`.

  Returns a new queue with the step added; queues are immutable. When the queue runs, the
  step stores `value` under `name`, where later steps can use it.

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
  # debug calls. Internal: used by the tests to check what a queue block compiles to.
  # Users get step names from operations/1.
  @doc false
  @spec __to_list__(t) :: [{kind, name | nil}]
  def __to_list__(%Q{operations: operations}) do
    operations
    |> Enum.reverse()
    |> Enum.map(fn
      {:step, name, kind, _} -> {kind, name}
      {:debug, _opts} -> {:debug, nil}
    end)
  end

  @doc """
  Returns the names of the queue's steps, in the order they were added.

  Debug calls aren't steps, so they aren't listed. Neither are the steps inside a child
  queue: a child queue appears as the step that runs it.

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
  Adds an operation that prints the results so far when execution reaches it.

  In a child queue, it prints the child's results. Printing or filtering never changes the
  results.

  The printing is performed using Elixir's `IO.inspect/2`. The Q-specific `:only` option
  selects one valid step name or a list of names; `only: []` prints an empty map. Valid
  names that aren't present are omitted. Remaining options, such as `:label`, are passed
  to `IO.inspect/2` after removing `:only`.

  In a `queue` block, options are evaluated each time execution reaches the debug
  statement, can reference earlier steps, and aren't evaluated after an error or halt.
  Options passed to `debug/2` are validated when added; options in a `queue` block when
  they're evaluated. Invalid options or selections raise `ArgumentError`.

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

  # A queue block evaluates the options expression only when this operation is reached.
  @doc false
  def __debug__(%Q{} = queue, fun, params) do
    add_op(queue, {:debug, {:deferred, build_call!(queue, fun, params)}})
  end

  @doc """
  Runs the queue's steps in order and returns `{:ok, results}`.

  When a step fails, execution stops and returns `{:error, step, reason, results}`, with
  the results of the steps before it. Exceptions propagate unchanged, including from child
  queues; Q doesn't turn them into error tuples or attach the results to them.

  Q doesn't roll back completed steps after an error, exception or halt.

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
      {:halted, state} -> {:ok, state}
      result -> result
    end
  end

  @doc """
  Adds a step whose function receives all results so far as one map.

  MFA fixed arguments follow the results. Use `run/4` with `[]` for no queue inputs, or
  with a list of names to receive specific results. See `run/4` for the return contract.
  """
  @doc group: "Functional API"
  @spec run(t, name, step_fun | fun_mfa) :: t
  def run(%Q{} = queue, name, fun) do
    add_op(queue, {:step, name, :run, resolve_call!(fun, :state, nil)})
  end

  @doc """
  Adds a step that runs a function, like `<-` in a `queue` block.

  The function's return value decides what happens next: `{:ok, value}` stores `value`
  under `name`; `{:error, reason}` or `:error` stops the queue; `{:halt, value}` stores
  `value` and stops the queue with success; a queue runs as a child, with its results
  stored under `name`; and any other value is stored as is. See the module documentation.

  ## Params

  - `queue`: The queue to add the step to.
  - `name`: A unique atom or tuple; the step's result is stored under it. See `t:name/0` for
    exclusions.
  - `fun`: The function to run: an anonymous function, a `{module, function}` tuple or a
    `{module, function, args}` tuple.
  - `params` (optional): The names of earlier steps whose results are passed to the function
    as arguments, or a `{names, opts}` tuple. Omitting it passes all results so far;
    explicit `[]` passes no queue inputs.

  ## Function input

  - Without `params`, the function receives all results so far as one map.
  - With `[]` (or `{[], opts}`), no queue inputs are passed.
  - With named `params`, the function receives the results of those steps, in order.
  - These rules apply to both functions and MFAs. `{module, function, args}` functions
    receive `args` as well; see the `:order` option. With `[]`, only these fixed arguments
    are passed.

  The function's arity is checked when the step is added, and `ArgumentError` is raised if it
  doesn't match, or if a module function doesn't exist.

  ## Options

  - `:order` - for `{module, function, args}` steps, whether the inputs go before
    (`:prepend`, the default) or after (`:append`) `args`. Passing it with a function or
    capture raises `ArgumentError`: a function receives its inputs in the order of `params`.

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
  Adds a plain-value step whose function receives all results so far as one map.

  The return value is stored unchanged. MFA fixed arguments follow the results. Use
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

  @doc """
  Builds a queue from a block of steps.

  Each statement is one of:

    * `name = expr` - a step that can't fail: the value of `expr` is stored as is, without
      unwrapping, even `{:ok, value}` (compiles to `let/4`)
    * `name <- expr` - a step whose result decides what happens next: `{:ok, value}` is
      unwrapped, `{:error, reason}` or `:error` stops the pipeline, `{:halt, value}` ends
      it; any other value is stored as is (compiles to `run/4`)
    * `debug()` or `debug(opts)` - prints the results so far, see `debug/2`

  Rules:

    * The step is named after the variable, and its inputs are the earlier steps `expr`
      uses. Variables from outside the block can't be used; bring them in with `bind:`.
      Variables bound inside `expr` itself, such as `fn` arguments and `case` patterns,
      work as usual.
    * The left side is a single named variable, and a name is bound once. Every successful
      result is stored, including names starting with `_`. Bare `_` is not allowed.
    * A conditional goes inside a step and chooses its value:
      `name <- if cond, do: ..., else: ...`. A branch can return a queue to run several
      steps as a child.
    * A `<-` step whose expression returns a queue runs it as a child, and stores the child's
      results as a map under the step's name. `name <- queue bind: [...] do ... end` nests a
      block inline; the nested block binds what it needs, like any other.
    * Expressions are evaluated when the queue runs, not when it's built.

  Breaking a rule is a compile error. The block returns the queue without running it, so a
  function can build a queue and its caller decides when to run it, or runs it as a child
  step. Run it with `execute/1`.

  ## Options

    * `bind:` - a list of outside values to bring in, each becoming one of the queue's
      first steps. A bare variable is bound under its own name; a `name: expr` pair binds
      the value of any expression. The values are evaluated when the block is built, and
      they're stored like any step, including in error tuples.

  ## Example
      iex> import Q
      iex> data = "aGVsbG8="
      iex> queue bind: [data] do
      ...>   decoded <- Base.decode64(data)
      ...>   greeting = decoded == "hello"
      ...> end
      ...> |> execute()
      {:ok, %{data: "aGVsbG8=", decoded: "hello", greeting: true}}
  """
  @doc group: "Writing a pipeline"
  defmacro queue(opts \\ [], do: block) do
    Q.DSL.compile(opts, block, __CALLER__)
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
      raise ArgumentError, "#{Kernel.inspect(name)} is already a step in this queue"
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
          :state -> "to receive all results (pass [] for no queue inputs)"
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
      raise ArgumentError, "param #{Kernel.inspect(key)} is not a step added before this one"
    end

    :ok
  end

  defp run_ops(ops, state), do: Enum.reduce_while(ops, {:ok, state}, &run_op/2)

  defp run_op({:debug, {:deferred, call}}, {:ok, state}),
    do: print_debug(state, validate_debug_opts!(call(call, state)))

  defp run_op({:debug, opts}, {:ok, state}), do: print_debug(state, opts)

  defp run_op({:step, name, :put, value}, {:ok, state}) do
    {:cont, {:ok, Map.put(state, name, value)}}
  end

  defp run_op({:step, name, :let, call}, {:ok, state}) do
    {:cont, {:ok, Map.put(state, name, call(call, state))}}
  end

  defp run_op({:step, name, :run, call}, {:ok, state}) do
    case call(call, state) do
      {:ok, value} ->
        {:cont, {:ok, Map.put(state, name, value)}}

      {:halt, value} ->
        {:halt, {:halted, Map.put(state, name, value)}}

      {:error, reason} ->
        {:halt, {:error, name, reason, state}}

      :error ->
        {:halt, {:error, name, :error, state}}

      %Q{operations: operations} ->
        run_child(name, operations, state)

      {:error, _name, _reason, _state} = executed ->
        raise "expected step #{Kernel.inspect(name)} to return a queue, not the result " <>
                "of executing one, got: #{Kernel.inspect(executed)}; return the queue instead " <>
                "of executing it, so it runs as a child"

      # Anything else is a plain value, stored as is
      value ->
        {:cont, {:ok, Map.put(state, name, value)}}
    end
  end

  # A child queue runs with its own state and its result map is stored under the
  # step's name. A halt stops the queue it's written in, so a halted child ends
  # with the results it has so far and the parent continues.
  defp run_child(name, operations, state) do
    case run_ops(Enum.reverse(operations), %{}) do
      {:ok, child} ->
        {:cont, {:ok, Map.put(state, name, child)}}

      {:halted, child} ->
        {:cont, {:ok, Map.put(state, name, child)}}

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
