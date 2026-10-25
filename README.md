![Build Status](https://github.com/gpedic/ex_q/actions/workflows/ci.yml/badge.svg?branch=master)
[![Coverage Status](https://coveralls.io/repos/github/gpedic/ex_q/badge.svg?branch=master)](https://coveralls.io/github/gpedic/ex_q?branch=master)
[![License](https://img.shields.io/hexpm/l/ex_q.svg)](https://github.com/gpedic/ex_q/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/gpedic/ex_q.svg)](https://github.com/gpedic/ex_q/commits/master)

# Q

Q is a tool for building and executing pipelines of operations, influenced by Ecto.Multi. It preserves intermediate results so that you retain clarity and visibility into your data transformations at each step. When a step returns an error, you can see precisely which step failed and what the state looked like at that point.

## Why Q?

* **Keep error context**: when a step returns an error, Q returns all prior step results along with the failing step's name and error. Child failures include their own intermediate results in the nested error tuple.

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
    |> execute()
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

When a step returns an error, Q identifies the failing step and includes the results of every completed step before it.

```elixir
def process_data(data) do
  queue do
    raw = data
    decoded <- Jason.decode(raw)
    validated <- validate_schema(decoded)
    normalized <- normalize_data(validated)
    enriched <- add_metadata(normalized)
  end
  |> execute()
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

### Exceptions and side effects

Exceptions raised by step functions propagate unchanged to the caller, including exceptions inside child queues. Q does not convert them into error tuples or attach accumulated results to them. This applies to both `<-` and `=` steps.

Q does not automatically roll back completed operations. Stopping a queue after a returned error, raised exception or halt leaves earlier side effects in place:

```elixir
queue do
  payment <- Payments.charge(card)
  receipt <- Receipts.create(payment)
end
|> Q.execute()
```

If receipt creation returns an error or raises, the payment has already happened. Applications must explicitly manage transactions or compensating actions where required; the comparison to `Ecto.Multi` describes pipeline composition, not automatic transaction behavior.

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

  # Side-effect steps are named and their successful results are stored too
  notified <- Notifier.notify(decoded)
end
```

A step's inputs are the earlier steps its expression uses: `decoded <- Base.decode64(trimmed)` depends on `trimmed`. Other variables, such as function arguments, are captured as in any closure. Steps run in order when the queue is executed, and each result is stored under the step's name.

The block only builds the queue and returns it; pipe it into `execute/1` to run it. That way a function can build a queue and leave it to the caller whether to run it now or as a [sub-pipeline](#sub-pipelines).

## Halting execution early

A step can return `{:halt, value}` to end the pipeline successfully, skipping the remaining steps:

```elixir
def process_data(input) do
  queue do
    request = input
    cached <- check_cache(request.key)
    processed <- expensive_operation(request)
    stored <- store_in_cache(request.key, processed)
  end
  |> execute()
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
{:ok, %{request: %{key: "BWBeN28Vb7cMEx7Ym8AUzs", ...}, cached: :not_found, processed: %{...}, stored: ...}}
```

A halt stops the whole pipeline, also from inside a [sub-pipeline](#sub-pipelines). Return `{:halt, value, propagate: false}` to stop only the queue the step is in.

## Branching

Wrap steps in `if`, `unless`, `case` or `cond` to choose which steps run based on earlier results:

```elixir
queue do
  total <- Orders.total(order)

  if total > 100 do
    approval <- Approvals.request(order)
  end

  charged <- Payments.charge(order)
end
|> execute()
```

Steps in the branch that runs are added to the result, and an error or halt in them stops the pipeline like any other step. As with variables in Elixir, a step bound inside a branch can't be used after the conditional.

## Sub-pipelines

A step whose function returns a queue runs it as a child, and stores the child's results as a map under the step's name. The child's step names stay separate from the parent's, so a queue built by a function can be reused anywhere:

```elixir
def billing_steps(user) do
  queue do
    validated <- Billing.validate(user)
    invoice <- Billing.invoice(validated)
  end
end

def shipping_steps(user) do
  queue do
    validated <- Shipping.validate(user)
    tracking <- Shipping.book(validated)
  end
end

queue do
  user <- Accounts.fetch_user(id)
  billing <- billing_steps(user)
  shipping <- shipping_steps(user)
  confirmation <- confirm(billing.invoice, shipping.tracking)
end
|> execute()

# {:ok, %{
#   user: ...,
#   billing: %{validated: ..., invoice: ...},
#   shipping: %{validated: ..., tracking: ...},
#   confirmation: ...
# }}
```

Both children use `validated` without conflict. A child runs with its own state, so it gets its inputs as arguments, like `user` above. A block can also be nested inline: `billing <- queue do ... end`.

If a child step fails, the parent step fails and the reason is the child's error tuple, with the child's results up to the failure:

```elixir
{:error, :billing, {:error, :invoice, :declined, %{validated: ...}}, %{user: ...}}
```

To store a queue as a value instead of running it, use `=` or return `{:ok, queue}`.

## Debugging

`debug()` prints the current queue's accumulated state when execution reaches it. Inline conditionals share their enclosing queue's state; named child queues see only their own state. Printing never changes the pipeline's results.

Pass `only:` to print selected keys:

```elixir
queue do
  a = 1
  b = 2
  debug(only: :a)
end
|> execute()

# Prints:
# %{a: 1}
```

Options can reference earlier steps and capture external variables, just like step expressions:

```elixir
label = "approval"

queue do
  selected = :user
  user = %{id: 7}

  if user.id == 7 do
    approved = true
    debug(only: [selected, :approved], label: label)
  end
end
|> Q.execute()

# Prints user and approved with the label "approval".
```

The options expression runs once each time execution reaches that statement, rather than while building the queue. It isn't evaluated in an untaken branch or after an earlier error or halt.

`only:` accepts one valid step name or a list of names, including tuple names such as `{:invite, 7}`. An empty list prints `%{}`, and valid names missing from the current state are omitted. Invalid names, including `nil`, `true`, `false`, `:_`, strings and nested lists, raise `ArgumentError`. Options must be a keyword list. Q removes `only:` before passing other options to `IO.inspect/2`.

In the functional API, `Q.debug(q, options)` takes ordinary options and validates them when added. DSL options are validated when execution evaluates them.

## Rules

* Every statement in a `queue` block is a step (`name = expr` or `name <- expr`), `debug()`, or a conditional containing steps. `execute()` isn't a statement: the block builds the queue, and `execute/1` runs it. Every step must have a name, including steps run for their side effects.
* The left side of a step is a single named variable, and each name is bound once. Every successful step stores its result, including names starting with `_`. Bare `_` is not allowed.
* Mistakes, including a malformed `if`, `unless`, `case` or `cond`, are compile errors pointing at the line.

## Building queues programmatically

The `queue` block compiles to the functional API in `Q`, which is also available directly. Use it when the steps come from data, such as a step per item or names that aren't variables. Step names must be atoms or tuples, such as `:user` or `{:invite, user_id}`; `nil`, `true`, `false` and `:_` are not allowed. Lists, strings and other terms are rejected when the step is added:

```elixir
users
|> Enum.reduce(Q.new(), fn user, q ->
  Q.run(q, {:invite, user.id}, fn -> Mailer.invite(user) end, [])
end)
|> Q.execute()
```

Here a step's inputs are listed explicitly: `decoded <- Base.decode64(trimmed)` in a `queue` block is `Q.run(q, :decoded, &Base.decode64/1, [:trimmed])`, and `billing <- billing_steps(user)` is `Q.run(q, :billing, &billing_steps/1, [:user])`. See the [documentation](https://hexdocs.pm/ex_q/Q.html) for `put/3`, `run/4`, `let/4` and `debug/2`.

For both `run` and `let`, omitted params and explicit `[]` have different meanings. These rules apply to functions, captures and MFAs:

| Params | Queue inputs |
|---|---|
| Omitted | The whole accumulated state as one argument |
| `[]` | No queue inputs |
| `[:input, :options]` | Those results, in the listed order |

For example, a whole-state callback omits params, while an independent operation supplies `[]`:

```elixir
Q.new()
|> Q.put(:input, "aGVsbG8")
|> Q.run(:snapshot, fn state -> {:ok, state} end)
|> Q.run(:decoded, fn -> Base.decode64("aGVsbG8", padding: false) end, [])
|> Q.execute()

# {:ok, %{input: "aGVsbG8", snapshot: %{input: "aGVsbG8"}, decoded: "hello"}}
```

Q validates arity when a step is added. A zero-argument function requires explicit `[]`; it does not change the meaning of omitted params. In the DSL, Q generates the dependency list, so calls such as `token <- generate_token()` need no special syntax.

A queue is a plain value, so functions that add steps to it compose like any other function:

```elixir
def parse(q), do: Q.run(q, :parsed, &CSV.parse/1, [:file])
def validate(q), do: Q.run(q, :validated, &validate_rows/1, [:parsed])

Q.new()
|> Q.put(:file, data)
|> parse()
|> validate()
|> Q.execute()
```

### Passing options to step functions

Fixed arguments, such as function options, can be passed alongside values from earlier steps. An MFA (`{module, function, args}`) lists the fixed arguments in `args`; a function capture can close over them:

```elixir
options = [padding: false]

Q.new()
|> Q.put(:encoded, "aGVsbG8")
|> Q.run(:decoded_mfa, {Base, :decode64, [options]}, [:encoded])
|> Q.run(:decoded_capture, &Base.decode64(&1, options), [:encoded])
|> Q.execute()

# {:ok, %{
#   encoded: "aGVsbG8",
#   decoded_mfa: "hello",
#   decoded_capture: "hello"
# }}
```

Both steps call `Base.decode64(encoded, options)`. For the MFA, dependency values precede the fixed arguments by default. The capture places them explicitly in the call.

Explicit `[]` passes only an MFA's fixed arguments, for example `Q.run(q, :decoded, {Base, :decode64, ["aGVsbG8", options]}, [])`. `{[], order: :append}` also passes no queue inputs. Omitting params instead passes the whole state before any fixed arguments.

If the options come from an earlier step, list them as another dependency and use a direct function reference:

```elixir
Q.new()
|> Q.put(:encoded, "aGVsbG8")
|> Q.put(:options, padding: false)
|> Q.run(:decoded, &Base.decode64/2, [:encoded, :options])
|> Q.execute()

# {:ok, %{
#   encoded: "aGVsbG8",
#   options: [padding: false],
#   decoded: "hello"
# }}
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
