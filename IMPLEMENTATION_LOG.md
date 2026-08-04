# llama-server backend implementation log

## P0 baseline (2026-08-04)

- Start revision: `35538762ae531187e151f00fddc2814f9335aa97`
- Upstream state: `main` matched `origin/main` after `git fetch origin` (`0` ahead, `0` behind).
- Work branch: `feat/llama-server-backend`
- Existing worktree change before implementation: untracked `PLAN.md`
- Required files listed in `PLAN.md` section 4.1 were present.
- `sh scripts/test.sh`: passed, 178 tests.
- `nvim --headless -u NONE -c "helptags doc" -c "qa!"`: passed with Neovim 0.12.4.
- StyLua 2.5.2 and Luacheck were not available on the local `PATH`; their baseline checks could not run. The CI workflow remains the authoritative version-pinned check, and both checks must run before completion.

The P0 code review covered the TranslationService backend contract and retry lifecycle, Codex backend lifecycle and cancellation, codec request normalization, configuration merge and validation, standard registry composition, Session-level configuration merging, and Neovim runtime injection.

## P1 shared translation prerequisites (2026-08-04)

- The format-retry regression test failed before the field-name fix and passed after `system_instructions` was used consistently.
- The Schema capability matrix failed before `schema_in_prompt` support and passed after request normalization was updated.
- The input limit test confirms that the complete prompt, including its Schema, is measured.
- The Codex backend now reports `schema_in_prompt = false`, preserving its existing request payload.
- `sh scripts/test.sh`: passed, 180 tests.

## P2 backend-specific configuration (2026-08-04)

- The new configuration tests first exposed the missing `translation.backends` defaults, selection, legacy overlay, custom-backend namespace, and deep-copy isolation behavior.
- Codex-specific invalid-option cases were moved from generic configuration tests to the concrete backend. They now return `E_BACKEND_INIT` from `open()` without acquiring a process, timer, or temporary directory; missing injected dependencies remain constructor errors.
- Session overrides replace nested Codex and llama command lists, as well as both legacy command lists, atomically.
- The registry resolver test failed while the Codex factory still read the compatibility mirror. The shared resolver now copies only `translation.backends[backend_id]`, applies global timeout and ring size, and injects runtime values without overwriting user values.
- Configuration keeps only generic backend namespace validation. The default backend, Codex model, and reasoning effort remain unchanged, while the llama and custom backend option namespaces remain independent.
- Added integer-boundary coverage for fractional Codex request and shutdown timeouts.
- `sh scripts/test.sh`: passed, 186 tests.
- `git diff --check`: passed.

## P3 curl HTTP transport (2026-08-04)

- The first GET contract test failed because the transport module did not exist, then passed with deterministic argv construction, loopback proxy bypass, scheduled response parsing, split status-marker handling, multiline body support, and CRLF normalization.
- Independent Red/Green cycles covered POST stdin delivery, header/request validation, curl exit-code mapping, stdout size enforcement, stderr truncation, and the default 64 KiB stderr limit.
- The transport accepts only GET and POST, never enables redirects, sorts header names, rejects CR/LF injection, passes request bodies only through stdin, and starts the injected process in text mode.
- curl exit 28 maps to `timeout`; 6, 7, 52, 55, and 56 map to `network`; other non-zero exits map to `io`. HTTP 4xx and 5xx remain successful transport responses.
- Oversized stdout kills the child and returns `protocol` after exit. Diagnostic stderr is byte-limited and is never interpolated into transport error messages.
- Cancellation is idempotent, kills active work once, and suppresses scheduled or late callbacks. Duplicate process exits still produce exactly one callback.
- `tests/fakes/system_process.lua` provides all subprocess behavior; the unit suite uses neither a curl binary nor network access.
- Static inspection confirms the transport has no Bilingua domain-error dependency, direct Neovim global, logger, or redirect option.
- `sh scripts/test.sh`: passed, 198 tests.
- `git diff --check`: passed.

## P4 llama-server backend (2026-08-04)

- The official `ggml-org/llama.cpp` server source and GBNF guide were checked before implementation and again during live verification. They confirm public `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`, the nested `response_format.json_schema.schema` field, and grammar support for the `const`, `enum`, `minItems`, and `maxItems` constraints used here.
- P4-1 began Red because the backend module was absent. Loopback endpoint normalization, backend-owned option validation, runtime dependency failures, and the full capability matrix then passed.
- P4-2 began Red with no health request or timer. The backend now polls 503 responses, enforces one overall timeout across health/poll/model discovery, filters usable model IDs, supports explicit routing, and settles open exactly once under late callbacks.
- P4-3 began Red with no `request()` method. Chat payload tests cover system/user ordering, selected model, non-streaming mode, Schema and prompt-only modes, both thinking controls, timeout precedence, absence of tool fields, encode failures, and idempotent cancellation.
- P4-4 replaced the intentional placeholder response parser. It now validates the Chat Completions envelope, rejects truncation and tool calls, maps every specified HTTP/curl failure, and retains only bounded allowlisted server error details.
- P4-5 began Red with no `close()` method. Close now queues callbacks, cancels every open/chat resource, distinguishes backend close from prior caller cancellation, retains the selected model for status, and never sends an external shutdown request.
- The adversarial fake transport permits duplicate and late callbacks; all open, request, cancellation, and close paths prove exactly-once delivery or intentional suppression.
- Static inspection confirms no direct Neovim global, Authorization header, logger, shutdown endpoint, or tool request field in the backend.
- `tests/unit/llama_server_spec.lua`: passed, 22 tests with zero active fake requests or timers at completion points.
- `sh scripts/test.sh`: passed, 220 tests.
- `git diff --check`: passed.

## P5 registry and service integration (2026-08-04)

- The registry test began Red because the `llama_server` factory was absent. Standard registration now loads both built-in backends through the shared backend-specific option resolver while the default remains `codex_app_server`.
- Registry composition proves that Codex and llama option namespaces stay separate, runtime functions reach the production curl transport by identity, construction starts no process or timer, and repeated registration remains idempotent.
- `tests/integration/llama_translation_service_spec.lua` composes the standard `TranslationService`, both existing JSON v1 codecs, and the real llama backend with only its HTTP transport replaced by a fake.
- Integration flows cover initial translation, target-to-source semantic patching, one format-correction retry after malformed JSON content, handle cancellation, and service close with duplicate or late HTTP callbacks.
- Captured requests prove that JSON Schema is present in both the llama API parameter and codec prompt, protected placeholders and unit correspondence survive decoding, and no llama-specific codec is needed.
- Every integration flow closes with zero active fake HTTP requests, backend timers, and retry delays; cancellation never calls a terminal task callback or a server shutdown endpoint.
- `sh scripts/test.sh`: passed, 225 tests.
- `git diff --check`: passed for tracked changes; the new integration file is also whitespace-clean under a no-index check.

## P6 live verification, documentation, and final review (2026-08-04)

- Added the service-level `scripts/live_llama_test.lua` and the public-command `scripts/live_llama_session_test.lua`, with executable wrappers for both. Every wrapper requires `BILINGUA_RUN_LIVE_LLAMA=1`; none downloads or starts a server or model.
- The service flow uses the production registry, TranslationService, llama backend, curl transport, and existing codecs. It checks one initial translation, one semantic patch, one protected placeholder, bounded timeouts, backend cleanup, and post-close health without printing response content or the resolved model ID.
- The Session flow uses `:BilinguaStart`, `:BilinguaStatus`, source-to-target and target-to-source `:BilinguaSync`, and `:BilinguaStop!` during an active request. It validates actual destination changes, URL and inline-code preservation, source-buffer retention, target cleanup, and server health.
- The first live response omitted the required `warnings` field. A Red/Green integration case now allows exactly one format retry for missing required object fields, while protected-placeholder failures remain non-retryable; the correction explicitly requires empty arrays for required array fields with no values.
- The running server ignored the plan's flat `response_format.schema` form. Current official server source reads `response_format.json_schema.schema`, so the backend now sends that nested OpenAI-compatible shape with a name and `strict = true`. Unit, integration, and live checks all cover the corrected form.
- During command smoke testing, the selected local model first returned an unchanged patch and then invented edited-unit IDs. The semantic instruction now requires changed meaning and exact IDs, while the task-specific response Schema constrains `task_id`, destination side, and edited IDs with supported grammar keywords. Duplicate correspondence remains enforced by the decoder because llama.cpp documents `uniqueItems` as unsupported.
- With `BILINGUA_LLAMA_SERVER_MODEL=lfm25-jp`, the final service live run passed: open 12 ms, initial translation 3603 ms, semantic patch 5457 ms, cleanup OK, server alive. Content and the resolved model field remained omitted from program output.
- The final Session live run passed: initial translation 3636 ms, source-to-target sync 5279 ms, target-to-source sync 6242 ms, active-request cancel 0 ms, protected literals/status/cleanup OK, server alive.
- After force stop, filtered process inspection found zero curl processes; the external server still returned HTTP 200; the health probe also left zero curl processes.
- README and Vim help now document backend selection, backend-specific and legacy options, prerequisites, launch/config examples, structured-output modes, thinking control, lifecycle ownership, troubleshooting, privacy, current nested API shape, and both live commands. CI formats and lints both llama live Lua scripts.
- `sh scripts/test.sh`: passed, 228 tests.
- StyLua 2.5.2 `--check`: passed for every CI target.
- Luacheck v1.2.0: passed with 0 warnings and 0 errors in 126 files. Lua 5.1, argparse, and LuaFileSystem were unpacked only under `/tmp` because no local Lua/Luacheck executable was installed.
- `nvim --headless -u NONE -c "helptags doc" -c "qa!"`: passed twice with Neovim 0.12.4; the generated hash was stable and no duplicate tags were found.
- Both llama live wrappers reject missing opt-in with exit 2. Shell syntax checks passed.

## PR description draft

### Changes

- Add an externally managed, loopback-only llama.cpp `llama-server` backend over a bounded curl subprocess transport.
- Reuse the existing initial-translation and semantic-patch codecs, including JSON Schema in both the llama API constraint and prompt.
- Introduce backend-specific configuration with a legacy `translation.backend_options` compatibility overlay.
- Preserve the Codex default while moving Codex-specific validation into its backend and fixing format-retry instruction handling.
- Add fake-only unit/integration coverage, service-level and public-command opt-in live tests, CI coverage, README guidance, and Vim help.

### Non-goals

- No llama-server/model lifecycle management, remote/TLS/auth/proxy support, streaming, tools, multimodal input, provider-general abstraction, or automatic Codex fallback.

### Compatibility

- `codex_app_server` remains the default with the same model, reasoning effort, and strict-isolation defaults.
- Legacy `translation.backend_options` remains supported and has final precedence for the selected backend.
- Custom backend namespaces remain generic, no external Lua dependency is added, and production process integration uses the existing Neovim 0.10-compatible `vim.system` runtime port.

### Verification and manual status

- Automated: 228 tests; StyLua 2.5.2; Luacheck v1.2.0 with 0 warnings/errors in 126 files; idempotent Vim helptags without duplicates; shell syntax; whitespace checks.
- Live service: actual initial translation and semantic patch passed through the production service/backend/transport/codecs with `lfm25-jp`; backend cleanup and post-close health passed.
- Manual smoke: all 12 plan items passed through public Ex commands, including bidirectional sync, protected literals, resolved-model status, active-request force stop, zero residual curl processes, and HTTP 200 server health afterward.

## Definition of Done evidence audit

| Requirement | Authoritative evidence | Status |
|---|---|---|
| Existing Codex behavior and configuration remain compatible | Default/config/registry/Codex payload and lifecycle regression tests | Verified |
| Loopback llama-server connection | Production service and Session live runs against `127.0.0.1:8080` | Verified with generation |
| Health 503 polling and overall timeout | Backend fake-transport polling, recovery, timeout, and cleanup tests | Verified |
| `model = "auto"` resolution | Zero/one/multiple/explicit unit cases; actual server exposed two valid IDs and therefore requires explicit selection | Verified |
| Initial and semantic-patch Chat Completions | Integration suite plus service and bidirectional Session live runs | Verified with generation |
| JSON Schema in API and prompt | Capability matrix, captured nested payloads, task-specific semantic constraints, and live runs | Verified |
| Thinking disabled by default | Default config and exact payload tests for both controls | Verified |
| HTTP/JSON/API/cancel/timeout error normalization | Transport and backend mapping/envelope/cancel tests | Verified |
| Stop/restart resource cleanup | Automated lifecycle tests plus active-request `:BilinguaStop!` and zero residual curl processes | Verified |
| Backend close does not stop llama-server | No-shutdown tests plus HTTP 200 health after service close and Session force stop | Verified |
| Ordinary tests require no model/network | Fake process/HTTP boundary and successful offline test suite | Verified |
| Opt-in live initial translation and patch | Guarded service and Session scripts executed with `lfm25-jp`, cleanup and post-close health validated | Verified |
| README and Vim help | Required settings/examples/constraints/remedies/tags plus idempotent `helptags` | Verified |
| Full automated quality gates | 228 tests, StyLua 2.5.2, Luacheck 0/0 in 126 files, helptags, shell and whitespace checks | Verified |
