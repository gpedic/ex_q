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
                   ~r/^expected operation `:bad_return` to return {:ok, value}, {:halt, value}, {:halt, value, propagate: boolean}, {:error, value}, :error or a queue, got: {:bad, 1}$/,
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

  describe "child queues" do
    defp billing(user) do
      Q.new()
      |> Q.put(:validated, user)
      |> Q.let(:invoice, fn -> {:invoice, user.id} end)
    end

    defp shipping(user) do
      Q.new()
      |> Q.put(:validated, user)
      |> Q.let(:tracking, fn -> {:tracking, user.id} end)
    end

    test "a step returning a queue runs it and stores its results under the step's name" do
      result =
        Q.new()
        |> Q.put(:user, %{id: 7})
        |> Q.run(:billing, &billing/1, [:user])
        |> Q.run(:shipping, &shipping/1, [:user])
        |> Q.let(:confirmation, fn b, s -> {b.invoice, s.tracking} end, [:billing, :shipping])
        |> Q.exec()

      assert result ==
               {:ok,
                %{
                  user: %{id: 7},
                  billing: %{validated: %{id: 7}, invoice: {:invoice, 7}},
                  shipping: %{validated: %{id: 7}, tracking: {:tracking, 7}},
                  confirmation: {{:invoice, 7}, {:tracking, 7}}
                }}
    end

    test "an empty child stores an empty map" do
      assert Q.new() |> Q.run(:child, fn -> Q.new() end) |> Q.exec() == {:ok, %{child: %{}}}
    end

    test "{:ok, queue} and let store a queue without running it" do
      assert {:ok, %{a: a, b: b}} =
               Q.new()
               |> Q.run(:a, fn -> {:ok, billing(%{id: 1})} end)
               |> Q.let(:b, fn -> billing(%{id: 1}) end)
               |> Q.exec()

      assert [put: :validated, let: :invoice] = Q.to_list(a)
      assert [put: :validated, let: :invoice] = Q.to_list(b)
    end

    test "a failing child step fails the parent step with the child's error tuple" do
      result =
        Q.new()
        |> Q.put(:user, %{id: 7})
        |> Q.run(:billing, fn ->
          Q.new()
          |> Q.put(:validated, true)
          |> Q.run(:charge, fn -> {:error, :declined} end)
        end)
        |> Q.run(:never, fn -> {:ok, :should_not_run} end)
        |> Q.exec()

      assert result ==
               {:error, :billing, {:error, :charge, :declined, %{validated: true}},
                %{user: %{id: 7}}}
    end

    test "nested failures nest their error tuples" do
      result =
        Q.new()
        |> Q.run(:outer, fn ->
          Q.new()
          |> Q.put(:a, 1)
          |> Q.run(:middle, fn ->
            Q.new()
            |> Q.put(:b, 2)
            |> Q.run(:inner, fn -> {:error, :deep} end)
          end)
        end)
        |> Q.exec()

      assert result ==
               {:error, :outer, {:error, :middle, {:error, :inner, :deep, %{b: 2}}, %{a: 1}}, %{}}
    end

    test "a child halt stops the parent too, keeping the partial results at each level" do
      result =
        Q.new()
        |> Q.put(:top, 0)
        |> Q.run(:outer, fn ->
          Q.new()
          |> Q.put(:a, 1)
          |> Q.run(:middle, fn ->
            Q.new()
            |> Q.put(:b, 2)
            |> Q.run(:stop, fn -> {:halt, :early} end)
            |> Q.put(:never, :inner)
          end)
          |> Q.put(:never, :outer)
        end)
        |> Q.put(:never, :top)
        |> Q.exec()

      assert result == {:ok, %{top: 0, outer: %{a: 1, middle: %{b: 2, stop: :early}}}}
    end

    test "a halt with propagate: false stops only the child" do
      result =
        Q.new()
        |> Q.run(:cache, fn ->
          Q.new()
          |> Q.run(:lookup, fn -> {:halt, :hit, propagate: false} end)
          |> Q.put(:never, true)
        end)
        |> Q.put(:after_cache, true)
        |> Q.exec()

      assert result == {:ok, %{cache: %{lookup: :hit}, after_cache: true}}
    end

    test "propagate: true is a plain halt, and both forms are the same at the top level" do
      child = fn -> Q.new() |> Q.run(:stop, fn -> {:halt, :early, propagate: true} end) end

      assert Q.new() |> Q.run(:child, child) |> Q.put(:never, true) |> Q.exec() ==
               {:ok, %{child: %{stop: :early}}}

      local = fn -> {:halt, :early, propagate: false} end

      assert Q.new() |> Q.run(:stop, local) |> Q.put(:never, true) |> Q.exec() ==
               {:ok, %{stop: :early}}
    end

    test "other third elements of a halt are invalid returns" do
      for bad <- [{:halt, 1, :bogus}, {:halt, 1, other: true}, {:halt, 1, propagate: :yes}] do
        assert_raise RuntimeError, ~r/expected operation `:step` to return/, fn ->
          Q.new() |> Q.run(:step, fn -> bad end) |> Q.exec()
        end
      end
    end

    test "a child under an unstored name runs and is discarded" do
      result =
        Q.new()
        |> Q.run(:_, fn -> Q.new() |> Q.let(:_, fn -> send(self(), :child_ran) end) end)
        |> Q.exec()

      assert result == {:ok, %{}}
      assert_received :child_ran

      failing = fn -> Q.new() |> Q.run(:inner, fn -> {:error, :boom} end) end

      assert Q.new() |> Q.run(:_, failing) |> Q.exec() ==
               {:error, :_, {:error, :inner, :boom, %{}}, %{}}
    end

    test "is listed as a run step" do
      assert [run: :billing] = Q.new() |> Q.run(:billing, fn -> Q.new() end) |> Q.to_list()
    end
  end

  describe "__branch__/3" do
    test "a hand-built branch that repeats a step name raises" do
      assert_raise ArgumentError, ~r/step :a from a branch conflicts/, fn ->
        Q.new()
        |> Q.put(:a, 1)
        |> Q.__branch__(fn -> Q.new() |> Q.put(:a, 2) end, [])
        |> Q.exec()
      end

      assert_raise ArgumentError, ~r/step :b conflicts with a step of the same name/, fn ->
        Q.new()
        |> Q.__branch__(fn -> Q.new() |> Q.put(:b, 1) end, [])
        |> Q.put(:b, 2)
        |> Q.exec()
      end
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
                   ~r/^expected operation `:bad_return` to return {:ok, value}, {:halt, value}, {:halt, value, propagate: boolean}, {:error, value}, :error or a queue, got: {:invalid, 1}$/,
                   fn ->
                     Q.new()
                     |> Q.run(:bad_return, fn _ -> {:invalid, 1} end)
                     |> Q.exec()
                   end

      assert_raise RuntimeError,
                   ~r"expected operation `:empty` to return {:ok, value}, {:halt, value}, {:halt, value, propagate: boolean}, {:error, value}, :error or a queue, got: nil",
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
