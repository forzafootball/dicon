# Digital Conveyor

![CI Status](https://github.com/lexmag/dicon/workflows/CI/badge.svg)
[![Hex Version](https://img.shields.io/hexpm/v/dicon.svg)](https://hex.pm/packages/dicon)

Simple release deliverer for Elixir.

## Installation

Add dicon as a dependency in your `mix.exs` file:

```elixir
def deps do
  [{:dicon, "~> 0.5", [only: :dev, runtime: false]}]
end
```

After you are done, run `mix deps.get` in your shell to fetch the dependencies.

## Release retention

Inspect and prune existing releases on the configured hosts:

```sh
mix dicon.prune --dry-run
mix dicon.prune --only app01
```

Both commands print the retained versions and each deletion per host. `--only`
and `--skip` can be repeated, just as for deploy and switch.

Pruning keeps the directory `current` resolves to and **one previous version**:
the highest version strictly below current according to `Version.compare/2`.
Previous may be an RC or another pre-release (e.g. current `1.7.6` keeps
`1.7.6-rc4` ahead of `1.7.5`). Current may itself be an RC. Build metadata does
not affect precedence; ties for previous are broken by directory name in
ascending lexical order. If no older version exists, only current is kept.

Every other directory with a valid Elixir SemVer name is deleted, including
newer unswitched releases and abandoned experiments. Non-version entries such
as `log/`, files and symlinks are untouched. A missing, broken, non-version or
external `current` stops pruning without deleting releases on that host.

For automatic cleanup, opt in per application:

```elixir
config :dicon, prune_on_switch: true
```

Cleanup runs after each host's `dicon.switch` and verifies that `current`
resolves to the requested version before deleting anything. `dicon.deploy`
does not prune, so uploading a release before switching remains safe. Automatic
cleanup defaults to off because dicon is shared by services with different
staging and retention workflows; services must enable it to bound disk growth.

Serialize deploy, switch and prune operations on each host. Never run standalone
pruning between deploy and switch: it removes the staged release. The commands
recheck current before each deletion but do not lock concurrent deployments.
Switch only changes the symlink, so stop processes using a release that pruning
would remove before switching/pruning (especially during rollback).

Rollback to the retained previous version uses the usual `mix dicon.switch
VERSION`. With automatic pruning enabled, the release rolled back from is then
removed as newer than current; rolling forward again requires redeploying it.
There may be no previous version left after rollback. Pruning errors abort the
task; they do not undo an already completed switch or earlier deletions. Inspect
the reported host and rerun `mix dicon.prune --dry-run` after resolving the error.

## License

This software is licensed under [the ISC license](LICENSE).
