# Changelog

## 2.0.0

### New

- **`let/4`**: a step for functions that can't fail. The return value is stored as is, so `let(:upper, &String.upcase/1, [:text])` needs no `{:ok, _}` wrapping.
- **`merge/3`**: adds steps at run time, chosen by a function of earlier results. This is how a pipeline branches on results.
- **Arity-0 steps**: an anonymous function of arity 0 without params is called with no arguments.
- **Step functions are validated when added**: an anonymous function's arity must match its params, and a `{module, function, args}` function must exist. Mistakes raise `ArgumentError` when the step is added instead of failing when the pipeline runs.
- `let` and `merge` are available in the DSL.

### Breaking changes

- **`run/6` is removed.**
  - Upgrade: `run(q, name, mod, fun, args, params)` becomes `run(q, name, {mod, fun, args}, params)`.
- **`to_list/1` returns `{kind, name}` tuples**, such as `{:run, :decoded}`, instead of the internal operation encoding. `Q.t()` is now an opaque type, so don't match on `%Q{}` fields.
- **Invalid step functions raise `ArgumentError` when the step is added**, see above. A function that isn't a function or `{module, function(, args)}` raises `ArgumentError` instead of `FunctionClauseError`.
- The `Q.fun_arity1()` type is removed; use `Q.step_fun()`.
- **`Q.inspect/2` is renamed to `Q.debug/2`**, and `inspect()` in the DSL to `debug()`. The old name clashed with `Kernel.inspect/2` in any module that did `import Q`.
  - Upgrade: replace `Q.inspect(...)` with `Q.debug(...)` and `inspect(...)` with `debug(...)` inside `queue` blocks. A leftover top-level `inspect` in a `queue` block raises at compile time with a pointer to the rename.
- **`exec/1` on an empty queue returns `{:ok, %{}}`** instead of `{:ok, nil}`.
  - Upgrade: match on `{:ok, %{}}` or `{:ok, state}` where you matched `{:ok, nil}`.
- **A step returning a bare `:error` fails the pipeline** with `{:error, step, :error, state}`. It used to raise.
  - Upgrade: code that rescued the `RuntimeError` for such steps should match the error tuple instead.
- **Build-time mistakes raise `ArgumentError`** instead of `RuntimeError`: a duplicate step name, or a param that refers to a step that doesn't exist.
  - Upgrade: rescue `ArgumentError` where you rescued `RuntimeError`.
- **Unknown params options raise `ArgumentError`**. `{[:a], ordr: :append}` used to be ignored silently; `:order` is the only option.
- **`operations/1` no longer lists debug operations.** `to_list/1` still returns them.
- `Q.transform_dsl/1`, which was undocumented, is now private.

### Planned

- Telemetry events for each step.
- Running independent steps concurrently, using the dependencies their params declare.

## 1.2.0

- Fixed the DSL rewriting calls inside step functions (e.g. `Kernel.inspect/1` in a `fn`), shadowing a caller variable named `queue`, and silently dropping steps added inside `if`/`case`. The latter, and `exec()` before the last statement, now raise at compile time.
- `{params, opts}` works for anonymous functions and `run/6`; malformed params and invalid `:order` values raise `ArgumentError` when the step is added.
- The duplicate name error no longer prints the queue's stored values.
- Doctests now assert their results; typespecs and docs corrected.
- Requires Elixir 1.15 or later.
