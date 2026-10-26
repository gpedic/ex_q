![Build Status](https://github.com/gpedic/ex_q/actions/workflows/ci.yml/badge.svg?branch=master)
[![Coverage Status](https://coveralls.io/repos/github/gpedic/ex_q/badge.svg?branch=master)](https://coveralls.io/github/gpedic/ex_q?branch=master)
[![License](https://img.shields.io/hexpm/l/ex_q.svg)](https://github.com/gpedic/ex_q/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/gpedic/ex_q.svg)](https://github.com/gpedic/ex_q/commits/master)

# Q

Q is a `with` that remembers. You get the result of every step, and when one fails, its name, its error and everything before it.

## The problem with `with`

A webhook handler, written with `with`:

```elixir
def handle_webhook(conn, body, signature) do
  with {:ok, payload} <- Webhooks.verify(body, signature),
       {:ok, event} <- Jason.decode(payload),
       {:ok, account} <- Accounts.fetch_by_customer(event["customer"]),
       {:ok, subscription} <- Subscriptions.fetch(account, event["subscription"]),
       {:ok, updated} <- Subscriptions.apply_event(subscription, event),
       {:ok, _} <- Notifications.subscription_changed(account, updated) do
    send_resp(conn, 200, "")
  else
    {:error, :invalid_signature} ->
      send_resp(conn, 401, "")

    {:error, %Jason.DecodeError{}} ->
      send_resp(conn, 400, "")

    {:error, reason} ->
      # Was it the account or the subscription that wasn't found? Did applying the
      # event fail, or the notification? And which event was it? `event` isn't in
      # scope here.
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
    updated <- Subscriptions.apply_event(subscription, event)
    notified <- Notifications.subscription_changed(account, updated)
  end
  |> execute()
  |> case do
    {:ok, %{event: event, notified: notified}} ->
      Logger.info("webhook #{event["id"]} applied, notification #{notified.id} sent")
      send_resp(conn, 200, "")

    {:error, :payload, _reason, _state} ->
      send_resp(conn, 401, "")

    {:error, :event, _reason, _state} ->
      send_resp(conn, 400, "")

    {:error, step, reason, %{event: event}} ->
      Logger.warning("webhook #{event["id"]} failed at #{step}: #{inspect(reason)}")
      send_resp(conn, 200, "")
  end
end
```

When a step fails, you get this:

```elixir
# Subscriptions.fetch/2 returned {:error, :not_found}
{:error, :subscription, :not_found, %{
  body: "...",
  signature: "...",
  payload: "...",
  event: %{"id" => "evt_123", "customer" => "cus_456", ...},
  account: %Account{id: 42, ...}
}}
```

The tuple holds the step's name, the reason from its `{:error, reason}`, and the state: the result of every step before it, each under its step's name. The failing step has no result, so it isn't in the state.

You match on the step, not the shape of the error. The earlier results are right there, for logging, error messages or cleanup. On success you get all of them too, as a map you can log, return or pass on.

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

Q requires Elixir 1.15 or later. Upgrading from 1.x? See the [changelog](CHANGELOG.md). Full documentation is at [hexdocs.pm/ex_q](https://hexdocs.pm/ex_q), and the [recipes](guides/recipes.md) show complete patterns, with failure and cleanup paths, for common tasks.

### Using Q with coding agents

The package ships [`usage-rules.md`](usage-rules.md), a short list of rules and common mistakes for coding agents. Tools such as the [usage_rules](https://hex.pm/packages/usage_rules) package can sync it into your project's `AGENTS.md` or `CLAUDE.md`, so agents see it without having to look.

## Writing steps

Every step in a `queue` block is a binding, and the variable names the step.

```elixir
queue bind: [input] do
  # = can't fail: the value is stored as is, never unwrapped
  trimmed = String.trim(input)

  # <- can fail: {:ok, value} is unwrapped, {:error, reason} or :error stops
  # the queue, {:halt, value} ends it early, anything else is stored as is
  decoded <- Base.decode64(trimmed)

  # Steps run for their side effects get a name too
  notified <- Notifier.notify(decoded)
end
|> execute()
```

A step's inputs are the earlier steps it uses: `decoded` uses `trimmed`. Steps run in order, and each result is stored under the step's name.

Use `<-` when the result decides what happens next. Use `=` for everything else, including results you want to keep as they are, like `{:ok, pid}`. Reading a block, the `<-` steps are the ones that can fail.

Step names come from variables, so a block has a fixed set of steps. For a step per item, or names like `{:reserve, sku}`, see [Building queues from data](#building-queues-from-data).

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

The block builds the queue but doesn't run it. Pipe it into `Q.execute/1`. That lets a function return a queue and leave it to the caller to run it, or to use it as a [child queue](#child-queues).

### Functions that build a queue

`defq` defines a function that returns a queue, with its arguments bound as the first steps:

```elixir
defq billing_steps(user) do
  validated <- Billing.validate(user)
  invoice <- Billing.invoice(validated)
end

billing_steps(user) |> execute()

# {:ok, %{user: ..., validated: ..., invoice: ...}}
```

It's the same as a `def` whose body is `queue bind: [user] do ... end`, so the signature lists the queue's inputs. The arguments must be plain variables; guards are allowed. `defpq` defines a private one.

Use `defq` for functions that build a queue, to run or to use as a [child queue](#child-queues). A function that runs the queue and handles the result, like the webhook handler above, stays a `def` with `queue ... |> execute()` inside.

### Rules

* Each statement is a step (`name = expr` or `name <- expr`) or `debug()`. Conditionals go inside a step; see [Conditional steps](#conditional-steps).
* The left side is a single variable, bound once. Bare `_` isn't allowed; `_name` is a normal step and its result is stored.
* Mistakes, like binding a name twice, are compile errors pointing at the line.

## Errors, exceptions and side effects

A `<-` step fails when it returns `{:error, reason}` or `:error`. So functions like `Base.decode64/1` and `Map.fetch/2` work as steps without wrapping. The error tuple holds `reason` itself, not `{:error, reason}`; a bare `:error` gives `:error` as the reason. Functions that return a plain value work too; the value is stored as is.

The state holds whatever your steps returned, including tokens and personal data. Pick what you log.

Exceptions aren't caught. They reach the caller unchanged, from child queues too, without the state attached.

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

## Conditional steps

Put the conditional inside the step, as you would with `x = if ...`:

```elixir
queue bind: [order] do
  total <- Orders.total(order)
  approval <- if total > 100, do: Approvals.request(order), else: {:ok, nil}
  charged <- Payments.charge(order, approval)
end
|> execute()
```

The step always runs, so it's always in the state and later steps can use it. If the branch that runs returns an error or a halt, the queue stops as usual.

Without an `else`, a false condition gives `nil`, which `<-` stores like any other value: `approval <- if total > 100, do: Approvals.request(order)` stores `nil` for small orders.

For several steps in one branch, return a queue. It runs as a [child queue](#child-queues):

```elixir
approval <-
  if total > 100 do
    queue bind: [order] do
      requested <- Approvals.request(order)
      notified <- Managers.notify(requested)
    end
  else
    {:ok, nil}
  end
```

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

The halting step's value is stored under its name, and the steps after it aren't in the state. `Q.execute/1` returns `{:ok, state}` either way, so to tell a halt from a full run, match on a key only one of them has:

```elixir
case process_data(input) do
  {:ok, %{stored: _, processed: processed}} -> processed
  {:ok, %{cached: cached}} -> cached
end
```

A halt stops the queue it's in, the way `{:halt, acc}` stops `Enum.reduce_while/3`. In a [child queue](#child-queues), it stops only the child. The parent stores the child's state and carries on.

## Child queues

A step that returns a queue runs it as a child. The child's state is stored under the step's name. Its step names don't clash with the parent's, so a function that builds a queue can be reused anywhere:

```elixir
defq billing_steps(user) do
  validated <- Billing.validate(user)
  invoice <- Billing.invoice(validated)
end

defq shipping_steps(user) do
  validated <- Shipping.validate(user)
  tracking <- Shipping.book(validated)
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

Both children have a `validated` step, with no conflict. A child starts with an empty state, so it gets what it needs as arguments, like `user` above. You can also nest a block inline: `billing <- queue bind: [user] do ... end`.

If a child step fails, the parent step fails too. Its reason is the child's error tuple, with the child's state:

```elixir
{:error, :billing, {:error, :invoice, :declined, %{user: ..., validated: ...}}, %{id: ..., user: ...}}
```

A failed child's state is only in that nested tuple, so that's where to find what it did before failing:

```elixir
{:error, :reservations, {:error, _step, reason, reserved}, _state} ->
  for {_step, reservation} <- reserved, do: Inventory.release(reservation)
  {:error, :reservations, reason}
```

If a later step fails instead, the child finished, and its state is under its name as usual.

To store a queue without running it, use `=` or return `{:ok, queue}`.

## Debugging

`debug()` prints the state so far. It never changes it. `only:` picks steps; other options go to `IO.inspect/2`:

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

Options can use earlier steps, and are evaluated when execution reaches `debug`. In a child queue, it prints only the child's state. See `Q.debug/2`.

## Building queues from data

A `queue` block compiles to the functional API in `Q`, which you can use directly. Both build the same queue and run with `Q.execute/1`. The return values, errors, child queues and halts work the same, and you can mix the two.

The block gives you compile-time checks, inferred inputs and inline nesting. The functional API gives you what a block can't do.

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

Step names must be unique, and a duplicate raises `ArgumentError` when it's added. If items can repeat, add their position to the name, like `{:invite, id, index}`.

Each item's result is stored under its own name, so after a failure you can undo exactly the items that went through:

```elixir
{:error, step, reason, state} ->
  for {{:reserve, _sku}, reservation} <- state, do: Inventory.release(reservation)
  {:error, step, reason}
```

**Steps chosen from data**, so the error names the check that failed:

```elixir
# Each check returns {:ok, value} or {:error, reason}
checks = [email: &check_email/1, age: &check_age/1, country: &check_country/1]

checks
|> Enum.reduce(Q.new() |> Q.put(:user, user), fn {name, check}, q ->
  Q.run(q, name, check, [:user])
end)
|> Q.execute()

# {:error, :age, :underage, %{user: ..., email: "joe@example.com"}}
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

`Q.put/3` stores a value. `Q.run/4` is `<-` and `Q.let/4` is `=`. Instead of being inferred, inputs are listed: `decoded <- Base.decode64(trimmed)` becomes `Q.run(q, :decoded, &Base.decode64/1, [:trimmed])`. Leaving params out and passing `[]` are different:

| Params | Inputs |
|---|---|
| Omitted | The whole state, as one map |
| `[]` | None |
| `[:input, :options]` | Those results, in that order |

Omitted params and a one-name list both call a one-argument function, so a mix-up isn't caught when the step is added: with params omitted, the function gets the whole state instead of one result.

A step function can be a function, a capture or an MFA (`{module, function, args}`). An MFA's `args` are fixed arguments, like options. Inputs go before them, or after with `{[:key], order: :append}`:

```elixir
Q.new()
|> Q.put(:encoded, "aGVsbG8")
|> Q.run(:decoded, {Base, :decode64, [[padding: false]]}, [:encoded])
|> Q.execute()

# {:ok, %{encoded: "aGVsbG8", decoded: "hello"}}
```

See `Q.run/4`, `Q.let/4`, `Q.put/3` and `Q.debug/2` for details.

### When mistakes are caught

The block is checked at compile time. A typo in a step name, an unbound outside variable or a duplicate step is a compile error. The functional API checks each step as it's added: a wrong arity, an unknown param, a bad name or a duplicate raises `ArgumentError`, but only when that code runs. That's the cost of building from data. If you can write the pipeline out in code, use the block.
