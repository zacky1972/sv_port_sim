# Changelog

All notable changes to this project will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

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
