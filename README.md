![Build Status](https://github.com/gpedic/ex_q/actions/workflows/ci.yml/badge.svg?branch=master)
[![Coverage Status](https://coveralls.io/repos/github/gpedic/ex_q/badge.svg?branch=master)](https://coveralls.io/github/gpedic/ex_q?branch=master)
[![License](https://img.shields.io/hexpm/l/ex_q.svg)](https://github.com/gpedic/ex_q/blob/master/LICENSE.md)
[![Last Updated](https://img.shields.io/github/last-commit/gpedic/ex_q.svg)](https://github.com/gpedic/ex_q/commits/master)


# ExQ

ExQ provides a powerful way to queue and execute operations while aggregating all returned values, similar to `Ecto.Multi`.
Operations are executed in a first-in-first-out (FIFO) order.

Functions can specify the keys they require from the queue's accumulated data via the `params` argument in the `run` function. By specifying params that way the called function does not have to be aware of the aggregate data structure.

In the following example, the write step will receive only the location since it is requested as param.
Params will be provided in the order they are specified.

On the other hand in the fail step, we can match the aggregate data since no params are specified.

```elixir
    iex> pipeline = Q.new()
    |> Q.put(:location, "Space")
    |> Q.run(:write, fn location -> {:ok, "#{location} the final frontier."} end, [:location])

    iex> pipeline |> Q.exec()

    {:ok, %{location: "Space", write: "Space the final frontier."}}

    iex> pipeline 
    |> Q.run(:fail, fn %{write: _write} -> {:error, :been_there_before} end)
    |> Q.exec()

    {:error, :write, :been_there_before, %{location: "Space", write: "Space the final frontier"}}

```

## Why use Q?

One of the major benefits of using ExQ is that it provides access to the results of all steps before an error occurs, making it easy to identify the step that produced the error.

Consider the following two code snippets which use the Blog module to do some work:
```elixir
  defmodule Blog do
    def fetch_user(user_id) do
      {:ok, %User{id: user_id, name: "John Doe"}}
    end

    def create_post(user, content, opts \\ []) do
      upcase = Keyword.get(opts, :upcase, false)

      if upcase do
        insert_post(user, String.upcase(content))
      else
        insert_post(user, content)
      end
    end

    def count_posts(user) do
      {:ok, get_post_count(user)}
    end
  end

```

### Without ExQ
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

### With ExQ

```elixir
  ex_que = Q.new()
  |> Q.put(:content, "hello world")
  |> Q.run(:user, fn %{user_id: id} -> Blog.fetch_user(id) end)
  |> Q.run(:post, Blog, :create_post, [[upcase: true]], [:user, :content])
  |> Q.run(:post_count, &Blog.count_posts/1, [:user])

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

## Using params in Functions

The run function has an optional params argument, which is a list of keys. When provided, the function only receives the values associated with these keys as arguments. If params are not provided, the function receives the entire accumulated data. The keys in params must exist before being used.

The params are provided to the function in order, and any additional arguments are passed after the params.

```elixir
    defmodule Test do
      def print(val, opts \\ []) do
        upcase? = Keyword.get(opts, :upcase, false)
        if upcase? do
          String.upcase(val)
        else
          val
        end
        |> IO.inspect()
      end
    end

    iex> pipeline = Q.new()
    |> Q.put(:init, %{start: "To boldly go"})
    |> Q.run(:go, fn %{start: val} -> {:ok, "#{val} where no man has gone before"} end, [:init])
    |> Q.run(:print, {Test, :write, [upcase: true]}, [:go])
    |> Q.exec()

    {:ok, %{init: %{start: "To boldly go"}, read: "To boldly go where no man has gone before", print: "TO BOLDLY GO WHERE NO MAN HAS GONE BEFORE"}}
```

## Halting execution early
Return `{:halt, value}` to halt execution at any point.
Halting is not considered an error and will return an `:ok` tuple will all values computed before halting.

```elixir
  iex> Q.new()
  |> Q.put(:user_id, "f68b7f42-d343-48e4-8f76-c434fab0ba1a")
  |> Q.run(:user, &Blog.fetch_user/1, [:user_id])
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

  {:ok, %{user_id: "...", user: %User{}}}
```

## DSL Usage

ExQ provides a DSL for creating queues in a more declarative way. To use it, simply import Q and use the `queue` macro:

```elixir
import Q

decode_q = queue do
  put(:base64_text, "aGVsbG8=")
  run(:decoded, &Base.decode64/1, [:base64_text])
  run(:decoded_mfa, {Base, :decoded64, []}, [:base64_text])
end

Q.exec(decode_q)

# Returns:
{:ok, %{base64_text: "aGVsbG8=", decoded: "hello", decoded_mfa: "hello"}}
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
