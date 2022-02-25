defmodule QTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  doctest Q

  defmodule TestWriter do
    def write(%{read: text}, opts \\ []) do
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

  describe "exec/0" do
    test "executing nothign returns expected result" do
      assert {:ok, nil} = Q.new() |> Q.exec()
    end

    test "raises for unexpected returns" do
      q =
        Q.new()
        |> Q.run(:bad_return, fn _ -> {:bad, 1} end)

      assert_raise RuntimeError,
                   ~r/^expected operation `:bad_return` to return {:ok, value}, {:halt, value} or {:error, value}, got: {:bad, 1}$/,
                   fn ->
                     Q.exec(q)
                   end
    end
  end

  describe "put/2" do
    test "put operations" do
      q =
        Q.new()
        |> Q.put(:init, :test)

      assert %Q{names: set, operations: [{:init, {:put, :test}}]} = q
      assert MapSet.equal?(MapSet.new([:init]), set)
      assert {:ok, %{init: :test}} = Q.exec(q)
    end

    test "repeating an operation" do
      assert_raise RuntimeError, ~r":test is already a member", fn ->
        Q.new() |> Q.put(:test, :test) |> Q.put(:test, :fails)
      end
    end
  end

  describe "run/5" do
    test "basic functionality" do
      result =
        Q.new()
        |> Q.put(:init, :test)
        |> Q.run(:read, fn _ -> {:ok, "hello world"} end)
        |> Q.run(:write, TestWriter, :write, [[upcase: true]])
        |> Q.exec()

      assert {:ok, %{init: :test, read: "hello world", write: "HELLO WORLD"}} = result
    end
  end

  test "run/3" do
    result =
      Q.new()
      |> Q.run(:read, fn _ -> {:ok, "hello world"} end)
      |> Q.run(:write1, fn params -> TestWriter.write(params, upcase: true) end)
      |> Q.run(:write2, {TestWriter, :write, [[upcase: true]]})
      |> Q.run(:write3, &TestWriter.write/1)
      |> Q.exec()

    assert {:ok,
            %{
              read: "hello world",
              write1: "HELLO WORLD",
              write2: "HELLO WORLD",
              write3: "hello world"
            }} = result
  end

  test "repeating an operation" do
    fun = fn _, _ -> {:ok, :ok} end

    assert_raise RuntimeError, ~r":run is already a member", fn ->
      Q.new() |> Q.run(:run, fun) |> Q.run(:run, fun)
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

  test "handles halt" do
    result =
      Q.new()
      |> Q.run(:read, fn _ -> {:halt, :done_early} end)
      |> Q.run(:write, fn %{read: _read} -> {:ok, :write_success} end)
      |> Q.exec()

    assert {:ok, %{read: :done_early} = output} = result
    refute Map.has_key?(output, :write)
  end

  describe "to_list/1" do
    test "returns a list of operations" do
      que =
        Q.new()
        |> Q.put(:init, :test)
        |> Q.run(:read, fn _ -> {:ok, :read} end)
        |> Q.run(:write, fn %{read: _read} -> {:ok, :write} end)

      assert [
               {:init, {:put, :test}},
               {:read, {:run, _}},
               {:write, {:run, _}}
             ] = Q.to_list(que)
    end
  end

  describe "inspect/2" do
    test "printing stuff" do
      que =
        Q.new()
        |> Q.put(:init, :test)
        |> Q.put(:init2, :test2)

      assert capture_io(fn ->
               que
               |> Q.inspect()
               |> Q.exec()
             end) == "%{init: :test, init2: :test2}\n"

      assert capture_io(fn ->
               que
               |> Q.inspect(only: :init)
               |> Q.exec()
             end) == "%{init: :test}\n"
    end
  end

  test "executing invalid operations fails" do
    Q.new()
    |> Q.put(:error, {:error, "test"})
    |> Q.exec()

    # |> IO.inspect
  end
end
