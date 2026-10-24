# Changelog

## 2.0.0

### Breaking changes

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

## 1.2.0

- Fixed the DSL rewriting calls inside step functions (e.g. `Kernel.inspect/1` in a `fn`), shadowing a caller variable named `queue`, and silently dropping steps added inside `if`/`case`. The latter, and `exec()` before the last statement, now raise at compile time.
- `{params, opts}` works for anonymous functions and `run/6`; malformed params and invalid `:order` values raise `ArgumentError` when the step is added.
- The duplicate name error no longer prints the queue's stored values.
- Doctests now assert their results; typespecs and docs corrected.
- Requires Elixir 1.15 or later.
