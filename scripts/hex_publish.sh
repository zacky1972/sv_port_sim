#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/hex_publish.sh [options]

Safe Hex.pm publish helper for sv_port_sim.

Default behavior:
  --dry-run            Run all preflight checks and Hex dry-run checks, but do not publish.

Publish modes:
  --publish            Run preflight checks, then publish with mix hex.publish.
  --package-only       Use mix hex.publish package. Works with --dry-run or --publish.
  --docs-only          Use mix hex.publish docs. Works with --dry-run or --publish.
  --yes                Pass --yes to mix hex.publish. Only valid with --publish.

Preflight options:
  --skip-verilator     Skip SV_PORT_SIM_RUN_VERILATOR_TESTS=1 mix test --warnings-as-errors.
  --allow-dirty        Allow a dirty git working tree for dry-run experiments only.
  -h, --help           Show this help.

Examples:
  scripts/hex_publish.sh
  scripts/hex_publish.sh --dry-run
  scripts/hex_publish.sh --skip-verilator
  scripts/hex_publish.sh --publish
  scripts/hex_publish.sh --publish --yes
  scripts/hex_publish.sh --publish --package-only
  scripts/hex_publish.sh --publish --docs-only

Environment:
  SV_PORT_SIM_VERILATOR_IMAGE controls the Docker image used by Verilator tests.
USAGE
}

mode="dry-run"
publish_target="all"
yes="false"
skip_verilator="false"
allow_dirty="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      mode="dry-run"
      ;;
    --publish)
      mode="publish"
      ;;
    --package-only)
      if [[ "$publish_target" != "all" ]]; then
        echo "error: --package-only and --docs-only are mutually exclusive" >&2
        exit 2
      fi
      publish_target="package"
      ;;
    --docs-only)
      if [[ "$publish_target" != "all" ]]; then
        echo "error: --package-only and --docs-only are mutually exclusive" >&2
        exit 2
      fi
      publish_target="docs"
      ;;
    --yes)
      yes="true"
      ;;
    --skip-verilator)
      skip_verilator="true"
      ;;
    --allow-dirty)
      allow_dirty="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$yes" == "true" && "$mode" != "publish" ]]; then
  echo "error: --yes is only valid together with --publish" >&2
  exit 2
fi

if [[ "$allow_dirty" == "true" && "$mode" == "publish" ]]; then
  echo "error: --allow-dirty is not allowed with --publish" >&2
  exit 2
fi

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 127
  fi
}

step() {
  printf '\n==> %s\n' "$*"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

need_command git
need_command mix
need_command elixir

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "error: this script must be run from inside a git repository" >&2
  exit 2
fi
cd "$repo_root"

if [[ ! -f "mix.exs" ]]; then
  echo "error: mix.exs was not found at repository root: $repo_root" >&2
  exit 2
fi

if [[ "$allow_dirty" != "true" ]]; then
  if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "error: working tree is dirty; commit, stash, or pass --allow-dirty for dry-run experiments" >&2
    git status --short >&2
    exit 1
  fi
else
  echo "warning: --allow-dirty is enabled for this dry run; this is not suitable for an actual release" >&2
fi

required_public_files=(README.md CHANGELOG.md LICENSE.md)
for path in "${required_public_files[@]}"; do
  if [[ ! -s "$path" ]]; then
    echo "error: required public release file is missing or empty: $path" >&2
    exit 1
  fi
done

if grep -q 'TODO: write changelog' CHANGELOG.md; then
  echo "error: CHANGELOG.md still contains placeholder release text" >&2
  exit 1
fi

if grep -q 'github.com/TODO' mix.exs README.md CHANGELOG.md LICENSE.md 2>/dev/null; then
  echo "error: public metadata still contains github.com/TODO placeholder" >&2
  exit 1
fi

for extra in README.md CHANGELOG.md LICENSE.md; do
  if ! grep -q "\"$extra\"" mix.exs; then
    echo "error: mix.exs does not appear to include $extra in docs/package metadata" >&2
    exit 1
  fi
done

project_version() {
  local detected=""

  # Prefer simple static extraction first. This avoids invoking Mix before
  # dependencies are fetched and supports the common project form:
  #   @version "0.1.0"
  #   version: @version
  detected="$(sed -n 's/^[[:space:]]*@version[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1)"

  if [[ -z "$detected" ]]; then
    detected="$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1)"
  fi

  # Fall back to Mix for projects that compute the version dynamically.
  # Do not use mix eval --no-compile here: it is not accepted by every Mix
  # version supported by this repository.
  if [[ -z "$detected" ]]; then
    detected="$(mix eval --no-start 'IO.write(Mix.Project.config()[:version] || "")' 2>/dev/null || true)"
  fi

  printf '%s' "$detected"
}

project_package_name() {
  local detected=""

  detected="$(sed -n 's/^[[:space:]]*app:[[:space:]]*:\([A-Za-z0-9_]*\).*/\1/p' mix.exs | head -n 1)"

  if [[ -z "$detected" ]]; then
    detected="$(mix eval --no-start 'cfg = Mix.Project.config(); package = Keyword.get(cfg, :package, []); IO.write(to_string(Keyword.get(package, :name, Keyword.get(cfg, :app, ""))))' 2>/dev/null || true)"
  fi

  if [[ -z "$detected" ]]; then
    detected="sv_port_sim"
  fi

  printf '%s' "$detected"
}

version="$(project_version)"
if [[ -z "$version" ]]; then
  echo "error: could not determine project version from mix.exs" >&2
  echo 'hint: expected either @version "x.y.z", version: "x.y.z", or a Mix.Project.config()[:version] value' >&2
  exit 1
fi

if ! grep -q "v$version" CHANGELOG.md && ! grep -q "## $version" CHANGELOG.md; then
  echo "error: CHANGELOG.md does not appear to contain an entry for version $version" >&2
  exit 1
fi

package_name="$(project_package_name)"

branch="$(git rev-parse --abbrev-ref HEAD)"
commit="$(git rev-parse --short HEAD)"
verilator_image="${SV_PORT_SIM_VERILATOR_IMAGE:-verilator/verilator:latest}"

cat <<INFO
Release preflight
  repository:    $repo_root
  branch:        $branch
  commit:        $commit
  package:       $package_name
  version:       $version
  mode:          $mode
  target:        $publish_target
  Verilator:     $([[ "$skip_verilator" == "true" ]] && echo "skipped" || echo "enabled")
  image:         $verilator_image
INFO

step "Fetch dependencies"
run mix deps.get

step "Compile with warnings as errors"
run mix compile --warnings-as-errors --force

step "Run tests with warnings as errors"
run mix test --warnings-as-errors

if [[ "$skip_verilator" == "true" ]]; then
  step "Skip real Verilator workflow"
  echo "warning: Verilator preflight was skipped by --skip-verilator" >&2
else
  need_command docker
  step "Verify Docker availability"
  run docker version

  step "Run opt-in real Verilator workflow"
  run env SV_PORT_SIM_RUN_VERILATOR_TESTS=1 SV_PORT_SIM_VERILATOR_IMAGE="$verilator_image" mix test --warnings-as-errors
fi

step "Generate docs with warnings as errors"
run mix docs --warnings-as-errors

step "Run Hex dry-run"
case "$publish_target" in
  all)
    run mix hex.publish --dry-run
    ;;
  package)
    run mix hex.publish package --dry-run
    ;;
  docs)
    run mix hex.publish docs --dry-run
    ;;
  *)
    echo "error: internal invalid publish target: $publish_target" >&2
    exit 2
    ;;
esac

step "Build and unpack Hex package for inspection"
inspection_dir="$(mktemp -d "${TMPDIR:-/tmp}/sv_port_sim_hex_publish.XXXXXX")"
package_output="$inspection_dir/${package_name}-${version}"
run mix hex.build --unpack --output "$package_output"

for path in README.md CHANGELOG.md LICENSE.md mix.exs; do
  if [[ ! -e "$package_output/$path" ]]; then
    echo "error: unpacked Hex package is missing expected file: $path" >&2
    echo "inspection directory: $package_output" >&2
    exit 1
  fi
done

cat <<INSPECT

Hex package inspection directory:
  $package_output

Inspect this directory before publishing. For example:
  find "$package_output" -maxdepth 3 -type f | sort
INSPECT

if [[ "$mode" == "dry-run" ]]; then
  cat <<DRYRUN

Dry run complete. Nothing was published.
To publish this version, run one of:
  scripts/hex_publish.sh --publish
  scripts/hex_publish.sh --publish --package-only
  scripts/hex_publish.sh --publish --docs-only
DRYRUN
  exit 0
fi

if ! mix hex.user whoami >/dev/null 2>&1; then
  cat >&2 <<AUTH
error: Hex authentication was not found or failed.
Run one of the following on the maintainer machine, then retry:
  mix hex.user auth
  mix hex.user register
AUTH
  exit 1
fi

if [[ "$yes" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    echo "error: --publish requires an interactive terminal unless --yes is provided" >&2
    exit 1
  fi

  echo
  echo "About to publish $package_name version $version to Hex.pm."
  echo "This is a public release operation. Type the exact version to continue."
  read -r -p "version> " confirmation
  if [[ "$confirmation" != "$version" ]]; then
    echo "error: confirmation did not match version $version; aborting" >&2
    exit 1
  fi
fi

step "Publish to Hex.pm"
case "$publish_target" in
  all)
    if [[ "$yes" == "true" ]]; then
      run mix hex.publish --yes
    else
      run mix hex.publish
    fi
    ;;
  package)
    if [[ "$yes" == "true" ]]; then
      run mix hex.publish package --yes
    else
      run mix hex.publish package
    fi
    ;;
  docs)
    if [[ "$yes" == "true" ]]; then
      run mix hex.publish docs --yes
    else
      run mix hex.publish docs
    fi
    ;;
  *)
    echo "error: internal invalid publish target: $publish_target" >&2
    exit 2
    ;;
esac

cat <<DONE

Publish command completed.
Post-publish checks:
  1. Verify the package page and version on Hex.pm.
  2. Verify HexDocs rendered README.md, CHANGELOG.md, and LICENSE.md.
  3. Verify metadata links.
  4. Test the released package from a clean sample project.
DONE
