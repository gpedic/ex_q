# Changelog

## 2.0.0

### New `queue` syntax

Steps in a `queue` block are now bindings, named after their variable. A step's inputs are the earlier steps its expression uses, so atom names, params lists and function wrappers are gone:

```elixir
queue do
  input = data
  decoded <- Base.decode64(input)
  upper = String.upcase(decoded)
end
|> execute()
```

The 1.x syntax is removed, and its calls inside a `queue` block are a compile error pointing at the new syntax. To upgrade, rewrite each statement:

| 1.x | 2.0 |
|---|---|
| `put(:input, data)` | `input = data` |
| `run(:decoded, &Base.decode64/1, [:input])` | `decoded <- Base.decode64(input)` |
| `run(:valid, fn %{decoded: d} -> validate(d) end)` | `valid <- validate(decoded)` |
| `run(:cs, {Mod, :changeset, [%S{}]}, {[:a, :b], order: :append})` | `cs <- Mod.changeset(%S{}, a, b)` |
| `inspect()` / `inspect(only: :a)` | `debug()` / `debug(only: :a)` |
| `exec()` at the end of the block | `queue do ... end \|> execute()` |

Also new in the block:

- The block only builds the queue; pipe it into `execute/1` to run it. `execute()` and `exec()` inside the block are compile errors, so a function that returns a queue can't run it by accident before its caller runs it as a child queue.
- A block is a scope of its own, like `quote`: steps can't use variables from outside it, so a misspelled step reference is a compile error even when a variable of that name exists. Outside values come in with `queue bind: [order, limit: opts[:limit]] do`; a bare variable binds under its own name, `name: expr` binds any expression, and each becomes one of the queue's first steps, in the state and in error tuples. A nested block binds what it needs from the enclosing one.
- `name <- expr` is a step whose result decides what happens next: `{:ok, value}` is unwrapped, `{:error, reason}` or `:error` stops the pipeline, `{:halt, value}` ends it, a queue runs as a child, and any other value is stored as is, so `<-` works for functions that return plain values. `name = expr` is a step that can't fail: the value is stored as is, never unwrapped. Reading a block, `<-` marks the steps that can fail. The same rule applies to `run/4` and `let/4`.
- Every step must have a unique name and stores its successful result, including names starting with `_`. Bare `_` bindings are rejected at compile time.
- **`defq/2` and `defpq/2`** define a function that builds a queue from its arguments: `defq billing_steps(user) do ... end` is `def billing_steps(user), do: queue bind: [user] do ... end`. The arguments are bound as the first steps and must be plain variables; guards are allowed. The function returns the queue, to run with `execute/1` or as a child step. `defpq` defines a private one.
- A step whose function returns a queue runs it as a child queue, with its state stored under the step's name; `name <- queue do ... end` nests a block inline.
- A halt stops the queue it's written in, like `{:halt, acc}` in `Enum.reduce_while/3`: in a child queue it ends the child, and the parent continues with the child's state so far, deciding from it whether to halt in turn.
- Conditionals go inside a step and choose its value: `approval <- if total > 100, do: request(order), else: {:ok, nil}`. An `if`, `unless`, `case` or `cond` as a statement of its own is a compile error.
- Mistakes, such as binding a name twice, are compile errors pointing at the line. Likely mistakes get a message showing the right form: `{:ok, user} <- fetch(id)` points at `user <- fetch(id)`, and calls like `run(...)` or `Q.run(...)` inside a block point at bindings and at the functional API for a step per item.
- The docs compare the `queue` block and the functional API: what each is for, and when mistakes are caught.
- The package ships a recipes guide (`guides/recipes.md`) with complete patterns, including failure and cleanup paths, and `usage-rules.md`, a short list of rules and common mistakes for coding agents.

### Functional API

New:

- **`let/4`**: a step for functions that can't fail. The return value is stored as is, so `let(:upper, &String.upcase/1, [:text])` needs no `{:ok, _}` wrapping.
- **Child queues**: a `run/4` function may return a queue, which runs as a child with its state stored under the step's name. A failing child step is reported as `{:error, step, {:error, child_step, reason, child_state}, state}`. A child's halt ends only the child; the parent continues with the child's state.
- **Arity-0 steps**: pass explicit `[]` to call a function or MFA with no queue inputs. In a `queue` block, this list is generated automatically.
- **Step functions are validated when added**: a function's arity must match its params, and a `{module, function, args}` function must exist. Mistakes raise `ArgumentError` when the step is added instead of failing when the pipeline runs.

Breaking:

- **Debugging follows execution timing.** Debug options in a `queue` block are evaluated only when reached and may reference earlier steps. Options must be a keyword list and `only:` must contain valid step names; invalid options or selections raise `ArgumentError` when added through the functional API or evaluated in a block. `nil` and `false` selections no longer print the whole state. The `only:` option is removed before forwarding inspection options.
- **Omitted params and explicit `[]` are distinct**, for both `run` and `let`, functions and MFAs. Omitting params passes the whole state as one map; `[]` or `{[], opts}` passes no queue inputs. MFA fixed arguments are still passed. If a callback needs the whole state, omit params instead of passing `[]`; zero-argument callbacks must supply `[]` explicitly. Named params continue passing the listed values in order.
- **Step names must be atoms or tuples**, such as `:user` or `{:invite, user_id}`. Lists, strings, numbers and other terms, as well as `nil`, `true` and `false`, now raise `ArgumentError` when the step is added. Wrap dynamic identifiers in a tuple, for example `{:item, id}`.
- **Bare `:_` step names are rejected** with `ArgumentError` when added through the functional API. Use a descriptive name instead. Underscore-prefixed names such as `:_notified` are ordinary unique names and retain their results.

- **`Q.inspect/2` is renamed to `Q.debug/2`.** The old name clashed with `Kernel.inspect/2` in any module that did `import Q`.
- **`run/6` is removed.**
  - Upgrade: `run(q, name, mod, fun, args, params)` becomes `run(q, name, {mod, fun, args}, params)`.
- **`exec/1` is renamed to `execute/1`.**
  - Upgrade: replace `Q.exec(queue)` and `|> exec()` with `Q.execute(queue)` and `|> execute()`.
- **`execute/1` on an empty queue returns `{:ok, %{}}`** instead of `{:ok, nil}`.
- **A step returning a bare `:error` fails the pipeline** with `{:error, step, :error, state}`. It used to raise.
  - Upgrade: code that rescued the `RuntimeError` for such steps should match the error tuple instead.
- **Build-time mistakes raise `ArgumentError`** instead of `RuntimeError`: a duplicate step name, or a param that refers to a step that doesn't exist.
- **Invalid step functions raise `ArgumentError` when the step is added**, see above. A value that isn't a function, `{module, function}` or `{module, function, args}` raises `ArgumentError` instead of `FunctionClauseError`.
- **Unknown params options raise `ArgumentError`**. `{[:a], ordr: :append}` used to be ignored silently; `:order` is the only option.
- **`:order` with a function or capture raises `ArgumentError`.** It used to be ignored: it places inputs relative to an MFA's fixed arguments, and a function receives its inputs in the order of the params list.
- **`to_list/1` is removed from the public API**; it exposed the internal operation encoding. Use `operations/1` for a queue's step names. `Q.t()` is now an opaque type, so don't match on `%Q{}` fields.
- **`operations/1` lists step names only**, without debug operations.
- The `Q.fun_arity1()` type is removed; use `Q.step_fun()`. The `Q.exec_error()` type is renamed to `Q.error()`, after `exec/1` became `execute/1`.

## 1.2.0

- Fixed the DSL rewriting calls inside step functions (e.g. `Kernel.inspect/1` in a `fn`), shadowing a caller variable named `queue`, and silently dropping steps added inside `if`/`case`. The latter, and `exec()` before the last statement, now raise at compile time.
- `{params, opts}` works for anonymous functions and `run/6`; malformed params and invalid `:order` values raise `ArgumentError` when the step is added.
- The duplicate name error no longer prints the queue's stored values.
- Doctests now assert their results; typespecs and docs corrected.
- Requires Elixir 1.15 or later.
