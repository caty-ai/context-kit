# context-kit — リファレンス

[← トップページ](../README.ja.md) ｜ [English](reference.md) ｜ **日本語**

正確な契約：すべての環境変数、スクラッチファイルのルール、終了コードの意味、フックの配線マップです。各要素の詳細な動作については、それぞれのドキュメントにリンクしています。

## ファイル構成

| パス | 内容 |
| --- | --- |
| `bin/` | スタンドアロン CLI：[`lg`](lg.md)、[`recall`](recall.md)、[`wt-snapshot`](wt-snapshot.ja.md) |
| `hooks/` | フックスクリプト：`lg-enforcer.py`、`scratch-persist.{sh,py}`、`validate-subagent-brief.{sh,py}`、`rm-enforcer.py`、`private-repo-enforcer.mjs`、`api-key-leak-detector.mjs` |
| `examples/settings.json` | すべてのフックの完全な配線例（`<CONTEXT_KIT_DIR>` プレースホルダー付き） |
| `docs/` | 本ドキュメント（[`wt-snapshot`](wt-snapshot.ja.md) を含む） |
| `tests/` | 一時ディレクトリのみで動作する7つのセルフチェックスイート |
| `refs/worktree-snapshots/<worktree-name>/<UTC-timestamp>` | `wt-snapshot` が main リポジトリへ書き込む耐久スナップショット ref |

---

## フック配線マップ

すべてのフックエントリは、ガード付きの形式 `sh -c 'f="<CONTEXT_KIT_DIR>/hooks/…"; if [ -f "$f" ]; then …; fi'` を使用します。インタプリタの有無も、必要なすべての箇所で確認されます — `lg-enforcer` と safety トリオでは配線内で、`scratch-persist` と brief validator では `sh` ランチャー内で確認します。正確なコマンドについては [`examples/settings.json`](../examples/settings.json) を参照してください。

| フック | イベント | マッチャー |
| --- | --- | --- |
| `lg-enforcer.py` | `PreToolUse` | `Bash` |
| `rm-enforcer.py` | `PreToolUse` | `Bash` |
| `private-repo-enforcer.mjs` | `PreToolUse` | `Bash` |
| `api-key-leak-detector.mjs` | `PreToolUse` | `Bash\|Write\|Edit` |
| `validate-subagent-brief.sh` | `PreToolUse` | `Agent\|Task` |
| `scratch-persist.sh` | `PostToolUse` | なし（すべてのツールが対象。必要であればマッチャーで絞り込み可能） |

---

## 環境変数

フック関連の変数は、Claude Code を起動するシェル、ランチャー、またはアプリのラッパーから export してください。後から対話シェルで設定した変数は、フックから見えません。

### 共通

| 変数 | 用途 | デフォルト |
| --- | --- | --- |
| `CK_AGENT` | `CK_SCRATCH_DIR` が未設定かつ `HOME` が利用可能な場合のスクラッチサブディレクトリ名 | `agent` |
| `CK_SCRATCH_DIR` | 永続化を行うすべての要素が使用するスクラッチディレクトリ。設定されたディレクトリの既存パーミッションは維持される。絶対パスを推奨 — 相対値の解決は要素ごとに異なる（下記スクラッチ契約を参照） | `HOME` が設定されている場合は `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory`、それ以外は `${TMPDIR:-/tmp}/context-kit-scratch` |

### lg（[詳細](lg.md)）

| 変数 | 用途 | デフォルト |
| --- | --- | --- |
| `CK_LG_PATH` | enforcer のリトライヒントに表示されるラッパーのパス | `lg` |
| `CK_LG_ENFORCER_DISABLED` | `1` を設定すると、そのシェル行1行分のみ enforcer をバイパスする | 未設定 |
| `LG_HEAD` | プレビューに残す先頭行数 | `40` |
| `LG_TAIL` | プレビューに残す末尾行数 | `40` |
| `LG_TTL_DAYS` | スクラッチのフロントマターに書き込まれる有効期限のメタデータ | `7` |

### scratch-persist（[詳細](scratch-persist.md)）

| 変数 | 用途 | デフォルト |
| --- | --- | --- |
| `CK_SCRATCH_DISABLED` | `1` で事後（reactive）の永続化を無効化する | 未設定 |
| `CK_SCRATCH_THRESHOLD` | 永続化がトリガーされる、抽出された出力の最小長（文字数） | `5000` |

`CK_SCRATCH_DIR_IS_DEFAULT` はランチャー内部の状態です。手動で設定しないでください。

### brief-validator（[詳細](brief-validator.md)）

| 変数 | 用途 | デフォルト |
| --- | --- | --- |
| `CK_SKIP_BRIEF_VALIDATION` | 起動環境で `1` を設定すると検証をバイパスする | 未設定 |
| `CK_BRIEF_REQUIRED_SECTIONS` | パイプ区切りの必須セクショントークン | `## 実装仕様\|## 実装チェック\|## レビュー基準` |
| `CK_BRIEF_SKIP_SUBAGENT_TYPES` | 検証をスキップするサブエージェントタイプ（カンマ区切り） | `Explore,explore,general-purpose,claude-code-guide,statusline-setup,writer` |
| `CK_BRIEF_MIN_PROMPT_CHARS` | 検証がトリガーされる最小プロンプト長 | `500` |

### safety-hooks（[詳細](safety-hooks.md)）

| 変数 | 用途 | デフォルト |
| --- | --- | --- |
| `CK_DESTRUCTIVE_OK` | `1`（環境変数または同一行の Bash トークン）で破壊的コマンドの検知をバイパスする | 未設定 |
| `CK_PUBLIC_REPO_OK` | `1`（環境変数または同一行の Bash トークン）で意図的な公開リポジトリ操作を許可する | 未設定 |
| `CK_API_KEY_DETECT_DISABLED` | `1` でキー検知を無効化する。同一行での指定は Bash のみで有効 | 未設定 |

### recall（[詳細](recall.md)）

| 変数 | 用途 | デフォルト |
| --- | --- | --- |
| `SUPERMEMORY_API_KEY` | Supermemory の API キー。env ファイルより先に読み込まれる | 未設定 |
| `SUPERMEMORY_CC_API_KEY` | 互換用の API キー名 | 未設定 |
| `CK_SM_ENV` | いずれかのキー名を含む env ファイル（`KEY=VALUE` 形式の行。source されることはない） | `${HOME}/.config/supermemory/env` |
| `CK_SM_CONTAINER` | Supermemory の `containerTag`。必須で、意図的にデフォルト値なし | 未設定 |
| `CK_RECALL_MEILI_CMD` | `mem-search` 互換の実行ファイル名またはパス | `mem-search` |
| `CK_RECALL_ROOTS` | ローカル検索のルート。プラットフォームのパス区切り文字で区切る。明示的に空にするとルートなしを意味する | キットのスクラッチルートに加えて、既存の `${HOME}/.claude/projects` |

---

### wt-snapshot（[詳細](wt-snapshot.ja.md)）

| 変数 | 用途 | デフォルト |
| --- | --- | --- |
| `CK_WTSNAP_INCLUDE_IGNORED` | スナップショットに含める gitignored パスの glob 一覧。コロン区切りまたはカンマ区切り。未設定なら ignored パスは一切含めない | 未設定 |
| `CK_WTSNAP_SECRET_SCAN_CMD` | スナップショット作成前に、候補ファイルごとの内容を stdin で受け取る任意コマンド。非ゼロ終了なら、ref を1つも書かず fail-closed で中断する | 未設定 |
| `CK_WTSNAP_IDENT` | すべての git 呼び出しに使う任意の identity。ユーザーの git config を読まず、author / committer 環境変数へ展開して使う | 組み込みのツール identity |
| `CK_WTSNAP_TTL_DAYS` | `wt-snapshot prune` が期限切れ ref を一覧表示する際のしきい値日数。`prune` は一覧表示のみで、削除はしない | `30` |

---

## スクラッチ契約

永続化を行うすべての要素は、同じルールに従います。

- **場所** — `CK_SCRATCH_DIR`、または上記の共通デフォルトです。ファイルはこのディレクトリ直下にフラットに書き込まれます。`CK_SCRATCH_DIR` は絶対パスを推奨します。相対値の解決は要素ごとに異なり、API キーフックはデフォルトのスクラッチルート配下に解決する一方、`lg`・`scratch-persist`・`recall` はプロセスの作業ディレクトリ基準で解決します（`recall` はさらに `~` と環境変数を展開します）。
- **パーミッション** — キットが作成するデフォルトルートは `0700` に強化されます。結果ファイルと証跡ファイルは `0600` です。ユーザーが指定した `CK_SCRATCH_DIR` は既存のパーミッションのままであり、その保護は運用者の責任です。
- **命名規則** — `scratch-<timestamp>-<tool>.md`（lg と scratch-persist）、`recall-*.md`（recall の結果ダンプ）、そして API キーフックが出力する、マスク済みのローテーション証跡レポートです。スクラッチへの書き込みに失敗した場合、`lg` は `${TMPDIR:-/tmp}` に `lg.` という一時ファイルを残すことがあります。
- **フロントマター** — `createdAt` と `expiresAt`。7日 TTL の規約に従います（該当する場合は `LG_TTL_DAYS`）。
- **クリーンアップはユーザーが担う** — キットは何も削除しません。lg と scratch-persist の出力をまとめてカバーする1つのジョブは次の通りです。

```sh
if [ -n "${CK_SCRATCH_DIR:-}" ]; then
  scratch_dir="${CK_SCRATCH_DIR}"
elif [ -n "${HOME:-}" ]; then
  scratch_dir="${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory"
else
  scratch_dir="${TMPDIR:-/tmp}/context-kit-scratch"
fi
find "${scratch_dir}" \( -type f -name 'scratch-*.md' -o -type f -name '.scratch-persist-*' \) -mtime +7 -delete
```

スクラッチの内容には、シークレット、トークン、スタックトレース、生の顧客データが含まれる場合があります。そのつもりでこのディレクトリを扱ってください。

---

## 終了コードの意味

| コンテキスト | コード | 意味 |
| --- | --- | --- |
| `PreToolUse` フック | `0` | 許可 — fail-open のすべての経路を含む（ファイル欠如、インタプリタ欠如、不正な入力、内部エラー） |
| `PreToolUse` フック | `2` | 本物の検知。是正メッセージで何を変更すべきかを説明する |
| `PostToolUse`（`scratch-persist`） | `0` | 常に。成功時、stdout には `hookSpecificOutput.additionalContext` を含む JSON オブジェクトが1つだけ出力される |
| `recall` | `0` | 試行したレイヤーのうち少なくとも1つが `status=ok` で完了した場合（ヒット数0の検索も含む） |
| `recall` | 非ゼロ | 試行したすべてのレイヤーがエラーになった場合、選択されたレイヤーを1つも試行できなかった場合、またはコマンド全体が失敗した場合（案内は stderr に出力され、stdout は機械可読なまま維持される） |
| `wt-snapshot` | `0` | スナップショット作成成功、`restore` 成功、`prune` が0件以上を一覧表示、または capture が clean no-op を検知して何も書かなかった場合 |
| `wt-snapshot` | `64` | 使い方エラー |
| `wt-snapshot` | スキャナの終了ステータス | `CK_WTSNAP_SECRET_SCAN_CMD` が非ゼロを返した。スナップショットは fail-closed で中断し、ref は1つも書かれず、スキャナの終了ステータスをそのまま返す |
| `wt-snapshot` | `70` | スナップショットの構築・保存・復元中に git またはリポジトリ操作が失敗した |
