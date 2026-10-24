# Changelog

## 2.0.0

### New `queue` syntax

Steps in a `queue` block are now bindings, named after their variable. A step's inputs are the earlier steps its expression uses, so atom names, params lists and function wrappers are gone:

```elixir
queue do
  input = data
  decoded <- Base.decode64(input)
  upper = String.upcase(decoded)
  exec()
end
```

The 1.x syntax is removed, and its calls inside a `queue` block are a compile error pointing at the new syntax. To upgrade, rewrite each statement:

| 1.x | 2.0 |
|---|---|
| `put(:input, data)` | `input = data` |
| `run(:decoded, &Base.decode64/1, [:input])` | `decoded <- Base.decode64(input)` |
| `run(:valid, fn %{decoded: d} -> validate(d) end)` | `valid <- validate(decoded)` |
| `run(:cs, {Mod, :changeset, [%S{}]}, {[:a, :b], order: :append})` | `cs <- Mod.changeset(%S{}, a, b)` |
| `inspect()` / `inspect(only: :a)` | `debug()` / `debug(only: :a)` |
| `exec()` | `exec()` (unchanged) |

Also new in the block:

- `name = expr` stores a value or the result of a function that can't fail; `<-` is for functions returning `{:ok, value}` or `{:error, reason}`.
- `if`, `unless`, `case` and `cond` around steps choose which steps run, based on earlier results.
- `_ = expr` and `_name <- expr` run a step without storing its result.
- A step whose function returns a queue runs it as a sub-pipeline, with its results stored as a map under the step's name; `name <- queue do ... end` nests a block inline.
- A halt stops the whole pipeline, also from inside a sub-pipeline; `{:halt, value, propagate: false}` stops only the queue the step is in.
- Mistakes, such as binding a name twice, are compile errors pointing at the line.

### Functional API

New:

- **`let/4`**: a step for functions that can't fail. The return value is stored as is, so `let(:upper, &String.upcase/1, [:text])` needs no `{:ok, _}` wrapping.
- **Child queues**: a `run/4` function may return a queue, which runs as a child with its result map stored under the step's name. A failing child step is reported as `{:error, step, {:error, child_step, reason, child_state}, state}`. A child's halt stops the parent too, unless it is `{:halt, value, propagate: false}`.
- **Arity-0 steps**: an anonymous function of arity 0 without params is called with no arguments.
- **Unstored steps**: steps named with an atom starting with `_` run, but their result isn't stored and the name can repeat.
- **Step functions are validated when added**: an anonymous function's arity must match its params, and a `{module, function, args}` function must exist. Mistakes raise `ArgumentError` when the step is added instead of failing when the pipeline runs.

Breaking:

- **`Q.inspect/2` is renamed to `Q.debug/2`.** The old name clashed with `Kernel.inspect/2` in any module that did `import Q`.
- **`run/6` is removed.**
  - Upgrade: `run(q, name, mod, fun, args, params)` becomes `run(q, name, {mod, fun, args}, params)`.
- **`exec/1` on an empty queue returns `{:ok, %{}}`** instead of `{:ok, nil}`.
- **A step returning a bare `:error` fails the pipeline** with `{:error, step, :error, state}`. It used to raise.
  - Upgrade: code that rescued the `RuntimeError` for such steps should match the error tuple instead.
- **Build-time mistakes raise `ArgumentError`** instead of `RuntimeError`: a duplicate step name, or a param that refers to a step that doesn't exist.
- **Invalid step functions raise `ArgumentError` when the step is added**, see above. A value that isn't a function or `{module, function(, args)}` raises `ArgumentError` instead of `FunctionClauseError`.
- **Unknown params options raise `ArgumentError`**. `{[:a], ordr: :append}` used to be ignored silently; `:order` is the only option.
- **`to_list/1` returns `{kind, name}` tuples**, such as `{:run, :decoded}`, instead of the internal operation encoding. `Q.t()` is now an opaque type, so don't match on `%Q{}` fields.
- **`operations/1` lists step names only**, without debug operations.
- The `Q.fun_arity1()` type is removed; use `Q.step_fun()`.

### Planned

- Telemetry events for each step.
- Running independent steps concurrently, using the dependencies each step declares.

## 1.2.0

- Fixed the DSL rewriting calls inside step functions (e.g. `Kernel.inspect/1` in a `fn`), shadowing a caller variable named `queue`, and silently dropping steps added inside `if`/`case`. The latter, and `exec()` before the last statement, now raise at compile time.
- `{params, opts}` works for anonymous functions and `run/6`; malformed params and invalid `:order` values raise `ArgumentError` when the step is added.
- The duplicate name error no longer prints the queue's stored values.
- Doctests now assert their results; typespecs and docs corrected.
- Requires Elixir 1.15 or later.
