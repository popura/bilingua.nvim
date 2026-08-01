# Bilingua.nvim terminology ledger

この台帳は README、Vim help、実装仕様、code comment で使う語の意味と表記を固定します。新しい概念名を追加するときは、既存語で表現できないかを先に確認します。

| Canonical term | 日本語での説明 | Status / source |
|---|---|---|
| source / source buffer | 翻訳 Session を開始した原文側と、その Neovim buffer。`source` を「送信元一般」の意味へ広げない。 | Accepted; implementation specification |
| target / target buffer | 初期翻訳で生成され、既定では日本語を保持する scratch buffer 側。方向が target-to-source のときも side 名は変えない。 | Accepted; implementation specification |
| Session | 一つの source と target、対応関係、同期 task、backend の lifecycle を所有する実行単位。code 上の型名なので先頭を大文字にする。 | Accepted; implementation specification |
| unit | Document Adapter が構文と span に基づいて抽出する最小の追跡単位。行と同義ではない。 | Accepted; implementation specification |
| mapping group | source unit 群と target unit 群の多対多対応、および baseline/state を保持する集合。単に `block` と呼ばない。 | Accepted; implementation specification |
| baseline triple | mapping group が保持する source baseline、target baseline、対応 metadata の組。両側編集と stale result の判定基準。 | Accepted; implementation specification |
| protected token | 翻訳対象 text から placeholder へ一時置換し、model output で完全一致を検証して復元する literal。 | Accepted; implementation specification |
| opaque unit | 翻訳せず raw text を相手側へそのまま mirror する Markdown unit。`unsupported text` とは呼ばない。 | Accepted; implementation specification |
| mirror | opaque unit の raw text を inference backend を使わず反対側へ複製する同期 mode。 | Accepted; implementation specification |
| semantic patch task | 一つの mapping group の baseline、編集前後、限定 context から反対側の replacement unit を要求する task。diff 文字列そのものではない。 | Accepted; implementation specification |
| dirty | mapping group の一方が baseline から変更され、同期が必要な state。`dirty_source` と `dirty_target` を区別する。 | Accepted; implementation specification |
| conflict | 同一 mapping group の両 side 編集、または安全に一意対応できないため人の方向選択を要する state。 | Accepted; implementation specification |
| invalid | parse、translation result、protected token、apply version などの検証に失敗した group state。conflict と同義ではない。 | Accepted; implementation specification |
| stale result | task 作成後に revision または destination version が変わり、現在の document へ適用できない結果。 | Accepted; implementation specification |
| automatic synchronization pause | 設定上 `sync.automatic = true` のまま、致命的な runtime error 後に自動 task 作成だけを停止した状態。`disabled` と区別する。 | Local UI wording; derived from Session status fields |
| strict isolation | Codex の一時 cwd、restricted read-only sandbox、external instruction source 拒否、ephemeral 確認、tool item 中断を組み合わせた標準 backend 設定。完全な OS process 禁止を意味しない。 | Accepted; implementation specification |
| non-persistence | Bilingua.nvim 自身が target file、sidecar、cache、transcript、resume state を残さない性質。Neovim や provider の保持までは含めない。 | Accepted; implementation specification |

表記規則:

- code identifier、state、command、API 名は原綴りを保持する。
- UI の既存語は `source`、`target`、`Session`、`unit`、`mapping group`、`task`、`backend` を優先する。
- 「ブロック」は Markdown の構文 block を指す場合だけ使い、mapping group の別名にはしない。
- `日本語側` は既定 `target_language = "ja"` の利用者向け説明に限り、汎用 API の説明では `target` を使う。
