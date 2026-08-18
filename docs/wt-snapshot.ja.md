# wt-snapshot

## 何のためのものか

`wt-snapshot` は、worktree の削除をあとから巻き戻せるようにするための CLI です。

人が Git worktree を消す前に実行すると、その lane を後日そのまま組み直すために必要なローカル状態を main リポジトリ側へ退避します。

- worktree `HEAD` からの tracked 変更
- nested path を含む untracked ファイル
- `CK_WTSNAP_INCLUDE_IGNORED` で明示した gitignored パス群

退避先は、main リポジトリ内の耐久 ref です。

```text
refs/worktree-snapshots/<worktree-name>/<UTC-timestamp>
```

このツールは worktree を削除しません。やることは capture・restore・古い snapshot 候補の一覧表示だけです。

## コマンド

### Capture

サブコマンドなしの `wt-snapshot` は、現在の worktree を main リポジトリへ退避します。

```sh
wt-snapshot
```

ignored パスは opt-in です。未設定なら1つも含めません。

```sh
CK_WTSNAP_INCLUDE_IGNORED='.state/**:.cache/**' wt-snapshot
```

family 系の lane が `.omc/` に一時状態を置くなら、docs 上の preset 例としては次です。

```sh
CK_WTSNAP_INCLUDE_IGNORED='.omc/**' wt-snapshot
```

### Restore

snapshot を fresh なディレクトリへ復元します。

```sh
wt-snapshot restore refs/worktree-snapshots/feature-x/20260818T120102Z /tmp/feature-x-restore
```

`restore` は空でない target を拒否します。round-trip を正確に保つため、target は fresh なディレクトリである必要があります。

### Prune

期限切れの snapshot ref 候補を、削除せず一覧表示します。

```sh
wt-snapshot prune
```

`prune` は `CK_WTSNAP_TTL_DAYS`（デフォルト `30`）で期限切れ判定を行い、人が後で確認・削除判断するための候補だけを出します。

## Capture 契約

`wt-snapshot` は false safety を避けるため、次を対象にします。

- dirty な tracked ファイルを含める
- untracked ファイルを含める
- ignored パスは `CK_WTSNAP_INCLUDE_IGNORED` に一致したものだけを含める
- worktree が clean でも、その `HEAD` が main リポジトリ内の ref からすでに到達可能な場合にだけ no-op にする

worktree が clean で、かつその `HEAD` が main リポジトリ内の ref から到達可能な場合だけ、`wt-snapshot` は明示的な no-op メッセージを出して `0` で終了し、何も書きません。

## Git 衛生

snapshot の作成は、`GIT_INDEX_FILE` で指定した一時 index だけを使います。worktree 側・main リポジトリ側の本物の index、`HEAD`、working tree は触りません。

すべての git 呼び出しは、identity を環境変数で明示します。

- `GIT_AUTHOR_NAME`
- `GIT_AUTHOR_EMAIL`
- `GIT_COMMITTER_NAME`
- `GIT_COMMITTER_EMAIL`

ユーザーの git config を前提にせず、必要な箇所では `GIT_CONFIG_GLOBAL=/dev/null` と `GIT_CONFIG_SYSTEM=/dev/null` などで読み込みを無効化します。

identity を差し替えたい場合は `CK_WTSNAP_IDENT` を設定します。未設定時はツール組み込みの identity を使います。

## Secret scan

`CK_WTSNAP_SECRET_SCAN_CMD` を設定すると、snapshot を書く前に各候補ファイルの内容を scanner に stdin で流します。

```sh
CK_WTSNAP_SECRET_SCAN_CMD='my-scan-wrapper' wt-snapshot
```

挙動は次の通りです。

- 未設定: 事前 scan は走らない
- 終了 `0`: snapshot を続行できる
- 非ゼロ終了: fail-closed で中断し、ref は1つも書かず、その scan 終了コードをそのまま返す

scan-hit と git failure を機械的に区別したい場合は、scanner wrapper 側で専用の非ゼロ終了コードを割り当てる想定です。

## Restore 契約

`restore` は、snapshot に入っていた内容を fresh なディレクトリへ組み戻します。

- snapshot 親 commit の base tree
- tracked 変更
- untracked の追加分
- snapshot 作成時に取り込まれていた ignored subset

目標は、capture された lane 状態を byte-for-byte で round-trip 復元できることです。

## 検証

リポジトリルートで worktree snapshot 用スイートを実行します。

```sh
bash tests/test_wt_snapshot.sh
```
