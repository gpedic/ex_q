defmodule Q.DSL do
  @moduledoc false

  # Compiles the body of `queue do ... end` into calls to the functional API.
  #
  # Each binding becomes a step named after its variable. The step's params are
  # the steps bound earlier in the same block that its expression references;
  # they become the arguments of the generated step function, so the expression
  # itself is left as written.

  @old_calls [:put, :run, :let, :inspect]

  def compile(block, caller) do
    statements = statements(block)
    check_exec!(statements, caller)
    {body, _bound} = compile_statements(statements, MapSet.new(), caller)

    quote do
      queue = Q.new()
      unquote_splicing(body)
      queue
    end
  end

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(statement), do: [statement]

  defp check_exec!(statements, caller) do
    statements
    |> Enum.drop(-1)
    |> Enum.each(fn
      {:exec, meta, []} -> compile_error!(caller, meta, "exec() must be the last statement")
      _statement -> :ok
    end)
  end

  # `bound` holds every step name visible to this block, to reject duplicates;
  # `steps` holds the names bound earlier in this block, which become params.
  defp compile_statements(statements, bound, caller) do
    {body, {bound, _steps}} =
      Enum.map_reduce(statements, {bound, MapSet.new()}, fn statement, {bound, steps} ->
        compile_statement(statement, bound, steps, caller)
      end)

    {body, bound}
  end

  defp compile_statement({op, meta, [lhs, expr]}, bound, steps, caller) when op in [:=, :<-] do
    name = step_name!(lhs, op, meta, caller)
    {fun, params} = step_fun(expr, steps)
    call = if op == :=, do: :let, else: :run

    ast =
      quote do
        queue = Q.unquote(call)(queue, unquote(name), unquote(fun), unquote(params))
      end

    cond do
      unstored?(name) ->
        {ast, {bound, steps}}

      MapSet.member?(bound, name) ->
        compile_error!(caller, meta, "#{name} is already a step in this queue")

      true ->
        {ast, {MapSet.put(bound, name), MapSet.put(steps, name)}}
    end
  end

  defp compile_statement({:debug, _meta, args}, bound, steps, _caller) when length(args) <= 1 do
    ast =
      quote do
        queue = Q.debug(queue, unquote_splicing(args))
      end

    {ast, {bound, steps}}
  end

  defp compile_statement({:merge, _meta, [expr]}, bound, steps, _caller) do
    {fun, params} = step_fun(expr, steps)

    ast =
      quote do
        queue = Q.merge(queue, unquote(fun), unquote(params))
      end

    {ast, {bound, steps}}
  end

  defp compile_statement({:exec, _meta, []}, bound, steps, _caller) do
    ast =
      quote do
        queue = Q.exec(queue)
      end

    {ast, {bound, steps}}
  end

  defp compile_statement({name, meta, args}, _bound, _steps, caller)
       when name in @old_calls and is_list(args) do
    compile_error!(
      caller,
      meta,
      "#{name}/#{length(args)} is not a queue statement since Q 2.0, steps are bindings: " <>
        "`name = expr` for values and functions that can't fail, `name <- expr` for " <>
        "functions that return {:ok, value} or {:error, reason}, and debug() to print the state"
    )
  end

  defp compile_statement(statement, _bound, _steps, caller) do
    compile_error!(
      caller,
      meta(statement),
      "expected a step such as `name = expr` or `name <- expr`, got: " <>
        "#{Macro.to_string(statement)}; use `_ = expr` to run an expression without storing it"
    )
  end

  defp step_name!({name, _meta, context}, _op, _meta_op, _caller)
       when is_atom(name) and is_atom(context),
       do: name

  defp step_name!(lhs, op, meta, caller) do
    compile_error!(
      caller,
      meta,
      "expected a variable on the left of #{op}, got: #{Macro.to_string(lhs)}"
    )
  end

  # Wraps `expr` in a function of the earlier steps it references. The `_ = var`
  # lines keep an argument from being reported as unused when every reference
  # to it is shadowed inside `expr`, e.g. by a nested `fn` argument of the same name.
  defp step_fun(expr, steps) do
    args = references(expr, steps)
    uses = Enum.map(args, &quote(do: _ = unquote(&1)))
    fun = {:fn, [], [{:->, [], [args, {:__block__, [], uses ++ [expr]}]}]}
    {fun, Enum.map(args, &elem(&1, 0))}
  end

  defp references(expr, steps) do
    {_expr, vars} =
      Macro.prewalk(expr, %{}, fn
        # Module attributes look like variables inside @
        {:@, _meta, _args}, vars ->
          {nil, vars}

        {name, meta, context} = var, vars when is_atom(name) and is_atom(context) ->
          if MapSet.member?(steps, name) do
            {var, Map.put_new(vars, name, {name, Keyword.take(meta, [:counter]), context})}
          else
            {var, vars}
          end

        node, vars ->
          {node, vars}
      end)

    vars |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  defp unstored?(name), do: String.starts_with?(Atom.to_string(name), "_")

  defp meta({_name, meta, _args}) when is_list(meta), do: meta
  defp meta(_statement), do: []

  defp compile_error!(caller, meta, description) do
    raise CompileError,
      file: caller.file,
      line: Keyword.get(meta, :line, caller.line),
      description: description
  end
end
