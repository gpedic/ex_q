defmodule Q do
  @moduledoc """
  Build pipelines of named steps, in the spirit of `Ecto.Multi`, and run them with `exec/1`.

  Every step's result is stored in a state map under the step's name. Later steps
  receive the whole state, or only the keys they ask for. When a step fails, `exec/1`
  returns the failing step's name and error together with the state built so far.

  ## Steps

    * `put/3` stores a value.
    * `run/4` runs a function that can fail.
    * `let/4` runs a function that can't fail, and stores its return value as is.
    * `merge/3` adds steps at run time, chosen from the results so far.
    * `debug/2` prints the state.

  Steps named with an atom starting with `_`, such as `:_notified`, run but their result
  isn't stored, and the name doesn't have to be unique. A failure still reports the name.

  A `run/4` function must return one of:

    * `{:ok, value}` - stores `value` under the step's name and continues
    * `{:error, reason}` - stops; `exec/1` returns `{:error, name, reason, state}`
    * `:error` - same as `{:error, :error}`, for functions such as `Base.decode64/1`
    * `{:halt, value}` - stores `value` and stops; `exec/1` returns `{:ok, state}`

  Any other return value raises.

  ## Function input

  A step function receives the values of the keys listed in its `params`. Without
  `params` it receives the whole state, or nothing if it is an anonymous function of
  arity 0. See `run/4` for `{module, function, args}` functions.

  ## DSL

  `queue/1` offers the same API without the piping:

      import Q

      queue do
        put(:input, "aGVsbG8=")
        run(:decoded, &Base.decode64/1, [:input])
        exec()
      end

  Only the top-level statements of the block are treated as DSL calls (`put/2`, `run/2`,
  `run/3`, `let/2`, `let/3`, `merge/1`, `merge/2`, `debug/0`, `debug/1` and `exec/0`);
  calls inside step functions are left alone. Steps can't be added inside `if`, `case`
  and the like, and `exec()` must be the last statement; both raise at compile time.
  Use `merge/3` to choose steps based on earlier results.
  """

  alias __MODULE__
  defstruct operations: [], names: MapSet.new(), merged: false
  @opaque t :: %__MODULE__{operations: [operation], names: MapSet.t(), merged: boolean}
  @type state :: map
  @type name :: any
  @type result :: {:ok, any} | {:error, any} | :error | {:halt, any}
  @type step_fun :: (... -> result)
  @type fun_mfa :: {module, atom, [any]} | {module, atom}
  @type params :: [name] | {[name], [order: :prepend | :append]}
  @type kind :: :put | :run | :let | :merge | :debug
  @type exec_error :: {:error, name, any, state}
  @typep input :: :none | :state | {:keys, [name]}
  @typep call :: {:fun, function, input} | {:mfa, module, atom, [any], input, :prepend | :append}
  @typep operation ::
           {:step, name, :put, any}
           | {:step, name, :run | :let, call}
           | {:merge, call}
           | {:debug, Keyword.t()}

  @doc """
  Creates and returns a new, empty `Q` struct.

  The resulting queue can be used as a starting point for queue operations,
  such as `put/3` and `run/4`.

  ## Example
      iex> Q.new() |> Q.to_list()
      []
  """
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
  - `name`: The name to associate with the value. It must be unique, or an error will be raised.
  - `value`: The value to add to the queue.

  ## Errors

  Raises `ArgumentError` if `name` is already present in the queue.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:params, %{foo: "bar"})
      ...> |> Q.exec()
      {:ok, %{params: %{foo: "bar"}}}
  """
  @spec put(t, name, any) :: t
  def put(%Q{} = queue, name, value) do
    add_op(queue, {:step, name, :put, value})
  end

  @doc """
  Lists the queue's operations in the order they were added, as `{kind, name}` tuples.

  `kind` is the function that added the operation; `name` is `nil` for `merge/3` and `debug/2`.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:a, 1)
      ...> |> Q.debug()
      ...> |> Q.run(:b, fn _ -> {:ok, 2} end)
      ...> |> Q.to_list()
      [{:put, :a}, {:debug, nil}, {:run, :b}]
  """
  @spec to_list(t) :: [{kind, name | nil}]
  def to_list(%Q{operations: operations}) do
    operations
    |> Enum.reverse()
    |> Enum.map(fn
      {:step, name, kind, _} -> {kind, name}
      {:merge, _call} -> {:merge, nil}
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
  @spec operations(t) :: [name]
  def operations(%Q{operations: operations}) do
    for {:step, name, _kind, _} <- Enum.reverse(operations), do: name
  end

  @doc """
  Adds an operation to the queue that, when executed, prints the current state of the queue.

  The printing is performed using Elixir's `IO.inspect/2`, which provides a human-readable
  representation of the queue's state.

  ## Params

  - `queue`: The queue to debug.
  - `opts`: Options passed to `IO.inspect/2`. If the `:only` option is provided, only those keys will be printed.

  """
  @spec debug(t, Keyword.t()) :: t
  def debug(%Q{} = queue, opts \\ []) do
    add_op(queue, {:debug, opts})
  end

  @doc """
  Executes the queue, running all operations in the order they were added.

  Each operation is provided with the state of the queue as of the start of the operation.
  If an operation function returns an error, the execution of the queue is halted and an error is returned.

  ## Example
      iex> Q.new()
      ...> |> Q.run(:write, fn _ -> {:ok, "Hello world!"} end)
      ...> |> Q.exec()
      {:ok, %{write: "Hello world!"}}
  """
  @spec exec(t) :: {:ok, state} | exec_error
  def exec(%Q{operations: operations}) do
    case run_ops(Enum.reverse(operations), %{}) do
      {:halted, state} -> {:ok, state}
      result -> result
    end
  end

  @doc """
  Adds a function to be executed as part of the queue.

  This function enables adding operations to the queue that are executed when `exec/1` is called.
  The operations can be anonymous functions or functions in a module.

  The function should return either `{:ok, value}` if the operation was successful or
  `{:error, value}` if the operation failed. Functions can also return {:halt, value} to halt
  execution at any point.

  ## Params

  - `queue`: The queue to which the function should be added.
  - `name`: A unique name for this operation. It will be used as a key in the queue's internal state.
  - `fun`: The function to be run. It can be an anonymous function, a `{module, function}` tuple
    or a `{module, function, args}` tuple.
  - `params` (optional): A list of keys in the queue's internal state that should be passed to the
    function as arguments, or a `{keys, opts}` tuple.

  ## Function input

  - With `params`, the function receives the values of those keys, in order.
  - Without `params`, it receives the whole state, or no arguments if it is an anonymous function
    of arity 0.
  - `{module, function, args}` functions receive `args` as well; see the `:order` option.

  The function's arity is checked when the step is added, and `ArgumentError` is raised if it
  doesn't match, or if a module function doesn't exist.

  ## Options

  - `:order` - for `{module, function, args}` steps, whether the values of `keys` go before
    (`:prepend`, the default) or after (`:append`) `args`. Ignored for anonymous functions.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:key, :b)
      ...> |> Q.run(:value, {Map, :fetch, [%{a: 1, b: 2}]}, {[:key], order: :append})
      ...> |> Q.exec()
      {:ok, %{key: :b, value: 2}}
  """
  @spec run(t, name, step_fun | fun_mfa, params) :: t
  def run(%Q{} = queue, name, fun, params \\ []) do
    add_op(queue, {:step, name, :run, build_call!(queue, fun, params)})
  end

  @doc """
  Adds a step whose function returns a plain value, for functions that can't fail.

  The value is stored under `name` as is. `fun` and `params` work as in `run/4`. Use `run/4`
  when the function returns `{:ok, value}` or `{:error, reason}`.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:text, "hello")
      ...> |> Q.let(:upper, &String.upcase/1, [:text])
      ...> |> Q.exec()
      {:ok, %{text: "hello", upper: "HELLO"}}
  """
  @spec let(t, name, (... -> any) | fun_mfa, params) :: t
  def let(%Q{} = queue, name, fun, params \\ []) do
    add_op(queue, {:step, name, :let, build_call!(queue, fun, params)})
  end

  @doc """
  Adds steps at run time, chosen by a function of the results so far.

  When the queue runs, `fun` is called like a `run/4` step function, with `params` working
  the same way, and must return a queue. That queue runs with its own state, starting empty,
  so pass values into it with a closure. Its results are then added to the state.

  - If a step of the merged queue fails, `exec/1` returns that step's name and error, with
    the state of both queues.
  - If a step of the merged queue halts, the whole pipeline halts.
  - A merged step whose name already exists in the state raises `ArgumentError`.

  The names a merged queue produces aren't known until it runs, so params of steps added
  after a merge are not checked when the steps are added. A missing one raises when the
  queue runs.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:amount, 120)
      ...> |> Q.merge(
      ...>   fn amount ->
      ...>     if amount > 100, do: Q.new() |> Q.put(:approval, :required), else: Q.new()
      ...>   end,
      ...>   [:amount]
      ...> )
      ...> |> Q.exec()
      {:ok, %{amount: 120, approval: :required}}
  """
  @spec merge(t, (... -> t) | fun_mfa, params) :: t
  def merge(%Q{} = queue, fun, params \\ []) do
    %{add_op(queue, {:merge, build_call!(queue, fun, params)}) | merged: true}
  end

  @doc """
  Builds a queue from bindings: `name = expr` for steps that can't fail, `name <- expr` for
  steps that can. See the module documentation.
  """
  defmacro queue(do: block) do
    Q.DSL.compile(block, __CALLER__)
  end

  defp add_op(%Q{} = queue, {:step, name, _kind, _} = op) do
    if unstored?(name) do
      %{queue | operations: [op | queue.operations]}
    else
      add_named_op(queue, name, op)
    end
  end

  defp add_op(%Q{} = queue, op), do: %{queue | operations: [op | queue.operations]}

  defp add_named_op(queue, name, op) do
    if MapSet.member?(queue.names, name) do
      raise ArgumentError, "#{Kernel.inspect(name)} is already a member of the Q"
    end

    %{queue | operations: [op | queue.operations], names: MapSet.put(queue.names, name)}
  end

  defp unstored?(name), do: is_atom(name) and String.starts_with?(Atom.to_string(name), "_")

  # Resolves a step function and its params into a call, so that mistakes are
  # caught when the step is added rather than when the queue runs.
  defp build_call!(%Q{names: names, merged: merged}, fun, params) do
    {keys, order} = normalize_params!(params)

    # Steps added by a merge are only known at run time, see merge/3
    if not merged, do: check_params_existence(names, keys)

    case fun do
      fun when is_function(fun) ->
        {:fun, fun, fun_input!(fun, keys)}

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        mfa_call!(mod, fun, [], keys, order)

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        mfa_call!(mod, fun, args, keys, order)

      other ->
        raise ArgumentError,
              "expected a function, {module, function} or {module, function, args}, got: #{Kernel.inspect(other)}"
    end
  end

  defp normalize_params!(keys) when is_list(keys), do: {keys, :prepend}

  defp normalize_params!({keys, opts}) when is_list(keys) and is_list(opts) do
    case Keyword.keys(opts) -- [:order] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown params options #{Kernel.inspect(unknown)}, the only supported option is :order"
    end

    case Keyword.get(opts, :order, :prepend) do
      order when order in [:prepend, :append] ->
        {keys, order}

      order ->
        raise ArgumentError,
              "expected the :order option to be :prepend or :append, got: #{Kernel.inspect(order)}"
    end
  end

  defp normalize_params!(params) do
    raise ArgumentError,
          "expected params to be a list of names or a {names, opts} tuple, got: #{Kernel.inspect(params)}"
  end

  defp fun_input!(fun, keys) do
    {:arity, arity} = Function.info(fun, :arity)

    case {keys, arity} do
      {[], 0} ->
        :none

      {[], 1} ->
        :state

      {[], _} ->
        raise ArgumentError,
              "expected a function of arity 0, or 1 to receive the state, got a function of arity #{arity}"

      {keys, arity} when length(keys) == arity ->
        {:keys, keys}

      {keys, _} ->
        raise ArgumentError,
              "expected a function of arity #{length(keys)} for params #{Kernel.inspect(keys)}, " <>
                "got a function of arity #{arity}"
    end
  end

  defp mfa_call!(mod, fun, args, keys, order) do
    {input, input_arity} = if keys == [], do: {:state, 1}, else: {{:keys, keys}, length(keys)}
    arity = input_arity + length(args)
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

  defp run_op({:debug, opts}, {:ok, state}) do
    if opts[:only] do
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      state |> Map.take(List.wrap(opts[:only])) |> IO.inspect(opts)
    else
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      IO.inspect(state, opts)
    end

    {:cont, {:ok, state}}
  end

  defp run_op({:step, name, :put, value}, {:ok, state}) do
    {:cont, {:ok, store!(state, name, value)}}
  end

  defp run_op({:step, name, :let, call}, {:ok, state}) do
    {:cont, {:ok, store!(state, name, call(call, state))}}
  end

  defp run_op({:merge, call}, {:ok, state}) do
    case call(call, state) do
      %Q{operations: operations} ->
        case run_ops(Enum.reverse(operations), %{}) do
          {:ok, merged} ->
            {:cont, {:ok, merge_state!(state, merged)}}

          {:halted, merged} ->
            {:halt, {:halted, merge_state!(state, merged)}}

          {:error, name, reason, merged} ->
            {:halt, {:error, name, reason, merge_state!(state, merged)}}
        end

      other ->
        raise "expected the merge function to return a Q, got: #{Kernel.inspect(other)}"
    end
  end

  defp run_op({:step, name, :run, call}, {:ok, state}) do
    case call(call, state) do
      {:ok, value} ->
        {:cont, {:ok, store!(state, name, value)}}

      {:halt, value} ->
        {:halt, {:halted, store!(state, name, value)}}

      {:error, reason} ->
        {:halt, {:error, name, reason, state}}

      :error ->
        {:halt, {:error, name, :error, state}}

      other ->
        raise "expected operation `#{Kernel.inspect(name)}` to return {:ok, value}, {:halt, value}, {:error, value} or :error, got: #{Kernel.inspect(other)}"
    end
  end

  defp call({:fun, fun, input}, state), do: apply(fun, input_args(input, state))

  defp call({:mfa, mod, fun, args, input, :prepend}, state),
    do: apply(mod, fun, input_args(input, state) ++ args)

  defp call({:mfa, mod, fun, args, input, :append}, state),
    do: apply(mod, fun, args ++ input_args(input, state))

  defp input_args(:none, _state), do: []
  defp input_args(:state, state), do: [state]

  defp input_args({:keys, keys}, state) do
    Enum.map(keys, fn key ->
      case Map.fetch(state, key) do
        {:ok, value} ->
          value

        :error ->
          raise "the parameter #{Kernel.inspect(key)} is not in the state, " <>
                  "it was expected from a merged queue"
      end
    end)
  end

  # Names are unique within a queue, so a clash is only possible with a merged queue
  defp store!(state, name, value) do
    cond do
      unstored?(name) ->
        state

      Map.has_key?(state, name) ->
        raise ArgumentError,
              "step #{Kernel.inspect(name)} conflicts with a merged step of the same name"

      true ->
        Map.put(state, name, value)
    end
  end

  defp merge_state!(state, merged) do
    Map.merge(state, merged, fn name, _, _ ->
      raise ArgumentError,
            "merged step #{Kernel.inspect(name)} conflicts with a step of the same name"
    end)
  end
end
