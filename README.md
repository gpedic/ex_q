![Build Status](https://github.com/gpedic/ex_q/actions/workflows/ci.yml/badge.svg?branch=master)
[![Coverage Status](https://coveralls.io/repos/github/gpedic/ex_q/badge.svg?branch=master)](https://coveralls.io/github/gpedic/ex_q?branch=master)
[![License](https://img.shields.io/hexpm/l/ex_q.svg)](https://github.com/gpedic/ex_q/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/gpedic/ex_q.svg)](https://github.com/gpedic/ex_q/commits/master)

# Q

Q is a `with` that remembers. When a step fails, you get its name, its error, and every result that came before it.

## The problem with `with`

A webhook handler, written with `with`:

```elixir
def handle_webhook(conn, body, signature) do
  with {:ok, payload} <- Webhooks.verify(body, signature),
       {:ok, event} <- Jason.decode(payload),
       {:ok, account} <- Accounts.fetch_by_customer(event["customer"]),
       {:ok, subscription} <- Subscriptions.fetch(account, event["subscription"]),
       {:ok, _} <- Subscriptions.apply_event(subscription, event) do
    send_resp(conn, 200, "")
  else
    {:error, :invalid_signature} ->
      send_resp(conn, 401, "")

    {:error, %Jason.DecodeError{}} ->
      send_resp(conn, 400, "")

    {:error, reason} ->
      # Was it the account or the subscription that wasn't found? Or did applying
      # the event fail? And which event was it? `event` isn't in scope here.
      Logger.warning("webhook failed: #{inspect(reason)}")
      send_resp(conn, 200, "")
  end
end
```

Each `else` clause has to guess the step from the shape of the error. Both lookups return `{:error, :not_found}`, so you can't tell them apart. And the values you'd want to log are gone.

The same handler with Q:

```elixir
import Q

def handle_webhook(conn, body, signature) do
  queue bind: [body, signature] do
    payload <- Webhooks.verify(body, signature)
    event <- Jason.decode(payload)
    account <- Accounts.fetch_by_customer(event["customer"])
    subscription <- Subscriptions.fetch(account, event["subscription"])
    applied <- Subscriptions.apply_event(subscription, event)
  end
  |> execute()
  |> case do
    {:ok, _results} ->
      send_resp(conn, 200, "")

    {:error, :payload, _reason, _results} ->
      send_resp(conn, 401, "")

    {:error, :event, _reason, _results} ->
      send_resp(conn, 400, "")

    {:error, step, reason, %{event: event}} ->
      Logger.warning("webhook #{event["id"]} failed at #{step}: #{inspect(reason)}")
      send_resp(conn, 200, "")
  end
end
```

When a step fails, you get this:

```elixir
{:error, :subscription, :not_found, %{
  body: "...",
  signature: "...",
  payload: "...",
  event: %{"id" => "evt_123", "customer" => "cus_456", ...},
  account: %Account{id: 42, ...}
}}
```

You match on the step, not the shape of the error. The earlier results are right there, for logging, error messages or cleanup. On success you get every result, not just the last one.

The steps are the same calls as in the `with`. No wrappers, no `{:ok, _}` patterns. Q has no dependencies.

### What about tagging the `with` clauses?

The usual fix is to tag each clause:

```elixir
with {:payload, {:ok, payload}} <- {:payload, Webhooks.verify(body, signature)},
     {:event, {:ok, event}} <- {:event, Jason.decode(payload)},
     {:account, {:ok, account}} <- {:account, Accounts.fetch_by_customer(event["customer"])},
     ...
else
  {:account, {:error, :not_found}} ->
    # The step is known now, but `event` is still out of scope
end
```

Now you know the step. But every line got noisier, and the earlier results are still out of reach. To get them back, you'd thread a map through every clause by hand. That's what Q does.

### When to use something else

* **Database writes that must all succeed or all fail.** Use [`Ecto.Multi`](https://hexdocs.pm/ecto/Ecto.Multi.html) in a transaction. Q returns errors in the same shape, but doesn't roll anything back.
* **Steps that need automatic undo on failure.** Use a saga library like [Sage](https://hex.pm/packages/sage).
* **Two or three steps with distinct errors.** Plain `with` is fine.

## Installation

Add `ex_q` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_q, "~> 2.0"}
  ]
end
```

Upgrading from 1.x? See the [changelog](CHANGELOG.md). Full documentation is at [hexdocs.pm/ex_q](https://hexdocs.pm/ex_q).

## Writing steps

Each line in a `queue` block is a step. The variable names it.

```elixir
queue bind: [input] do
  # <- can fail: {:ok, value} is unwrapped, {:error, reason} or :error stops
  # the queue, {:halt, value} ends it early, anything else is stored as is
  trimmed <- String.trim(input)
  decoded <- Base.decode64(trimmed)

  # = can't fail: the value is stored as is, never unwrapped
  limit = 100

  # Steps run for their side effects get a name too
  notified <- Notifier.notify(decoded)
end
|> execute()
```

A step's inputs are the earlier steps it uses: `decoded` uses `trimmed`. Steps run in order, and each result is stored under the step's name.

Use `<-` when the result decides what happens next. Use `=` for everything else, including results you want to keep as they are, like `{:ok, pid}`. Reading a block, the `<-` steps are the ones that can fail.

### Outside values

A block is its own scope, like `quote`. Steps can't see variables from outside, so a typo in a step name is a compile error, even if an outside variable has that name. Bring values in with `bind:`. A bare variable keeps its name; `name: expr` binds any expression:

```elixir
def settings(conn, opts) do
  queue bind: [opts, current_user: conn.assigns.current_user] do
    settings <- Settings.load(current_user, opts)
  end
  |> execute()
end

# {:ok, %{opts: ..., current_user: ..., settings: ...}}
```

Bound values are evaluated when the block is built, and they're stored like any other step. Variables bound inside an expression, like `fn` arguments, work as usual.

### Building and running

The block builds the queue but doesn't run it. Pipe it into `execute/1`. That lets a function return a queue and leave it to the caller to run it, or to use it as a [sub-pipeline](#sub-pipelines).

### Rules

* Each statement is a step (`name = expr` or `name <- expr`), `debug()`, or a conditional with steps inside.
* The left side is a single variable, bound once. Bare `_` isn't allowed; `_name` is a normal step and its result is stored.
* Mistakes, like a malformed `if` or `case`, are compile errors pointing at the line.

## Errors, exceptions and side effects

A `<-` step fails when it returns `{:error, reason}` or `:error`. So functions like `Base.decode64/1` and `Map.fetch/2` work as steps without wrapping. A bare `:error` is reported with `:error` as the reason. Functions that return a plain value work too; the value is stored as is.

The results hold whatever your steps returned, including tokens and personal data. Pick what you log.

Exceptions aren't caught. They reach the caller unchanged, from child queues too, without the results attached.

Q doesn't roll back. If a step fails, the steps before it have already happened:

```elixir
queue bind: [card] do
  payment <- Payments.charge(card)
  receipt <- Receipts.create(payment)
end
|> execute()
```

If creating the receipt fails, the card has been charged. The error tuple has what you need to refund it:

```elixir
{:error, :receipt, reason, %{payment: payment}} ->
  Payments.refund(payment)
  {:error, reason}
```

## Branching

Wrap steps in `if`, `unless`, `case` or `cond` to choose what runs:

```elixir
queue bind: [order] do
  total <- Orders.total(order)

  if total > 100 do
    approval <- Approvals.request(order)
  end

  charged <- Payments.charge(order)
end
|> execute()
```

Steps in the branch that runs are added to the results. An error or halt in them stops the queue. As with ordinary Elixir variables, a step bound in a branch can't be used after it.

## Halting early

A step can return `{:halt, value}` to finish early, with success:

```elixir
def process_data(input) do
  queue bind: [request: input] do
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

A halt stops the queue it's in, the way `{:halt, acc}` stops `Enum.reduce_while/3`. In a [sub-pipeline](#sub-pipelines), it stops only the sub-pipeline. The parent keeps the child's results and carries on.

## Sub-pipelines

A step that returns a queue runs it as a child. The child's results are stored as a map under the step's name. Its step names don't clash with the parent's, so a function that builds a queue can be reused anywhere:

```elixir
def billing_steps(user) do
  queue bind: [user] do
    validated <- Billing.validate(user)
    invoice <- Billing.invoice(validated)
  end
end

def shipping_steps(user) do
  queue bind: [user] do
    validated <- Shipping.validate(user)
    tracking <- Shipping.book(validated)
  end
end

queue bind: [id] do
  user <- Accounts.fetch_user(id)
  billing <- billing_steps(user)
  shipping <- shipping_steps(user)
  confirmation <- confirm(billing.invoice, shipping.tracking)
end
|> execute()

# {:ok, %{
#   id: ...,
#   user: ...,
#   billing: %{user: ..., validated: ..., invoice: ...},
#   shipping: %{user: ..., validated: ..., tracking: ...},
#   confirmation: ...
# }}
```

Both children have a `validated` step, with no conflict. A child starts with an empty state, so it binds what it needs, like `user` above. You can also nest a block inline: `billing <- queue bind: [user] do ... end`.

If a child step fails, the parent step fails too. Its reason is the child's error tuple, with the child's results:

```elixir
{:error, :billing, {:error, :invoice, :declined, %{user: ..., validated: ...}}, %{id: ..., user: ...}}
```

To store a queue without running it, use `=` or return `{:ok, queue}`.

## Debugging

`debug()` prints the results so far. It never changes them. `only:` picks steps; other options go to `IO.inspect/2`:

```elixir
queue do
  a = 1
  b = 2
  debug(only: :a, label: "after b")
end
|> execute()

# Prints:
# after b: %{a: 1}
```

Options can use earlier steps, and are evaluated when execution reaches `debug`. In a conditional it sees the enclosing queue's results; in a child, only the child's. See `debug/2`.

## Building queues from data

A `queue` block compiles to plain function calls in `Q`, and you can use them directly. Both build the same queue and run with `execute/1`. Results, errors, child queues and halts work the same, and you can mix the two.

The block gives you compile-time checks, inferred inputs, branching and inline nesting. The functions give you what a block can't do.

**A step per item**, named after the item, so you see which one failed:

```elixir
users
|> Enum.reduce(Q.new(), fn user, q ->
  Q.run(q, {:invite, user.id}, fn -> Mailer.invite(user) end, [])
end)
|> Q.execute()

# {:ok, %{{:invite, 1} => :sent, {:invite, 3} => :sent}}
# {:error, {:invite, 2}, :bounced, %{{:invite, 1} => :sent}}
```

**Steps chosen from data**, so the error names the check that failed:

```elixir
checks = [email: &valid_email?/1, age: &adult?/1, country: &supported_country?/1]

checks
|> Enum.reduce(Q.new() |> Q.put(:user, user), fn {name, check}, q ->
  Q.run(q, name, check, [:user])
end)
|> Q.execute()

# {:error, :age, :underage, %{user: ..., email: true}}
```

**Queues built across functions**, or with steps added conditionally:

```elixir
def parse(q), do: Q.run(q, :parsed, &CSV.parse/1, [:file])
def validate(q), do: Q.run(q, :validated, &validate_rows/1, [:parsed])

q = Q.new() |> Q.put(:file, data) |> parse() |> validate()
q = if opts[:notify], do: Q.run(q, :notified, &Notifier.notify/1, [:validated]), else: q
Q.execute(q)
```

Step names are atoms or tuples, like `{:invite, id}`. `nil`, `true`, `false` and `:_` aren't allowed.

### Inputs and step functions

`put/3` stores a value. `run/4` is `<-` and `let/4` is `=`. Instead of being inferred, inputs are listed: `decoded <- Base.decode64(trimmed)` becomes `Q.run(q, :decoded, &Base.decode64/1, [:trimmed])`. Leaving params out and passing `[]` are different:

| Params | Inputs |
|---|---|
| Omitted | All results so far, as one map |
| `[]` | None |
| `[:input, :options]` | Those results, in that order |

A step function can be a function, a capture or an MFA (`{module, function, args}`). An MFA's `args` are fixed arguments, like options. Inputs go before them, or after with `{[:key], order: :append}`:

```elixir
Q.new()
|> Q.put(:encoded, "aGVsbG8")
|> Q.run(:decoded, {Base, :decode64, [[padding: false]]}, [:encoded])
|> Q.execute()

# {:ok, %{encoded: "aGVsbG8", decoded: "hello"}}
```

See `run/4`, `let/4`, `put/3` and `debug/2` for details.

### When mistakes are caught

The block is checked at compile time. A typo in a step name, an unbound outside variable, a duplicate step or a malformed `if` or `case` is a compile error. The functions check each step as it's added: a wrong arity, an unknown param, a bad name or a duplicate raises `ArgumentError`, but only when that code runs. That's the cost of building from data. If you can write the pipeline out in code, use the block.
