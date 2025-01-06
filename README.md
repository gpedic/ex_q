![Build Status](https://github.com/gpedic/ex_q/actions/workflows/ci.yml/badge.svg?branch=master)
[![Coverage Status](https://coveralls.io/repos/github/gpedic/ex_q/badge.svg?branch=master)](https://coveralls.io/github/gpedic/ex_q?branch=master)
[![License](https://img.shields.io/hexpm/l/ex_q.svg)](https://github.com/gpedic/ex_q/blob/master/LICENSE.md)
[![Last Updated](https://img.shields.io/github/last-commit/gpedic/ex_q.svg)](https://github.com/gpedic/ex_q/commits/master)

# Q

Q is a tool for building and executing pipelines of operations, influenced by Ecto.Multi. It preserves all intermediate results so that you retain clarity and visibility into your data transformations at each step. When a pipeline fails, you can see precisely which step broke and what the state looked like at that point.

## Why Q?

Q simplifies building pipelines in three key ways:

* **Never lose context**: Q like Ecto.Multi will always return all executed steps results. When a step breaks, Q returns all prior step results along with the failing step’s error.

* **Control passed parameters**: Steps can operate on the entire pipeline state or on specific labels only. This reduces the need to rewrite functions to suite the pipeline or having to introduce anonyomous functions just to be able to pick the parameters.

* **Flexible Composition**: Q queues can be composed just like normal Elixir functions. Smaller pipelines can be combined to form larger ones.


## Example

A pipeline (or “queue”) is a collection of labeled steps that transform data. Each step can take the entire pipeline state or selected portions of it. 
Results are always labeled and retained:

```elixir
defmodule UploadProcessor do
  import Q

  def process_upload(file_data) do
    queue do
      put(:file_data, file_data)
      run(:parsed, &DataProcessor.parse_csv/1, [:file_data])
      run(:validated, fn %{parsed: rows} ->
        Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
          case DataProcessor.validate_row(row) do
            {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
      end)
      run(:enriched, {DataProcessor, :enrich_data, [[use_ai: true]]}, [:validated])
    end
    |> exec()
  end
end
```

## Error handling

One of the major benefits of using Q is that it provides a complete context even in case of errors - you know not only which step failed but have access to all results leading up to the error.

```elixir
def process_data(data) do
  queue do
    put(:raw_data, data)
    run(:decoded, &Jason.decode/1, [:raw_data])
    run(:validated, &validate_schema/1, [:decoded])
    run(:normalized, &normalize_data/1, [:validated])
    run(:enriched, &add_metadata/1, [:normalized])
    exec()
  end
end

# If JSON parsing fails
{:error, :decoded, %Jason.DecodeError{data: "invalid", position: 0, token: nil}, %{raw_data: "invalid"}}

# If validation fails, notice both previous processing steps results are available
{:error, :validated, :invalid_schema, %{
  raw_data: "{\"foo\": 123}",
  decoded: %{"foo" => 123}
}}

```

### Without Q
```elixir
def process_data_without_q(data) do
  with {:ok, decoded} <- Jason.decode(data),
    {:ok, validated} <- validate_data(data),
    {:ok, transformed} <- normalize_data(validated),
    {:ok, enriched} <- add_metadata(transformed) do
    {:ok, enriched}
  else
    {:error, reason} -> 
      # We know the failure reason, but not the state when it failed
      # as the data from of processing steps is not available here
      {:error, reason}
  end
end
```

## Parameter Passing

Every step function will receive the entire pipeline state by default, or you can list which keys you want to pass as function arguments.

```elixir
defmodule ParamDemo do
  import Q

  def run_stuff(data) do
    queue do
      # Store some data for subsequent steps
      put(:some_data, data)

      # Pass a single argument from the state
      run(:single_arg, &MyModule.process_single/1, [:some_data])

      # Pass the complete state
      run(:custom_extract, fn %{single_arg: val} ->
        MyModule.do_something(val)
      end)

      # Pass a multiple arguments from the state
      run(:multi_arg, &MyModule.process_multiple/1, [:custom_extract, :some_data])

      # The mfa version allows us to pass additional params directly
      # by default args will be prepended i.e.
      # MyModule.delete(single_arg, some_data, soft_delete: true)
      run(:prepend_args, {MyModule, :delete, [[soft_delete: true]]}, [:single_arg, :some_data])

      # To append the arguments instead we can define the order
      # MyModule.changeset(%MyStruct{}, single_arg, some_data)
      run(:appended_args, {MyModule, :changeset, [%MyStruct{}]}, {[:single_arg, :some_data], order: :append})
    end
    |> exec()
  end
end
```

## Halting Execution Early

Sometimes you don’t need the remaining steps once a certain condition is met. Q allows functions to return `{:halt, value}` to end the pipeline successfully:

```elixir
    defmodule ExpensiveProcessor do
      import Q

      def process_data(input) do
        queue do
          put(:input, input)
          
          # Check cache first
          run(:cache_check, fn %{key: key} ->
            cached = get_from_cache(key)
            if not is_nil(cached) do
              {:halt, cached}  # Skip expensive operation if cached
            else
              {:ok, :not_found}
            end
          end)

          # Only runs if not in cache
          run(:processed, &expensive_operation/1, [:input])
          run(:cache, &cache_processed_data/1, [:processed])

          exec()
        end
      end

  # halt early on cache hit
  {:ok, %{
        input: %{key: "BWBeN28Vb7cMEx7Ym8AUzs", data: %{...}},
        cache_check: %{data: %{...}}
      }

  # run full pipeline when not cached
    {:ok, %{
        input: %{key: "BWBeN28Vb7cMEx7Ym8AUzs", data: %{...}},
        cache_check: :not_found
        processed: %{data: %{...}}
        cache: :ok
      }
```

## API

Q provides two styles, the DSL and a more functional chaining API.
Here are both approaches side by side.

### DSL
```elixir
import Q

decode_q = queue do
  put(:base64_text, "aGVsbG8=")
  run(:decoded, &Base.decode64/1, [:base64_text])
  run(:decoded_mfa, {Base, :decoded64, []}, [:base64_text])
end

exec(decode_q)

# Returns:
{:ok, %{base64_text: "aGVsbG8=", decoded: "hello", decoded_mfa: "hello"}}
```

### Functional
```elixir
decode_q = Q.new()
  |> Q.put(:base64_text, "aGVsbG8=")
  |> Q.run(:decoded, &Base.decode64/1, [:base64_text])
  |> Q.run(:decoded_mfa, {Base, :decoded64, []}, [:base64_text])


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
    {:ex_q, "~> 1.1"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/ex_q](https://hexdocs.pm/ex_q).
