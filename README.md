[![Coverage Status](https://coveralls.io/repos/github/gpedic/ex_q/badge.svg?branch=master)](https://coveralls.io/github/gpedic/ex_q?branch=master)

# ExQ

ExQ provides a way of queuing the execution of operations and aggregates all returned values similar to `Ecto.Multi`.
Operations are queued and executed in FIFO order.

```elixir
    iex> pipeline = Q.new()
    |> Q.put(:init, %{test: "setup"})
    |> Q.run(:read, fn _ -> {:ok, "Once upon a time ..."} end)

    iex> pipeline |> Q.exec()

    {:ok, %{init: %{test: "setup"}, read: "Once upon a time ..."}}


    iex> pipeline 
    |> Q.run(:write, fn %{read: _read} -> {:error, :write_failed} end)
    |> Q.exec()

    {:error, :write, :write_failed, %{init: %{test: "setup"}, read: "Once upon a time ..."}}
```

## Comparison to `with`

A major benefit of using ExQ over `with` is that the results of all steps before an error are available and the step which produced the error is also easily identifiable.

```elixir
  user_id = 1234
  with {:ok, user} <- Blog.fetch_user(user_id),
    {:ok, post} <- Blog.create_post(user, "test") do
    broadcast(post)
  else
    {:error, :create_post_failed} = error ->
      Logger.error("Failed to create post for user #{user_id}")
      error
    {:error, error} = error ->
      Logger.error(error)
      error
  end
```
### Note
* When `with` is used on its own the return of the `user` step is not available for error handling if create_post fails
* To match a specific error in `else` requires workarounds e.g. `create_post/2` returning a special error tuple


```elixir
  defmodule Blog do
    def create_post(%{user: user, content: content}, opts) do
      upcase = Keyword.get(opts, :upcase, false)

      if upcase do
        insert_post(user, String.upcase(content))
      else
        insert_post(user, content)
      end
    end

    def count_posts(%{user: user}) do
      {:ok, get_post_count(user)}
    end
  end

  ex_que = Q.new()
  |> Q.put(:content, "hello world")
  |> Q.run(:user, fn %{user_id: id} -> Blog.fetch_user(id) end)
  |> Q.run(:post, Blog, :create_post, [[upcase: true]])
  |> Q.run(:post_count, &Blog.count_posts/1)

  with {:ok, %{post: post}} <- Q.exec(ex_que) do
    broadcast(post)
  else
    {:error, :post, failed_value, %{user: user}} ->
      Logger.error("Failed to create post for user #{user.id}")
      {:error, failed_value}
    {:error, failed_operation, failed_value, _changes_so_far} ->
      Logger.error("Operation #{failed_operation} failed, #{inspect(failed_value)}")
      {:error, failed_value}
  end
```
### Note
* With ExQ the `user` result is available for error handling if `create_post` fails
* We can also handle errors for specific steps while `create_post/2` can return a standard error tuple like `{:error, "msg"}`

## Ending execution early
Return `{:halt, value}` to end execution early

```elixir
  iex> Q.new()
  |> Q.put(:user_id, 1235)
  |> Q.run(:user, &Blog.fetch_user/1 end)
  |> Q.run(:earned_daily_award, fn %{user: user} ->
      count = Blog.count_posts_today(user)
      if count < 1 do
        {:halt, false}
      else
        {:ok, true}
      end
  end)
  |> Q.run(:send_daily_award, Blog, :send_daily_award, [])
  |> Q.exec()
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ex_q` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_q, "~> 1.0"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/ex_q](https://hexdocs.pm/ex_q).
