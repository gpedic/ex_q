defmodule Q.DSL do
  @moduledoc false

  # Compiles the body of `queue do ... end` into calls to the functional API.
  #
  # Each binding becomes a step named after its variable. The step's params are
  # the steps bound earlier in the same block that its expression references;
  # they become the arguments of the generated step function, so the expression
  # itself is left as written.
  #
  # A block is a scope of its own, like `quote`: the variables in its expressions
  # get a context unique to the block, so a variable from outside no longer
  # resolves and Elixir reports it as undefined. Steps and variables bound inside
  # an expression keep working, since their bindings and uses are rewritten
  # together. `bind:` is the way in; its values are evaluated where the block is
  # written and become the queue's first steps.

  @old_calls [:put, :run, :let, :inspect]
  @conditionals [:if, :unless, :case, :cond]
  @special_forms [:__MODULE__, :__ENV__, :__DIR__, :__CALLER__, :__STACKTRACE__]

  def compile(opts, block, caller) do
    # One context per block, so a nested block can't see the enclosing block's
    # variables. The line is unique enough: a nested block opens on a later line
    # than the block it's in, and blocks that aren't nested never share variables.
    env = %{caller: caller, scope: :"Elixir.Q.DSL.Scope.L#{caller.line}"}
    {binds, names} = compile_binds!(opts, env)

    {body, _steps} =
      Enum.map_reduce(statements(block), names, &compile_statement(&1, &2, env))

    quote do
      queue = Q.new()
      unquote_splicing(binds ++ body)
      queue
    end
  end

  defp compile_binds!(opts, env) do
    unless Keyword.keyword?(opts) do
      compile_error!(
        env,
        [],
        "expected queue options, got: #{Macro.to_string(opts)}; " <>
          "bring outside values in with `queue bind: [...] do`"
      )
    end

    case Keyword.keys(opts) -- [:bind] do
      [] ->
        :ok

      [key | _] ->
        compile_error!(env, [], "unknown queue option #{inspect(key)}; the only option is :bind")
    end

    entries = Keyword.get(opts, :bind, [])

    unless is_list(entries) do
      compile_error!(
        env,
        [],
        "expected bind: to be a list of variables or `name: expr` pairs, got: #{Macro.to_string(entries)}"
      )
    end

    Enum.map_reduce(entries, [], fn entry, names ->
      {name, expr, meta} = bind_entry!(entry, env)

      if name in names do
        compile_error!(env, meta, "#{name} is bound twice")
      end

      ast =
        quote do
          queue = Q.put(queue, unquote(name), unquote(expr))
        end

      {ast, [name | names]}
    end)
  end

  defp bind_entry!({:_, meta, context}, env) when is_atom(context) do
    compile_error!(env, meta, "every input must have a name; _ cannot be bound")
  end

  defp bind_entry!({name, meta, context} = var, _env) when is_atom(name) and is_atom(context),
    do: {name, var, meta}

  defp bind_entry!({name, expr}, _env) when is_atom(name) and name not in [nil, true, false, :_],
    do: {name, expr, meta(expr)}

  defp bind_entry!(other, env) do
    compile_error!(
      env,
      meta(other),
      "expected a variable or `name: expr` in bind:, got: #{Macro.to_string(other)}"
    )
  end

  defp scope(ast, env) do
    Macro.prewalk(ast, fn
      {name, meta, context}
      when is_atom(name) and is_atom(context) and name not in @special_forms ->
        {name, meta, env.scope}

      node ->
        node
    end)
  end

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(statement), do: [statement]

  # `steps` lists the names bound earlier in the block, which become params.
  defp compile_statement({op, meta, [lhs, expr]}, steps, env) when op in [:=, :<-] do
    name = step_name!(lhs, op, meta, env)
    {fun, params} = step_fun(scope(expr, env), steps)
    call = if op == :=, do: :let, else: :run

    ast =
      quote do
        queue = Q.unquote(call)(queue, unquote(name), unquote(fun), unquote(params))
      end

    if name in steps do
      compile_error!(env, meta, "#{name} is already a step in this queue")
    end

    {ast, [name | steps]}
  end

  defp compile_statement({:debug, _meta, []}, steps, _env) do
    ast =
      quote do
        queue = Q.debug(queue)
      end

    {ast, steps}
  end

  defp compile_statement({:debug, _meta, [opts]}, steps, env) do
    {fun, params} = step_fun(scope(opts, env), steps)

    ast =
      quote do
        queue = Q.__debug__(queue, unquote(fun), unquote(params))
      end

    {ast, steps}
  end

  defp compile_statement({:merge, meta, [_expr]}, _steps, env) do
    compile_error!(
      env,
      meta,
      "merge(queue) is not a statement; run a queue as a step with `name <- queue`, " <>
        "its results are stored under `name`"
    )
  end

  # A conditional chooses a step's value, so it goes inside the step
  defp compile_statement({kind, meta, args}, _steps, env)
       when kind in @conditionals and is_list(args) do
    compile_error!(
      env,
      meta,
      "#{kind} is not a queue statement; put it inside a step to choose the step's value, " <>
        "such as `name <- #{kind} ...`"
    )
  end

  # A queue block only builds a queue, so it can be returned from a helper and run
  # as a child; running it is the caller's job.
  defp compile_statement({name, meta, []}, _steps, env)
       when name in [:execute, :exec] do
    compile_error!(
      env,
      meta,
      "#{name}() is not a queue statement; a queue block builds a queue, " <>
        "run it with `queue do ... end |> execute()`"
    )
  end

  defp compile_statement({name, meta, args}, _steps, env)
       when name in @old_calls and is_list(args) do
    compile_error!(
      env,
      meta,
      "#{name}/#{length(args)} is not a queue statement since Q 2.0, steps are bindings: " <>
        "`name = expr` for values and functions that can't fail, `name <- expr` for " <>
        "functions that return {:ok, value} or {:error, reason}, and debug() to print the state"
    )
  end

  defp compile_statement(statement, _steps, env) do
    compile_error!(
      env,
      meta(statement),
      "expected a step such as `name = expr` or `name <- expr`, got: " <>
        "#{Macro.to_string(statement)}; every step must have a name"
    )
  end

  defp step_name!({:_, _meta, context}, _op, meta, env) when is_atom(context) do
    compile_error!(env, meta, "every step must have a name; _ cannot name a step")
  end

  defp step_name!({name, _meta, context}, _op, _meta_op, _env)
       when is_atom(name) and is_atom(context),
       do: name

  defp step_name!(lhs, op, meta, env) do
    compile_error!(
      env,
      meta,
      "expected a variable on the left of #{op}, got: #{Macro.to_string(lhs)}"
    )
  end

  # Wraps `expr` in a function of the earlier steps it references. The `_ = var`
  # lines keep an argument from being reported as unused when every reference to
  # it is shadowed, e.g. by a nested `fn` argument of the same name.
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

  defp compile_error!(%{caller: caller}, meta, description) do
    raise CompileError,
      file: caller.file,
      line: Keyword.get(meta, :line, caller.line),
      description: description
  end
end
