# Rules for working with Q (ex_q)

Q runs a chain of steps like `with`, keeps every step's result, and on failure returns which step failed and the results before it.

## Writing a queue

- Write a pipeline as a `queue` block after `import Q`, and run it with `execute/1`. The block only builds the queue; never call `execute()` inside it.

  ```elixir
  queue bind: [order_id] do
    order <- Orders.fetch(order_id)
    total = Orders.total(order)
    charge <- Payments.charge(order, total)
  end
  |> execute()
  ```

- Every statement is a step: a single variable, then `<-` or `=`. The variable names the step. Each name is bound once. `debug()` is the only other statement.
- `name <- expr` is for calls that can fail:
  - `{:ok, value}` stores `value`
  - `{:error, reason}` or `:error` stops the queue
  - `{:halt, value}` stores `value` and ends the queue successfully
  - a queue runs as a child, with its results stored as a map under `name`
  - **any other value, including `false` and `nil`, is stored and the queue continues**
- `name = expr` can't fail. The value is stored as is, never unwrapped: `{:ok, 1}` stays `{:ok, 1}`.
- Steps can't see variables from outside the block. Bring them in with `bind: [var, name: expr]`; each becomes a step at the start of the queue.

## Results and errors

- `execute/1` returns `{:ok, results}` or `{:error, step, reason, results}`.
- `reason` is what the function returned in `{:error, reason}`, not the whole tuple.
- `results` holds the steps that completed. The failing step isn't in it.
- Match errors on `step`, not on the shape of `reason`.
- A halt also returns `{:ok, results}`, without the steps after it. Tell it from a full run by matching on a key only the full run has.
- A failed child queue's error is `{:error, step, {:error, child_step, reason, child_results}, results}`. The child's results are only in that nested tuple.
- Q doesn't roll back and doesn't catch exceptions. Undo side effects yourself from the error tuple's results.

## Common mistakes

- **Don't write `{:ok, user} <- fetch(id)`.** `<-` unwraps `{:ok, value}` itself: write `user <- fetch(id)`.
- **Don't put `if`, `case` or `cond` around steps.** Put the conditional inside a step: `approval <- if total > 100, do: request(order), else: {:ok, nil}`.
- **A boolean check doesn't stop the queue.** `<-` stores `false`. Write `ok <- if valid?(x), do: {:ok, true}, else: {:error, :invalid}`.
- **Don't execute a queue you return from a step.** Return the queue itself, so it runs as a child.
- **A block has a fixed set of steps.** For a step per item, or names like `{:reserve, sku}`, use the functional API: `Q.new/0`, then `Q.run/4` in `Enum.reduce/3`, then `Q.execute/1`.
- **Step names must be unique.** If per-item names can repeat, add the item's position: `{:reserve, index}`.
- **In `Q.run`, omitted params and `[:key]` both take a one-argument function.** Omitted passes the whole results map; `[:key]` passes that one result. `[]` passes nothing, for a zero-argument function.

## More

- README: overview and the full rules.
- `guides/recipes.md`: complete patterns with failure and cleanup paths.
- `Q` module docs: the contract for each function.
