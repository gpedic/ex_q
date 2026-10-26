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
    {body, _bound} = compile_statements(statements(block), names, names, env)

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

  # `bound` lists every step name visible to this block, to reject duplicates;
  # `steps` lists the names bound earlier in this block, which become params.
  defp compile_statements(statements, bound, steps, env) do
    {body, {bound, _steps}} =
      Enum.map_reduce(statements, {bound, steps}, fn statement, {bound, steps} ->
        compile_statement(statement, bound, steps, env)
      end)

    {body, bound}
  end

  defp compile_statement({op, meta, [lhs, expr]}, bound, steps, env) when op in [:=, :<-] do
    name = step_name!(lhs, op, meta, env)
    {fun, params} = step_fun(scope(expr, env), steps)
    call = if op == :=, do: :let, else: :run

    ast =
      quote do
        queue = Q.unquote(call)(queue, unquote(name), unquote(fun), unquote(params))
      end

    if name in bound do
      compile_error!(env, meta, "#{name} is already a step in this queue")
    end

    {ast, {[name | bound], [name | steps]}}
  end

  defp compile_statement({:debug, _meta, []}, bound, steps, _env) do
    ast =
      quote do
        queue = Q.debug(queue)
      end

    {ast, {bound, steps}}
  end

  defp compile_statement({:debug, _meta, [opts]}, bound, steps, env) do
    {fun, params} = step_fun(scope(opts, env), steps)

    ast =
      quote do
        queue = Q.__debug__(queue, unquote(fun), unquote(params))
      end

    {ast, {bound, steps}}
  end

  defp compile_statement({:merge, meta, [_expr]}, _bound, _steps, env) do
    compile_error!(
      env,
      meta,
      "merge(queue) is not a statement; run a queue as a step with `name <- queue`, " <>
        "its results are stored under `name`"
    )
  end

  # A conditional runs as a branch op: the branch taken builds the queue of its
  # steps. Outer steps the conditional references become params of the branch
  # function, so inside the branches they're plain variables.
  defp compile_statement({kind, meta, args}, bound, steps, env)
       when kind in @conditionals and is_list(args) do
    {kind, meta, args} = conditional = scope({kind, meta, args}, env)
    {branches, branch_names} = compile_branches(kind, args, meta, bound, env)
    {fun, params} = step_fun(conditional, steps, {kind, meta, branches})

    ast =
      quote do
        queue = Q.__branch__(queue, unquote(fun), unquote(params))
      end

    {ast, {branch_names ++ bound, steps}}
  end

  # A queue block only builds a queue, so it can be returned from a helper and run
  # as a child; running it is the caller's job.
  defp compile_statement({name, meta, []}, _bound, _steps, env)
       when name in [:execute, :exec] do
    compile_error!(
      env,
      meta,
      "#{name}() is not a queue statement; a queue block builds a queue, " <>
        "run it with `queue do ... end |> execute()`"
    )
  end

  defp compile_statement({name, meta, args}, _bound, _steps, env)
       when name in @old_calls and is_list(args) do
    compile_error!(
      env,
      meta,
      "#{name}/#{length(args)} is not a queue statement since Q 2.0, steps are bindings: " <>
        "`name = expr` for values and functions that can't fail, `name <- expr` for " <>
        "functions that return {:ok, value} or {:error, reason}, and debug() to print the state"
    )
  end

  defp compile_statement(statement, _bound, _steps, env) do
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

  # Conditionals are rewritten before Elixir sees them, so their shape is checked
  # here: anything the rewrite didn't understand would otherwise be dropped.
  defp compile_branches(kind, [condition, opts], meta, bound, env)
       when kind in [:if, :unless] do
    check_options!(kind, opts, [:do, :else], meta, env)

    # The user's options are kept, with each branch compiled in place
    {opts, names} =
      Enum.map_reduce(opts, [], fn {key, block}, names ->
        {branch, branch_names} = compile_branch(block, bound, env)
        {{key, branch}, branch_names ++ names}
      end)

    # Without an else, the branch function still has to return a queue
    opts = if Keyword.has_key?(opts, :else), do: opts, else: opts ++ [else: quote(do: Q.new())]
    {[condition, opts], Enum.uniq(names)}
  end

  defp compile_branches(:case, [expr, opts], meta, bound, env) do
    check_options!(:case, opts, [:do], meta, env)
    clauses = arrow_clauses!(:case, Keyword.fetch!(opts, :do), meta, env)
    {clauses, names} = compile_clauses(clauses, bound, env)
    {[expr, [do: clauses]], names}
  end

  defp compile_branches(:cond, [opts], meta, bound, env) do
    check_options!(:cond, opts, [:do], meta, env)
    clauses = arrow_clauses!(:cond, Keyword.fetch!(opts, :do), meta, env)
    {clauses, names} = compile_clauses(clauses, bound, env)
    {[[do: clauses]], names}
  end

  defp compile_branches(kind, args, meta, _bound, env) do
    expected =
      if kind == :cond,
        do: "1 argument (a do: block)",
        else: "2 arguments (an expression and a do: block)"

    compile_error!(env, meta, "#{kind} expects #{expected}, got #{length(args)}")
  end

  defp check_options!(kind, opts, allowed, meta, env) do
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []

    cond do
      not Keyword.keyword?(opts) or :do not in keys ->
        compile_error!(env, meta, "#{kind} requires a do: block")

      (unknown = Enum.reject(keys, &(&1 in allowed))) != [] ->
        compile_error!(
          env,
          meta,
          "unknown #{kind} option #{inspect(hd(unknown))}; supported options are " <>
            Enum.map_join(allowed, " and ", &inspect/1)
        )

      (duplicates = keys -- Enum.uniq(keys)) != [] ->
        compile_error!(env, meta, "duplicate #{kind} option #{inspect(hd(duplicates))}")

      true ->
        :ok
    end
  end

  defp arrow_clauses!(kind, body, meta, env) do
    form = if kind == :case, do: "pattern -> steps", else: "condition -> steps"

    case body do
      empty
      when empty == [] or
             (is_tuple(empty) and elem(empty, 0) == :__block__ and elem(empty, 2) == []) ->
        compile_error!(env, meta, "#{kind} requires at least one -> clause")

      clauses when is_list(clauses) ->
        for clause <- clauses, not match?({:->, _, [head, _]} when is_list(head), clause) do
          compile_error!(
            env,
            meta(clause) ++ meta,
            "expected #{kind} clauses in the form `#{form}`, got: #{Macro.to_string(clause)}"
          )
        end

        clauses

      other ->
        compile_error!(
          env,
          meta(other) ++ meta,
          "expected #{kind} clauses in the form `#{form}`, got: #{Macro.to_string(other)}"
        )
    end
  end

  defp compile_clauses(clauses, bound, env) do
    {clauses, names} =
      Enum.map_reduce(clauses, [], fn {:->, meta, [head, body]}, names ->
        {branch, branch_names} = compile_branch(body, bound, env)
        {{:->, meta, [head, branch]}, branch_names ++ names}
      end)

    {clauses, Enum.uniq(names)}
  end

  # Returns code building the branch's queue, and the step names it binds. An
  # explicit nil branch (`do: nil`) adds no steps.
  defp compile_branch(nil, _bound, _env), do: {quote(do: Q.new()), []}

  defp compile_branch(block, bound, env) do
    {body, branch_bound} = compile_statements(statements(block), bound, [], env)

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

  defp compile_error!(%{caller: caller}, meta, description) do
    raise CompileError,
      file: caller.file,
      line: Keyword.get(meta, :line, caller.line),
      description: description
  end
end
