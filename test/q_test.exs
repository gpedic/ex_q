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

  defmodule TestInputs do
    def result, do: {:ok, :no_inputs}
    def result(state), do: {:ok, state}
    def plain, do: :no_inputs
    def plain(state), do: state
    def with_options(state, options), do: {:ok, {state, options}}
    def arguments(first, second, third), do: {:ok, {first, second, third}}
  end

  describe "new/0" do
    test "creating the basic struct" do
      assert %Q{names: _, operations: []} = Q.new()
    end
  end

  describe "execute/1" do
    test "executing without queued tasks returns an empty state" do
      assert {:ok, %{}} = Q.new() |> Q.execute()
    end

    test "raises for unexpected returns" do
      q =
        Q.new()
        |> Q.run(:bad_return, fn _ -> {:bad, 1} end)

      assert_raise RuntimeError,
                   ~r/^expected operation `:bad_return` to return {:ok, value}, {:halt, value}, {:halt, value, propagate: boolean}, {:error, value}, :error or a queue, got: {:bad, 1}$/,
                   fn ->
                     Q.execute(q)
                   end
    end

    test "callback exceptions propagate unchanged and leave completed effects in place" do
      original = ArgumentError.exception("raised inside a step")

      for add_step <- [&Q.run/4, &Q.let/4] do
        queue =
          Q.new()
          |> Q.run(
            :effect,
            fn ->
              send(self(), :completed_effect)
              {:ok, :done}
            end,
            []
          )
          |> add_step.(:raised, fn -> raise original end, [])
          |> Q.let(:later, fn -> send(self(), :later_effect) end, [])

        raised = assert_raise ArgumentError, fn -> Q.execute(queue) end

        assert raised == original
        assert_received :completed_effect
        refute_received :later_effect
      end
    end

    test "exceptions inside children propagate unchanged without a nested error tuple" do
      original = RuntimeError.exception("raised inside a child")

      child =
        Q.new()
        |> Q.let(:effect, fn -> send(self(), :child_effect) end, [])
        |> Q.run(:raised, fn -> raise original end, [])
        |> Q.let(:later, fn -> send(self(), :later_child_effect) end, [])

      queue =
        Q.new()
        |> Q.run(:child, fn -> child end, [])
        |> Q.let(:later, fn -> send(self(), :later_parent_effect) end, [])

      raised = assert_raise RuntimeError, fn -> Q.execute(queue) end

      assert raised == original
      assert_received :child_effect
      refute_received :later_child_effect
      refute_received :later_parent_effect
    end

    test "returned errors and halts retain earlier effects and skip later operations" do
      for {outcome, expected} <- [
            {{:error, :offline}, {:error, :stopped, :offline, %{effect: :done}}},
            {{:halt, :done}, {:ok, %{effect: :done, stopped: :done}}}
          ] do
        queue =
          Q.new()
          |> Q.run(
            :effect,
            fn ->
              send(self(), :completed_effect)
              {:ok, :done}
            end,
            []
          )
          |> Q.run(:stopped, fn -> outcome end, [])
          |> Q.let(:later, fn -> send(self(), :later_effect) end, [])

        assert Q.execute(queue) == expected
        assert_received :completed_effect
        refute_received :later_effect
      end
    end
  end

  describe "running a queue" do
    test "exec/1 no longer exists" do
      refute function_exported?(Q, :exec, 1)
    end

    test "a step returning an executed queue's error points at returning the queue" do
      failing = Q.new() |> Q.run(:inner, fn -> {:error, :boom} end, [])

      assert_raise RuntimeError, ~r/return the queue instead of executing it/, fn ->
        Q.new() |> Q.run(:child, fn -> Q.execute(failing) end, []) |> Q.execute()
      end
    end
  end

  describe "put/3" do
    test "put operations" do
      q =
        Q.new()
        |> Q.put(:init, :test)

      assert [{:put, :init}] = Q.__to_list__(q)
      assert {:ok, %{init: :test}} = Q.execute(q)
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
        |> Q.execute()

      assert {:ok, %{init: :test, read: "hello world", write: "HELLO WORLD"}} = result
    end

    test "an arity-0 function with explicit [] is called with no arguments" do
      assert {:ok, %{answer: 42}} =
               Q.new()
               |> Q.run(:answer, fn -> {:ok, 42} end, [])
               |> Q.execute()
    end

    test "a function whose arity doesn't match its params raises when added" do
      assert_raise ArgumentError, ~r/expected a function of arity 1 for params \[:a\]/, fn ->
        Q.new() |> Q.put(:a, 1) |> Q.run(:b, fn -> {:ok, 2} end, [:a])
      end

      assert_raise ArgumentError,
                   ~r/expected a function of arity 1 to receive the whole state/,
                   fn ->
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
        |> Q.execute()

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
        |> Q.execute()

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
        |> Q.execute()

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
        |> Q.execute()
      end
    end

    test "functions reject :order, which only applies to MFA fixed arguments" do
      q = Q.new() |> Q.put(:a, 1)

      for fun <- [fn a -> {:ok, a * 2} end, &TestInputs.result/1], order <- [:append, :prepend] do
        assert_raise ArgumentError,
                     ~r/the :order option only applies to \{module, function, args\}/,
                     fn ->
                       Q.run(q, :b, fun, {[:a], order: order})
                     end
      end

      assert_raise ArgumentError, ~r/the :order option only applies/, fn ->
        Q.let(q, :b, fn -> 2 end, {[], order: :append})
      end
    end

    test "functions accept {params, opts} without options" do
      result =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.run(:b, fn a -> {:ok, a * 2} end, {[:a], []})
        |> Q.execute()

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

  describe "queue inputs" do
    test "omitted params pass the accumulated state to functions and MFAs" do
      queue = Q.new() |> Q.put(:input, 7)

      assert queue |> Q.run(:snapshot, &TestInputs.result/1) |> Q.execute() ==
               {:ok, %{input: 7, snapshot: %{input: 7}}}

      assert queue |> Q.run(:snapshot, {TestInputs, :result}) |> Q.execute() ==
               {:ok, %{input: 7, snapshot: %{input: 7}}}

      assert queue |> Q.let(:snapshot, &TestInputs.plain/1) |> Q.execute() ==
               {:ok, %{input: 7, snapshot: %{input: 7}}}

      assert queue |> Q.let(:snapshot, {TestInputs, :plain}) |> Q.execute() ==
               {:ok, %{input: 7, snapshot: %{input: 7}}}
    end

    test "explicit empty params pass no inputs to functions and MFAs" do
      queue = Q.new() |> Q.put(:input, 7)

      assert queue |> Q.run(:empty, &TestInputs.result/0, []) |> Q.execute() ==
               {:ok, %{input: 7, empty: :no_inputs}}

      assert queue |> Q.let(:empty, &TestInputs.plain/0, []) |> Q.execute() ==
               {:ok, %{input: 7, empty: :no_inputs}}

      # :order only applies to MFAs
      for params <- [[], {[], order: :prepend}, {[], order: :append}] do
        assert queue |> Q.run(:empty, {TestInputs, :result}, params) |> Q.execute() ==
                 {:ok, %{input: 7, empty: :no_inputs}}

        assert queue |> Q.let(:empty, {TestInputs, :plain}, params) |> Q.execute() ==
                 {:ok, %{input: 7, empty: :no_inputs}}
      end
    end

    test "omitted params reject zero-arity functions with an explicit-empty hint" do
      for build <- [
            fn -> Q.run(Q.new(), :empty, &TestInputs.result/0) end,
            fn -> Q.let(Q.new(), :empty, &TestInputs.plain/0) end
          ] do
        error = assert_raise ArgumentError, build
        assert error.message =~ "expected a function of arity 1 to receive the whole state"
        assert error.message =~ "pass [] for no queue inputs"
      end
    end

    test "explicit empty params reject state callbacks rather than injecting state" do
      assert_raise ArgumentError, ~r/expected a function of arity 0 for params \[\]/, fn ->
        Q.run(Q.new(), :snapshot, &TestInputs.result/1, [])
      end

      assert_raise ArgumentError, ~r/expected a function of arity 0 for params \[\]/, fn ->
        Q.let(Q.new(), :snapshot, &TestInputs.plain/1, [])
      end
    end

    test "MFA validation uses the declared input count" do
      assert_raise ArgumentError, ~r/System.version\/1 is undefined or private/, fn ->
        Q.let(Q.new(), :version, {System, :version})
      end

      assert_raise ArgumentError, ~r/Map.keys\/0 is undefined or private/, fn ->
        Q.let(Q.new(), :keys, {Map, :keys}, [])
      end

      assert {:ok, %{version: version}} =
               Q.new() |> Q.let(:version, {System, :version}, []) |> Q.execute()

      assert version == System.version()
    end

    test "MFA fixed arguments are added to the declared inputs" do
      queue = Q.new() |> Q.put(:input, 7)
      options = [strict: true]

      assert queue
             |> Q.run(:snapshot, {TestInputs, :with_options, [options]})
             |> Q.execute() == {:ok, %{input: 7, snapshot: {%{input: 7}, options}}}

      for params <- [[], {[], order: :prepend}, {[], order: :append}] do
        assert queue
               |> Q.run(:fixed, {TestInputs, :with_options, [:value, options]}, params)
               |> Q.execute() == {:ok, %{input: 7, fixed: {:value, options}}}
      end
    end

    test "named dependencies retain their order alongside fixed MFA arguments" do
      queue = Q.new() |> Q.put(:first, 1) |> Q.put(:second, 2)
      options = [strict: true]

      result =
        queue
        |> Q.run(:prepend, {TestInputs, :arguments, [options]}, [:second, :first])
        |> Q.run(
          :append,
          {TestInputs, :arguments, [options]},
          {[:second, :first], order: :append}
        )
        |> Q.run(:capture, &TestInputs.arguments(&1, &2, options), [:second, :first])
        |> Q.execute()

      assert result ==
               {:ok,
                %{
                  first: 1,
                  second: 2,
                  prepend: {2, 1, options},
                  append: {options, 2, 1},
                  capture: {2, 1, options}
                }}
    end
  end

  test "results are aggregated" do
    result =
      Q.new()
      |> Q.put(:init, :test)
      |> Q.run(:read, fn _ -> {:ok, :read} end)
      |> Q.run(:write, fn %{read: _read} -> {:ok, :write} end)
      |> Q.execute()

    assert {:ok, %{init: :test, read: :read, write: :write}} = result
  end

  test "handles error" do
    result =
      Q.new()
      |> Q.put(:init, :test)
      |> Q.run(:read, fn _ -> {:ok, :read} end)
      |> Q.run(:write, fn %{read: _read} -> {:error, :write_failed} end)
      |> Q.execute()

    assert {:error, :write, :write_failed, %{init: :test, read: :read}} = result
  end

  test "a bare :error return is a failure" do
    result =
      Q.new()
      |> Q.put(:input, "not base64")
      |> Q.run(:decoded, &Base.decode64/1, [:input])
      |> Q.run(:never, fn _ -> {:ok, :should_not_run} end)
      |> Q.execute()

    assert {:error, :decoded, :error, %{input: "not base64"}} = result
  end

  test "handles halt" do
    result =
      Q.new()
      |> Q.run(:read, fn _ -> {:halt, :done_early} end)
      |> Q.run(:write, fn %{read: _read} -> {:ok, :write_success} end)
      |> Q.execute()

    assert {:ok, %{read: :done_early} = output} = result
    refute Map.has_key?(output, :write)
  end

  describe "step names" do
    test "invalid names are rejected by every step builder" do
      invalid_names = [
        [],
        [:a, :b],
        [name: :a],
        "user",
        1,
        1.5,
        %{},
        MapSet.new(),
        self(),
        make_ref(),
        fn -> :name end,
        nil,
        true,
        false
      ]

      for name <- invalid_names do
        builders = [
          fn -> Q.put(Q.new(), name, :value) end,
          fn -> Q.run(Q.new(), name, fn -> {:ok, :value} end, []) end,
          fn -> Q.let(Q.new(), name, fn -> :value end, []) end
        ]

        for build <- builders do
          assert_raise ArgumentError, ~r/expected a step name to be an atom .* or a tuple/, build
        end
      end
    end

    test "tuple names work as result keys, dependencies and operation names" do
      queue =
        Q.new()
        |> Q.put({:input, 7}, 2)
        |> Q.run({:double, 7}, fn n -> {:ok, n * 2} end, [{:input, 7}])
        |> Q.let(:summary, &Integer.to_string/1, [{:double, 7}])

      assert Q.execute(queue) ==
               {:ok, %{{:input, 7} => 2, {:double, 7} => 4, :summary => "4"}}

      assert Q.operations(queue) == [{:input, 7}, {:double, 7}, :summary]
      assert Q.__to_list__(queue) == [put: {:input, 7}, run: {:double, 7}, let: :summary]

      assert_raise ArgumentError, ~r/is already a member/, fn ->
        Q.run(queue, {:input, 7}, fn -> {:ok, :duplicate} end, [])
      end
    end

    test "tuple names work with MFA steps and are preserved in failures" do
      result =
        Q.new()
        |> Q.put(:key, :a)
        |> Q.run({:fetch, 7}, {Map, :fetch, [%{a: 1}]}, {[:key], order: :append})
        |> Q.run({:charge, 7}, fn -> {:error, :declined} end, [])
        |> Q.execute()

      assert result ==
               {:error, {:charge, 7}, :declined, %{{:fetch, 7} => 1, :key => :a}}
    end

    test "debug can select a tuple-named step" do
      output =
        capture_io(fn ->
          Q.new()
          |> Q.put({:invite, 7}, :sent)
          |> Q.put(:other, :unrelated)
          |> Q.debug(only: {:invite, 7})
          |> Q.execute()
        end)

      assert output == "%{{:invite, 7} => :sent}\n"
    end
  end

  describe "names starting with _" do
    test "successful results are stored for put, run, let and halt" do
      result =
        Q.new()
        |> Q.put(:_input, 1)
        |> Q.run(
          :_sent,
          fn a ->
            send(self(), {:ran, a})
            {:ok, :sent}
          end,
          [:_input]
        )
        |> Q.let(:_logged, fn -> :logged end, [])
        |> Q.run(:_stop, fn -> {:halt, :done} end, [])
        |> Q.execute()

      assert result == {:ok, %{_input: 1, _sent: :sent, _logged: :logged, _stop: :done}}
      assert_received {:ran, 1}
    end

    test "bare underscore names are rejected when added" do
      builders = [
        fn -> Q.put(Q.new(), :_, :value) end,
        fn -> Q.run(Q.new(), :_, fn -> {:ok, :value} end, []) end,
        fn -> Q.let(Q.new(), :_, fn -> :value end, []) end
      ]

      for build <- builders do
        assert_raise ArgumentError, "every step must have a name; _ cannot name a step", build
      end
    end

    test "underscore-prefixed names must be unique across operation kinds" do
      queue = Q.new() |> Q.put(:_step, 1)

      builders = [
        fn -> Q.put(queue, :_step, 2) end,
        fn -> Q.run(queue, :_step, fn -> {:ok, 2} end, []) end,
        fn -> Q.let(queue, :_step, fn -> 2 end, []) end
      ]

      for build <- builders do
        assert_raise ArgumentError, ~r/:_step is already a member/, build
      end
    end

    test "a failure still names the step" do
      result =
        Q.new()
        |> Q.put(:a, 1)
        |> Q.run(:_notified, fn -> {:error, :offline} end, [])
        |> Q.execute()

      assert {:error, :_notified, :offline, %{a: 1}} = result
    end

    test "can be used as params and are listed as ordinary steps" do
      queue =
        Q.new()
        |> Q.let(:_x, fn -> 1 end, [])
        |> Q.let(:y, & &1, [:_x])

      assert Q.execute(queue) == {:ok, %{_x: 1, y: 1}}
      assert Q.operations(queue) == [:_x, :y]
      assert Q.__to_list__(queue) == [let: :_x, let: :y]
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
        |> Q.execute()

      assert {:ok, %{text: "hello", upper: "HELLO", twice: "hellohello", size: 3}} = result
    end

    test "a tuple return value is stored, not interpreted" do
      assert {:ok, %{pair: {:error, :not_a_failure}}} =
               Q.new()
               |> Q.let(:pair, fn -> {:error, :not_a_failure} end, [])
               |> Q.execute()
    end
  end

  describe "child queues" do
    defp billing(user) do
      Q.new()
      |> Q.put(:validated, user)
      |> Q.let(:invoice, fn -> {:invoice, user.id} end, [])
    end

    defp shipping(user) do
      Q.new()
      |> Q.put(:validated, user)
      |> Q.let(:tracking, fn -> {:tracking, user.id} end, [])
    end

    test "a step returning a queue runs it and stores its results under the step's name" do
      result =
        Q.new()
        |> Q.put(:user, %{id: 7})
        |> Q.run(:billing, &billing/1, [:user])
        |> Q.run(:shipping, &shipping/1, [:user])
        |> Q.let(:confirmation, fn b, s -> {b.invoice, s.tracking} end, [:billing, :shipping])
        |> Q.execute()

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
      assert Q.new() |> Q.run(:child, fn -> Q.new() end, []) |> Q.execute() ==
               {:ok, %{child: %{}}}
    end

    test "{:ok, queue} and let store a queue without running it" do
      assert {:ok, %{a: a, b: b}} =
               Q.new()
               |> Q.run(:a, fn -> {:ok, billing(%{id: 1})} end, [])
               |> Q.let(:b, fn -> billing(%{id: 1}) end, [])
               |> Q.execute()

      assert [put: :validated, let: :invoice] = Q.__to_list__(a)
      assert [put: :validated, let: :invoice] = Q.__to_list__(b)
    end

    test "a failing child step fails the parent step with the child's error tuple" do
      result =
        Q.new()
        |> Q.put(:user, %{id: 7})
        |> Q.run(
          :billing,
          fn ->
            Q.new()
            |> Q.put(:validated, true)
            |> Q.run(:charge, fn -> {:error, :declined} end, [])
          end,
          []
        )
        |> Q.run(:never, fn -> {:ok, :should_not_run} end, [])
        |> Q.execute()

      assert result ==
               {:error, :billing, {:error, :charge, :declined, %{validated: true}},
                %{user: %{id: 7}}}
    end

    test "nested failures nest their error tuples" do
      result =
        Q.new()
        |> Q.run(
          :outer,
          fn ->
            Q.new()
            |> Q.put(:a, 1)
            |> Q.run(
              :middle,
              fn ->
                Q.new()
                |> Q.put(:b, 2)
                |> Q.run(:inner, fn -> {:error, :deep} end, [])
              end,
              []
            )
          end,
          []
        )
        |> Q.execute()

      assert result ==
               {:error, :outer, {:error, :middle, {:error, :inner, :deep, %{b: 2}}, %{a: 1}}, %{}}
    end

    test "a child halt stops the parent too, keeping the partial results at each level" do
      result =
        Q.new()
        |> Q.put(:top, 0)
        |> Q.run(
          :outer,
          fn ->
            Q.new()
            |> Q.put(:a, 1)
            |> Q.run(
              :middle,
              fn ->
                Q.new()
                |> Q.put(:b, 2)
                |> Q.run(:stop, fn -> {:halt, :early} end, [])
                |> Q.put(:never, :inner)
              end,
              []
            )
            |> Q.put(:never, :outer)
          end,
          []
        )
        |> Q.put(:never, :top)
        |> Q.execute()

      assert result == {:ok, %{top: 0, outer: %{a: 1, middle: %{b: 2, stop: :early}}}}
    end

    test "a halt with propagate: false stops only the child" do
      result =
        Q.new()
        |> Q.run(
          :cache,
          fn ->
            Q.new()
            |> Q.run(:lookup, fn -> {:halt, :hit, propagate: false} end, [])
            |> Q.put(:never, true)
          end,
          []
        )
        |> Q.put(:after_cache, true)
        |> Q.execute()

      assert result == {:ok, %{cache: %{lookup: :hit}, after_cache: true}}
    end

    test "a local halt in a grandchild allows both ancestors to continue" do
      result =
        Q.new()
        |> Q.run(
          :child,
          fn ->
            Q.new()
            |> Q.run(
              :grandchild,
              fn ->
                Q.new()
                |> Q.put(:before_halt, true)
                |> Q.run(:stop, fn -> {:halt, :done, propagate: false} end, [])
                |> Q.let(:never, fn -> raise "grandchild must stop" end, [])
              end,
              []
            )
            |> Q.put(:after_grandchild, true)
          end,
          []
        )
        |> Q.put(:after_child, true)
        |> Q.execute()

      assert result ==
               {:ok,
                %{
                  child: %{
                    grandchild: %{before_halt: true, stop: :done},
                    after_grandchild: true
                  },
                  after_child: true
                }}
    end

    test "propagate: true is a plain halt, and both forms are the same at the top level" do
      child = fn -> Q.new() |> Q.run(:stop, fn -> {:halt, :early, propagate: true} end, []) end

      assert Q.new() |> Q.run(:child, child, []) |> Q.put(:never, true) |> Q.execute() ==
               {:ok, %{child: %{stop: :early}}}

      local = fn -> {:halt, :early, propagate: false} end

      assert Q.new() |> Q.run(:stop, local, []) |> Q.put(:never, true) |> Q.execute() ==
               {:ok, %{stop: :early}}
    end

    test "other third elements of a halt are invalid returns" do
      for bad <- [{:halt, 1, :bogus}, {:halt, 1, other: true}, {:halt, 1, propagate: :yes}] do
        assert_raise RuntimeError, ~r/expected operation `:step` to return/, fn ->
          Q.new() |> Q.run(:step, fn -> bad end, []) |> Q.execute()
        end
      end
    end

    test "a child under an underscore-prefixed name retains its results and errors" do
      result =
        Q.new()
        |> Q.run(
          :_child,
          fn -> Q.new() |> Q.let(:_sent, fn -> send(self(), :child_ran) end, []) end,
          []
        )
        |> Q.execute()

      assert result == {:ok, %{_child: %{_sent: :child_ran}}}
      assert_received :child_ran

      failing = fn -> Q.new() |> Q.run(:inner, fn -> {:error, :boom} end, []) end

      assert Q.new() |> Q.run(:_child, failing, []) |> Q.execute() ==
               {:error, :_child, {:error, :inner, :boom, %{}}, %{}}
    end

    test "is listed as a run step" do
      assert [run: :billing] =
               Q.new() |> Q.run(:billing, fn -> Q.new() end, []) |> Q.__to_list__()
    end
  end

  describe "__branch__/3" do
    test "a hand-built branch that repeats a step name raises" do
      assert_raise ArgumentError, ~r/step :a conflicts with a step of the same name/, fn ->
        Q.new()
        |> Q.put(:a, 1)
        |> Q.__branch__(fn -> Q.new() |> Q.put(:a, 2) end, [])
        |> Q.execute()
      end

      assert_raise ArgumentError, ~r/step :b conflicts with a step of the same name/, fn ->
        Q.new()
        |> Q.__branch__(fn -> Q.new() |> Q.put(:b, 1) end, [])
        |> Q.put(:b, 2)
        |> Q.execute()
      end
    end

    test "a conflict prevents later branch steps from running" do
      assert_raise ArgumentError, ~r/step :a conflicts/, fn ->
        Q.new()
        |> Q.put(:a, 1)
        |> Q.__branch__(
          fn ->
            Q.new()
            |> Q.put(:a, 2)
            |> Q.let(:later, fn -> send(self(), :later_branch_step) end, [])
          end,
          []
        )
        |> Q.execute()
      end

      refute_received :later_branch_step
    end
  end

  describe "__to_list__/1" do
    test "returns a list of operations" do
      que =
        Q.new()
        |> Q.put(:init, :test)
        |> Q.run(:read, fn _ -> {:ok, :read} end)
        |> Q.run(:write, fn %{read: _read} -> {:ok, :write} end)

      assert [put: :init, run: :read, run: :write] = Q.__to_list__(que)
    end
  end

  describe "debug/2" do
    test "filtering accepts valid names and never modifies state" do
      state = %{:a => 1, {:invite, 7} => :sent}
      queue = Q.new() |> Q.put(:a, 1) |> Q.put({:invite, 7}, :sent)

      selections = [
        {:a, %{a: 1}},
        {{:invite, 7}, %{{:invite, 7} => :sent}},
        {[:a, {:invite, 7}], state},
        {[:a, :missing], %{a: 1}},
        {:missing, %{}},
        {[], %{}}
      ]

      for {selection, expected} <- selections do
        output =
          capture_io(fn ->
            assert queue |> Q.debug(only: selection) |> Q.execute() == {:ok, state}
          end)

        assert {^expected, []} = Code.eval_string(output)
      end
    end

    test "inspection options are forwarded after selecting keys" do
      output =
        capture_io(fn ->
          Q.new()
          |> Q.put(:text, "hello")
          |> Q.put(:other, :unrelated)
          |> Q.debug(only: :text, label: "selected", limit: :infinity)
          |> Q.execute()
        end)

      assert output == "selected: %{text: \"hello\"}\n"
    end

    test "non-keyword options are rejected when added" do
      for opts <- [
            nil,
            :invalid,
            "invalid",
            %{},
            [:invalid],
            [{1, :invalid}],
            [{:label, "x"} | :invalid]
          ] do
        assert_raise ArgumentError, ~r/debug options must be a keyword list/, fn ->
          Q.debug(Q.new(), opts)
        end
      end
    end

    test "invalid selectors are rejected when added" do
      for selection <- [nil, true, false, :_, "name", 1, [:a, [:b]], [:a | :invalid]] do
        assert_raise ArgumentError, ~r/debug :only must be a valid step name/, fn ->
          Q.debug(Q.new(), only: selection)
        end
      end
    end

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
          |> Q.execute()
        end)

      assert {%{init: :test, init2: :test2}, []} = Code.eval_string(printed)

      assert capture_io(fn ->
               que
               |> Q.debug(only: :init)
               |> Q.execute()
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
      assert [put: :a, debug: nil, put: :b, debug: nil] = Q.__to_list__(q)
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
                     |> Q.execute()
                   end

      assert_raise RuntimeError,
                   ~r"expected operation `:empty` to return {:ok, value}, {:halt, value}, {:halt, value, propagate: boolean}, {:error, value}, :error or a queue, got: nil",
                   fn ->
                     Q.new()
                     |> Q.run(:empty, fn _ -> nil end)
                     |> Q.execute()
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
