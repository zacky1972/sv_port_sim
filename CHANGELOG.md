# Changelog

All notable changes to this project will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

## v0.2.0 - 2026-06-09

### Added

- Added `SvPortSim.Compiler.lint/3` and `mode: :lint_only` for faster generated RTL validation through Verilator `--lint-only` without requiring a runnable executable.
- Added content-addressed compiler caching for repeated identical build and lint jobs with `cache: true` and `cache_dir:` options.
- Added opt-in persistent Docker worker support via `docker_mode: :persistent` and `SvPortSim.Verilator.DockerWorker` to reuse a long-running Verilator container across jobs.
- Added Docker backend tests with fake Docker scripts covering lint-only mode, structured lint failures, cache hits/misses, cache invalidation, and persistent worker reuse.

### Changed

- Kept `SvPortSim.Compiler.compile/3` backwards compatible by preserving executable-producing `mode: :build` as the default.
- Generalized the Docker Verilator backend around build and lint modes while keeping `compile_executable/4` as the build-mode compatibility entrypoint.
- Documented build vs lint-only validation, cache behavior, run-once vs persistent Docker execution, and the Docker backend tradeoff relative to a possible future local Verilator backend.

## v0.1.0 - 2026-06-07

Initial public Hex.pm release.

### Added

- Public `SvPortSim` runtime API for starting, driving, reading, and stopping one Verilated simulator instance from Elixir.
- Length-prefixed JSON protocol support for wrapper executables.
- `SvPortSim.SignalSpec` metadata for scalar and packed-vector `bit` / `logic` top-level ports.
- SystemVerilog source-map expansion and Verilator wrapper generation.
- Docker-based Verilator compile path via `SvPortSim.Compiler.compile/3`.
- Runtime operations for `reset`, `tick`, `poke`, `peek`, metadata, and shutdown.
- Tests for wrapper generation, protocol framing, runtime error handling, and the generated RTL compile-and-run workflow.
- Opt-in real Verilator test workflow controlled by `SV_PORT_SIM_RUN_VERILATOR_TESTS=1`.

### Fixed

- Elixir 1.20 / OTP 29 warning regressions in compile and test paths.
- Generated wrapper assignments for Verilator top-level ports to avoid casting into reference port types.
- Generated wrapper reset response helper names and duplicated clock detail helper generation.

### Documentation

- Added README coverage for the generated RTL compile-and-run workflow.
- Added a Hex.pm publish runbook and local publish helper script.
