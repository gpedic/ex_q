defmodule Q.DSLTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  # A plain import, to check that nothing in Q clashes with Kernel
  import Q

  @suffix "!"

  defp positive(n) when n > 0, do: {:ok, n}
  defp positive(_n), do: {:error, :not_positive}

  defp greeting(name) do
    queue do
      greeting = "hello " <> name
    end
  end

  defp named(queue) do
    queue do
      name = queue
      execute()
    end
  end

  defp compile_error(code) do
    assert_raise CompileError, fn ->
      Code.eval_string("import Q, only: [queue: 1]\n\n" <> code)
    end
  end

  describe "steps" do
    test "terminal exec() still executes and warns at its source line" do
      warning =
        capture_io(:stderr, fn ->
          assert {{:ok, %{value: 1}}, _bindings} =
                   Code.eval_string(
                     "import Q, only: [queue: 1]\nqueue do\n  value = 1\n  exec()\nend",
                     [],
                     file: "deprecated_queue.exs"
                   )
        end)

      assert warning =~ "exec() is deprecated; use execute() instead"
      assert warning =~ "deprecated_queue.exs:4"
    end

    test "= stores a value, <- unwraps a result" do
      result =
        queue do
          input = "aGVsbG8="
          decoded <- Base.decode64(input)
          upper = String.upcase(decoded)
        end
        |> execute()

      assert {:ok, %{input: "aGVsbG8=", decoded: "hello", upper: "HELLO"}} = result
    end

    test "a failing step is named after its variable" do
      result =
        queue do
          input = -1
          validated <- positive(input)
          never = raise "should not run"
        end
        |> execute()

      assert {:error, :validated, :not_positive, %{input: -1}} = result
    end

    test "a bare :error fails the step" do
      result =
        queue do
          input = "not base64"
          decoded <- Base.decode64(input)
          execute()
        end

      assert {:error, :decoded, :error, _state} = result
    end

    test "a step can halt the pipeline" do
      result =
        queue do
          count = 0
          checked <- if(count == 0, do: {:halt, :zero}, else: {:ok, count})
          never = raise "should not run"
          execute()
        end

      assert {:ok, %{count: 0, checked: :zero}} = result
    end

    test "steps compile to let and run" do
      q =
        queue do
          input = "aGVsbG8="
          decoded <- Base.decode64(input)
        end

      assert [let: :input, run: :decoded] = Q.to_list(q)
    end

    test "an empty block builds an empty queue" do
      empty =
        queue do
        end

      assert {:ok, %{}} = execute(empty)
    end
  end

  describe "inputs" do
    test "are the earlier steps an expression references" do
      result =
        queue do
          first = "hello"
          second = "world"
          joined = "#{first} #{second}"
          execute()
        end

      assert {:ok, %{joined: "hello world"}} = result
    end

    test "other variables are captured as usual" do
      punctuation = "!"

      result =
        queue do
          text = "hi"
          shout = String.upcase(text) <> punctuation
          execute()
        end

      assert {:ok, %{shout: "HI!"}} = result
    end

    test "a step name shadowed in a nested fn keeps the inner meaning" do
      result =
        queue do
          n = 10
          doubled = Enum.map([1, 2], fn n -> n * 2 end)
          execute()
        end

      assert {:ok, %{n: 10, doubled: [2, 4]}} = result
    end

    test "a module attribute isn't taken for a step of the same name" do
      q =
        queue do
          suffix = "?"
          text = "hi" <> @suffix
        end

      assert {:ok, %{text: "hi!"}} = execute(q)
    end

    test "a caller variable named queue is not the internal queue" do
      assert {:ok, %{name: "emails"}} = named("emails")
    end

    test "Kernel.inspect/1 works in steps" do
      result =
        queue do
          n = 42
          label = inspect(n)
          execute()
        end

      assert {:ok, %{label: "42"}} = result
    end
  end

  describe "_ bindings" do
    test "run without being stored, and can repeat" do
      result =
        queue do
          a = 1
          _ = send(self(), {:ran, a})
          _ = send(self(), :again)
          _sent <- {:ok, :sent}
          execute()
        end

      assert {:ok, %{a: 1} = state} = result
      assert map_size(state) == 1
      assert_received {:ran, 1}
      assert_received :again
    end

    test "a failure still names the step" do
      result =
        queue do
          _notified <- {:error, :offline}
          execute()
        end

      assert {:error, :_notified, :offline, %{}} = result
    end
  end

  describe "statements" do
    test "debug prints the state" do
      output =
        capture_io(fn ->
          queue do
            a = 1
            debug()
            b = 2
            debug(only: :b)
            execute()
          end
        end)

      # One key per print, as the order of atom keys in a printed map isn't stable
      assert output == "%{a: 1}\n%{b: 2}\n"
    end

    test "a step returning a queue runs it as a child" do
      result =
        queue do
          name = "joe"
          greeting <- greeting(name)
          execute()
        end

      assert {:ok, %{name: "joe", greeting: %{greeting: "hello joe"}}} = result
    end

    test "a queue block nests inline and can use outer steps" do
      result =
        queue do
          name = "joe"

          greeting <-
            queue do
              text = "hello " <> name
              upper = String.upcase(text)
            end

          execute()
        end

      assert {:ok, %{name: "joe", greeting: %{text: "hello joe", upper: "HELLO JOE"}}} = result
    end

    test "a child halt with propagate: false lets the parent continue" do
      result =
        queue do
          cached <-
            queue do
              hit <- {:halt, :cached, propagate: false}
              never = raise("should not run")
            end

          after_child = :ran
          execute()
        end

      assert {:ok, %{cached: %{hit: :cached}, after_child: :ran}} = result
    end

    test "a local halt inside a branch stops the child, not just the branch" do
      result =
        queue do
          cached <-
            queue do
              enabled = true

              if enabled do
                hit <- {:halt, :cached, propagate: false}
                never_in_branch = raise("branch must stop")
              end

              never_in_child = raise("child must stop")
            end

          after_child = :ran
          execute()
        end

      assert result == {:ok, %{cached: %{enabled: true, hit: :cached}, after_child: :ran}}
    end
  end

  describe "branching" do
    defp checkout(total) do
      queue do
        amount = total

        if amount > 100 do
          discount = div(amount, 10)
          final = amount - discount
        else
          shipping = 5
        end

        execute()
      end
    end

    test "if/else picks the steps from a result" do
      assert {:ok, %{amount: 120, discount: 12, final: 108} = state} = checkout(120)
      refute Map.has_key?(state, :shipping)
      assert {:ok, %{amount: 50, shipping: 5}} = checkout(50)
    end

    test "if without else, and unless" do
      run = fn flag ->
        queue do
          on = flag
          if on, do: yes = true
          unless on, do: no = true
          execute()
        end
      end

      assert {:ok, %{on: true, yes: true} = state} = run.(true)
      refute Map.has_key?(state, :no)
      assert {:ok, %{on: false, no: true}} = run.(false)
    end

    test "case binds pattern variables for its branch" do
      run = fn input ->
        queue do
          result = input

          case result do
            {:ok, n} -> doubled = n * 2
            {:error, reason} -> failed = reason
          end

          execute()
        end
      end

      assert {:ok, %{doubled: 10}} = run.({:ok, 5})
      assert {:ok, %{failed: :nope}} = run.({:error, :nope})
    end

    test "cond and nested conditionals" do
      run = fn n ->
        queue do
          number = n

          cond do
            number < 0 ->
              sign = :negative

            number < 10 ->
              sign = :small
              if number == 0, do: zero = true

            true ->
              sign = :large
          end

          execute()
        end
      end

      assert {:ok, %{sign: :negative}} = run.(-1)
      assert {:ok, %{sign: :small, zero: true}} = run.(0)
      assert {:ok, %{sign: :large}} = run.(10)
      assert {:ok, %{sign: :small} = state} = run.(1)
      refute Map.has_key?(state, :zero)
    end

    test "a failing branch step names the step and keeps both states" do
      result =
        queue do
          total = 120

          if total > 100 do
            request = {:approval, total}
            approved <- {:error, :rejected}
          end

          charged <- raise("should not run")
          execute()
        end

      assert {:error, :approved, :rejected, %{total: 120, request: {:approval, 120}}} = result
    end

    test "a halt in a branch halts the pipeline" do
      result =
        queue do
          cached = true
          if cached, do: hit <- {:halt, :cached}
          computed <- raise("should not run")
          execute()
        end

      assert {:ok, %{cached: true, hit: :cached}} = result
    end

    test "compiles to a branch" do
      q =
        queue do
          a = 1
          if a > 0, do: b = 2
        end

      assert [let: :a, branch: nil] = Q.to_list(q)
    end
  end

  describe "compile errors" do
    test "a branch step isn't a variable after the conditional" do
      diagnostics =
        capture_io(:stderr, fn ->
          compile_error("""
          queue do
            a = 1
            if a > 0, do: b = 2
            c = b
          end
          """)
        end)

      assert diagnostics =~ ~s(undefined variable "b")
    end

    test "a branch rebinding an outer step" do
      error = compile_error("queue do\n  a = 1\n  if a > 0, do: a = 2\nend")
      assert error.description =~ "a is already a step in this queue"
    end

    test "rebinding a step bound in a branch" do
      error = compile_error("queue do\n  a = 1\n  if a > 0, do: b = 2\n  b = 3\nend")
      assert error.description =~ "b is already a step in this queue"
    end

    test "execute() inside a branch" do
      for name <- [:execute, :exec] do
        error = compile_error("queue do\n  a = 1\n  if a > 0, do: #{name}()\nend")
        assert error.description =~ "#{name}() can't be used inside a branch"
      end
    end

    test "a bare expression" do
      error = compile_error("queue do\n  a = 1\n  IO.puts(a)\nend")
      assert error.description =~ "expected a step such as `name = expr`"
      assert error.description =~ "use `_ = expr`"
      assert error.line == 5
    end

    test "a bare literal" do
      error = compile_error("queue do\n  a = 1\n  :ok\nend")

      assert error.description =~
               "expected a step such as `name = expr` or `name <- expr`, got: :ok"
    end

    test "merge(queue) is no longer a statement" do
      error = compile_error("queue do\n  merge(Q.new())\nend")
      assert error.description =~ "merge(queue) is not a statement"
      assert error.description =~ "name <- queue"
    end

    test "a pattern on the left" do
      error = compile_error("queue do\n  {a, b} = {1, 2}\nend")
      assert error.description =~ "expected a variable on the left of =, got: {a, b}"
    end

    test "binding a name twice" do
      error = compile_error("queue do\n  a = 1\n  a = 2\nend")
      assert error.description =~ "a is already a step in this queue"
      assert error.line == 5
    end

    test "execute() before the last statement" do
      for name <- [:execute, :exec] do
        error = compile_error("queue do\n  #{name}()\n  a = 1\nend")
        assert error.description =~ "#{name}() must be the last statement"
      end
    end

    test "1.x style calls point at the new syntax" do
      for call <- ["put(:a, 1)", "run(:a, &f/1, [:b])", "let(:a, &f/1)", "inspect()"] do
        error = compile_error("queue do\n  #{call}\nend")
        assert error.description =~ "is not a queue statement since Q 2.0"
      end
    end
  end
end
