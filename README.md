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

Standalone pruning keeps the directory `current` resolves to and **one previous
version**: the highest stable (non-pre-release) version strictly below current
according to `Version.compare/2`. If no lower stable version exists, it falls
back to the highest pre-release below current. For example, current `1.7.6`
keeps `1.7.5` and deletes an unused `1.7.6-rc4`. Current may itself be an RC.
Build metadata does not affect precedence; ties for previous are broken by
directory name in ascending lexical order. If no older version exists, only
current is kept.

Every other directory with a valid Elixir SemVer name is deleted, including
newer unswitched releases and abandoned experiments. Non-version entries such
as `log/`, files and symlinks are untouched. A missing, broken, non-version or
external `current` stops pruning without deleting releases on that host.

For automatic cleanup, opt in per application:

```elixir
config :dicon, prune_on_switch: true
```

Automatic pruning retains **the exact release current pointed to before the
switch**, whether it is stable, an RC, or newer than the requested version during
rollback. Each host's old current is read and validated before switching; cleanup
then verifies that current resolves to the requested version. Thus switching
from `1.7.5` to `1.7.6` keeps `1.7.5` and deletes an unused `1.7.6-rc4`. This
preserves the old release throughout a `switch → stop → start` sequence.

If current is absent on the first switch, cleanup keeps only the new release.
An invalid existing current aborts before switching. Switching to the
already-current version skips pruning so a retry preserves the rollback target.
`dicon.deploy` never prunes, so uploading before switching remains safe. Automatic
cleanup defaults to off because dicon is shared by services with different staging
and retention workflows; services must enable it to bound disk growth.

Serialize deploy, switch and prune operations on each host. Never run standalone
pruning between deploy and switch: it removes the staged release. The commands
recheck current before each deletion but do not lock concurrent deployments.
Standalone pruning has no switch history: inspect its dry run and stop any process
using a release it would delete before running it. It can remove an RC or newer
release that automatic pruning retained as the previous current.

Rollback to the retained previous version uses the usual `mix dicon.switch
VERSION`. Automatic pruning keeps the release rolled back from, so rolling
forward to it requires no redeploy. Pruning errors abort the task; they do not
undo an already completed switch or earlier deletions. Inspect the reported host
before retrying; standalone pruning uses the stable-first policy described above.

## License

This software is licensed under [the ISC license](LICENSE).
