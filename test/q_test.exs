defmodule QTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  import Q
  doctest Q

  defmodule TestWriter do
    def write(text, opts \\ [])

    def write(%{read: text}, opts) do
      upcase = Keyword.get(opts, :upcase, false)

      if upcase do
        {:ok, String.upcase(text)}
      else
        {:ok, text}
      end
    end

    def write(text, opts) do
      upcase = Keyword.get(opts, :upcase, false)

      if upcase do
        {:ok, String.upcase(text)}
      else
        {:ok, text}
      end
    end
  end

  defmodule DSLScoping do
    # A plain import, to check Q no longer clashes with Kernel.inspect/1
    import Q

    defp put(key, value), do: {key, value}

    def nested_calls do
      queue do
        put(:n, 42)
        run(:label, fn n -> {:ok, inspect(n)} end, [:n])
        run(:pair, fn n -> {:ok, put(:n, n)} end, [:n])
        exec()
      end
    end

    def debug_calls do
      queue do
        label = inspect(:x)
        put(:label, label)
        put(:other, 1)
        debug()
        debug(only: :label)
        exec()
      end
    end

    def caller_variable(queue) do
      queue do
        put(:queue_name, queue)
        exec()
      end
    end
  end

  describe "new/0" do
    test "creating the basic struct" do
      assert %Q{names: _, operations: []} = Q.new()
    end
  end

  describe "exec/1" do
    test "executing without queued tasks returns nil" do
      assert {:ok, %{}} = Q.new() |> Q.exec()
    end

    test "raises for unexpected returns" do
      q =
        Q.new()
        |> Q.run(:bad_return, fn _ -> {:bad, 1} end)

      assert_raise RuntimeError,
                   ~r/^expected operation `:bad_return` to return {:ok, value}, {:halt, value}, {:error, value} or :error, got: {:bad, 1}$/,
                   fn ->
                     Q.exec(q)
                   end
    end
  end

  describe "put/3" do
    test "put operations" do
      q =
        Q.new()
        |> Q.put(:init, :test)

      assert [{:put, :init}] = Q.to_list(q)
      assert {:ok, %{init: :test}} = Q.exec(q)
    end

    test "repeating an operation" do
      assert_raise ArgumentError, ~r":test is already a member", fn ->
        Q.new() |> Q.put(:test, :test) |> Q.put(:test, :fails)
      end
    end

    test "the duplicate name error does not leak stored values" do
      error =
        assert_raise ArgumentError, fn ->
          Q.new() |> Q.put(:password, "hunter2") |> Q.put(:password, "x")
        end

      refute error.message =~ "hunter2"
    end
  end

  describe "run/4" do
    test "an MFA without params receives the whole state" do
      result =
        Q.new()
        |> Q.put(:init, :test)
        |> Q.run(:read, fn _ -> {:ok, "hello world"} end)
        |> Q.run(:write, {TestWriter, :write, [[upcase: true]]})
        |> Q.exec()

      assert {:ok, %{init: :test, read: "hello world", write: "HELLO WORLD"}} = result
    end

    test "an arity-0 function without params is called with no arguments" do
      assert {:ok, %{answer: 42}} =
               Q.new()
               |> Q.run(:answer, fn -> {:ok, 42} end)
               |> Q.exec()
    end

    test "a function whose arity doesn't match its params raises when added" do
      assert_raise ArgumentError, ~r/expected a function of arity 1 for params \[:a\]/, fn ->
        Q.new() |> Q.put(:a, 1) |> Q.run(:b, fn -> {:ok, 2} end, [:a])
      end

      assert_raise ArgumentError, ~r/expected a function of arity 0, or 1/, fn ->
        Q.new() |> Q.run(:b, fn _, _ -> {:ok, 2} end)
      end
    end

    test "an MFA that doesn't exist raises when added" do
      assert_raise ArgumentError, ~r/String.nope\/1 is undefined or private/, fn ->
        Q.new() |> Q.put(:a, "x") |> Q.run(:b, {String, :nope}, [:a])
      end

      assert_raise ArgumentError, ~r/Kernel.<>\/2 is undefined or private/, fn ->
        Q.new() |> Q.put(:a, "x") |> Q.run(:b, {Kernel, :<>, ["y"]}, [:a])
      end
    end

    test "basic functionality" do
      result =
        Q.new()
        |> Q.run(:read, fn _ -> {:ok, "hello world"} end)
        |> Q.run(:write1, fn text -> TestWriter.write(text, upcase: true) end, [:read])
        |> Q.run(:write2, {TestWriter, :write, [[upcase: true]]}, {[:read], order: :prepend})
        |> Q.run(:write3, &TestWriter.write/1, [:read])
        |> Q.exec()

      assert {:ok,
              %{
                read: "hello world",
                write1: "HELLO WORLD",
                write2: "HELLO WORLD",
                write3: "hello world"
              }} = result
    end

    test "when using a 2 element tuple args default to []" do
      result =
        Q.new()
        |> Q.put(:init, "hello world")
        |> Q.run(:write, {TestWriter, :write}, [:init])
        |> Q.exec()

      assert {:ok,
              %{
                init: "hello world",
                write: "hello world"
              }} = result
    end

    test "the only the requested params are passed" do
      result =
        Q.new()
        |> Q.run(:read2, fn _ -> {:ok, "hello world"} end)
        |> Q.run(:write, fn text -> {:ok, text} end, [:read2])
        |> Q.run(:write2, {TestWriter, :write, [[upcase: true]]}, {[:read2], order: :prepend})
        |> Q.run(:write3, &TestWriter.write/1, [:read2])
        |> Q.exec()

      assert {:ok,
              %{
                read2: "hello world",
                write: "hello world",
                write2: "HELLO WORLD",
                write3: "hello world"
              }} = result
    end

    test "it should fail to run an operation with invalid params" do
      assert_raise ArgumentError, ~r"The parameter :foo does not exist in the queue.", fn ->
        Q.new()
        |> Q.run(:read, fn _ -> {:ok, "hello world"} end)
        |> Q.run(:write, fn _ -> {:error, :invalid_params} end, [:foo])
        |> Q.exec()
      end
    end

    test "anonymous functions accept {params, opts}" do
      result =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.run(:b, fn a -> {:ok, a * 2} end, {[:a], order: :append})
        |> Q.exec()

      assert {:ok, %{a: 1, b: 2}} = result
    end

    test "params that are not a list or {list, opts} raise" do
      q = Q.new() |> Q.put(:a, 1)

      # apply/3 keeps the type checker from flagging the deliberately invalid params
      assert_raise ArgumentError, ~r/expected params to be a list of names/, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Q, :run, [q, :b, {Map, :fetch, []}, :a])
      end
    end

    test "an invalid :order raises when the step is added" do
      assert_raise ArgumentError, ~r/expected the :order option to be :prepend or :append/, fn ->
        Q.new()
        |> Q.put(:a, 1)
        |> Q.run(:b, {Map, :fetch, []}, {[:a], order: :sideways})
      end
    end

    test "unknown params options raise when the step is added" do
      assert_raise ArgumentError, ~r/unknown params options \[:ordr\]/, fn ->
        Q.new()
        |> Q.put(:a, 1)
        |> Q.run(:b, {Map, :fetch, []}, {[:a], ordr: :append})
      end
    end
  end

  test "results are aggregated" do
    result =
      Q.new()
      |> Q.put(:init, :test)
      |> Q.run(:read, fn _ -> {:ok, :read} end)
      |> Q.run(:write, fn %{read: _read} -> {:ok, :write} end)
      |> Q.exec()

    assert {:ok, %{init: :test, read: :read, write: :write}} = result
  end

  test "handles error" do
    result =
      Q.new()
      |> Q.put(:init, :test)
      |> Q.run(:read, fn _ -> {:ok, :read} end)
      |> Q.run(:write, fn %{read: _read} -> {:error, :write_failed} end)
      |> Q.exec()

    assert {:error, :write, :write_failed, %{init: :test, read: :read}} = result
  end

  test "a bare :error return is a failure" do
    result =
      Q.new()
      |> Q.put(:input, "not base64")
      |> Q.run(:decoded, &Base.decode64/1, [:input])
      |> Q.run(:never, fn _ -> {:ok, :should_not_run} end)
      |> Q.exec()

    assert {:error, :decoded, :error, %{input: "not base64"}} = result
  end

  test "handles halt" do
    result =
      Q.new()
      |> Q.run(:read, fn _ -> {:halt, :done_early} end)
      |> Q.run(:write, fn %{read: _read} -> {:ok, :write_success} end)
      |> Q.exec()

    assert {:ok, %{read: :done_early} = output} = result
    refute Map.has_key?(output, :write)
  end

  describe "let/4" do
    test "stores the function's plain return value" do
      result =
        Q.new()
        |> Q.put(:text, "hello")
        |> Q.let(:upper, &String.upcase/1, [:text])
        |> Q.let(:twice, {String, :duplicate, [2]}, [:text])
        |> Q.let(:size, fn state -> map_size(state) end)
        |> Q.exec()

      assert {:ok, %{text: "hello", upper: "HELLO", twice: "hellohello", size: 3}} = result
    end

    test "a tuple return value is stored, not interpreted" do
      assert {:ok, %{pair: {:error, :not_a_failure}}} =
               Q.new()
               |> Q.let(:pair, fn -> {:error, :not_a_failure} end)
               |> Q.exec()
    end

    test "works in the DSL" do
      result =
        queue do
          put(:text, "hello")
          let(:upper, &String.upcase/1, [:text])
          let(:keys, fn state -> Map.keys(state) |> Enum.sort() end)
          exec()
        end

      assert {:ok, %{text: "hello", upper: "HELLO", keys: [:text, :upper]}} = result
    end
  end

  describe "to_list/1" do
    test "returns a list of operations" do
      que =
        Q.new()
        |> Q.put(:init, :test)
        |> Q.run(:read, fn _ -> {:ok, :read} end)
        |> Q.run(:write, fn %{read: _read} -> {:ok, :write} end)

      assert [put: :init, run: :read, run: :write] = Q.to_list(que)
    end
  end

  describe "debug/2" do
    test "printing stuff" do
      que =
        Q.new()
        |> Q.put(:init, :test)
        |> Q.put(:init2, :test2)

      assert capture_io(fn ->
               que
               |> Q.debug()
               |> Q.exec()
             end) == "%{init: :test, init2: :test2}\n"

      assert capture_io(fn ->
               que
               |> Q.debug(only: :init)
               |> Q.exec()
             end) == "%{init: :test}\n"
    end

    test "debug operations are not listed by operations/1" do
      q =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.debug()
        |> Q.put(:b, 2)
        |> Q.debug()

      assert [:a, :b] = Q.operations(q)
      assert [put: :a, debug: nil, put: :b, debug: nil] = Q.to_list(q)
    end
  end

  describe "negative cases" do
    test "duplicating an operation will raise and error" do
      fun = fn _ -> {:ok, :ok} end

      assert_raise ArgumentError, ~r":run is already a member", fn ->
        Q.new() |> Q.run(:run, fun) |> Q.run(:run, fun)
      end
    end

    test "returning invalid return value will raise and error" do
      assert_raise RuntimeError,
                   ~r/^expected operation `:bad_return` to return {:ok, value}, {:halt, value}, {:error, value} or :error, got: {:invalid, 1}$/,
                   fn ->
                     Q.new()
                     |> Q.run(:bad_return, fn _ -> {:invalid, 1} end)
                     |> Q.exec()
                   end

      assert_raise RuntimeError,
                   ~r"expected operation `:empty` to return {:ok, value}, {:halt, value}, {:error, value} or :error, got: nil",
                   fn ->
                     Q.new()
                     |> Q.run(:empty, fn _ -> nil end)
                     |> Q.exec()
                   end
    end

    test "passing an operation that is not a function or mfa tuple raises" do
      # apply/3 keeps the type checker from flagging the deliberately invalid function
      assert_raise ArgumentError, ~r/expected a function, {module, function}/, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Q, :run, [Q.new(), :nil_op, nil])
      end
    end
  end

  describe "DSL integration" do
    test "queue macro creates valid Q struct" do
      result =
        queue do
          put(:test, "value")
        end

      assert [put: :test] = Q.to_list(result)
    end

    test "DSL supports function references" do
      result =
        queue do
          put(:base64_text, "Zm9vYmFy")
          run(:decoded, &Base.decode64/1, [:base64_text])
        end
        |> Q.exec()

      assert {:ok, %{base64_text: "Zm9vYmFy", decoded: "foobar"}} = result
    end

    test "DSL supports anonymous functions with multiple params" do
      result =
        queue do
          put(:first, "hello")
          put(:second, "world")
          run(:join, fn a, b -> {:ok, "#{a} #{b}"} end, [:first, :second])
        end
        |> Q.exec()

      assert {:ok, %{first: "hello", second: "world", join: "hello world"}} = result
    end

    test "DSL handles errors properly" do
      result =
        queue do
          put(:input, -1)

          run(:validate, fn n -> if n > 0, do: {:ok, n}, else: {:error, :invalid_number} end, [
            :input
          ])
        end
        |> Q.exec()

      assert {:error, :validate, :invalid_number, %{input: -1}} = result
    end

    test "DSL supports halt operations" do
      result =
        queue do
          put(:count, 0)
          run(:check, fn n -> if n == 0, do: {:halt, :zero}, else: {:ok, :continue} end, [:count])
          run(:never, fn _ -> {:ok, :should_not_run} end)
          exec()
        end

      assert {:ok, %{count: 0, check: :zero}} = result
    end

    test "DSL works with MFA style calls" do
      result =
        queue do
          put(:base64_text, "aGVsbG8gd29ybGQ=")
          run(:decoded, {Base, :decode64, []}, [:base64_text])
          exec()
        end

      assert {:ok, %{base64_text: "aGVsbG8gd29ybGQ=", decoded: "hello world"}} = result
    end

    test "DSL passes MFA args after params" do
      defmodule Concat do
        def join(prefix, text), do: {:ok, "#{prefix} #{text}"}
      end

      result =
        queue do
          put(:text, "hello")
          run(:joined, {Concat, :join, ["world"]}, [:text])
          exec()
        end

      assert {:ok, %{text: "hello", joined: "hello world"}} = result
    end

    test "supports param ordering options for MFA calls" do
      defmodule OrderTest do
        def concat(first, second), do: {:ok, "#{first}#{second}"}
      end

      result =
        queue do
          put(:text, "!")
          run(:appended, {OrderTest, :concat, ["world"]}, {[:text], order: :append})
          run(:prepended, {OrderTest, :concat, ["world"]}, {[:text], order: :prepend})
          exec()
        end

      assert {:ok,
              %{
                text: "!",
                # mfa args first
                appended: "world!",
                # q params first (default)
                prepended: "!world"
              }} = result
    end

    test "only top-level statements are rewritten" do
      assert {:ok, %{n: 42, label: "42", pair: {:n, 42}}} = DSLScoping.nested_calls()
    end

    test "top-level debug is a DSL call, inspect/1 is Kernel.inspect/1" do
      output =
        capture_io(fn ->
          assert {:ok, %{label: ":x", other: 1}} = DSLScoping.debug_calls()
        end)

      assert output == "%{label: \":x\", other: 1}\n%{label: \":x\"}\n"
    end

    test "an empty block builds an empty queue" do
      empty =
        queue do
        end

      assert {:ok, %{}} = Q.exec(empty)
      assert {:ok, %{}} = queue(do: nil) |> Q.exec()
    end

    test "a caller variable named queue is not shadowed" do
      assert {:ok, %{queue_name: "emails"}} = DSLScoping.caller_variable("emails")
    end

    test "top-level expressions without DSL calls still run" do
      parent = self()
      notify? = Application.get_env(:ex_q, :notify_test, true)

      result =
        queue do
          put(:a, 1)
          if notify?, do: send(parent, :ran)
          exec()
        end

      assert {:ok, %{a: 1}} = result
      assert_received :ran
    end

    test "DSL calls nested in other expressions raise at compile time" do
      assert_raise ArgumentError, ~r"put/2 must be a top-level statement", fn ->
        Code.eval_string("""
        import Q, only: [queue: 1]

        queue do
          put(:a, 1)
          if true, do: put(:b, 2)
        end
        """)
      end
    end

    test "exec() must be the last statement" do
      assert_raise ArgumentError, ~r"exec\(\) must be the last statement", fn ->
        Code.eval_string("""
        import Q, only: [queue: 1]

        queue do
          exec()
          put(:a, 1)
        end
        """)
      end
    end

    test "a top-level inspect() points at the rename to debug()" do
      for call <- ["inspect()", "inspect(only: :a)"] do
        assert_raise ArgumentError, ~r"inspect was renamed to debug", fn ->
          Code.eval_string("""
          import Q, only: [queue: 1]

          queue do
            put(:a, 1)
            #{call}
          end
          """)
        end
      end
    end
  end
end
