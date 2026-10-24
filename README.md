![Build Status](https://github.com/gpedic/ex_q/actions/workflows/ci.yml/badge.svg?branch=master)
[![Coverage Status](https://coveralls.io/repos/github/gpedic/ex_q/badge.svg?branch=master)](https://coveralls.io/github/gpedic/ex_q?branch=master)
[![License](https://img.shields.io/hexpm/l/ex_q.svg)](https://github.com/gpedic/ex_q/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/gpedic/ex_q.svg)](https://github.com/gpedic/ex_q/commits/master)

# Q

Q is a tool for building and executing pipelines of operations, influenced by Ecto.Multi. It preserves all intermediate results so that you retain clarity and visibility into your data transformations at each step. When a pipeline fails, you can see precisely which step broke and what the state looked like at that point.

## Why Q?

* **Never lose context**: like Ecto.Multi, Q returns the results of all executed steps. When a step breaks, Q returns all prior step results along with the failing step's name and error.

* **Plain Elixir**: steps are written like the bindings of a `with` chain. Q works out which earlier results each step needs, so step functions don't have to be wrapped or rewritten to fit the pipeline.

* **Branch on results**: wrap steps in `if` or `case` to choose what runs next based on what earlier steps returned.

## Example

```elixir
defmodule UploadProcessor do
  import Q

  def process_upload(file_data) do
    queue do
      file = file_data
      parsed <- DataProcessor.parse_csv(file)
      validated <- validate_rows(parsed)
      enriched <- DataProcessor.enrich_data(validated, use_ai: true)
    end
    |> exec()
  end

  defp validate_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case DataProcessor.validate_row(row) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end

# {:ok, %{file: ..., parsed: ..., validated: ..., enriched: ...}}
```

## Error handling

Q provides the complete context even when something fails: you know which step failed, and you have the results of every step before it.

```elixir
def process_data(data) do
  queue do
    raw = data
    decoded <- Jason.decode(raw)
    validated <- validate_schema(decoded)
    normalized <- normalize_data(validated)
    enriched <- add_metadata(normalized)
    exec()
  end
end

# If JSON parsing fails
{:error, :decoded, %Jason.DecodeError{data: "invalid", position: 0, token: nil}, %{raw: "invalid"}}

# If validation fails, the results of the previous steps are available
{:error, :validated, :invalid_schema, %{
  raw: "{\"foo\": 123}",
  decoded: %{"foo" => 123}
}}
```

Steps can return `{:error, reason}` or a bare `:error`, so functions like `Base.decode64/1` or `Map.fetch/2` work as steps without wrapping. A bare `:error` is reported as `{:error, step, :error, state}`.

### Without Q

```elixir
def process_data_without_q(data) do
  with {:ok, decoded} <- Jason.decode(data),
       {:ok, validated} <- validate_schema(decoded),
       {:ok, normalized} <- normalize_data(validated),
       {:ok, enriched} <- add_metadata(normalized) do
    {:ok, enriched}
  else
    {:error, reason} ->
      # We know the failure reason, but not which step failed,
      # and the results of the earlier steps are gone
      {:error, reason}
  end
end
```

## Writing steps

Every step is a binding, and the variable names the step:

```elixir
queue do
  # = stores the value of an expression: a value, or a function that can't fail
  input = data
  trimmed = String.trim(input)

  # <- runs a function that returns {:ok, value}, {:error, reason} or :error,
  # and stores the value
  decoded <- Base.decode64(trimmed)

  # _ runs a step without storing its result
  _ <- Notifier.notify(decoded)
end
```

A step's inputs are the earlier steps its expression uses: `decoded <- Base.decode64(trimmed)` depends on `trimmed`. Other variables, such as function arguments, are captured as in any closure. Steps run in order when the queue is executed, and each result is stored under the step's name.

The block returns the queue. Run it with `exec()` as the last statement, or by piping it into `exec/1`.

## Halting execution early

A step can return `{:halt, value}` to end the pipeline successfully, skipping the remaining steps:

```elixir
def process_data(input) do
  queue do
    request = input
    cached <- check_cache(request.key)
    processed <- expensive_operation(request)
    _ <- store_in_cache(request.key, processed)
    exec()
  end
end

defp check_cache(key) do
  case get_from_cache(key) do
    nil -> {:ok, :not_found}
    cached -> {:halt, cached}
  end
end

# Cache hit
{:ok, %{request: %{key: "BWBeN28Vb7cMEx7Ym8AUzs", ...}, cached: %{...}}}

# Cache miss
{:ok, %{request: %{key: "BWBeN28Vb7cMEx7Ym8AUzs", ...}, cached: :not_found, processed: %{...}}}
```

## Branching

Wrap steps in `if`, `unless`, `case` or `cond` to choose which steps run based on earlier results:

```elixir
queue do
  total <- Orders.total(order)

  if total > 100 do
    approval <- Approvals.request(order)
  end

  charged <- Payments.charge(order)
  exec()
end
```

Steps in the branch that runs are added to the result, and an error or halt in them stops the pipeline like any other step. As with variables in Elixir, a step bound inside a branch can't be used after the conditional.

A conditional compiles to `merge`, which works like `Ecto.Multi.merge`: a function of the results so far returns a queue, whose steps run next with their own state. `merge` is also a statement, to include a queue built by another function:

```elixir
queue do
  user <- Accounts.fetch_user(id)
  merge(onboarding_steps(user))
  exec()
end
```

## Debugging

`debug()` prints the state at that point of the pipeline when it runs. Pass `only:` to print selected keys:

```elixir
queue do
  a = 1
  b = 2
  debug(only: :a)
  exec()
end

# Prints:
%{a: 1}
```

## Rules

* Every statement in a `queue` block is a step (`name = expr` or `name <- expr`), `debug()`, `merge(queue)`, a conditional containing steps, or `exec()` as the last statement. Use `_ = expr` to run an expression without storing its result.
* The left side of a step is a single variable, and each name is bound once. Names starting with `_` aren't stored and can repeat.
* Mistakes are compile errors pointing at the line.

## Building queues programmatically

The `queue` block compiles to the functional API in `Q`, which is also available directly. Use it when the steps come from data, such as a step per item or names that aren't variables:

```elixir
users
|> Enum.reduce(Q.new(), fn user, q ->
  Q.run(q, {:invite, user.id}, fn -> Mailer.invite(user) end)
end)
|> Q.exec()
```

Here a step's inputs are listed explicitly: `decoded <- Base.decode64(trimmed)` in a `queue` block is `Q.run(q, :decoded, &Base.decode64/1, [:trimmed])`. See the [documentation](https://hexdocs.pm/ex_q/Q.html) for `put/3`, `run/4`, `let/4`, `merge/3` and `debug/2`.

A queue is a plain value, so functions that add steps to it compose like any other function:

```elixir
def parse(q), do: Q.run(q, :parsed, &CSV.parse/1, [:file])
def validate(q), do: Q.run(q, :validated, &validate_rows/1, [:parsed])

Q.new()
|> Q.put(:file, data)
|> parse()
|> validate()
|> Q.exec()
```

## Installation

Add `ex_q` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_q, "~> 2.0"}
  ]
end
```

Upgrading from 1.x? See the [changelog](CHANGELOG.md).

Documentation can be found at [https://hexdocs.pm/ex_q](https://hexdocs.pm/ex_q).
