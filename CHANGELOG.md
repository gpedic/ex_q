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

- The block only builds the queue; pipe it into `execute/1` to run it. `execute()` and `exec()` inside the block are compile errors, so a function that returns a queue can't run it by accident before its caller runs it as a sub-pipeline.
- `name = expr` stores a value or the result of a function that can't fail; `<-` is for functions returning `{:ok, value}` or `{:error, reason}`.
- `if`, `unless`, `case` and `cond` around steps choose which steps run, based on earlier results.
- Every step must have a unique name and stores its successful result, including names starting with `_`. Bare `_` bindings are rejected at compile time.
- A step whose function returns a queue runs it as a sub-pipeline, with its results stored as a map under the step's name; `name <- queue do ... end` nests a block inline.
- A halt stops the whole pipeline, also from inside a sub-pipeline; `{:halt, value, propagate: false}` stops only the queue the step is in.
- Mistakes, such as binding a name twice or a malformed `if`, `unless`, `case` or `cond` (a missing `do:`, an unknown or duplicate option, no `->` clauses), are compile errors pointing at the line.
- The docs compare the DSL and the functional API: what each is for, and when mistakes are caught.

### Functional API

New:

- **`let/4`**: a step for functions that can't fail. The return value is stored as is, so `let(:upper, &String.upcase/1, [:text])` needs no `{:ok, _}` wrapping.
- **Child queues**: a `run/4` function may return a queue, which runs as a child with its result map stored under the step's name. A failing child step is reported as `{:error, step, {:error, child_step, reason, child_state}, state}`. A child's halt stops the parent too, unless it is `{:halt, value, propagate: false}`.
- **Arity-0 steps**: pass explicit `[]` to call a function or MFA with no queue inputs. In a `queue` block, the DSL generates this list automatically.
- **Step functions are validated when added**: an anonymous function's arity must match its params, and a `{module, function, args}` function must exist. Mistakes raise `ArgumentError` when the step is added instead of failing when the pipeline runs.

Breaking:

- **Debugging follows queue scope and execution timing.** Inside inline conditionals, `debug()` now includes earlier enclosing results; named children remain isolated. DSL debug options are evaluated only when reached and may reference earlier steps. Options must be a keyword list and `only:` must contain valid step names; invalid options or selections raise `ArgumentError` when added through the functional API or evaluated in the DSL. `nil` and `false` selections no longer print the whole state. The `only:` option is removed before forwarding inspection options.
- **Omitted params and explicit `[]` are distinct**, for both `run` and `let`, functions and MFAs. Omitting params passes the whole state as one argument; `[]` or `{[], opts}` passes no queue inputs. MFA fixed arguments are still passed. If a callback needs the whole state, omit params instead of passing `[]`; zero-argument callbacks must supply `[]` explicitly. Named params continue passing the listed values in order.
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
- **Invalid step functions raise `ArgumentError` when the step is added**, see above. A value that isn't a function or `{module, function(, args)}` raises `ArgumentError` instead of `FunctionClauseError`.
- **Unknown params options raise `ArgumentError`**. `{[:a], ordr: :append}` used to be ignored silently; `:order` is the only option.
- **`:order` with a function or capture raises `ArgumentError`.** It used to be ignored: it places inputs relative to an MFA's fixed arguments, and a function receives its inputs in the order of the params list.
- **`to_list/1` is removed from the public API**; it exposed the internal operation encoding. Use `operations/1` for a queue's step names. `Q.t()` is now an opaque type, so don't match on `%Q{}` fields.
- **`operations/1` lists step names only**, without debug operations.
- The `Q.fun_arity1()` type is removed; use `Q.step_fun()`. The `Q.exec_error()` type is renamed to `Q.error()`, after `exec/1` became `execute/1`.

### Planned

- Telemetry events for each step.
- Running independent steps concurrently, using the dependencies each step declares.

## 1.2.0

- Fixed the DSL rewriting calls inside step functions (e.g. `Kernel.inspect/1` in a `fn`), shadowing a caller variable named `queue`, and silently dropping steps added inside `if`/`case`. The latter, and `exec()` before the last statement, now raise at compile time.
- `{params, opts}` works for anonymous functions and `run/6`; malformed params and invalid `:order` values raise `ArgumentError` when the step is added.
- The duplicate name error no longer prints the queue's stored values.
- Doctests now assert their results; typespecs and docs corrected.
- Requires Elixir 1.15 or later.
