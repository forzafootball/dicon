defmodule Mix.Tasks.Dicon.PruneTest do
  use DiconTest.Case

  import Mix.Tasks.Dicon.Prune, only: [run: 1]

  setup do
    root = Path.join(System.tmp_dir!(), "dicon-prune-#{System.unique_integer([:positive])}")
    target = Path.join(root, "releases")
    File.mkdir_p!(target)

    put_dicon_env(%{
      target_dir: "releases",
      hosts: [:one],
      one: [authority: "one"],
      two: [authority: "two"],
      prune_on_switch: false
    })

    # Keep the fake connection/notifications, but exercise the actual shell
    # commands against disposable local releases. Like SecureShell, ignore exit
    # status so the pruning success checks are exercised too.
    on_exec(:all, fn command, device -> exec_locally(command, device, root) end)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:dicon, :prune_on_switch)
    end)

    {:ok, root: root, target: target}
  end

  test "dry run reports each host's deletions without changing anything", %{target: target} do
    versions = ~w(1.7.5 1.7.6-rc4 1.7.6 1.8.0-rc3-fcm-http2)
    releases(target, versions, "1.7.6")
    put_dicon_env(%{hosts: [:one, :two]})

    run(["--dry-run"])

    for host <- ["one", "two"] do
      assert_receive {:dicon, _, :connect, [^host, []]}
      assert_info("#{host}: keeping current 1.7.6, previous 1.7.6-rc4")
      assert_info_suffix("#{host}: would delete ", "/1.8.0-rc3-fcm-http2")
      assert_info_suffix("#{host}: would delete ", "/1.7.5")
    end

    assert Enum.sort(File.ls!(target)) == Enum.sort(["current" | versions])
    refute_delete_command()
  end

  test "deletes older and newer versions, keeping the highest previous RC", %{target: target} do
    releases(target, ~w(1.7.5 1.7.6-rc4 1.7.6 1.8.0-rc3-fcm-http2), "1.7.6")

    run([])

    assert Enum.sort(File.ls!(target)) == ~w(1.7.6 1.7.6-rc4 current)
    assert File.read_link!(Path.join(target, "current")) == "1.7.6"
    assert_info_suffix("one: deleted ", "/1.8.0-rc3-fcm-http2")
    assert_info_suffix("one: deleted ", "/1.7.5")
  end

  test "current can be an RC and alphanumeric identifiers sort lexically", %{target: target} do
    releases(target, ~w(1.1.8 1.1.9-rc2 1.1.9-rc9 1.1.9-rc10 1.1.9 1.1.10), "1.1.9-rc9")

    run([])

    # SemVer compares alphanumeric identifiers lexically: rc10 < rc2 < rc9.
    assert Enum.sort(File.ls!(target)) == ~w(1.1.9-rc2 1.1.9-rc9 current)
  end

  test "numeric pre-release identifiers and release components use SemVer", %{target: target} do
    releases(target, ~w(1.9.0 1.10.0-rc.2 1.10.0-rc.10 1.10.0 2.0.0), "1.10.0")

    run([])

    assert Enum.sort(File.ls!(target)) == ~w(1.10.0 1.10.0-rc.10 current)
  end

  test "ignores metadata precedence and breaks previous ties deterministically", %{target: target} do
    releases(target, ~w(1.0.0+a 1.0.0+b 1.1.0+a 1.1.0+b 1.1.0+c), "1.1.0+b")

    run([])

    assert Enum.sort(File.ls!(target)) == ~w(1.0.0+a 1.1.0+b current)
  end

  test "keeps only current when there is no lower version, and is idempotent", %{target: target} do
    releases(target, ~w(1.0.0-rc1 1.0.0 1.1.0), "1.0.0-rc1")

    run([])
    run([])

    assert Enum.sort(File.ls!(target)) == ~w(1.0.0-rc1 current)
    assert_info("one: keeping current 1.0.0-rc1, previous none")
  end

  test "never removes non-version entries, version files or symlinks", %{target: target} do
    releases(
      target,
      ~w(1.3.1-rc1-bruce 1.4.0-incident.0 1.4.0-rc1-yuri-track-device-token-activity 1.5.0 1.6.0),
      "1.6.0"
    )

    for name <- ["log", "data", "v1.0.0", "1.0", "notes\n1.0.0", "1.0.0; touch injected"] do
      File.mkdir_p!(Path.join(target, name))
    end

    File.write!(Path.join(target, "0.1.0"), "not a directory")
    File.ln_s!("log", Path.join(target, "1.2.0"))
    File.ln_s!("missing", Path.join(target, "1.2.1"))
    before = File.ls!(target)

    run([])

    assert Enum.sort(before -- File.ls!(target)) ==
             ~w(1.3.1-rc1-bruce 1.4.0-incident.0 1.4.0-rc1-yuri-track-device-token-activity)

    assert File.read!(Path.join(target, "0.1.0")) == "not a directory"
    assert File.read_link!(Path.join(target, "1.2.0")) == "log"
    assert File.read_link!(Path.join(target, "1.2.1")) == "missing"
  end

  test "supports absolute paths and shell metacharacters in the target", %{root: root} do
    target = Path.join(root, "app's releases $(touch injected)")
    releases(target, ~w(1.0.0 1.1.0 1.2.0), Path.join(target, "1.2.0"))
    put_dicon_env(%{target_dir: target})

    run([])

    assert Enum.sort(File.ls!(target)) == ~w(1.1.0 1.2.0 current)
    refute File.exists?(Path.join(root, "injected"))
  end

  test "treats a relative target starting with a dash as a literal directory", %{root: root} do
    target = Path.join(root, "-releases")
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.2.0")
    put_dicon_env(%{target_dir: "-releases"})

    run([])

    assert Enum.sort(File.ls!(target)) == ~w(1.1.0 1.2.0 current)
  end

  test "rejects a missing current", %{target: target} do
    File.mkdir_p!(Path.join(target, "1.0.0"))

    assert_raise Mix.Error, ~r/Pruning command failed/, fn -> run([]) end

    assert File.dir?(Path.join(target, "1.0.0"))
    refute_delete_command()
  end

  test "rejects a dangling current", %{target: target} do
    releases(target, ~w(1.0.0), "1.1.0")

    assert_raise Mix.Error, ~r/Pruning command failed/, fn -> run([]) end

    assert File.dir?(Path.join(target, "1.0.0"))
    refute_delete_command()
  end

  test "rejects a current directory instead of a symlink", %{target: target} do
    File.mkdir_p!(Path.join(target, "current"))

    assert_raise Mix.Error, ~r/Pruning command failed/, fn -> run([]) end

    refute_delete_command()
  end

  test "rejects a non-version current", %{target: target} do
    releases(target, ~w(log 1.0.0), "log")

    assert_raise Mix.Error, ~r/current must resolve to a version directory/, fn -> run([]) end

    assert File.dir?(Path.join(target, "1.0.0"))
    refute_delete_command()
  end

  test "rejects an external current with the same basename as a release", %{
    root: root,
    target: target
  } do
    outside = Path.join(root, "1.1.0")
    File.mkdir_p!(outside)
    releases(target, ~w(1.0.0 1.1.0), outside)

    assert_raise Mix.Error, ~r/current must resolve to a version directory/, fn -> run([]) end

    assert Enum.sort(File.ls!(target)) == ~w(1.0.0 1.1.0 current)
    refute_delete_command()
  end

  test "aborts if current changes between listing and deleting", %{root: root, target: target} do
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.2.0")

    on_exec(:all, fn command, device ->
      if String.contains?(command, "rm -rf") do
        File.rm!(Path.join(target, "current"))
        File.ln_s!("1.0.0", Path.join(target, "current"))
      end

      exec_locally(command, device, root)
    end)

    assert_raise Mix.Error, ~r/current changed/, fn -> run([]) end

    assert Enum.sort(File.ls!(target)) == ~w(1.0.0 1.1.0 1.2.0 current)
  end

  test "aborts if a candidate becomes a symlink", %{root: root, target: target} do
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.2.0")

    on_exec(:all, fn command, device ->
      if String.contains?(command, "rm -rf") do
        File.rm_rf!(Path.join(target, "1.0.0"))
        File.ln_s!("1.2.0", Path.join(target, "1.0.0"))
      end

      exec_locally(command, device, root)
    end)

    assert_raise Mix.Error, ~r/Pruning command failed/, fn -> run([]) end

    assert File.read_link!(Path.join(target, "1.0.0")) == "1.2.0"
    assert File.dir?(Path.join(target, "1.2.0"))
  end

  test "rejects incomplete inventories even if the executor returns ok", %{target: target} do
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.2.0")
    on_exec(:all, fn _command, device -> IO.write(device, "#{target}\0#{target}/1.2.0\0") end)

    assert_raise Mix.Error, ~r/Pruning command failed/, fn -> run([]) end

    refute_delete_command()
  end

  test "reports a deletion failure even if the executor returns ok", %{root: root, target: target} do
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.2.0")

    on_exec(:all, fn command, device ->
      if String.contains?(command, "rm -rf") do
        IO.write(device, "rm: permission denied")
      else
        exec_locally(command, device, root)
      end
    end)

    assert_raise Mix.Error, ~r/rm: permission denied/, fn -> run([]) end

    assert File.dir?(Path.join(target, "1.0.0"))
  end

  test "a directory name cannot masquerade as the success marker in a failed listing", %{
    target: target
  } do
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.2.0")

    on_exec(:all, fn _command, device ->
      IO.write(
        device,
        "#{target}\0#{target}/1.2.0\0./1.0.0\0./1.1.0\0./1.2.0\0./dicon:prune:ok\0"
      )
    end)

    assert_raise Mix.Error, ~r/Pruning command failed/, fn -> run([]) end

    refute_delete_command()
  end

  test "filters hosts and passes their connection options", %{target: target} do
    releases(target, ~w(1.0.0), "1.0.0")
    put_dicon_env(%{hosts: [:one, :two], one: [authority: "one", jump_authority: "jump"]})

    run(["--dry-run", "--only", "one", "--only", "two", "--skip", "two"])

    assert_receive {:dicon, ref, :connect, ["one", [jump_authority: "jump"]]}
    flush_reply(ref)
    refute_receive {:dicon, _, _, _}

    run(["--skip", "one", "--skip", "two"])
    refute_receive {:dicon, _, _, _}

    assert_raise Mix.Error, "Unknown host: \"unknown\"", fn ->
      run(["--only", "unknown"])
    end
  end

  test "validates arguments" do
    assert_raise Mix.Error, "Expected no arguments", fn -> run(["1.0.0"]) end
    assert_raise Mix.Error, "Invalid option: --invalid", fn -> run(["--invalid"]) end
  end

  test "opted-in switch prunes after selecting the staged release and allows rollback", %{
    target: target
  } do
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.1.0")
    put_dicon_env(%{prune_on_switch: true})

    Mix.Tasks.Dicon.Switch.run(["1.2.0"])

    assert Enum.sort(File.ls!(target)) == ~w(1.1.0 1.2.0 current)
    assert Path.basename(File.read_link!(Path.join(target, "current"))) == "1.2.0"

    Mix.Tasks.Dicon.Switch.run(["1.1.0"])

    assert Enum.sort(File.ls!(target)) == ~w(1.1.0 current)
    assert Path.basename(File.read_link!(Path.join(target, "current"))) == "1.1.0"
  end

  test "does not prune if switch fails to select the requested version", %{target: target} do
    releases(target, ~w(1.0.0 1.1.0 1.2.0), "1.1.0")
    put_dicon_env(%{prune_on_switch: true})

    on_exec("ln -snf $PWD/releases/1.2.0 $PWD/releases/current", fn device ->
      IO.write(device, "ln: permission denied")
    end)

    assert_raise Mix.Error, ~r/current is 1.1.0, expected 1.2.0/, fn ->
      Mix.Tasks.Dicon.Switch.run(["1.2.0"])
    end

    assert Enum.sort(File.ls!(target)) == ~w(1.0.0 1.1.0 1.2.0 current)
    refute_delete_command()
  end

  test "switch and deploy retain all versions unless switch pruning is enabled", %{target: target} do
    releases(target, ~w(1.0.0 1.1.0), "1.1.0")
    put_dicon_env(%{prune_on_switch: true})
    source = PathHelpers.fixture_path("empty.tar.gz")
    File.cp!(source, Path.join(target, "release.tar.gz"))

    Mix.Tasks.Dicon.Deploy.run([source, "1.2.0"])

    assert Enum.sort(File.ls!(target)) == ~w(1.0.0 1.1.0 1.2.0 current)
    refute_delete_command()

    Application.delete_env(:dicon, :prune_on_switch)
    Mix.Tasks.Dicon.Switch.run(["1.2.0"])

    assert Enum.sort(File.ls!(target)) == ~w(1.0.0 1.1.0 1.2.0 current)
    refute_delete_command()
  end

  defp releases(target, versions, current) do
    for version <- versions do
      File.mkdir_p!(Path.join(target, version))
      File.write!(Path.join([target, version, "release.txt"]), version)
    end

    File.ln_s!(current, Path.join(target, "current"))
  end

  defp exec_locally(command, device, root) do
    {output, _status} = System.cmd("sh", ["-c", command], cd: root, stderr_to_stdout: true)
    IO.binwrite(device, output)
  end

  defp assert_info(expected) do
    assert_receive {:mix_shell, :info, [^expected]}
  end

  defp assert_info_suffix(prefix, suffix) do
    messages = drain_messages()

    assert Enum.any?(messages, fn
             {:mix_shell, :info, [message]} ->
               String.starts_with?(message, prefix) and String.ends_with?(message, suffix)

             _ ->
               false
           end)

    Enum.each(messages, &send(self(), &1))
  end

  defp refute_delete_command() do
    for {:dicon, _, :exec, [command]} <- drain_messages() do
      refute String.contains?(command, "rm -rf")
    end
  end

  defp drain_messages() do
    receive do
      message -> [message | drain_messages()]
    after
      0 -> []
    end
  end
end
