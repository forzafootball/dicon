defmodule Dicon.ExecutorTest do
  use ExUnit.Case

  alias Dicon.Executor

  defmodule FakeExecutor do
    @behaviour Executor

    @impl true
    def connect("fail", _), do: {:error, "connect failed"}
    def connect(term, _), do: {:ok, term}

    @impl true
    def exec(_conn, 'fail', _device), do: {:error, "exec failed"}
    def exec(_conn, _command, _device), do: :ok

    @impl true
    def write_file(_conn, 'fail', "fail", _mode), do: {:error, "write failed"}
    def write_file(_conn, _target, _content, _mode), do: :ok

    @impl true
    def copy(_conn, 'fail', 'fail'), do: {:error, "copy failed"}
    def copy(_conn, _source, _target), do: :ok
  end

  setup_all do
    Application.put_env(:dicon, :executor, FakeExecutor)
    on_exit(fn -> Application.delete_env(:dicon, :executor) end)
  end

  test "connect/1" do
    assert %Executor{} = Executor.connect("whatever")
    assert_receive {:mix_shell, :info, ["Connected to whatever"]}

    message = "(in Dicon.ExecutorTest.FakeExecutor) connect failed"
    assert_raise Mix.Error, message, fn -> Executor.connect("fail") end
  end

  test "exec/2" do
    conn = Executor.connect("whatever")

    assert Executor.exec(conn, "whatever") == :ok
    assert_receive {:mix_shell, :info, ["==> EXEC whatever"]}

    message = "(in Dicon.ExecutorTest.FakeExecutor) exec failed"
    assert_raise Mix.Error, message, fn -> Executor.exec(conn, 'fail') end
  end

  test "copy/2" do
    conn = Executor.connect("whatever")

    assert Executor.copy(conn, 'source', 'target') == :ok
    assert_receive {:mix_shell, :info, ["==> COPY source target"]}

    message = "(in Dicon.ExecutorTest.FakeExecutor) copy failed"
    assert_raise Mix.Error, message, fn -> Executor.copy(conn, 'fail', 'fail') end
  end

  test "write_file/4" do
    conn = Executor.connect("whatever")

    assert Executor.write_file(conn, 'target', "content") == :ok
    assert_receive {:mix_shell, :info, ["==> WRITE target"]}

    message = "(in Dicon.ExecutorTest.FakeExecutor) write failed"

    assert_raise Mix.Error, message, fn ->
      Executor.write_file(conn, 'fail', "fail")
    end
  end
end
