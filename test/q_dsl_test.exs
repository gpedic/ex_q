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
      exec()
    end
  end

  defp compile_error(code) do
    assert_raise CompileError, fn ->
      Code.eval_string("import Q, only: [queue: 1]\n\n" <> code)
    end
  end

  describe "steps" do
    test "= stores a value, <- unwraps a result" do
      result =
        queue do
          input = "aGVsbG8="
          decoded <- Base.decode64(input)
          upper = String.upcase(decoded)
        end
        |> exec()

      assert {:ok, %{input: "aGVsbG8=", decoded: "hello", upper: "HELLO"}} = result
    end

    test "a failing step is named after its variable" do
      result =
        queue do
          input = -1
          validated <- positive(input)
          never = raise "should not run"
        end
        |> exec()

      assert {:error, :validated, :not_positive, %{input: -1}} = result
    end

    test "a bare :error fails the step" do
      result =
        queue do
          input = "not base64"
          decoded <- Base.decode64(input)
          exec()
        end

      assert {:error, :decoded, :error, _state} = result
    end

    test "a step can halt the pipeline" do
      result =
        queue do
          count = 0
          checked <- if(count == 0, do: {:halt, :zero}, else: {:ok, count})
          never = raise "should not run"
          exec()
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

      assert {:ok, %{}} = exec(empty)
    end
  end

  describe "inputs" do
    test "are the earlier steps an expression references" do
      result =
        queue do
          first = "hello"
          second = "world"
          joined = "#{first} #{second}"
          exec()
        end

      assert {:ok, %{joined: "hello world"}} = result
    end

    test "other variables are captured as usual" do
      punctuation = "!"

      result =
        queue do
          text = "hi"
          shout = String.upcase(text) <> punctuation
          exec()
        end

      assert {:ok, %{shout: "HI!"}} = result
    end

    test "a step name shadowed in a nested fn keeps the inner meaning" do
      result =
        queue do
          n = 10
          doubled = Enum.map([1, 2], fn n -> n * 2 end)
          exec()
        end

      assert {:ok, %{n: 10, doubled: [2, 4]}} = result
    end

    test "a module attribute isn't taken for a step of the same name" do
      q =
        queue do
          suffix = "?"
          text = "hi" <> @suffix
        end

      assert {:ok, %{text: "hi!"}} = exec(q)
    end

    test "a caller variable named queue is not the internal queue" do
      assert {:ok, %{name: "emails"}} = named("emails")
    end

    test "Kernel.inspect/1 works in steps" do
      result =
        queue do
          n = 42
          label = inspect(n)
          exec()
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
          exec()
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
          exec()
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
            b = 2
            debug()
            debug(only: :a)
            exec()
          end
        end)

      assert output == "%{a: 1, b: 2}\n%{a: 1}\n"
    end

    test "merge includes a queue built elsewhere" do
      result =
        queue do
          name = "joe"
          merge(greeting(name))
          exec()
        end

      assert {:ok, %{name: "joe", greeting: "hello joe"}} = result
    end
  end

  describe "compile errors" do
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

    test "a pattern on the left" do
      error = compile_error("queue do\n  {a, b} = {1, 2}\nend")
      assert error.description =~ "expected a variable on the left of =, got: {a, b}"
    end

    test "binding a name twice" do
      error = compile_error("queue do\n  a = 1\n  a = 2\nend")
      assert error.description =~ "a is already a step in this queue"
      assert error.line == 5
    end

    test "exec() before the last statement" do
      error = compile_error("queue do\n  exec()\n  a = 1\nend")
      assert error.description =~ "exec() must be the last statement"
    end

    test "1.x style calls point at the new syntax" do
      for call <- ["put(:a, 1)", "run(:a, &f/1, [:b])", "let(:a, &f/1)", "inspect()"] do
        error = compile_error("queue do\n  #{call}\nend")
        assert error.description =~ "is not a queue statement since Q 2.0"
      end
    end
  end
end
