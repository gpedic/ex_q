defmodule Q.DSLTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  # A plain import, to check that nothing in Q clashes with Kernel
  import Q

  @suffix "!"

  defmodule Pipelines do
    import Q

    defq decode(data) do
      decoded <- Base.decode64(data)
      upper = String.upcase(decoded)
    end

    defq constant do
      answer = 42
    end

    defq guarded(n) when is_integer(n) do
      doubled = n * 2
    end

    defpq secret(x) do
      hidden = x
    end

    def uses_private(x), do: execute(secret(x))

    defq nested(name) do
      inner <- secret(name)
    end
  end

  defp positive(n) when n > 0, do: {:ok, n}
  defp positive(_n), do: {:error, :not_positive}

  defp greeting(name) do
    queue bind: [name] do
      greeting = "hello " <> name
    end
  end

  defp named(queue) do
    queue bind: [queue] do
      name = queue
    end
    |> execute()
  end

  defp compile_error(code) do
    assert_raise CompileError, fn ->
      Code.eval_string("import Q, only: [queue: 1, queue: 2, defq: 2, defpq: 2]\n\n" <> code)
    end
  end

  # Compiles under a file name, with the import on line 1, so `queue do` is line 2
  defp malformed(code) do
    error =
      assert_raise CompileError, fn ->
        Code.eval_string("import Q, only: [queue: 1, queue: 2]\n" <> code, [],
          file: "malformed.exs"
        )
      end

    assert error.file =~ "malformed.exs"
    error
  end

  describe "steps" do
    test "a queue block builds a queue, which execute/1 runs" do
      q =
        queue do
          value = 1
        end

      assert [let: :value] = Q.__to_list__(q)
      assert {:ok, %{value: 1}} = execute(q)
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

    test "<- stores a plain value as is, = stores even a result whole" do
      result =
        queue do
          trimmed <- String.trim("  hi ")
          unwrapped <- {:ok, 1}
          whole = {:ok, 1}
        end
        |> execute()

      assert result == {:ok, %{trimmed: "hi", unwrapped: 1, whole: {:ok, 1}}}
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
        end
        |> execute()

      assert {:error, :decoded, :error, _state} = result
    end

    test "a step can halt the pipeline" do
      result =
        queue do
          count = 0
          checked <- if(count == 0, do: {:halt, :zero}, else: {:ok, count})
          never = raise "should not run"
        end
        |> execute()

      assert {:ok, %{count: 0, checked: :zero}} = result
    end

    test "steps compile to let and run" do
      q =
        queue do
          input = "aGVsbG8="
          decoded <- Base.decode64(input)
        end

      assert [let: :input, run: :decoded] = Q.__to_list__(q)
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
        end
        |> execute()

      assert {:ok, %{joined: "hello world"}} = result
    end

    test "outside variables come in through bind:" do
      punctuation = "!"

      result =
        queue bind: [punctuation] do
          text = "hi"
          shout = String.upcase(text) <> punctuation
        end
        |> execute()

      assert result == {:ok, %{punctuation: "!", text: "hi", shout: "HI!"}}
    end

    test "a step name shadowed in a nested fn keeps the inner meaning" do
      result =
        queue do
          n = 10
          doubled = Enum.map([1, 2], fn n -> n * 2 end)
        end
        |> execute()

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
        end
        |> execute()

      assert {:ok, %{label: "42"}} = result
    end
  end

  describe "_ bindings" do
    test "underscore-prefixed bindings store their results" do
      result =
        queue do
          a = 1
          _sent = send(self(), {:ran, a})
          _notified <- {:ok, :sent}
        end
        |> execute()

      assert result == {:ok, %{a: 1, _sent: {:ran, 1}, _notified: :sent}}
      assert_received {:ran, 1}
    end

    test "bare underscore bindings are compile errors" do
      for binding <- ["_ = 1", "_ <- {:ok, 1}"] do
        error = compile_error("queue do\n  #{binding}\nend")
        assert error.description == "every step must have a name; _ cannot name a step"
        assert error.line == 4
      end
    end

    test "underscore-prefixed names cannot repeat" do
      error = compile_error("queue do\n  _sent = 1\n  _sent <- {:ok, 2}\nend")
      assert error.description == "_sent is already a step in this queue"
    end

    test "a failure still names the step" do
      result =
        queue do
          _notified <- {:error, :offline}
        end
        |> execute()

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
          end
          |> execute()
        end)

      # One key per print, as the order of atom keys in a printed map isn't stable
      assert output == "%{a: 1}\n%{b: 2}\n"
    end

    test "a step returning a queue runs it as a child" do
      result =
        queue do
          name = "joe"
          greeting <- greeting(name)
        end
        |> execute()

      assert {:ok, %{name: "joe", greeting: %{greeting: "hello joe"}}} = result
    end

    test "a queue block nests inline and binds outer steps" do
      result =
        queue do
          name = "joe"

          greeting <-
            queue bind: [name] do
              text = "hello " <> name
              upper = String.upcase(text)
            end
        end
        |> execute()

      assert result ==
               {:ok,
                %{name: "joe", greeting: %{name: "joe", text: "hello joe", upper: "HELLO JOE"}}}
    end

    test "a child's halt lets the parent continue" do
      result =
        queue do
          cached <-
            queue do
              hit <- {:halt, :cached}
              never = raise("should not run")
            end

          after_child = :ran
        end
        |> execute()

      assert {:ok, %{cached: %{hit: :cached}, after_child: :ran}} = result
    end
  end

  describe "debug scope and evaluation" do
    test "a child prints its own state, the parent everything including the child" do
      output =
        capture_io(fn ->
          result =
            queue do
              parent = 1

              child <-
                queue do
                  a = 2
                  b = 3
                  debug()
                end

              debug()
            end
            |> execute()

          assert result == {:ok, %{parent: 1, child: %{a: 2, b: 3}}}
        end)

      [child_output, parent_output] = String.split(output, "\n", trim: true)
      assert {%{a: 2, b: 3}, []} = Code.eval_string(child_output)
      assert {%{parent: 1, child: %{a: 2, b: 3}}, []} = Code.eval_string(parent_output)
    end

    test "options can use earlier steps and bound values" do
      label = "selected"

      queue =
        queue bind: [label] do
          selected = :a
          a = 1
          debug(only: selected, label: label)
        end

      output =
        capture_io(fn ->
          assert execute(queue) == {:ok, %{label: "selected", selected: :a, a: 1}}
        end)

      assert output == "selected: %{a: 1}\n"
      assert Q.operations(queue) == [:label, :selected, :a]
      assert Q.__to_list__(queue) == [put: :label, let: :selected, let: :a, debug: nil]
    end

    test "options are evaluated once per execution, and never while building" do
      queue =
        queue do
          a = 1

          debug(
            (
              send(self(), :debug_options_evaluated)
              [only: :a]
            )
          )
        end

      refute_received :debug_options_evaluated

      for _execution <- 1..2 do
        assert capture_io(fn -> assert execute(queue) == {:ok, %{a: 1}} end) == "%{a: 1}\n"
        assert_received :debug_options_evaluated
        refute_received :debug_options_evaluated
      end
    end

    test "options are not evaluated after an earlier error or halt" do
      for {outcome, expected} <- [
            {{:error, :offline}, {:error, :stopped, :offline, %{outcome: {:error, :offline}}}},
            {{:halt, :done}, {:ok, %{outcome: {:halt, :done}, stopped: :done}}}
          ] do
        queue =
          queue bind: [outcome] do
            stopped <- outcome

            debug(
              (
                send(self(), :unreachable_debug_options)
                [only: :stopped]
              )
            )
          end

        assert capture_io(fn -> assert execute(queue) == expected end) == ""
        refute_received :unreachable_debug_options
      end
    end

    test "invalid deferred options are rejected only when reached" do
      for options <- [:invalid, %{}, [only: nil], [only: [:a, [:b]]]] do
        queue =
          queue bind: [options] do
            debug(options)
          end

        assert capture_io(fn ->
                 error = assert_raise ArgumentError, fn -> execute(queue) end
                 assert error.message =~ "debug"
               end) == ""
      end
    end
  end

  describe "conditionals" do
    test "a conditional in a step chooses its value, which later steps can use" do
      run = fn total ->
        queue bind: [total] do
          approval <- if total > 100, do: {:ok, :approved}, else: {:ok, nil}
          charged = {total, approval}
        end
        |> execute()
      end

      assert {:ok, %{approval: :approved, charged: {120, :approved}}} = run.(120)
      assert {:ok, %{approval: nil, charged: {50, nil}}} = run.(50)
    end

    test "a branch that fails or halts stops the queue" do
      run = fn outcome ->
        queue bind: [outcome] do
          checked <-
            case outcome do
              :error -> {:error, :rejected}
              :halt -> {:halt, :cached}
            end

          never = raise "should not run"
        end
        |> execute()
      end

      assert {:error, :checked, :rejected, %{outcome: :error}} = run.(:error)
      assert {:ok, %{outcome: :halt, checked: :cached}} = run.(:halt)
    end

    test "a branch that returns a queue runs it as a child" do
      run = fn total ->
        queue bind: [total] do
          approval <-
            if total > 100 do
              queue bind: [total] do
                requested = {:request, total}
                notified = {:notified, requested}
              end
            else
              {:ok, nil}
            end
        end
        |> execute()
      end

      assert {:ok, %{approval: %{requested: {:request, 120}, notified: _}}} = run.(120)
      assert {:ok, %{approval: nil}} = run.(50)
    end

    test "a conditional statement is a compile error pointing at the step form" do
      for {kind, code} <- [
            if: "if a > 0, do: b = 2",
            unless: "unless a > 0, do: b = 2",
            case: "case a do\n    1 -> b = 2\n  end",
            cond: "cond do\n    a > 0 -> b = 2\n  end"
          ] do
        error = malformed("queue do\n  a = 1\n  #{code}\nend")

        assert error.description ==
                 "#{kind} is not a queue statement; put it inside a step to choose the " <>
                   "step's value, such as `name <- #{kind} ...`"

        assert error.line == 4
      end
    end
  end

  describe "bind:" do
    test "binds outside values as the first steps" do
      order = %{id: 1}
      opts = [limit: 100]

      q =
        queue bind: [order, limit: opts[:limit]] do
          total = order.id * 50
          over = total > limit
        end

      assert Q.operations(q) == [:order, :limit, :total, :over]
      assert Q.__to_list__(q) == [put: :order, put: :limit, let: :total, let: :over]
      assert execute(q) == {:ok, %{order: %{id: 1}, limit: 100, total: 50, over: false}}
    end

    test "bound values are evaluated once, when the block is built" do
      q =
        queue bind: [stamp: send(self(), :bound)] do
          copy = stamp
        end

      assert_received :bound
      assert execute(q) == {:ok, %{stamp: :bound, copy: :bound}}
      assert execute(q) == {:ok, %{stamp: :bound, copy: :bound}}
      refute_received :bound
    end

    test "a bound name is a step name" do
      error = compile_error("a = 1\nqueue bind: [a, a] do\nend")
      assert error.description == "a is bound twice"

      error = compile_error("a = 1\nqueue bind: [a] do\n  a = 2\nend")
      assert error.description == "a is already a step in this queue"
    end

    test "entries must be variables or name: expr pairs" do
      error = compile_error("queue bind: [1] do\nend")
      assert error.description == "expected a variable or `name: expr` in bind:, got: 1"

      error = compile_error("queue bind: [_] do\nend")
      assert error.description == "every input must have a name; _ cannot be bound"

      error = compile_error("queue bind: :a do\nend")
      assert error.description =~ "expected bind: to be a list of variables or `name: expr` pairs"
    end

    test "other queue options are rejected" do
      error = compile_error("queue timeout: 1 do\nend")
      assert error.description == "unknown queue option :timeout; the only option is :bind"

      error = compile_error("a = 1\nqueue [a] do\nend")
      assert error.description =~ "bring outside values in with `queue bind: [...] do`"
    end
  end

  describe "scope" do
    # Compiles with usr and limit in scope, and returns the compiler's diagnostics
    defp undefined_in_block(code) do
      capture_io(:stderr, fn ->
        assert_raise CompileError, fn ->
          Code.eval_string("import Q, only: [queue: 1, queue: 2]\n" <> code, usr: 99, limit: 1)
        end
      end)
    end

    test "an outside variable in a step is a compile error, even when it exists" do
      assert undefined_in_block("queue do\n  user = 12\n  profile = {:profile, usr}\nend") =~
               ~s(undefined variable "usr")
    end

    test "an outside variable in a condition is a compile error" do
      assert undefined_in_block("queue do\n  total = 5\n  big = if total > limit, do: true\nend") =~
               ~s(undefined variable "limit")
    end

    test "an outside variable in debug options is a compile error" do
      assert undefined_in_block("queue do\n  a = 1\n  debug(only: :a, label: usr)\nend") =~
               ~s(undefined variable "usr")
    end

    test "a nested block sees only what it binds" do
      code = "queue do\n  name = 1\n  inner <- queue do\n    copy = name\n  end\nend"
      assert undefined_in_block(code) =~ ~s(undefined variable "name")
    end

    test "bindings local to an expression keep working" do
      result =
        queue do
          items = [1, 2, 3]
          doubled = for item <- items, do: item * 2
          summed = Enum.reduce(items, 0, fn item, acc -> item + acc end)

          kind =
            case items do
              [first | _] -> {:first, first}
              [] -> :empty
            end

          module = __MODULE__
          suffix = @suffix
        end
        |> execute()

      assert result ==
               {:ok,
                %{
                  items: [1, 2, 3],
                  doubled: [2, 4, 6],
                  summed: 6,
                  kind: {:first, 1},
                  module: __MODULE__,
                  suffix: "!"
                }}
    end
  end

  describe "defq and defpq" do
    test "the arguments are the queue's first steps, and the queue is returned unrun" do
      q = Pipelines.decode("aGVsbG8=")
      assert Q.__to_list__(q) == [put: :data, run: :decoded, let: :upper]
      assert execute(q) == {:ok, %{data: "aGVsbG8=", decoded: "hello", upper: "HELLO"}}
    end

    test "zero arguments and guards" do
      assert execute(Pipelines.constant()) == {:ok, %{answer: 42}}
      assert execute(Pipelines.guarded(2)) == {:ok, %{n: 2, doubled: 4}}
      # Called through apply/3, as the type checker rightly rejects a direct call
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      assert_raise FunctionClauseError, fn -> apply(Pipelines, :guarded, [:two]) end
    end

    test "defpq defines a private function" do
      refute function_exported?(Pipelines, :secret, 1)
      assert Pipelines.uses_private(1) == {:ok, %{x: 1, hidden: 1}}
    end

    test "a defq queue runs as a child step" do
      assert execute(Pipelines.nested("joe")) ==
               {:ok, %{name: "joe", inner: %{x: "joe", hidden: "joe"}}}
    end

    test "arguments must be plain variables, and the error says what to do instead" do
      for {arg, expected} <- [
            {"%{id: id}",
             "defq arguments must be plain variables, got: %{id: id}; each argument becomes " <>
               "a step named after its variable, so take the value apart in the steps that use it"},
            {"a \\\\ 1",
             "defq arguments must be plain variables, got: a \\\\ 1; for a default, define " <>
               "another function that calls this one with it"},
            {"_",
             "defq arguments must be named; _ cannot be an input, since each argument becomes " <>
               "a step named after its variable"}
          ] do
        error = compile_error("defmodule BadArgs do\n  defq f(#{arg}) do\n    b = 1\n  end\nend")
        assert error.description == expected
      end

      error = compile_error("defmodule BadHead do\n  defpq 1 do\n    b = 1\n  end\nend")

      assert error.description ==
               "expected a function head after defpq, got: 1; write `defpq name(arg) do ... end`"
    end

    test "a queue block inside a defq body points at writing the steps directly" do
      error =
        compile_error("""
        defmodule NestedBody do
          defq f(x) do
            queue bind: [x] do
              y = x
            end
          end
        end
        """)

      assert error.description =~ "a queue block is not a queue statement"
      assert error.description =~ "A defq body is already a queue block"
    end

    test "the body follows the queue block rules" do
      error =
        compile_error(
          "defmodule BadBody do\n  defq f(x) do\n    {:ok, y} <- {:ok, x}\n  end\nend"
        )

      assert error.description =~ "so write `y <- expr`"
    end
  end

  describe "compile errors" do
    test "a bare expression" do
      error = compile_error("queue do\n  a = 1\n  IO.puts(a)\nend")
      assert error.description =~ "expected a step such as `name = expr`"
      assert error.description =~ "every step must have a name"
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
      assert error.description =~ "a step is named by a single variable"
    end

    test "an {:ok, var} pattern on the left points at <-" do
      for op <- ["<-", "="] do
        error = compile_error("queue do\n  {:ok, user} #{op} {:ok, 1}\nend")

        assert error.description ==
                 "expected a variable on the left of #{op}, got: {:ok, user}; " <>
                   "<- unwraps {:ok, value} itself, so write `user <- expr`"

        assert error.line == 4
      end

      error = compile_error("queue do\n  {:ok, _} <- {:ok, 1}\nend")
      assert error.description =~ "so write `name <- expr`"
    end

    test "binding a name twice" do
      error = compile_error("queue do\n  a = 1\n  a = 2\nend")
      assert error.description =~ "a is already a step in this queue"
      assert error.line == 5
    end

    test "execute() or exec() as a statement, anywhere in the block" do
      for name <- [:execute, :exec], code <- ["#{name}()\n  a = 1", "a = 1\n  #{name}()"] do
        error = compile_error("queue do\n  #{code}\nend")

        assert error.description ==
                 "#{name}() is not a queue statement; a queue block builds a queue, " <>
                   "run it with `queue do ... end |> execute()`"
      end
    end

    test "calls shaped like the functional API point at bindings" do
      for call <- ["put(:a, 1)", "run(:a, &f/1, [:b])", "let(:a, &f/1)", "inspect()"] do
        error = compile_error("queue do\n  #{call}\nend")

        assert error.description =~
                 "is not a queue statement; in a queue block, steps are bindings"

        refute error.description =~ "2.0"
      end
    end

    test "Q function calls inside a block point at bindings" do
      error = compile_error("queue do\n  Q.run(Q.new(), :a, fn -> 1 end, [])\nend")

      assert error.description =~
               "Q.run/4 builds a queue outside a block, it isn't a queue statement; " <>
                 "in a queue block, steps are bindings"

      assert error.description =~ "build the queue with Q.new/0 and Q.run/4 instead of a block"
    end
  end
end
