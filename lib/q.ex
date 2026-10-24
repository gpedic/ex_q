defmodule Q do
  @moduledoc """
  Build pipelines of named steps, in the spirit of `Ecto.Multi`, and run them with `exec/1`.

  Every step's result is stored in a state map under the step's name. Later steps
  receive the whole state, or only the keys they ask for. When a step fails, `exec/1`
  returns the failing step's name and error together with the state built so far.

  ## Steps

  A step function must return one of:

    * `{:ok, value}` - stores `value` under the step's name and continues
    * `{:error, reason}` - stops; `exec/1` returns `{:error, name, reason, state}`
    * `{:halt, value}` - stores `value` and stops; `exec/1` returns `{:ok, state}`

  Any other return value raises.

  ## DSL

  `queue/1` offers the same API without the piping:

      import Q, only: [queue: 1]

      queue do
        put(:input, "aGVsbG8=")
        run(:decoded, &Base.decode64/1, [:input])
        exec()
      end

  Only the top-level statements of the block are treated as DSL calls (`put/2`,
  `run/2`, `run/3`, `inspect/0`, `inspect/1` and `exec/0`); calls inside step
  functions are left alone. Steps can't be added conditionally (inside `if`, `case`
  and the like) and `exec()` must be the last statement; both raise at compile time.
  Use the functional API to add steps conditionally.

  A plain `import Q` also imports `Q.inspect/2`, which makes calls to `inspect/1,2`
  in the importing module ambiguous with `Kernel.inspect/2`. Import only what you
  need, as above.
  """

  alias __MODULE__
  defstruct operations: [], names: MapSet.new()
  @type t :: %__MODULE__{operations: operations, names: names}
  @type state :: map
  @type result :: {:ok, any} | {:error, any} | {:halt, any}
  @type fun_arity1 :: (state -> result)
  @type step_fun :: (... -> result)
  @type fun_mfa :: {module, atom, [any]} | {module, atom}
  @type params :: [name] | {[name], [order: :prepend | :append]}
  @typep operation ::
           {:run, {step_fun, params} | {module, atom, [any], params}}
           | {:put, any}
           | {:inspect, Keyword.t()}
  @typep operations :: [{name, operation}]
  @typep names :: MapSet.t()
  @type name :: any
  @type exec_error :: {:error, name, any, state}

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

  This function will raise an error if `name` is already present in the queue.

  ## Example
      iex> Q.new()
      ...> |> Q.put(:params, %{foo: "bar"})
      ...> |> Q.exec()
      {:ok, %{params: %{foo: "bar"}}}
  """
  @spec put(t, name, any) :: t
  def put(queue, name, value) do
    add_operation(queue, name, {:put, value}, [])
  end

  @doc """
  Converts the operations queue to a list, in the order they were added.

  This function is useful for inspecting the current state of the queue.
  Direct inspection of the queue's internal state is discouraged to maintain
  encapsulation.
  """
  @spec to_list(t) :: [{name, term}]
  def to_list(%Q{operations: operations}) do
    operations
    |> Enum.reverse()
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
  @spec operations(Q.t()) :: list
  def operations(%Q{operations: operations}) do
    operations
    |> Enum.map(fn {op_name, _} -> op_name end)
    |> Enum.reverse()
  end

  @doc """
  Adds an operation to the queue that, when executed, prints the current state of the queue.

  The printing is performed using Elixir's `IO.inspect/2`, which provides a human-readable
  representation of the queue's state.

  ## Params

  - `queue`: The queue to inspect.
  - `opts`: Options passed to `IO.inspect/2`. If the `:only` option is provided, only those keys will be printed.

  """
  @spec inspect(t, Keyword.t()) :: t
  def inspect(queue, opts \\ []) do
    Map.update!(queue, :operations, &[{:inspect, {:inspect, opts}} | &1])
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
  @spec exec(t) :: {:ok, term} | exec_error
  def exec(%Q{operations: operations}) do
    operations
    |> Enum.reverse()
    |> apply_operations()
  end

  @doc """
  Adds a function to be executed as part of the queue.

  This function enables adding operations to the queue that are executed when `exec/1` is called.
  The operations can be anonymous functions or functions in a module.

  The function should return either `{:ok, value}` if the operation was successful or
  `{:error, value}` if the operation failed. The state of the queue is passed
  as arguments to the function if no params are specified.

  Functions can also return {:halt, value} to halt execution at any point.

  ## Params

  - `queue`: The queue to which the function should be added.
  - `name`: A unique name for this operation. It will be used as a key in the queue's internal state.
  - `fun`: The function to be run. It can be an anonymous function, a `{module, function}` tuple
    or a `{module, function, args}` tuple.
  - `params` (optional): A list of keys in the queue's internal state that should be passed to the
    function as arguments, or a `{keys, opts}` tuple.

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
  def run(queue, name, fun, params \\ [])

  def run(queue, name, {mod, fun, args}, params)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    add_operation(queue, name, {:run, {mod, fun, args, params}}, params)
  end

  def run(queue, name, {mod, fun}, params)
      when is_atom(mod) and is_atom(fun) do
    run(queue, name, {mod, fun, []}, params)
  end

  def run(queue, name, fun, params) when is_function(fun) do
    add_operation(queue, name, {:run, {fun, params}}, params)
  end

  @doc """
  Adds a function to be executed as part of the queue.
  Similar to `run/4`, but allows to pass module name, function and arguments.

  The function should return either `{:ok, value}` if the operation was successful or
  `{:error, value}` if the operation failed. The state of the queue is passed
  as arguments to the function if no params are specified.

  Functions can also return {:halt, value} to halt execution at any point.

  ## Params

  - `queue`: The queue to which the function should be added.
  - `name`: A unique name for this operation. It will be used as a key in the queue's internal state.
  - `mod`: The module where the function is defined.
  - `fun`: The function to be executed.
  - `args`: Arguments that should be passed to the function.
  - `params` (optional): A list of keys in the queue's internal state that should be passed to the
    function as arguments, or a `{keys, opts}` tuple. See `run/4` for the options.
  """
  @spec run(t, name, module, function :: atom, args :: [any], params) :: t
  def run(queue, name, mod, fun, args, params \\ [])
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    add_operation(queue, name, {:run, {mod, fun, args, params}}, params)
  end

  @doc """
  Provides a DSL for creating a queue using a more declarative syntax.

  Only top-level statements are DSL calls; see the module documentation for the limitations.

  ## Example
      queue do
        put(:input, "some data")
        run(:processed, &process_data/1, [:input])
        exec()      # optional, will return the result immediately
      end
  """
  defmacro queue(do: block) do
    statements = dsl_statements(block)
    validate_dsl!(statements)
    body = Enum.map(statements, &transform_dsl/1)

    quote do
      (fn ->
         queue = Q.new()
         unquote_splicing(body)
         queue
       end).()
    end
  end

  @doc false
  def transform_dsl({:exec, _meta, []}) do
    quote do
      queue = Q.exec(queue)
    end
  end

  def transform_dsl({:put, _meta, [name, value]}) do
    quote do
      queue = Q.put(queue, unquote(name), unquote(value))
    end
  end

  def transform_dsl({:run, _meta, [name, fun, params]}) do
    quote do
      queue = Q.run(queue, unquote(name), unquote(fun), unquote(params))
    end
  end

  def transform_dsl({:run, _meta, [name, fun]}) do
    quote do
      queue = Q.run(queue, unquote(name), unquote(fun), [])
    end
  end

  def transform_dsl({:inspect, _meta, []}) do
    quote do
      queue = Q.inspect(queue)
    end
  end

  def transform_dsl({:inspect, _meta, [opts]}) do
    quote do
      queue = Q.inspect(queue, unquote(opts))
    end
  end

  def transform_dsl(other), do: other

  defp dsl_statements({:__block__, _meta, statements}), do: statements
  defp dsl_statements(statement), do: [statement]

  defp validate_dsl!(statements) do
    last_index = length(statements) - 1

    statements
    |> Enum.with_index()
    |> Enum.each(fn {statement, index} ->
      if match?({:exec, _, []}, statement) and index != last_index do
        raise ArgumentError, "exec() must be the last statement in queue/1"
      end

      reject_nested_dsl!(statement)
    end)
  end

  # Steps can only be added by top-level statements. A DSL call nested in another
  # expression (`if`, `case`, an assignment, ...) would not add its step to the
  # queue, so it is rejected. Function bodies are skipped: calls in there belong
  # to the step, not the DSL. `inspect/1` is not checked as it is usually
  # `Kernel.inspect/1`.
  defp reject_nested_dsl!(statement) do
    if dsl_call?(statement) do
      {_name, _meta, args} = statement
      Enum.each(args, &find_nested_dsl!/1)
    else
      find_nested_dsl!(statement)
    end
  end

  defp find_nested_dsl!(ast) do
    Macro.prewalk(ast, fn
      {:fn, _, _} ->
        nil

      {:inspect, _, [_]} = node ->
        node

      {name, _, args} = node when is_atom(name) and is_list(args) ->
        if dsl_call?(node) do
          raise ArgumentError,
                "#{name}/#{length(args)} must be a top-level statement in queue/1, " <>
                  "steps can't be added inside other expressions such as `if` or `case`; " <>
                  "use the functional API to add steps conditionally"
        end

        node

      node ->
        node
    end)
  end

  defp dsl_call?({:exec, _, []}), do: true
  defp dsl_call?({:put, _, [_, _]}), do: true
  defp dsl_call?({:run, _, [_, _]}), do: true
  defp dsl_call?({:run, _, [_, _, _]}), do: true
  defp dsl_call?({:inspect, _, []}), do: true
  defp dsl_call?({:inspect, _, [_]}), do: true
  defp dsl_call?(_), do: false

  defp add_operation(%Q{} = queue, name, operation, params) do
    %{operations: operations, names: names} = queue
    check_params_existence(names, param_names(params))

    if MapSet.member?(names, name) do
      raise "#{Kernel.inspect(name)} is already a member of the Q"
    else
      %{queue | operations: [{name, operation} | operations], names: MapSet.put(names, name)}
    end
  end

  defp param_names(params) when is_list(params), do: params

  defp param_names({params, opts}) when is_list(params) and is_list(opts) do
    case Keyword.get(opts, :order, :prepend) do
      order when order in [:prepend, :append] ->
        params

      order ->
        raise ArgumentError,
              "expected the :order option to be :prepend or :append, got: #{Kernel.inspect(order)}"
    end
  end

  defp param_names(params) do
    raise ArgumentError,
          "expected params to be a list of names or a {names, opts} tuple, got: #{Kernel.inspect(params)}"
  end

  defp apply_operations([]), do: {:ok, nil}

  defp apply_operations(operations) do
    Enum.reduce_while(operations, {:ok, %{}}, &apply_operation/2)
  end

  defp apply_operation({:inspect, {:inspect, opts}}, {:ok, acc}) do
    if opts[:only] do
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      acc |> Map.take(List.wrap(opts[:only])) |> IO.inspect(opts)
    else
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      IO.inspect(acc, opts)
    end

    {:cont, {:ok, acc}}
  end

  defp apply_operation({name, operation}, {:ok, acc}) do
    case run_operation(operation, acc) do
      {:ok, value} ->
        {:cont, {:ok, Map.put(acc, name, value)}}

      {:halt, value} ->
        {:halt, {:ok, Map.put(acc, name, value)}}

      {:error, value} ->
        {:halt, {:error, name, value, acc}}

      other ->
        raise "expected operation `#{Kernel.inspect(name)}` to return {:ok, value}, {:halt, value} or {:error, value}, got: #{Kernel.inspect(other)}"
    end
  end

  defp run_operation({:run, run}, acc),
    do: apply_run_fun(run, acc)

  defp run_operation({:put, value}, _acc),
    do: {:ok, value}

  defp apply_run_fun({mod, fun, args, {params, opts}}, acc)
       when is_list(opts) and is_list(params) do
    param_args = build_args(acc, params, [])

    final_args =
      case Keyword.get(opts, :order, :prepend) do
        :prepend -> param_args ++ args
        :append -> args ++ param_args
      end

    apply(mod, fun, final_args)
  end

  defp apply_run_fun({mod, fun, args, params}, acc) when is_list(params) do
    apply_run_fun({mod, fun, args, {params, []}}, acc)
  end

  defp apply_run_fun({fun, {params, _opts}}, acc) when is_function(fun) do
    apply_run_fun({fun, params}, acc)
  end

  defp apply_run_fun({fun, params}, acc) when is_function(fun) do
    apply(fun, build_args(acc, params, []))
  end

  defp build_args(acc, params, rest_args) do
    case params do
      [] -> [acc | rest_args]
      _ -> Enum.map(params, fn key -> Map.get(acc, key) end) ++ rest_args
    end
  end

  defp check_params_existence(_names, []), do: :ok

  defp check_params_existence(names, params) do
    for param <- params do
      unless MapSet.member?(names, param) do
        raise "The parameter #{Kernel.inspect(param)} does not exist in the queue."
      end
    end

    :ok
  end
end
