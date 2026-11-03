defmodule Mix.Tasks.Dicon.Prune do
  use Mix.Task

  @shortdoc "Keeps current and the previous release on the configured servers"

  @moduledoc """
  Deletes version directories except current and the highest stable SemVer below
  it. If no lower stable version exists, keeps the highest pre-release below
  current instead. All other versions, including newer versions, are deleted.
  Non-version entries and symlinks are left alone. Unlike automatic pruning on
  switch, this task has no record of the release previously selected by current.

  The configured hosts and target directory come from the application's `:dicon`
  configuration. Use `--only HOST` / `--skip HOST` to filter hosts and `--dry-run`
  to print the deletions without changing anything.

  Run only after switching and stopping any process that uses a release to be
  deleted. Serialize deploy, switch and prune operations for each host; never
  prune between uploading a release and switching to it. An invalid or missing
  `current` aborts pruning. See the README for rollback and automatic pruning.

  ## Usage

      mix dicon.prune --dry-run
      mix dicon.prune --only app01
  """

  import Dicon, only: [config: 1, config: 2, host_config: 1]

  alias Dicon.{Executor, Pruner}

  @options [strict: [only: :keep, skip: :keep, dry_run: :boolean]]

  def run(argv) do
    case OptionParser.parse(argv, @options) do
      {opts, [], []} ->
        target_dir = config(:target_dir)

        for host <- config(:hosts, opts) do
          {authority, host_config} = Keyword.pop!(host_config(host), :authority)
          conn = Executor.connect(authority, host_config)
          Pruner.prune(conn, target_dir, host, opts)
        end

      {_opts, _commands, [switch | _]} ->
        Mix.raise("Invalid option: " <> Mix.Dicon.switch_to_string(switch))

      {_opts, _commands, _errors} ->
        Mix.raise("Expected no arguments")
    end
  end
end
