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
  Returns an empty `Q` struct.

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
  ## Example
      Q.new()
      |> Q.put(:params, params)
      |> Q.run()
  """
  @spec put(t, name, any) :: t
  def put(que, name, value) do
    add_operation(que, name, {:put, value})
  end

  @doc """
  Returns the list of operations stored in the queue.
  Always use this function when you need to access the operations you
  have defined in `Q`. Inspecting the `Q` struct internals
  directly is discouraged.
  """
  @spec to_list(t) :: [{name, term}]
  def to_list(%Q{operations: operations}) do
    operations
    |> Enum.reverse()
  end

  @spec inspect(t, Keyword.t()) :: t
  def inspect(que, opts \\ []) do
    Map.update!(que, :operations, &[{:inspect, {:inspect, opts}} | &1])
  end

  @doc """
  Executes the queue.

  ## Example
      Q.new()
      |> Q.run(:write, fn _, _ -> {:ok, nil} end)
      |> Q.exec()
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
  Adds a function to run as part of the queue.
  The function should return either `{:ok, value}` or `{:error, value}`.
  Receives the changes so far as its argument (prepended to those passed in the call to the function).

  ## Example
      Q.run(multi, :write, fn %{image: image} ->
        with :ok <- File.write(image.name, image.contents) do
          {:ok, nil}
        end
      end)
  """
  @spec run(t, name, run) :: t
  def run(que, name, {mod, fun, args} = run)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    add_operation(que, name, {:run, run})
  end

  def run(que, name, run) when is_function(run) do
    add_operation(que, name, {:run, run})
  end

  @doc """
  Adds a function to run as part of the queue.
  Similar to `run/3`, but allows to pass module name, function and arguments.
  The function should return either `{:ok, value}` or `{:error, value}`.
  Receives the changes so far as its argument (prepended to those passed in the call to the function).
  """
  @spec run(t, name, module, function, args) :: t when function: atom, args: [any]
  def run(que, name, mod, fun, args)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    add_operation(que, name, {:run, {mod, fun, args}})
  end

  defp add_operation(%Q{} = que, name, operation) do
    %{operations: operations, names: names} = que

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
    case apply_operation(operation, acc) do
      {:ok, value} ->
        {:cont, {Map.put(acc, name, value), names}}

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

  defp apply_run_fun({mod, fun, args}, acc) do
    apply(mod, fun, [acc | args])
  end

  defp apply_run_fun(fun, acc), do: fun.(acc)
end
