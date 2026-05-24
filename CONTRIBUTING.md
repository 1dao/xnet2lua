# Contributing

Thanks for helping improve xnet2lua. The project is intentionally small and portable, so contributions should keep build, test, and runtime behavior easy to verify on Linux, macOS, and Windows.

## Development Workflow

1. Open an issue or discussion for larger behavior changes before starting.
2. Keep pull requests focused on one topic: bug fix, feature, documentation, or test coverage.
3. Add or update tests for behavior changes.
4. Run the relevant local checks before opening a PR:

```sh
make test BUILD_MODE=debug WITH_HTTPS=0 WITH_RPMALLOC=0
# or: make -C tests test ROOT=.. BUILD_MODE=debug WITH_HTTPS=0 WITH_RPMALLOC=0
```

On Windows:

```bat
build.bat test norpmalloc nohttps debug
```

## Coding Style

- Keep C code C11-compatible and warning-clean under GCC/Clang/MSVC where practical.
- Prefer the existing module boundaries and naming style: `xpoll_*`, `xthread_*`, `xtimer_*`, etc.
- Include `xmacro.h` only after standard and third-party headers unless a project header explicitly needs allocation helpers.
- Use `XMACRO_USE_RPMALLOC=0` for sanitizer or leak-oriented test builds.
- Keep Lua modules small, table-returning, and easy to load with `dofile` from the embedded runner.
- Avoid broad refactors in bug-fix PRs.
- Add comments for non-obvious concurrency, lifetime, or platform-specific behavior.

## Commit Guidelines

Commit subjects follow a Conventional Commits-style shape:

```
<type>(<scope>): <description>
```

- **type** (required, lowercase). The repo mostly uses `feat`, `fix`, `refactor`, and `perf`. Other Conventional Commit types (`docs`, `test`, `chore`, `build`, `ci`) are accepted but uncommon.
- **scope** (optional but encouraged). The affected module(s) as they appear in source: `xthread`, `xnet`, `xhttp`, `xtimer`, `xpoll`, `xchannel`, `xdebug`, `log`, `build`, `reload`, etc. Multiple scopes are comma-separated with no space: `feat(reload,xnats,xadmin): ...`. Omit the scope only when the change is genuinely project-wide.
- **description**. Imperative mood, no trailing period. Keep it focused on the user- or runtime-visible change.
- **body** (optional, after a blank line). Use it for non-trivial changes to explain *why* — the diff already shows the *what*.

Examples from history:

- `feat(xtimer): firing-time-safe destroy + xtimerx reload wrapper`
- `fix(xdebug): stabilize breakpoint sync and force resume on disconnect`
- `refactor(xpoll): unify fd registry with xhash for all backends`
- `perf(xchannel): xBuffer struct + scatter-gather direct send`
- `feat(reload,xnats,xadmin): cross-process hot-reload via NATS RPC`
- `feat: using rpmalloc`

Other guidelines:

- Keep generated binaries and local build outputs (`bin/`, `obj/`, `*.gcov`, `coverage/`, `*.exe`, `*.a`) out of commits.
- Prefer focused commits over mega-commits — see "Keep pull requests focused on one topic" in the workflow section.

## Pull Request Checklist

- Describe the user-visible behavior change.
- Link any related issue.
- Include build/test output or explain why a check was skipped.
- Update `README.md`, `xnet2lua-docs-cn.md`, or `xnet2lua-docs-en.md` when behavior or usage changes.
- Note any platform limitations, especially Windows/MSYS2/MSVC differences.

## Tests

The repository uses a lightweight in-tree C xUnit harness and Lua Busted-style spec helper so contributors do not need external test packages for the default suite. Test orchestration lives in `tests/Makefile`; the root `Makefile` only keeps forwarding shortcuts. New tests should go under:

- `tests/c/` for C unit coverage.
- `tests/lua/` for Lua module specs.
- `demo/` for end-to-end examples that also serve as regression scripts.

Run `make unit` for the focused unit layer and `make test` before submitting a PR. The direct equivalents are `make -C tests unit ROOT=..` and `make -C tests test ROOT=..`. For C changes, `make coverage-c` can be used as a quick `gcov` check for the current unit suite.

CI also compiles a release configuration with `WITH_HTTPS=1 WITH_RPMALLOC=1`, runs `make unit`, and runs C coverage on the Ubuntu debug lane, so changes touching TLS, allocation, timers, logging, polling, or HTTP parsing should keep both the fast regression path and the feature-enabled build path healthy.
