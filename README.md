# Bilingua.nvim

Bilingua.nvim は、Neovim で原文（source）と日本語訳（target）を同時に編集したい利用者向けに、Codex app-server による初期翻訳と双方向同期を一つの編集画面へまとめるプラグインです。

[![継続的インテグレーション（CI）](https://github.com/popura/bilingua.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/popura/bilingua.nvim/actions/workflows/ci.yml)
![Neovim 0.10 以上](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)
![Codex command-line interface（CLI）0.146.0 以上](https://img.shields.io/badge/Codex_CLI-0.146.0%2B-111111)
![開発ステータス: Minimum Viable Product（MVP）](https://img.shields.io/badge/status-MVP-orange)
[![ライセンス: Apache License 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

## デモ

次の例は、英語の `README.md` を日本語 target と並べ、現在位置の編集を同期して Session を終了する最小操作です。Session は、一組の source／target buffer、対応関係、同期 task、backend のライフサイクルを管理する実行単位です。実行前に、Codex へ送る文書内容と利用料金を確認してください。

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
- **厳格な Codex 実行分離**: ephemeral thread、隔離用一時 directory、permission profile、network off、空の environments、tool item の中断を組み合わせます。
- **一時的な target**: target は scratch buffer として動作し、Session 終了時に buffer、window、task、backend process、一時 directory を解放します。
- **状態表示と復旧**: sign／virtual text、`:BilinguaStatus`、`:BilinguaRetry`、`:BilinguaRestartBackend` で状態確認と復旧を行います。

## 動作要件

| 項目 | 要件 |
|---|---|
| Neovim | 0.10 以上 |
| Codex CLI | 0.146.0 以上 |
| Codex 認証 | `codex login` で利用可能な認証 |
| Model | text input 対応 model。既定は `gpt-5.6-luna` |
| Reasoning effort | 既定は `max` |
| Lua runtime | Neovim 同梱 runtime |
| 外部 Lua dependency | なし |
| Plugin manager | Dein.vim |
| OS | <要確認: 対応 OS と検証済み環境> |

準備状況を確認します。`<CODEX_CREDENTIAL>` は説明用の認証情報 placeholder であり、実際の認証値は Codex CLI の対話画面へ入力します。

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
    backend_options = {
      model = "gpt-5.6-luna",
      reasoning_effort = "max",
      strict_isolation = true,
      experimental_api = true,
    },
  },
})
```

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
| `translation.backend_options.model` | `"gpt-5.6-luna"` | Codex model |
| `translation.backend_options.reasoning_effort` | `"max"` | reasoning effort |
| `translation.backend_options.strict_isolation` | `true` | Codex 実行分離 |
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
- live Codex test は通常 CI に含まれません。
- 対応 OS と OS ごとの検証状況は `<要確認: 対応 OS と検証済み環境>` です。

## 開発手順

### 開発環境

repository root を作業 directory として使います。通常 test は fake app-server と local fixture を使います。

| Tool | 用途 |
|---|---|
| Neovim 0.10 以上 | unit／contract／integration test |
| StyLua 2.5.2 | format check |
| Luacheck | lint |
| Codex CLI 0.146.0 以上 | schema check と opt-in live test |
| 開発用 package manager | <要確認: 対応 OS ごとの推奨導入コマンド> |

```sh
cd "$(git rev-parse --show-toplevel)"
```

### Test、format、lint

```sh
sh scripts/test.sh
stylua --check lua plugin tests scripts/benchmark.lua scripts/benchmark_runner.lua scripts/live_codex_test.lua
luacheck lua plugin tests scripts/benchmark.lua scripts/benchmark_runner.lua scripts/live_codex_test.lua
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

### 開発用環境変数

| 変数 | 用途 |
|---|---|
| `BILINGUA_RUN_LIVE_CODEX=1` | 実 Codex request への明示 opt-in |
| `BILINGUA_NVIM` | live test で使う Neovim executable の絶対 path |
| `BILINGUA_BENCHMARK_UNITS` | benchmark の unit 数 |
| `BILINGUA_BENCHMARK_ITERATIONS` | benchmark の反復数 |
| `BILINGUA_BENCHMARK_PAYLOAD_BYTES` | benchmark の unit payload size |

CI は format／lint、Neovim 0.10.4／stable の test、allowed-failure の nightly test、週次／手動の最新 Codex schema check を実行します。

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
| バグ報告 | [GitHub Issues](https://github.com/popura/bilingua.nvim/issues) | Neovim／Codex version、再現手順、期待結果、実際の結果、正規化済み error code |
| 使用方法の質問 | [GitHub Issues](https://github.com/popura/bilingua.nvim/issues) | title に `[Question]` を付け、利用目的、設定、実行 command、`:BilinguaStatus` の metadata |
| 脆弱性報告 | `<要確認: 非公開の security advisory URL または連絡先>` | 影響範囲、再現条件、緩和策、連絡先 |

Issue は情報共有用です。maintainer は必要と判断した内容だけを確認します。

報告内の文書本文、prompt、model response、認証情報は `<REDACTED>` へ置換してください。

### セキュリティの要点

- Bilingua.nvim は source／target を信頼境界外の document data として扱い、固定 instruction と JSON data を分離します。
- strict isolation は backend instance ごとに空の一時 directory と permission profile を作り、workspace read access をその directory へ限定し、network を off、environments を空に設定します。
- backend は ephemeral thread と instruction source を検証し、approval request を decline し、command／file change／Model Context Protocol（MCP）／web search／image view／subagent item を中断します。
- model output は schema、task ID、revision、document structure、protected token、destination version の順で検証してから Editor adapter が適用します。
- Codex home（`$CODEX_HOME`、既定 `~/.codex`）の user-level instruction file は利用者が内容を確認してください。
- 認証情報には Codex CLI の公式認証または環境側の credential store を使い、設定例と報告には `<CODEX_CREDENTIAL>` を使ってください。
- 追加の OS-level 保護が必要な環境では Codex app-server process を外部 sandbox へ収容してください。

詳細な信頼境界、privacy、resource cleanup は [`:help bilingua-security`](doc/bilingua.txt) を参照してください。

## ライセンス

Bilingua.nvim は Apache License 2.0 の下で提供します。配布条件は [LICENSE](LICENSE) を参照してください。
