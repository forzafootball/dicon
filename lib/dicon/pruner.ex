defmodule Dicon.Pruner do
  @moduledoc false

  alias Dicon.Executor

  # SecureShell does not propagate remote exit statuses. Require this marker only
  # after every shell operation succeeds, including a complete directory listing.
  @success "dicon:prune:ok"

  def prune(%Executor{} = conn, target_dir, host, opts \\ []) when is_binary(target_dir) do
    target_dir = if Path.type(target_dir) == :absolute, do: target_dir, else: "./" <> target_dir

    output =
      checked_exec(conn, [
        "cd ",
        quote_path(target_dir),
        " && root=$(pwd -P) && test -L current",
        " && current=$(cd current && pwd -P)",
        " && printf '%s\\0' \"$root\" \"$current\"",
        " && find . -mindepth 1 -maxdepth 1 -type d -print0"
      ])

    {root, current, releases} = parse_inventory(output, host)

    if expected = opts[:expected_current] do
      if current != expected do
        Mix.raise("#{host}: current is #{current}, expected #{expected}; refusing to prune")
      end
    end

    previous =
      Enum.find(releases, fn {_, %Version{} = version} ->
        Version.compare(version, current) == :lt
      end)

    previous_name = if previous, do: elem(previous, 0)
    Mix.shell().info("#{host}: keeping current #{current}, previous #{previous_name || "none"}")

    for {name, _} <- releases, name not in [current, previous_name] do
      path = Path.join(root, name)

      if opts[:dry_run] do
        Mix.shell().info("#{host}: would delete #{path}")
      else
        checked_exec(conn, [
          "cd ",
          quote_path(root),
          " && test -L current && test \"$(cd current && pwd -P)\" = ",
          quote_path(Path.join(root, current)),
          " && test ! -L ",
          quote_path("./" <> name),
          " && test -d ",
          quote_path("./" <> name),
          " && rm -rf -- ",
          quote_path("./" <> name)
        ])

        Mix.shell().info("#{host}: deleted #{path}")
      end
    end

    :ok
  end

  defp parse_inventory(output, host) when is_binary(output) do
    case String.split(output, "\0", trim: false) do
      ["/" <> _ = root, "/" <> _ = current_path | entries] ->
        releases =
          entries
          |> Enum.flat_map(fn
            "./" <> name ->
              case Version.parse(name) do
                {:ok, version} -> [{name, version}]
                :error -> []
              end

            _ ->
              []
          end)
          |> Enum.sort(fn {left_name, left}, {right_name, right} ->
            case Version.compare(left, right) do
              :gt -> true
              :lt -> false
              :eq -> left_name <= right_name
            end
          end)

        current = Path.basename(current_path)

        if Path.dirname(current_path) != root or not List.keymember?(releases, current, 0) do
          Mix.raise("#{host}: current must resolve to a version directory inside #{root}")
        end

        {root, current, releases}

      _ ->
        Mix.raise("#{host}: invalid release inventory; refusing to prune")
    end
  end

  defp checked_exec(%Executor{} = conn, command) do
    {:ok, device} = StringIO.open("")
    success = @success <> "\0"

    try do
      Executor.exec(conn, [command, " && printf '%s\\0' ", quote_path(@success)], device)
      {"", output} = StringIO.contents(device)

      if String.ends_with?(output, success) do
        binary_part(output, 0, byte_size(output) - byte_size(success))
      else
        Mix.raise("Pruning command failed or current changed; refusing to continue: #{output}")
      end
    after
      StringIO.close(device)
    end
  end

  defp quote_path(path) when is_binary(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
