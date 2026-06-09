# Hex.pm publish runbook

This document defines the local release procedure for publishing `sv_port_sim` to Hex.pm.

The release workflow is deliberately conservative:

- local preflight checks must pass before publishing,
- public package metadata must be reviewed before publishing,
- generated HexDocs must be checked before publishing,
- the helper script defaults to a dry run,
- the real publish step requires an explicit `--publish` flag,
- the script prints the version about to be published,
- credentials are handled only by Hex's standard local authentication commands.

## Scope

This runbook covers maintainer-driven publishing to the public Hex.pm repository.

It intentionally does not cover:

- publishing from GitHub Actions,
- storing Hex API keys as GitHub Actions secrets,
- private Hex organizations or private packages,
- changing the public API surface only for release automation.

## Files

- `docs/hex_publish.md` — this runbook.
- `scripts/hex_publish.sh` — local publish helper.
- `CHANGELOG.md` — user-facing release notes.
- `LICENSE.md` — full package license text.

## Preconditions

Before publishing, confirm all of the following.

1. The release branch is up to date with the commit that passed CI.
2. The GitHub Actions workflow is green for the exact commit being published.
3. The working tree is clean.
4. The `:version` in `mix.exs` is the intended semantic version.
5. `CHANGELOG.md` has an entry for the version being published.
6. `LICENSE.md` contains the full license text.
7. `mix.exs` contains complete public package metadata:
   - `:description`,
   - `:package`,
   - licenses,
   - links,
   - intended package files.
8. `mix.exs` documentation settings include public extras that should appear in HexDocs:
   - `README.md`,
   - `CHANGELOG.md`,
   - `LICENSE.md`.
9. Package metadata links point to public, working URLs.
10. `README.md`, `CHANGELOG.md`, `LICENSE.md`, and generated HexDocs content are appropriate for public users.
11. No local-only files, build artifacts, credentials, private notes, or unpublished project material are included in the Hex package.
12. Docker is available if the release preflight will run the opt-in Verilator workflow locally.

Hex publishes packages publicly by default. Do not publish until all public metadata and documentation have been reviewed.

## Hex authentication

Check whether the maintainer machine is already authenticated:

```sh
mix hex.user whoami
```

Authenticate before publishing:

```sh
mix hex.user auth
```

If the maintainer does not have a Hex account yet, register first:

```sh
mix hex.user register
```

Do not commit Hex credentials, generated API keys, `~/.hex` contents, shell history containing secrets, or CI secrets to this repository.

## Recommended dry run

Run the helper script from the repository root:

```sh
scripts/hex_publish.sh --dry-run
```

`--dry-run` is the default, so this is equivalent:

```sh
scripts/hex_publish.sh
```

The script runs the following safe preflight steps:

```sh
mix deps.get
mix compile --warnings-as-errors --force
mix test --warnings-as-errors
SV_PORT_SIM_RUN_VERILATOR_TESTS=1 mix test --warnings-as-errors
mix docs --warnings-as-errors
mix hex.publish --dry-run
mix hex.build --unpack --output <temporary inspection directory>
```

The Verilator step uses Docker and the configured Verilator image. To override the image:

```sh
SV_PORT_SIM_VERILATOR_IMAGE=verilator/verilator:latest scripts/hex_publish.sh --dry-run
```

For a maintainer machine without Docker or Verilator support, skip only that local preflight step:

```sh
scripts/hex_publish.sh --dry-run --skip-verilator
```

Only use `--skip-verilator` when CI has already run the real Verilator workflow for the exact commit being published.

## Documentation validation

Before publishing, generate documentation locally:

```sh
mix docs --warnings-as-errors
```

Then review the generated `doc/` directory. Confirm that HexDocs includes:

- the README as the main page,
- the changelog,
- the full license text,
- correct project name, source URL, homepage URL, and version.

The release runbook itself is maintainer-facing. It does not need to be a public HexDocs page unless maintainers intentionally add it to `docs.extras`.

## Manual validation commands

The helper script is preferred, but the equivalent manual preflight is:

```sh
mix deps.get
mix compile --warnings-as-errors --force
mix test --warnings-as-errors
SV_PORT_SIM_RUN_VERILATOR_TESTS=1 mix test --warnings-as-errors
mix docs --warnings-as-errors
mix hex.publish --dry-run
mix hex.build --unpack
```

After `mix hex.build --unpack`, inspect the generated tarball and unpacked package contents. Verify that the package includes only intended files and does not contain credentials, `_build`, `deps`, generated simulator artifacts, temporary files, or private notes.

At minimum, the package should include:

```text
lib/
priv/
.formatter.exs
mix.exs
README.md
CHANGELOG.md
LICENSE.md
```

The helper script uses `mix hex.build --unpack --output <temporary inspection directory>` so the inspection directory is outside the repository working tree.

## Publishing

The actual publish step is deliberately separate from the dry-run step.

Publish the package and documentation interactively:

```sh
scripts/hex_publish.sh --publish
```

The script runs the full preflight again, checks Hex authentication, prints the version, and asks you to type the exact version before calling `mix hex.publish`.

For non-interactive maintainer use, confirmation can be skipped explicitly:

```sh
scripts/hex_publish.sh --publish --yes
```

Use `--yes` only when the command is being run by the package maintainer in a controlled release shell.

### Package-only and docs-only publishing

Publish only the package:

```sh
scripts/hex_publish.sh --publish --package-only
```

Publish only documentation:

```sh
scripts/hex_publish.sh --publish --docs-only
```

The script maps these to:

```sh
mix hex.publish package
mix hex.publish docs
```

Dry-run mode also supports these targets:

```sh
scripts/hex_publish.sh --dry-run --package-only
scripts/hex_publish.sh --dry-run --docs-only
```

## Dirty working tree policy

By default, the script refuses to run when `git status --porcelain` is not empty. This protects against publishing local edits or generated files by accident.

For local dry-run experiments only, the check can be overridden:

```sh
scripts/hex_publish.sh --dry-run --allow-dirty
```

`--allow-dirty` is intentionally rejected for `--publish`. An actual release must be made from a clean working tree.

## Post-publish verification

After publishing, verify all of the following.

1. The package page exists on Hex.pm.
2. The expected version is listed.
3. The installation snippet points to the expected version range.
4. HexDocs were published and render correctly.
5. The changelog and license are visible in HexDocs.
6. Package metadata links work.
7. The README shown on Hex.pm is appropriate.
8. A clean sample project can depend on the newly published version.

Example smoke test:

```sh
VERSION=0.1.0
mix new /tmp/sv_port_sim_hex_smoke
cd /tmp/sv_port_sim_hex_smoke
```

Edit `mix.exs` and add:

```elixir
{:sv_port_sim, "~> 0.1.0"}
```

Then run:

```sh
mix deps.get
mix compile
```

Replace `0.1.0` with the actual published version.

## Revert and update procedure

Hex package releases are intended to be immutable. There are limited time windows for replacing or reverting a release.

Commands:

```sh
mix hex.publish --revert VERSION
mix hex.publish docs --revert VERSION
```

Documentation can also be republished separately:

```sh
mix hex.publish docs
```

If a package version can no longer be safely reverted or replaced, publish a new patch version instead.
