defmodule QTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
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

  describe "names starting with _" do
    test "run but aren't stored, and can repeat" do
      result =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.run(
          :_,
          fn a ->
            send(self(), {:ran, a})
            {:ok, :sent}
          end,
          [:a]
        )
        |> Q.let(:_, fn -> :ignored end)
        |> Q.let(:_logged, fn -> :ignored end)
        |> Q.exec()

      assert {:ok, %{a: 1} = state} = result
      assert map_size(state) == 1
      assert_received {:ran, 1}
    end

    test "a failure still names the step" do
      result =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.run(:_notified, fn -> {:error, :offline} end)
        |> Q.exec()

      assert {:error, :_notified, :offline, %{a: 1}} = result
    end

    test "can't be used as params" do
      assert_raise ArgumentError, ~r/The parameter :_x does not exist/, fn ->
        Q.new()
        |> Q.let(:_x, fn -> 1 end)
        |> Q.let(:y, & &1, [:_x])
      end
    end
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
  end

  describe "merge/3" do
    defp checkout(total) do
      Q.new()
      |> Q.put(:total, total)
      |> Q.merge(
        fn total ->
          if total > 100 do
            Q.new() |> Q.put(:discount, 10)
          else
            Q.new() |> Q.put(:shipping, 5)
          end
        end,
        [:total]
      )
      |> Q.run(:done, fn -> {:ok, true} end)
      |> Q.exec()
    end

    test "adds steps chosen from earlier results" do
      assert {:ok, %{total: 120, discount: 10, done: true}} = checkout(120)
      assert {:ok, %{total: 50, shipping: 5, done: true}} = checkout(50)
    end

    test "the merge function can take the whole state or nothing" do
      result =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.merge(fn %{a: a} -> Q.new() |> Q.put(:b, a + 1) end)
        |> Q.merge(fn -> Q.new() |> Q.put(:c, 3) end)
        |> Q.exec()

      assert {:ok, %{a: 1, b: 2, c: 3}} = result
    end

    test "later steps can use merged results as params" do
      result =
        Q.new()
        |> Q.merge(fn -> Q.new() |> Q.put(:b, 2) end)
        |> Q.let(:c, &(&1 * 10), [:b])
        |> Q.exec()

      assert {:ok, %{b: 2, c: 20}} = result
    end

    test "a missing merged param raises when the queue runs" do
      q =
        Q.new()
        |> Q.merge(fn -> Q.new() end)
        |> Q.let(:c, &(&1 * 10), [:b])

      assert_raise RuntimeError, ~r/the parameter :b is not in the state/, fn -> Q.exec(q) end
    end

    test "an error in the merged queue stops the pipeline with both states" do
      result =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.merge(fn ->
          Q.new()
          |> Q.put(:inner, :ok)
          |> Q.run(:failing, fn -> {:error, :boom} end)
        end)
        |> Q.run(:never, fn -> {:ok, :should_not_run} end)
        |> Q.exec()

      assert {:error, :failing, :boom, %{a: 1, inner: :ok}} = result
    end

    test "a halt in the merged queue halts the whole pipeline" do
      result =
        Q.new()
        |> Q.merge(fn -> Q.new() |> Q.run(:stop, fn -> {:halt, :early} end) end)
        |> Q.run(:never, fn -> {:ok, :should_not_run} end)
        |> Q.exec()

      assert {:ok, %{stop: :early}} = result
    end

    test "merged queues can merge" do
      result =
        Q.new()
        |> Q.merge(fn ->
          Q.new()
          |> Q.put(:outer, 1)
          |> Q.merge(fn -> Q.new() |> Q.put(:inner, 2) end)
        end)
        |> Q.exec()

      assert {:ok, %{outer: 1, inner: 2}} = result
    end

    test "name conflicts with merged steps raise" do
      assert_raise ArgumentError, ~r/merged step :a conflicts/, fn ->
        Q.new()
        |> Q.put(:a, 1)
        |> Q.merge(fn -> Q.new() |> Q.put(:a, 2) end)
        |> Q.exec()
      end

      assert_raise ArgumentError, ~r/step :b conflicts with a merged step/, fn ->
        Q.new()
        |> Q.merge(fn -> Q.new() |> Q.put(:b, 1) end)
        |> Q.put(:b, 2)
        |> Q.exec()
      end
    end

    test "the merge function must return a queue" do
      assert_raise RuntimeError, ~r/expected the merge function to return a Q, got: :nope/, fn ->
        Q.new() |> Q.merge(fn -> :nope end) |> Q.exec()
      end
    end

    test "is listed by to_list/1" do
      q = Q.new() |> Q.merge(fn -> Q.new() end)
      assert [merge: nil] = Q.to_list(q)
      assert [] = Q.operations(q)
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

      # Not compared as a string, as the order of atom keys in a printed map isn't stable
      printed =
        capture_io(fn ->
          que
          |> Q.debug()
          |> Q.exec()
        end)

      assert {%{init: :test, init2: :test2}, []} = Code.eval_string(printed)

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
end
