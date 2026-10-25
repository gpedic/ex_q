defmodule Q.DSL do
  @moduledoc false

  # Compiles the body of `queue do ... end` into calls to the functional API.
  #
  # Each binding becomes a step named after its variable. The step's params are
  # the steps bound earlier in the same block that its expression references;
  # they become the arguments of the generated step function, so the expression
  # itself is left as written.

  @old_calls [:put, :run, :let, :inspect]
  @conditionals [:if, :unless, :case, :cond]

  def compile(block, caller) do
    statements = statements(block)
    check_execution!(statements, caller)
    {body, _bound} = compile_statements(statements, [], caller)

    quote do
      queue = Q.new()
      unquote_splicing(body)
      queue
    end
  end

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(statement), do: [statement]

  defp check_execution!(statements, caller) do
    statements
    |> Enum.drop(-1)
    |> Enum.each(fn
      {name, meta, []} when name in [:execute, :exec] ->
        compile_error!(caller, meta, "#{name}() must be the last statement")

      _statement ->
        :ok
    end)
  end

  # `bound` lists every step name visible to this block, to reject duplicates;
  # `steps` lists the names bound earlier in this block, which become params.
  defp compile_statements(statements, bound, caller) do
    {body, {bound, _steps}} =
      Enum.map_reduce(statements, {bound, []}, fn statement, {bound, steps} ->
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

    if name in bound do
      compile_error!(caller, meta, "#{name} is already a step in this queue")
    end

    {ast, {[name | bound], [name | steps]}}
  end

  defp compile_statement({:debug, _meta, []}, bound, steps, _caller) do
    ast =
      quote do
        queue = Q.debug(queue)
      end

    {ast, {bound, steps}}
  end

  defp compile_statement({:debug, _meta, [opts]}, bound, steps, _caller) do
    {fun, params} = step_fun(opts, steps)

    ast =
      quote do
        queue = Q.__debug__(queue, unquote(fun), unquote(params))
      end

    {ast, {bound, steps}}
  end

  defp compile_statement({:merge, meta, [_expr]}, _bound, _steps, caller) do
    compile_error!(
      caller,
      meta,
      "merge(queue) is not a statement; run a queue as a step with `name <- queue`, " <>
        "its results are stored under `name`"
    )
  end

  # A conditional runs as a branch op: the branch taken builds the queue of its
  # steps. Outer steps the conditional references become params of the branch
  # function, so inside the branches they're plain variables.
  defp compile_statement({kind, meta, args} = conditional, bound, steps, caller)
       when kind in @conditionals and is_list(args) do
    {branches, branch_names} = compile_branches(kind, args, bound, caller)
    {fun, params} = step_fun(conditional, steps, {kind, meta, branches})

    ast =
      quote do
        queue = Q.__branch__(queue, unquote(fun), unquote(params))
      end

    {ast, {branch_names ++ bound, steps}}
  end

  defp compile_statement({name, meta, []}, bound, steps, caller)
       when name in [:execute, :exec] do
    if name == :exec do
      IO.warn(
        "exec() is deprecated; use execute() instead",
        Macro.Env.stacktrace(%{caller | line: Keyword.get(meta, :line, caller.line)})
      )
    end

    ast =
      quote do
        queue = Q.execute(queue)
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
        "#{Macro.to_string(statement)}; every step must have a name"
    )
  end

  defp step_name!({:_, _meta, context}, _op, meta, caller) when is_atom(context) do
    compile_error!(caller, meta, "every step must have a name; _ cannot name a step")
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

  defp compile_branches(kind, [condition, clauses], bound, caller) when kind in [:if, :unless] do
    {do_branch, do_names} = compile_branch(Keyword.get(clauses, :do), bound, caller)
    {else_branch, else_names} = compile_branch(Keyword.get(clauses, :else), bound, caller)
    {[condition, [do: do_branch, else: else_branch]], Enum.uniq(do_names ++ else_names)}
  end

  defp compile_branches(:case, [expr, [do: clauses]], bound, caller) do
    {clauses, names} = compile_clauses(clauses, bound, caller)
    {[expr, [do: clauses]], names}
  end

  defp compile_branches(:cond, [[do: clauses]], bound, caller) do
    {clauses, names} = compile_clauses(clauses, bound, caller)
    {[[do: clauses]], names}
  end

  defp compile_clauses(clauses, bound, caller) do
    {clauses, names} =
      Enum.map_reduce(clauses, [], fn {:->, meta, [head, body]}, names ->
        {branch, branch_names} = compile_branch(body, bound, caller)
        {{:->, meta, [head, branch]}, branch_names ++ names}
      end)

    {clauses, Enum.uniq(names)}
  end

  # Returns code building the branch's queue, and the step names it binds. A
  # missing branch (`if` without `else`) adds no steps.
  defp compile_branch(nil, _bound, _caller), do: {quote(do: Q.new()), []}

  defp compile_branch(block, bound, caller) do
    statements = statements(block)

    for {name, meta, []} <- statements, name in [:execute, :exec] do
      compile_error!(caller, meta, "#{name}() can't be used inside a branch")
    end

    {body, branch_bound} = compile_statements(statements, bound, caller)

    ast =
      quote do
        queue = Q.new()
        unquote_splicing(body)
        queue
      end

    {ast, branch_bound -- bound}
  end

  # Wraps `body` in a function of the earlier steps that `expr` references; `body`
  # is `expr` unless it was compiled further. The `_ = var` lines keep an argument
  # from being reported as unused when every reference to it is shadowed, e.g. by
  # a nested `fn` argument of the same name.
  defp step_fun(expr, steps, body \\ nil) do
    args = references(expr, steps)
    uses = Enum.map(args, &quote(do: _ = unquote(&1)))
    fun = {:fn, [], [{:->, [], [args, {:__block__, [], uses ++ [body || expr]}]}]}
    {fun, Enum.map(args, &elem(&1, 0))}
  end

  defp references(expr, steps) do
    {_expr, vars} =
      Macro.prewalk(expr, %{}, fn
        # Module attributes look like variables inside @
        {:@, _meta, _args}, vars ->
          {nil, vars}

        {name, meta, context} = var, vars when is_atom(name) and is_atom(context) ->
          if name in steps do
            {var, Map.put_new(vars, name, {name, Keyword.take(meta, [:counter]), context})}
          else
            {var, vars}
          end

        node, vars ->
          {node, vars}
      end)

    vars |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  defp meta({_name, meta, _args}) when is_list(meta), do: meta
  defp meta(_statement), do: []

  defp compile_error!(caller, meta, description) do
    raise CompileError,
      file: caller.file,
      line: Keyword.get(meta, :line, caller.line),
      description: description
  end
end
