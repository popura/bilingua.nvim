# Bilingua.nvim

Bilingua.nvim は、Neovim 上で原文と日本語訳を左右または上下に並べ、どちら側の編集も対応する側へ同期する非永続の翻訳プラグインです。標準バックエンドとして Codex app-server を使用します。

このリポジトリは初期版（MVP）です。Plaintext と Markdown の双方向同期、手動の競合解決、厳格な Codex 実行分離、終了時の資源解放を実装しています。

## 必要環境

- Neovim 0.10 以上
- Codex CLI 0.146.0 以上
  - 0.146.0 は本プロジェクトが生成スキーマを確認した最低版です。
  - Codex app-server protocol は Codex の版に依存するため、更新時は後述のスキーマ検査を実行してください。
- Codex CLI で利用可能な認証と text input 対応モデル
- 外部 Lua runtime dependency はありません。

Codex CLI の準備状況は次で確認できます。

```sh
codex --version
codex login
codex app-server --help
```

## インストール

現在の checkout を lazy.nvim から使う場合は次のように指定できます。

```lua
{
  dir = "/absolute/path/to/bilingua.nvim",
  config = function()
    require("bilingua").setup()
  end,
}
```

`setup()` は省略可能です。省略時も既定設定でコマンドを利用できます。

## クイックスタート

1. 実ファイルに対応する、通常の編集可能な原文バッファを開きます。
2. `:BilinguaStart` または `<leader>bs` を実行します。原言語を固定する場合は `:BilinguaStart en` のように指定します。
3. 原文または日本語スクラッチバッファを編集します。既定では 700 ms 後、または InsertLeave 時に対応する mapping group を同期します。
4. 直ちに同期するには `:BilinguaSync`、全 group を同期するには `:BilinguaSyncAll` を使います。
5. `!` が表示された競合では、`:BilinguaUseSource` または `:BilinguaUseJapanese` で正とする側を明示します。
6. 原文を残して終了するには `:BilinguaStop` を使います。

対象バッファは `bilingua://ja/{buffer}/{name}` 形式の名前を持つ scratch buffer です。通常のファイルとしては保存されません。

## コマンド

| コマンド | 動作 |
|---|---|
| `:BilinguaStart [source-language]` | 現在バッファで Session を開始します。 |
| `:BilinguaStart! [source-language]` | 既存 Session を強制停止して再開始します。 |
| `:BilinguaToggle` | 原文と日本語側の表示・focus を切り替えます。 |
| `:BilinguaSync` | cursor 下の mapping group を即時同期します。 |
| `:BilinguaSyncAll` | conflict 以外の dirty／invalid group を同期します。 |
| `:BilinguaUseSource` | conflict で原文側を正として日本語側を更新します。 |
| `:BilinguaUseJapanese` | conflict で日本語側を正として原文側を更新します。 |
| `:BilinguaNext` / `:BilinguaPrev` | 次／前の mapping group へ移動します。 |
| `:BilinguaStatus` | 本文を含まない Session 状態を表示します。 |
| `:BilinguaRetry` | 現在 group、または直前に失敗した開始処理を新しい Session で再試行します。 |
| `:BilinguaRestartBackend` | backend を再起動し、成功時に自動同期を再開します。 |
| `:BilinguaStop` | 未同期変更を保護しながら Session を停止し、原文を残します。 |
| `:BilinguaStop!` | 未同期の target 編集と conflict を破棄して強制停止します。 |
| `:BilinguaQuit` | 正常停止後、Neovim 標準の確認付きで原文バッファを閉じます。 |
| `:BilinguaQuit!` | 強制停止後、原文バッファも強制削除します。未保存の原文を失います。 |

`:BilinguaQuit!` には意図的に既定 mapping を割り当てていません。

## 既定 mapping

`start` だけが global です。それ以外は Session の原文・target buffer にだけ設定され、停止時に削除されます。

| Mapping | 動作 |
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

すべての `<Plug>(Bilingua...)` mapping は、既定 mapping を無効にしても利用できます。`Status`、`Retry`、`RestartBackend` には既定キーがありません。

## 既定設定

```lua
require("bilingua").setup({
  source_language = "auto",
  target_language = "ja",

  mappings = {
    enabled = true,
    start = "<leader>bs",
    toggle = "<leader>bb",
    sync = "<leader>by",
    sync_all = "<leader>ba",
    use_source = "<leader>bo",
    use_japanese = "<leader>bj",
    next = "]b",
    prev = "[b",
    stop = "<leader>bq",
    quit = "<leader>bQ",
  },

  layout = {
    direction = "vertical",
    target_position = "right",
    size = 0.5,
    follow_cursor = true,
    follow_debounce_ms = 50,
    open_folds = false,
  },

  sync = {
    automatic = true,
    debounce_ms = 700,
    on_insert_leave = true,
    max_concurrency = 1,
    context_groups = 1,
    structural_changes = "auto_safe",
    conflict_policy = "manual",
    retry = {
      max_attempts = 3,
      initial_delay_ms = 500,
      max_delay_ms = 3000,
    },
  },

  stop = {
    sync_pending = true,
    timeout_ms = 120000,
  },

  persistence = {
    enabled = false,
  },

  limits = {
    max_document_bytes = 2 * 1024 * 1024,
    max_units = 2000,
    max_task_input_chars = 24000,
    max_task_output_chars = 24000,
    initial_batch_chars = 12000,
    initial_batch_units = 32,
  },

  documents = {
    fallback_to_plaintext = true,
    aliases = {},
    protected_patterns = {},
    routes = {
      markdown = {
        adapter = "markdown",
        tracker = "hybrid",
        aligner = "generated_id",
      },
      text = {
        adapter = "plaintext",
        tracker = "hybrid",
        aligner = "generated_id",
      },
    },
  },

  translation = {
    service = "default",
    backend = "codex_app_server",
    initial_codec = "initial_translation_json_v1",
    patch_codec = "semantic_patch_json_v1",
    timeout_ms = 120000,
    backend_options = {
      command = { "codex", "app-server" },
      model = "gpt-5.6-luna",
      reasoning_effort = "max",
      require_ephemeral = true,
      strict_isolation = true,
      reject_external_instruction_sources = true,
      include_platform_default_reads = false,
      experimental_api = true,
      request_timeout_ms = 10000,
      shutdown_timeout_ms = 500,
    },
  },

  ui = {
    signs = true,
    virtual_text = true,
    notify_backend = true,
    show_progress = true,
  },

  debug = {
    enabled = false,
    log_payloads = false,
    ring_size = 200,
  },
})
```

未知の設定キーは警告します。型・値域の不正は `E_INVALID_ARGUMENT` です。初期版では `persistence.enabled = true`、`debug.log_payloads = true`、`sync.conflict_policy` の `manual` 以外を拒否します。個々の mapping は `false` で無効化できます。
`ui.notify_backend = true` では、実行時の `BilinguaError` を固定文と正規化済みエラーコードだけで `vim.notify()` に表示します。同じ Session の同じコードは 1 秒間、重複表示しません。`false` はこの通知だけを無効化し、コマンドのエラー表示には影響しません。

`ui.show_progress = true` では、初期翻訳の完了 batch 数を target 先頭行の `Translating completed/total…` virtual text に表示し、開始完了・失敗・再開始・停止時に消去します。`false` はこの初期進捗だけを無効にします。mapping group の状態表示は `ui.signs` と `ui.virtual_text` が制御します。

`layout.open_folds = true` にすると cursor follow の移動先にある fold を自動で開きます。既定の `false` では fold 状態を変えません。どちらの場合も移動元の focus と移動先 window の scroll view を保持します。

`documents.protected_patterns` は追加で保護する有効な Lua pattern の配列です。一致した literal は標準の URL、inline code、placeholder などと同様に完全一致で検証されます。空配列を含む Session ごとの指定は、global の配列を要素単位で merge せず置き換えます。

`documents.routes` は filetype の完全一致、次に `documents.aliases` を参照します。既定では未登録 filetype も Plaintext へ fallback します。Markdown route では Neovim の Markdown Tree-sitter parser または同梱 query が利用できない場合も、`fallback_to_plaintext = true` なら警告して Plaintext を使い、`false` なら `E_PARSE` で開始を中止します。

初期翻訳では unit を分割しません。単一 unit 自体が `limits.initial_batch_chars` を超える場合は、推論へ送信せず `E_DOCUMENT_TOO_LARGE` で開始を中止します。

既定の `strict_isolation = true` は Codex の experimental permission profile API を使うため、`experimental_api = false` とは併用できません。`strict_isolation = false` は Codex 標準の `readOnly` sandbox へ戻り、隔離用一時 directory 外も読み取り可能になります。安全上の理由から、通常は既定値を変更しないでください。

標準 backend は `gpt-5.6-luna` と reasoning effort `max` に固定されています。`max` は推論時間と token 使用量が増える場合があるため、速度を優先する用途では `reasoning_effort` を明示的に下げてください。

## 文書処理

Plaintext は空行で区切られた段落を unit として扱い、改行形式と最終改行の有無を保持します。

Markdown route は、利用可能なら Neovim の Markdown Tree-sitter parser と `queries/markdown/bilingua.scm` を解析・検証に使います。Bilingua の Markdown Adapter は構文テンプレートを保持しながら heading、paragraph、list item、blockquote paragraph を翻訳対象にします。front matter、fenced／indented code、数式 block、table、HTML block、thematic break、reference definition、画像だけの行は opaque unit として原文のまま双方向に mirror します。inline code、URL、link destination、reference label、HTML tag、template、printf placeholder、inline math は protected token として完全一致を検証します。

Bilingua の構文テンプレート抽出は完全な CommonMark 実装ではありません。構造を安全に保持できない編集、曖昧な対応、未閉鎖の opaque block は自動適用せず、conflict または invalid とします。

## 状態と復旧

表示記号は `✓` clean、`S` source dirty、`J` target dirty、`…` syncing、`!` conflict、`×` invalid です。

`:BilinguaStatus` は Session／health、adapter、tracker、aligner、backend／model、group 数、active task、自動同期状態を表示します。本文・prompt・model response は表示しません。

backend protocol、認証、隔離、無効出力などの致命的な実行時エラーでは health が `degraded` になり、自動同期を一時停止します。`:BilinguaRestartBackend` が成功すると、同じ document state を保ったまま `healthy` に戻り、自動同期を再開します。個別 group の再試行は `:BilinguaRetry` を使います。

同一 group の両側が baseline から変更された場合、自動 merge はしません。正しい側を確認して `UseSource` または `UseJapanese` を実行してください。

## セキュリティとプライバシー

Bilingua.nvim は原文・訳文を信頼できない document data として Codex へ渡します。文書中の命令、URL、shell command は実行指示として扱いません。

標準の strict isolation では、backend instance ごとに隔離資源を作り、各 task の ephemeral thread で次の制約を適用します。

- backend instance ごとに空の一時 directory を作り、Codex process と各 thread／turn の `cwd` にします。
- source path、source directory、Neovim RPC 情報を request や readable root に含めません。
- ephemeral thread を要求し、確認できなければ document data を送る前に失敗します。
- `thread/start` の `instructionSources` が隔離用一時 directory 内、または Bilingua の初期化時に検出した Codex user-level `AGENTS.override.md`／`AGENTS.md` と同一の file だけであることを確認してから turn を開始します。それ以外の instruction source は拒否します。
- backend instance ごとに推測困難な名前の permission profile を定義し、各 task で隔離用一時 directory だけを read-only workspace root として許可します。network と local environment access は無効化します。
- approval request を decline し、command、file change、MCP、web search、image view、subagent などの item を検出した task を中断します。
- model output を schema、task/revision、文書構造、protected token、適用先 version の順に検証してから Editor adapter だけが反映します。

空の `environments` は local environment access を無効化しますが、`approvalPolicy = "never"` だけで tool が無効になるわけではありません。permission profile、environment 無効化、item 検出は多層防御です。さらに強い保証が必要な環境では、利用者側で `codex app-server` process を外部 sandbox に収容してください。

Codex home（`$CODEX_HOME`、未設定時は `~/.codex`）に上記の user-level instruction file が存在すると、Codex app-server はその内容を model instruction として読み込む場合があります。Bilingua は `realpath` で同一と確認できた file だけを許可しますが、instruction の内容は変更しません。翻訳に影響し得るため、利用者はこれらの file も確認してください。

Codex app-server が local process でも、選択モデルによって document content が外部 OpenAI service へ送信される場合があります。Bilingua.nvim は機密情報を自動検出・匿名化しません。Codex／provider 側の data retention、logging、cache は各 service の方針に従い、プラグインの非永続性では保証されません。認証情報を設定、文書、log に書き込まないでください。

プラグインは payload logging を実装していません。User autocmd の `data`、実行時エラーの `vim.notify()`、既定の診断 metadata に本文を含めません。

## 非永続性と終了

target buffer は `nofile`、`noswapfile`、persistent undo 無効です。プラグインは sidecar、訳文ファイル、mapping cache、database、transcript、resume file を作りません。停止時に target buffer、window、extmark、autocmd、timer、mapping graph、task、Codex thread/process、一時 directory を解放します。

原文側の swap、undo、backup 設定は変更せず、自動保存もしません。原文へ既に同期済みの編集は、強制停止でも巻き戻しません。Neovim 自身の undo・swap・backup と provider 側の保持は、この非永続性の範囲外です。

安全に終了する通常経路は `:BilinguaStop` です。target buffer を直接 `bdelete`／`bwipeout` した場合や Neovim 終了時は、未同期内容を同期せず force dispose します。`:BilinguaQuit!` は未保存の原文も破棄します。

## Lua API と User event

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

`start`、`retry_current`、`restart_backend`、`stop`、`quit` は非同期完了を callback で通知できます。公開 API は内部 Session を返さず、`status()` は本文を含まず内部 table と共有されない状態のコピーを返します。

次の `User` event を発火します。

- `BilinguaSessionStarted`
- `BilinguaSessionStopped`
- `BilinguaSyncStarted`
- `BilinguaSyncCompleted`
- `BilinguaConflict`
- `BilinguaError`

`event.data` は `session_id`、`group_id`、`task_id`、`state`、`error_code` だけです。

拡張 API version は 1 です。`require("bilingua.registry")` から document adapter、unit tracker、aligner、translation backend、task codec、translation service の factory を登録できます。同名の置換には `{ replace = true }` が必要です。

## 開発

通常の test は Codex や network を起動せず、fake app-server を使います。

```sh
sh scripts/test.sh
stylua --check lua plugin tests scripts/benchmark.lua scripts/benchmark_runner.lua scripts/live_codex_test.lua
luacheck lua plugin tests scripts/benchmark.lua scripts/benchmark_runner.lua scripts/live_codex_test.lua
nvim --headless -u NONE -c "helptags doc" -c "qa!"
```

型・静的検査方針はリポジトリ全体で共通です。Lua 5.1 構文を使い、単一の `.luacheckrc` で `vim` だけを global として許可し、個別 file の抑制は置きません。extension は `api_version = 1` と必須 method を SessionFactory で runtime contract-check し、同じ contract test を実装ごとに適用します。

既定上限に近い 2,000 unit の Plaintext／Markdown parse と Hybrid Tracker を再現可能に計測できます。機種差が大きいため合否閾値は設けず、Neovim 版、unit 数、byte 数、反復数と min／median／max を出力します。

```sh
sh scripts/benchmark.sh
```

短い確認では `BILINGUA_BENCHMARK_UNITS`、`BILINGUA_BENCHMARK_ITERATIONS`、`BILINGUA_BENCHMARK_PAYLOAD_BYTES` を小さくできます。

Codex app-server の生成スキーマとの互換性は次で確認します。

```sh
sh scripts/check-codex-schema.sh
```

この検査は `codex app-server generate-json-schema --experimental` を一時 directory へ実行し、利用 method、必須 field、permission profile 関連 field を確認してから directory を削除します。

認証・model availability・network に依存する実 Codex test は、明示的な opt-in で1回だけ実行できます。document の代わりに固定 marker を送り、応答本文は出力せず、標準 backend の `gpt-5.6-luna`／`max`、structured output、cleanup を検証します。外部 service への送信と利用料金が発生し得ます。

```sh
BILINGUA_RUN_LIVE_CODEX=1 sh scripts/test-live-codex.sh
```

別の Neovim executable を使う場合は `BILINGUA_NVIM=/absolute/path/to/nvim` も指定します。CI では最低 Neovim 0.10.4 と stable、allowed-failure の nightly、週次／手動の最新 Codex schema check を実行し、live test は通常含めません。

詳細は `:help bilingua`、安全上の注意は `:help bilingua-security` を参照してください。
