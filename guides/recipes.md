# Recipes

Complete patterns for common tasks, each with its success path, failure path and cleanup. The service modules (`Orders`, `Payments`, `Inventory` and so on) stand in for your own code.

## Match errors by step

Name each step after what it produces, then match on the step in the error tuple. The reason is what the failing function returned in `{:error, reason}`.

```elixir
def refund(order_id) do
  queue bind: [order_id] do
    order <- Orders.fetch(order_id)
    refund <- Payments.refund(order.charge_id, order.amount)
    notice <- Mailer.send_refund_notice(order.customer_id, refund)
  end
  |> execute()
  |> case do
    {:ok, %{refund: refund}} -> {:ok, refund}
    {:error, :order, :not_found, _state} -> {:error, :unknown_order}
    {:error, step, reason, _state} -> {:error, step, reason}
  end
end
```

## Return your own error shape

Callers often don't need the state. Drop it, or keep only what helps:

```elixir
|> case do
  {:ok, state} -> {:ok, state.refund}
  {:error, step, reason, %{order: order}} -> {:error, %{step: step, reason: reason, order_id: order.id}}
  {:error, step, reason, _state} -> {:error, %{step: step, reason: reason}}
end
```

## Fail a step on a boolean check

`<-` stores `false` like any other value, so a check that returns a boolean doesn't stop the queue on its own. Turn it into a result:

```elixir
queue bind: [order_id] do
  order <- Orders.fetch(order_id)
  refundable <- if Orders.refundable?(order), do: {:ok, true}, else: {:error, :not_refundable}
  refund <- Payments.refund(order.charge_id, order.amount)
end
|> execute()

# {:error, :refundable, :not_refundable, %{order_id: ..., order: ...}}
```

## Run a step only sometimes

Put the conditional inside the step. Return `{:ok, nil}` when it doesn't apply, so the step is always in the state and later steps can use it:

```elixir
queue bind: [order] do
  total <- Orders.total(order)
  approval <- if total > 100, do: Approvals.request(order), else: {:ok, nil}
  charge <- Payments.charge(order, approval)
end
|> execute()
```

Without an `else`, a false condition gives `nil`, which is stored too.

## Stop early on a cache hit

Return `{:halt, value}` to end the queue successfully. The halting step's value is stored under its name, and the later steps aren't in the state. Tell a hit from a full run by a key only the full run has:

```elixir
def price(product_id) do
  queue bind: [product_id] do
    cached <- cache_lookup(product_id)
    price <- Pricing.compute(product_id)
    stored = Cache.put(product_id, price)
  end
  |> execute()
  |> case do
    {:ok, %{price: price}} -> {:ok, price}
    {:ok, %{cached: price}} -> {:ok, price}
    {:error, step, reason, _state} -> {:error, step, reason}
  end
end

defp cache_lookup(product_id) do
  case Cache.get(product_id) do
    {:ok, price} -> {:halt, price}
    :miss -> {:ok, :miss}
  end
end
```

Match the full-run key first: on a miss, `cached` is in the state too.

## Undo completed steps after a failure

Q doesn't roll back. The state in the error tuple holds the result of every step that completed, so undo what's there:

```elixir
queue bind: [order] do
  payment <- Payments.charge(order)
  shipment <- Shipping.book(order)
end
|> execute()
|> case do
  {:ok, state} ->
    {:ok, state}

  {:error, step, reason, %{payment: payment}} ->
    Payments.refund(payment)
    {:error, step, reason}

  {:error, step, reason, _state} ->
    {:error, step, reason}
end
```

The failing step has no result, so a failed charge leaves nothing to refund, and the last clause handles it.

## One step per item, with cleanup

A block has a fixed set of steps. For a step per item, build the queue with the functional API and name each step after its item. Names must be unique, so add the position if items can repeat:

```elixir
def reserve_all(items) do
  items
  |> Enum.with_index()
  |> Enum.reduce(Q.new(), fn {item, index}, q ->
    Q.run(q, {:reserve, index}, fn -> Inventory.reserve(item.sku, item.qty) end, [])
  end)
  |> Q.execute()
  |> case do
    {:ok, reservations} ->
      {:ok, reservations}

    {:error, {:reserve, index}, reason, reserved} ->
      for {_step, reservation} <- reserved, do: Inventory.release(reservation)
      {:error, {:item, Enum.at(items, index).sku}, reason}
  end
end
```

## Per-item steps that need an earlier result

When the items come from an earlier step, return the per-item queue from a step. It runs as a child queue, with its state stored under the step's name.

A failed child's state is only in the nested error tuple, so clean up from there. If a later step fails, the child finished, and its state is under its name:

```elixir
def import_order(customer, csv) do
  queue bind: [customer, csv] do
    rows <- CSV.parse(csv)
    reservations <- reservation_steps(rows)
    charge <- Payments.charge(customer, Orders.total(rows))
  end
  |> execute()
  |> case do
    {:ok, state} ->
      {:ok, state.charge}

    {:error, :reservations, {:error, step, reason, reserved}, _state} ->
      release(reserved)
      {:error, step, reason}

    {:error, step, reason, state} ->
      release(Map.get(state, :reservations, %{}))
      {:error, step, reason}
  end
end

defp reservation_steps(rows) do
  rows
  |> Enum.with_index()
  |> Enum.reduce(Q.new(), fn {row, index}, q ->
    Q.run(q, {:reserve, index}, fn -> Inventory.reserve(row.sku, row.qty) end, [])
  end)
end

defp release(reservations) do
  for {_step, reservation} <- reservations, do: Inventory.release(reservation)
end
```

## Reuse a group of steps

A function that returns a queue, without running it, can be used as a step in any other queue. Its step names don't clash with the parent's:

```elixir
def billing_steps(user) do
  queue bind: [user] do
    account <- Billing.fetch_account(user)
    invoice <- Billing.invoice(account)
  end
end

queue bind: [id] do
  user <- Accounts.fetch_user(id)
  billing <- billing_steps(user)
  receipt <- Mailer.send_receipt(user, billing.invoice)
end
|> execute()

# {:ok, %{id: ..., user: ..., billing: %{user: ..., account: ..., invoice: ...}, receipt: ...}}
```

The same function can also run on its own: `billing_steps(user) |> execute()`.

## Use every step's result on success

The state has every step's result, so you can return or pass on several values without building a map by hand:

```elixir
def show(conn, %{"id" => id}) do
  queue bind: [id] do
    account <- Accounts.fetch(id)
    subscription <- Subscriptions.fetch(account)
    invoice <- Billing.upcoming_invoice(subscription)
  end
  |> execute()
  |> case do
    {:ok, state} -> render(conn, :show, state)
    {:error, _step, :not_found, _state} -> send_resp(conn, 404, "")
    {:error, _step, _reason, _state} -> send_resp(conn, 500, "")
  end
end
```

Bound values are in the state too, so `id` is passed to the template along with the rest.

## Test a queue

Run the queue and assert on the state, intermediate steps included. For failures, assert on the step:

```elixir
test "a declined card fails at :charge and keeps the reservations for cleanup" do
  assert {:error, :charge, :declined, state} = checkout_steps(declined_card()) |> Q.execute()
  assert Map.has_key?(state, :reservations)
end
```

`Q.operations/1` lists a queue's step names without running it.
