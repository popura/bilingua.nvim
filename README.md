# Bilingua.nvim

Bilingua.nvim は、Neovim で原文（source）と日本語訳（target）を同時に編集したい利用者向けに、Codex app-server または利用者が管理する local llama-server による初期翻訳と双方向同期を一つの編集画面へまとめるプラグインです。既定 backend は Codex のままです。

[![継続的インテグレーション（CI）](https://github.com/popura/bilingua.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/popura/bilingua.nvim/actions/workflows/ci.yml)
![Neovim 0.10 以上](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)
![Codex command-line interface（CLI）0.146.0 以上](https://img.shields.io/badge/Codex_CLI-0.146.0%2B-111111)
![開発ステータス: Minimum Viable Product（MVP）](https://img.shields.io/badge/status-MVP-orange)
[![ライセンス: Apache License 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

## デモ

次の例は、英語の `README.md` を日本語 target と並べ、現在位置の編集を同期して Session を終了する最小操作です。Session は、一組の source／target buffer、対応関係、同期 task、backend のライフサイクルを管理する実行単位です。既定の Codex backend を使う場合は、送信する文書内容と利用料金を実行前に確認してください。

```sh
cd /path/to/your/project
nvim README.md
```

Neovim で次を実行します。

```vim
:BilinguaStart en
" source または target を編集する
:BilinguaSync
:BilinguaStop
```

`:BilinguaStart` は target scratch buffer を開いて初期翻訳を開始します。`:BilinguaSync` は cursor 下の対応箇所を同期し、`:BilinguaStop` は source buffer を残して Session の資源を解放します。

## 主な機能

- **双方向同期**: source から target、target から source の両方向へ編集を反映します。
- **構造を考慮した文書処理**: unit（構文と範囲に基づく最小追跡単位）を抽出し、mapping group（source unit 群と target unit 群の対応集合）ごとに同期します。
- **Plaintext／Markdown 対応**: 段落、見出し、list item、blockquote paragraph を翻訳します。code block、table、数式などは opaque unit（inference backend を経由して raw text を保持する unit）として扱い、raw text を反対側へ複製する mirror を行います。
- **protected token 検証**: URL、inline code、placeholder、link destination などを一時 placeholder 化し、model output を完全一致で検証して復元します。
- **手動 conflict 解決**: 両側編集や曖昧な対応を conflict として表示し、利用者が source または target を正として選択します。
- **二つの標準 backend**: 既定の Codex app-server と、loopback 上で利用者が運用する local llama-server を選べます。
- **厳格な Codex 実行分離**: ephemeral thread、隔離用一時 directory、permission profile、network off、空の environments、tool item の中断を組み合わせます。
- **一時的な target**: target は scratch buffer として動作し、Session 終了時に buffer、window、task と plugin 所有の backend 資源を解放します。外部 llama-server process は停止しません。
- **状態表示と復旧**: sign／virtual text、`:BilinguaStatus`、`:BilinguaRetry`、`:BilinguaRestartBackend` で状態確認と復旧を行います。

## 動作要件

| 項目 | 要件 |
|---|---|
| Neovim | 0.10 以上 |
| Codex backend | Codex CLI 0.146.0 以上、`codex login` で利用可能な認証、text input 対応 model |
| Codex model／reasoning effort | 既定は `gpt-5.6-luna`／`max` |
| llama-server backend | `curl`、外部で起動した llama-server、対応 chat template を持つ instruct model |
| Lua runtime | Neovim 同梱 runtime |
| 外部 Lua dependency | なし |
| Plugin manager | Dein.vim |
| OS | <要確認: 対応 OS と検証済み環境> |

既定の Codex backend の準備状況を確認します。`<CODEX_CREDENTIAL>` は説明用の認証情報 placeholder であり、実際の認証値は Codex CLI の対話画面へ入力します。

```sh
nvim --version
codex --version
codex login
codex login status
codex app-server --help
```

`nvim --version` が `NVIM v0.10` 以上、`codex --version` が `codex-cli 0.146.0` 以上を示し、`codex login status` が終了 status 0 を返す状態が利用開始の目安です。

## インストール

### Dein.vim

Neovim の `init.vim` で、`dein#begin()` と `dein#end()` の間に公開 repository を登録します。

```vim
call dein#add('popura/bilingua.nvim')
```

Neovim で Dein.vim の install function を実行します。

```vim
:call dein#install()
```

Bilingua.nvim の command は文書化された既定設定を使用し、`setup(opts)` は利用者設定を既定値へ重ねます。Dein.vim 自体の導入方法は [Dein.vim 公式 repository](https://github.com/Shougo/dein.vim) を参照してください。

## Quick start

### 前提

この Quick start は、Dein.vim で Bilingua.nvim を導入し、一時 directory の文書を翻訳する構成です。

| 項目 | この手順で使う値 |
|---|---|
| Neovim | 0.10 以上 |
| Codex CLI | 0.146.0 以上 |
| Package manager | Dein.vim |
| Install 設定 | Neovim の `init.vim` にある Dein.vim 初期化 block |
| Demo の実行 directory | `mktemp -d` が作る一時 directory |
| 必須環境変数 | なし |
| Codex 認証 | `codex login` |

### 手順

1. `init.vim` の `dein#begin()` と `dein#end()` の間へ plugin を登録します。

   ```vim
   call dein#add('popura/bilingua.nvim')
   ```

2. Neovim で plugin を install します。

   ```vim
   :call dein#install()
   ```

3. shell で Codex 認証を完了します。

   ```sh
   codex login
   codex login status
   ```

4. 実ファイルを持つ再現用 directory を作り、Neovim を起動します。

   ```sh
   bilingua_demo_dir=$(mktemp -d)
   printf 'Hello, world.\n\nThis file is a Bilingua.nvim demo.\n' > "$bilingua_demo_dir/source.txt"
   cd "$bilingua_demo_dir"
   nvim source.txt
   ```

5. Neovim で初期翻訳を開始します。

   ```vim
   :BilinguaStart en
   ```

6. source または target を編集し、現在の mapping group を同期して Session を終了します。

   ```vim
   :BilinguaSync
   :BilinguaStop
   ```

### 成功時の表示

- Neovim は source と `bilingua://ja/{buffer}/{name}` 形式の target scratch buffer を並べます。
- 初期翻訳中は target の先頭に `Translating completed/total…` を表示します。
- 同期済みの mapping group は `✓` を表示します。
- `:BilinguaStop` は source buffer を画面に残し、Bilingua.nvim が所有する資源を解放します。

## 使用方法

### コマンド

| コマンド | 動作 |
|---|---|
| `:BilinguaStart [source-language]` | 現在の source buffer で Session を開始します。 |
| `:BilinguaStart! [source-language]` | 未同期 target 編集と conflict を破棄して現在の Session を強制終了し、同じ source buffer で新しい Session を開始します。 |
| `:BilinguaToggle` | source と target の表示／focus を切り替えます。 |
| `:BilinguaSync` | cursor 下の mapping group を直ちに同期します。 |
| `:BilinguaSyncAll` | conflict を保持しながら dirty／invalid mapping group をまとめて同期します。 |
| `:BilinguaUseSource` | conflict で source を正として target を更新します。 |
| `:BilinguaUseJapanese` | conflict で target を正として source を更新します。 |
| `:BilinguaNext` / `:BilinguaPrev` | 次／前の mapping group へ移動します。 |
| `:BilinguaStatus` | Session metadata、health（backend の稼働状態）、model、state 別 group 数を表示します。 |
| `:BilinguaRetry` | 現在の mapping group、または直前の開始処理を再試行します。 |
| `:BilinguaRestartBackend` | backend を再起動し、document state を保って自動同期を再開します。 |
| `:BilinguaStop` | `stop.sync_pending` に従って target 編集を source へ同期し、source buffer を残して Session を終了します。 |
| `:BilinguaStop!` | active task を cancel し、未同期 target 編集と conflict を破棄して Session を強制終了します。source buffer は残ります。 |
| `:BilinguaQuit` | 正常停止後、Neovim 標準の確認付きで source buffer を閉じます。 |
| `:BilinguaQuit!` | Session と source buffer を強制削除し、保存前の source 編集を破棄します。 |

### 既定 mapping

`start` は global mapping、その他は Session の source／target buffer に属する buffer-local mapping です。

| Mapping | 操作 |
|---|---|
| `<leader>bs` | Start |
| `<leader>bb` | Toggle |
| `<leader>by` | Sync |
| `<leader>ba` | SyncAll |
| `<leader>bo` | UseSource |
| `<leader>bj` | UseJapanese |
| `]b` / `[b` | Next / Prev |
| `<leader>bq` | Stop |
| `<leader>bQ` | Quit |

`Status`、`Retry`、`RestartBackend` は Ex command または対応する `<Plug>(Bilingua...)` mapping から実行します。force Quit は `:BilinguaQuit!` から実行します。各既定 mapping は設定値 `false` で個別に切り替えられます。

### 状態表示

| 表示 | State | 意味 |
|---|---|---|
| `✓` | `clean` | baseline（最後に同期した source／target と対応 metadata）と一致 |
| `S` | `dirty_source` | source の同期が必要 |
| `J` | `dirty_target` | target の同期が必要 |
| `…` | `syncing_*` | 同期 task を実行中 |
| `!` | `conflict` | 利用者による方向選択が必要 |
| `×` | `invalid` | parse／result／apply の再確認が必要 |

### Lua API と User event

```lua
local bilingua = require("bilingua")

bilingua.setup(opts)
bilingua.start(opts, callback)
bilingua.toggle()
bilingua.sync_current()
bilingua.sync_all()
bilingua.use_source()
bilingua.use_japanese()
bilingua.next_group()
bilingua.prev_group()
bilingua.retry_current(callback)
bilingua.restart_backend(callback)
bilingua.stop({ force = false }, callback)
bilingua.quit({ force = false }, callback)
bilingua.status()
```

`start`、`retry_current`、`restart_backend`、`stop`、`quit` は callback で非同期完了を通知します。`status()` は Session metadata と状態のコピーを返します。

User event は `BilinguaSessionStarted`、`BilinguaSessionStopped`、`BilinguaSyncStarted`、`BilinguaSyncCompleted`、`BilinguaConflict`、`BilinguaError` です。`event.data` は `session_id`、`group_id`、`task_id`、`state`、`error_code` に限定されます。

拡張 API の version は 1 です。document adapter、unit tracker、aligner、translation backend、task codec、translation service は `require("bilingua.registry")` から登録できます。

完全な command、API、error code、文書処理のリファレンスは [Neovim help](doc/bilingua.txt) を参照してください。内部構造と extension contract は [実装仕様](bilingua-nvim-implementation-spec.md)、用語の定義は [用語集](TERMS.md) にあります。

## 設定

次は頻繁に調整する設定を含む最小例です。

```lua
require("bilingua").setup({
  source_language = "auto",
  target_language = "ja",
  layout = {
    direction = "vertical",
    target_position = "right",
    size = 0.5,
  },
  sync = {
    automatic = true,
    debounce_ms = 700,
  },
  translation = {
    backend = "codex_app_server",
    backends = {
      codex_app_server = {
        model = "gpt-5.6-luna",
        reasoning_effort = "max",
        strict_isolation = true,
        experimental_api = true,
      },
    },
  },
})
```

### Local llama-server backend

Bilingua.nvim には `codex_app_server` と `llama_server` の二つの標準 backend があります。既定は `codex_app_server` です。llama-server を使う場合、Bilingua.nvim は server や model を download／起動せず、利用者が外部で管理している process へ `curl` で接続します。

実行には `curl`、llama-server、および対応 chat template を持つ instruct model が必要です。次の例では、model 固有の GPU option や context size を指定していません。

```sh
llama-server \
  -m /path/to/model.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  --alias local-translator
```

Neovim 側で backend を選択します。

```lua
require("bilingua").setup({
  translation = {
    backend = "llama_server",
    backends = {
      llama_server = {
        endpoint = "http://127.0.0.1:8080",
        model = "auto",
        structured_output = "json_schema",
        disable_thinking = true,
      },
    },
  },
})
```

- `endpoint` は `http` の loopback host（`127.0.0.1`、`localhost`、`[::1]`）だけを受理します。remote host、TLS、認証 header、redirect には対応しません。
- `model = "auto"` は `/v1/models` に有効な model ID がちょうど一つある場合だけ、その ID を採用します。複数 model を公開する server では ID を明示してください。
- `structured_output = "json_schema"` は Schema を llama.cpp の `response_format` と prompt の両方へ渡します。server または model が拒否する場合、`"prompt_only"` は API parameter を省略して Schema を prompt だけへ含めます。
- `disable_thinking = true` は既定値です。`reasoning_effort = "none"` と `chat_template_kwargs.enable_thinking = false` を request に加えます。実際の挙動は model の chat template にも依存します。
- `:BilinguaStop` と `:BilinguaStop!` は active curl request と timer を解放しますが、利用者所有の llama-server process は停止しません。

構造化出力は OpenAI-compatible な nested 形式 `response_format.json_schema.schema` を使用します。2026-08-04 時点の [llama.cpp server source](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/server-common.cpp) と [GBNF guide](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md) を照合し、実際の loopback server でも確認しています。llama.cpp の更新で API や chat template の挙動が変わる可能性があります。

| 症状 | 確認事項 |
|---|---|
| connection refused | llama-server process、`--host`、`--port`、`endpoint` |
| health 503 | model loading の完了、`open_timeout_ms` |
| model auto resolution failure | `/v1/models` の ID 数、明示的な `model` |
| JSON Schema rejection | llama.cpp version、`structured_output = "prompt_only"` |
| JSON 前に reasoning が出る | `disable_thinking`、model の chat template |
| response truncated | model context、server の prediction limit、task batch size |
| placeholder mismatch | model 能力、prompt、task size |

local 実行でも、model の license と利用条件、文書内の機密情報、CPU／GPU／memory などの hardware resource は利用者が管理してください。Bilingua.nvim は server 側の request log、cache、model telemetry を制御しません。

### 主要設定

| 設定 | 既定値 | 用途 |
|---|---|---|
| `source_language` | `"auto"` | source language の自動検出または固定値 |
| `target_language` | `"ja"` | target language |
| `layout.direction` | `"vertical"` | vertical／horizontal layout |
| `layout.target_position` | `"right"` | target window の位置 |
| `layout.size` | `0.5` | target window の比率または固定 size |
| `layout.follow_cursor` | `true` | 対応する mapping group の表示追従 |
| `sync.automatic` | `true` | 編集後の自動同期 |
| `sync.debounce_ms` | `700` | 自動同期までの待機時間 |
| `sync.on_insert_leave` | `true` | InsertLeave 時の同期開始 |
| `sync.max_concurrency` | `1` | 同時に実行する異なる mapping group 数 |
| `sync.context_groups` | `1` | task に含める前後の bilingual context |
| `sync.structural_changes` | `"auto_safe"` | 構造編集の処理方針 |
| `sync.conflict_policy` | `"manual"` | conflict の解決方針 |
| `stop.sync_pending` | `true` | 正常停止時の target-to-source 同期 |
| `translation.backend` | `"codex_app_server"` | inference backend |
| `translation.backends.codex_app_server.model` | `"gpt-5.6-luna"` | Codex model |
| `translation.backends.codex_app_server.reasoning_effort` | `"max"` | Codex reasoning effort |
| `translation.backends.codex_app_server.strict_isolation` | `true` | Codex 実行分離 |
| `documents.fallback_to_plaintext` | `true` | route 解決時の Plaintext fallback |
| `ui.notify_backend` | `true` | 正規化済み backend error の通知 |
| `ui.show_progress` | `true` | 初期翻訳 batch の進捗表示 |

### 既定上限

| 設定 | 既定値 |
|---|---:|
| `limits.max_document_bytes` | 2 MiB |
| `limits.max_units` | 2,000 |
| `limits.max_task_input_chars` | 24,000 |
| `limits.max_task_output_chars` | 24,000 |
| `limits.initial_batch_chars` | 12,000 |
| `limits.initial_batch_units` | 32 |

### 環境変数

| 変数 | 必須性 | 用途 | 例 |
|---|---|---|---|
| `CODEX_HOME` | 任意 | Codex user-level 設定 directory を指定する | `/home/user/.codex` |

完全な既定設定、型、値域、動的 extension key は [`:help bilingua-configuration`](doc/bilingua.txt) を参照してください。設定 resolver は未知 key を警告し、型・値域の違反を `E_INVALID_ARGUMENT` として返します。

## Limitations

- 開発ステータスは Minimum Viable Product（MVP）です。
- 標準の文書処理は Plaintext と Markdown を対象とし、登録外 filetype は Plaintext へ fallback します。
- Markdown Adapter は完全な CommonMark 実装ではありません。構造を安全に保持できない編集、曖昧な対応、未閉鎖の opaque block は conflict または invalid になります。
- target buffer は `nofile`／`noswapfile`／persistent undo off の scratch buffer であり、訳文 file、sidecar、cache、database、transcript、resume state を保存しません。
- `persistence.enabled = true` と `debug.log_payloads = true` は `E_INVALID_ARGUMENT` になります。`sync.conflict_policy` は `"manual"` だけを受理します。
- conflict の自動 merge は行いません。`:BilinguaUseSource` または `:BilinguaUseJapanese` で正しい側を選択します。
- 単一 unit は初期 batch 境界で分割されません。`limits.initial_batch_chars` を超える unit は `E_DOCUMENT_TOO_LARGE` になります。
- Markdown Tree-sitter parser または同梱 query が利用できない場合、`fallback_to_plaintext = true` は Plaintext を使い、`false` は `E_PARSE` になります。
- `strict_isolation = true` は Codex experimental permission profile API を必要とし、`experimental_api = false` と併用できません。
- `strict_isolation = false` は Codex 標準 `readOnly` sandbox を使い、隔離用一時 directory 外も読み取り対象になります。
- `approvalPolicy = "never"` 単独は tool-disable option ではありません。完全な OS process 実行禁止が必要な環境では、Codex app-server process を外部 sandbox へ収容してください。
- Codex app-server は選択 model に応じて document content を外部 OpenAI service へ送信する場合があります。Bilingua.nvim の non-persistence は provider の retention、logging、cache を保証しません。
- Codex home の `AGENTS.override.md`／`AGENTS.md` は model instruction に影響する場合があります。利用者は内容を確認してください。
- 既定の `gpt-5.6-luna`／`max` は推論時間と token 使用量を増やす場合があります。
- llama-server backend は loopback HTTP 専用です。remote endpoint、TLS、認証、server process の起動／停止を扱いません。
- llama.cpp version、model 能力、chat template により Schema 制約や翻訳品質が変わります。
- Codex／llama の live test は通常 CI に含まれません。
- 対応 OS と OS ごとの検証状況は `<要確認: 対応 OS と検証済み環境>` です。

## 開発手順

### 開発環境

repository root を作業 directory として使います。通常 test は fake app-server と local fixture を使います。

| Tool | 用途 |
|---|---|
| Neovim 0.10 以上 | unit／contract／integration test |
| StyLua 2.5.2 | format check |
| Luacheck | lint |
| Codex CLI 0.146.0 以上 | Codex schema check と opt-in live test |
| curl | llama-server HTTP transport と opt-in live test |
| llama-server | 利用者が起動した local live-test server |
| 開発用 package manager | <要確認: 対応 OS ごとの推奨導入コマンド> |

```sh
cd "$(git rev-parse --show-toplevel)"
```

### Test、format、lint

```sh
sh scripts/test.sh
stylua --check lua plugin tests scripts/benchmark.lua scripts/benchmark_runner.lua scripts/live_codex_test.lua scripts/live_llama_test.lua scripts/live_llama_session_test.lua
luacheck lua plugin tests scripts/benchmark.lua scripts/benchmark_runner.lua scripts/live_codex_test.lua scripts/live_llama_test.lua scripts/live_llama_session_test.lua
nvim --headless -u NONE -c "helptags doc" -c "qa!"
```

成功時、test runner は各項目を `ok` として表示し、末尾に Test Anything Protocol（TAP）の plan `1..N` を出力します。format／lint／help tag command は終了 status 0 を返します。

### Benchmark

```sh
sh scripts/benchmark.sh
```

benchmark は Neovim version、unit 数、byte 数、反復数、min／median／max を出力します。

### Codex schema check

```sh
sh scripts/check-codex-schema.sh
```

成功時は次を出力します。

```text
Codex app-server experimental schema exposes every method, field, and value required by Bilingua.nvim.
```

### Opt-in live test

live test は認証済み Codex へ固定 marker を1回送り、`gpt-5.6-luna`／`max`、structured output、backend cleanup を確認します。実行前に、外部 service への送信と利用料金を確認してください。

```sh
BILINGUA_RUN_LIVE_CODEX=1 sh scripts/test-live-codex.sh
```

成功時の出力形式です。

```text
LIVE_CODEX_TEST passed model=gpt-5.6-luna effort=max open_ms=<number> request_ms=<number> response_content=omitted cleanup=ok
```

llama live test は、利用者が事前に起動した loopback server に対して、既存 codec による初回翻訳と semantic patch を一件ずつ実行します。protected placeholder、timeout、backend cleanup を検証し、close 後の health probe で llama-server が停止されていないことも確認します。server／model の download や起動は行いません。

```sh
BILINGUA_RUN_LIVE_LLAMA=1 \
BILINGUA_LLAMA_SERVER_URL=http://127.0.0.1:8080 \
BILINGUA_LLAMA_SERVER_MODEL=auto \
sh scripts/test-live-llama.sh
```

成功時も model ID と response content は表示しません。

```text
LIVE_LLAMA_TEST passed open_ms=<number> initial_ms=<number> patch_ms=<number> model_id=omitted response_content=omitted cleanup=ok server_alive=yes
```

公開 Ex コマンド、双方向同期、status、active request の強制停止まで含む smoke test は、同じ固定の合成 plaintext だけを送信します。

```sh
BILINGUA_RUN_LIVE_LLAMA=1 \
BILINGUA_LLAMA_SERVER_URL=http://127.0.0.1:8080 \
BILINGUA_LLAMA_SERVER_MODEL=auto \
sh scripts/test-live-llama-session.sh
```

```text
LIVE_LLAMA_SESSION_TEST passed initial_ms=<number> source_sync_ms=<number> target_sync_ms=<number> cancel_ms=<number> model_id=omitted response_content=omitted protected_literals=ok status=ok cleanup=ok server_alive=yes
```

### 開発用環境変数

| 変数 | 用途 |
|---|---|
| `BILINGUA_RUN_LIVE_CODEX=1` | 実 Codex request への明示 opt-in |
| `BILINGUA_RUN_LIVE_LLAMA=1` | 実 llama-server request への明示 opt-in |
| `BILINGUA_LLAMA_SERVER_URL` | live test の loopback endpoint。既定 `http://127.0.0.1:8080` |
| `BILINGUA_LLAMA_SERVER_MODEL` | live test の model ID。既定 `auto` |
| `BILINGUA_NVIM` | live test で使う Neovim executable の絶対 path |
| `BILINGUA_BENCHMARK_UNITS` | benchmark の unit 数 |
| `BILINGUA_BENCHMARK_ITERATIONS` | benchmark の反復数 |
| `BILINGUA_BENCHMARK_PAYLOAD_BYTES` | benchmark の unit payload size |

CI は format／lint、Neovim 0.10.4／stable の test、allowed-failure の nightly test、週次／手動の最新 Codex schema check を実行します。外部 service／server に依存する live test は通常 CI から実行しません。

## Contributing

この repository は個人プロジェクトです。Issue と Pull Request は原則として対応対象外です。maintainer は必要と判断した内容だけを確認します。

1. [実装仕様](bilingua-nvim-implementation-spec.md) で変更対象の contract と受入条件を確認します。
2. [用語集](TERMS.md) で既存の canonical term を確認します。
3. 変更内容を示す unit／contract／integration test と実装を用意します。
4. `Test、format、lint` の全 command を repository root で実行します。
5. 利用者向けの挙動に合わせて README と [Neovim help](doc/bilingua.txt) を更新します。
6. [Pull Request](https://github.com/popura/bilingua.nvim/pulls) へ変更理由、検証結果、互換性への影響を記載します。

## サポートとセキュリティ

### 問い合わせ窓口

| 種別 | 窓口 | 記載する情報 |
|---|---|---|
| バグ報告 | [GitHub Issues](https://github.com/popura/bilingua.nvim/issues) | Neovim／選択 backend／Codex または llama.cpp version、再現手順、期待結果、実際の結果、正規化済み error code |
| 使用方法の質問 | [GitHub Issues](https://github.com/popura/bilingua.nvim/issues) | title に `[Question]` を付け、利用目的、設定、実行 command、`:BilinguaStatus` の metadata |
| 脆弱性報告 | `<要確認: 非公開の security advisory URL または連絡先>` | 影響範囲、再現条件、緩和策、連絡先 |

Issue は情報共有用です。maintainer は必要と判断した内容だけを確認します。

報告内の文書本文、prompt、model response、認証情報は `<REDACTED>` へ置換してください。

### セキュリティの要点

- Bilingua.nvim は source／target を信頼境界外の document data として扱い、固定 instruction と JSON data を分離します。
- Codex strict isolation は backend instance ごとに空の一時 directory と permission profile を作り、workspace read access をその directory へ限定し、network を off、environments を空に設定します。
- Codex backend は ephemeral thread と instruction source を検証し、approval request を decline し、command／file change／Model Context Protocol（MCP）／web search／image view／subagent item を中断します。
- model output は schema、task ID、revision、document structure、protected token、destination version の順で検証してから Editor adapter が適用します。
- Codex home（`$CODEX_HOME`、既定 `~/.codex`）の user-level instruction file は利用者が内容を確認してください。
- 認証情報には Codex CLI の公式認証または環境側の credential store を使い、設定例と報告には `<CODEX_CREDENTIAL>` を使ってください。
- 追加の OS-level 保護が必要な環境では Codex app-server process を外部 sandbox へ収容してください。
- llama backend は tool 定義を送らず、HTTP endpoint を loopback に限定します。Codex の permission profile は適用されないため、server process、model、chat template、model file の権限は利用者が保護してください。
- local model へ渡す場合も文書の機密性を確認し、model license、server の log／cache、hardware resource を管理してください。

詳細な信頼境界、privacy、resource cleanup は [`:help bilingua-security`](doc/bilingua.txt) を参照してください。

## ライセンス

Bilingua.nvim は Apache License 2.0 の下で提供します。配布条件は [LICENSE](LICENSE) を参照してください。
