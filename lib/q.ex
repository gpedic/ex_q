defmodule Q do
  @moduledoc """
    ExQ

    Documentation for `ExQ`.
  """

  alias __MODULE__
  defstruct operations: [], names: MapSet.new()
  @type t :: %__MODULE__{operations: operations, names: names}
  @type changes :: map
  @type run :: (changes -> {:ok | :error, any}) | {module, atom, [any]}
  @typep operation :: {:run, run} | {:put, any} | {:inspect, Keyword.t()}
  @typep operations :: [{name, operation}]
  @typep names :: MapSet.t()
  @type name :: any
  @type exec_error :: {:error, name, any, list}

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
    %Q{}
  end

  @doc """
  Adds a value to the changes so far under the given name.

  This function modifies the queue by associating the given `name` with a `value`.
  If the operation is successful, the `name` will become a key in the queue's internal
  state map, and `value` will be its associated value.

  ## Params

  - `que`: The queue to add the value to.
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
  def put(que, name, value) do
    add_operation(que, name, {:put, value}, [])
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

      ["test", "init"]
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

  - `que`: The queue to inspect.
  - `opts`: Options passed to `IO.inspect/2`. If the `:only` option is provided, only those keys will be printed.

  """
  @spec inspect(t, Keyword.t()) :: t
  def inspect(que, opts \\ []) do
    Map.update!(que, :operations, &[{:inspect, {:inspect, opts}} | &1])
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
  def exec(%Q{} = que) do
    Enum.reverse(que.operations)
    |> apply_operations(que.names)
    |> case do
      {name, value, acc} -> {:error, name, value, acc}
      {results, _} -> {:ok, results}
    end
  end

  @doc """
  Adds a function to be executed as part of the queue.

  This function enables adding operations to the queue that are executed when `exec/1` is called.
  The operations can be anonymous functions or functions in a module.

  The function should return either `{:ok, value}` if the operation was successful or
  `{:error, value}` if the operation failed. The state of the queue is passed
  as arguments to the function if no params are specified.

  Functions can additionally return {:halt, value} to halt execution early.

  ## Params

  - `que`: The queue to which the function should be added.
  - `name`: A unique name for this operation. It will be used as a key in the queue's internal state.
  - `run`: The function to be run. It can be an anonymous function or a tuple containing a module, function, and arguments.
  - `params` (optional): A list of keys in the queue's internal state that should be passed to the function as arguments.

  """
  @spec run(t, name, run, [atom]) :: t
  def run(que, name, run, params \\ [])

  def run(que, name, {mod, fun, args} = _run, params)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    add_operation(que, name, {:run, {mod, fun, args, params}}, params)
  end

  def run(que, name, run, params) when is_function(run) do
    add_operation(que, name, {:run, {run, params}}, params)
  end

  @doc """
  Adds a function to run as part of the queue.
  Similar to `run/3`, but allows to pass module name, function and arguments.
  The function should return either `{:ok, value}` or `{:error, value}`.
  Receives the changes so far as its argument (prepended to those passed in the call to the function).

  ## Params

  - `que`: The queue to which the function should be added.
  - `name`: A unique name for this operation. It will be used as a key in the queue's internal state.
  - `mod`: The module where the function is defined.
  - `fun`: The function to be executed.
  - `args`: Arguments that should be passed to the function.
  - `params` (optional): A list of keys in the queue's internal state that should be passed to the function as arguments.
  """
  @deprecated "Use run/4 instead"
  @spec run(t, name, module, function, args, [atom]) :: t when function: atom, args: [any]
  def run(que, name, mod, fun, args, params \\ [])
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    add_operation(que, name, {:run, {mod, fun, args, params}}, params)
  end

  defp add_operation(%Q{} = que, name, operation, params) do
    %{operations: operations, names: names} = que
    check_params_existence(names, params)

    if MapSet.member?(names, name) do
      raise "#{Kernel.inspect(name)} is already a member of the Q: \n#{Kernel.inspect(que)}"
    else
      %{que | operations: [{name, operation} | operations], names: MapSet.put(names, name)}
    end
  end

  defp apply_operations([], _names), do: {nil, []}

  defp apply_operations(operations, names) do
    operations
    |> Enum.reduce_while({%{}, names}, &apply_operation(&1, &2))
  end

  defp apply_operation({:inspect, {:inspect, opts}}, {acc, names}) do
    if opts[:only] do
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      acc |> Map.take(List.wrap(opts[:only])) |> IO.inspect(opts)
    else
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      IO.inspect(acc, opts)
    end

    {:cont, {acc, names}}
  end

  defp apply_operation({name, operation}, {acc, names}) do
    with {:ok, value} <- apply_operation(operation, acc),
         acc <- Map.put(acc, name, value) do
      {:cont, {acc, names}}
    else
      {:halt, value} ->
        {:halt, {Map.put(acc, name, value), names}}

      {:error, value} ->
        {:halt, {name, value, acc}}

      other ->
        raise "expected operation `#{Kernel.inspect(name)}` to return {:ok, value}, {:halt, value} or {:error, value}, got: #{Kernel.inspect(other)}"
    end
  end

  defp apply_operation({:run, run}, acc),
    do: apply_run_fun(run, acc)

  defp apply_operation({:put, value}, _acc),
    do: {:ok, value}

  defp apply_run_fun({mod, fun, args, params}, acc) do
    apply(mod, fun, build_args(acc, params, args))
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
