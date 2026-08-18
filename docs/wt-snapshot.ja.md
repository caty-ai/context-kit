# wt-snapshot

## 何のためのものか

`wt-snapshot` は、worktree の削除をあとから巻き戻せるようにするための CLI です。

人が Git worktree を消す前に実行すると、リポジトリ metadata を除く worktree の full copy と、必要な staged-index 差分を main リポジトリ側へ退避します。

- worktree `HEAD` からの tracked 変更
- worktree ファイル自体が `HEAD` と同じ場合も含む staged 変更
- clean な populated submodule の staged gitlink 変更
- nested path を含む untracked ファイル
- 空の untracked ディレクトリ
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

snapshot に staged 変更がある場合、restore は target を保存時の `HEAD` にある Git リポジトリとして初期化し、保存した binary patch を index にだけ再適用します。ディスク上のファイルは capture 時の worktree bytes のままで、`git diff --cached` や `git show :path` から別保存された staged 状態を確認できます。

### Prune

期限切れの snapshot ref 候補を、削除せず一覧表示します。

```sh
wt-snapshot prune
```

`prune` は `CK_WTSNAP_TTL_DAYS`（デフォルト `30`）で期限切れ判定を行い、人が後で確認・削除判断するための候補だけを出します。

## tar 要件

capture には、このツールが使う archive の作成・一覧・展開ができる local `tar` が必要です。Linux / GNU tar での `wt-snapshot` は、まだ実機検証していません。

各 capture invocation の開始時に、`wt-snapshot` は小さな test archive を作成・検査し、続いて `--no-mac-metadata`、`--no-xattrs`、`--no-acls`、`--no-fflags` を1つずつ probe します。以降の tar command には、受理された suppression option だけを渡します。未対応 option は stderr の `tar metadata suppression unavailable: ...` で明示し、対応済み subset で capture を続行しますが、設定済み raw-archive scan と厳密な member-set verification は必須のままです。基礎 archive の作成・検証に失敗して安全な構成を確定できない場合は、pack 前に `tar capability probe failed: ...` と exit `70` で中断します。

## Capture 契約

`wt-snapshot` は false safety を避けるため、次を対象にします。

- dirty な tracked ファイルを含める
- index と `HEAD` を比較し、staged-only 差分を別に保存する
- assume-unchanged / skip-worktree path は porcelain を信用せず `HEAD` と直接比較する。通常の sparse checkout のように path が存在しない場合も、index entry が `HEAD` と一致すれば clean と扱う
- staged gitlink 変更は保存済み index patch に含め、target index へ復元する
- untracked ファイルを含める
- 空の untracked ディレクトリを含める
- ignored パスは `CK_WTSNAP_INCLUDE_IGNORED` に一致したものだけを含める
- worktree が clean でも、その `HEAD` が main リポジトリ内の ref からすでに到達可能な場合にだけ no-op にする

worktree、index、flag 付き tracked path、untracked set、設定済み ignored set がすべて clean で、かつその `HEAD` が main リポジトリ内の ref から到達可能な場合だけ、`wt-snapshot` は明示的な no-op メッセージを出して `0` で終了し、何も書きません。

### Submodule

version 1 は submodule working tree を再帰 capture しません。clean な populated submodule は、その `.git` gitfile も含め payload から除外します。`.git` entry のない未初期化 submodule は populated と扱わず、clean no-op を妨げません。populated submodule の checkout が staged 済みの親 gitlink と異なる場合、または staged・modified・untracked・ignored・flag に隠れた content（recursive に検査する nested submodule を含む）がある場合は、exit `75` と `submodule dirt present — not captured, do not delete` で capture を停止します。新しく staged した gitlink と同じ commit にある clean な populated submodule は、gitlink 差分を index patch へ保存できるため安全に capture できます。未 capture の submodule 作業を削除可と誤認させないための意図的な拒否です。

untracked の nested repository は別扱いです。working file は明示的に capture しますが、nested `.git` file / directory はすべて除外します。

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

ツールは非再帰の明示的な archive path list を1つ凍結し、scan と pack の両方が同じ list を消費します。directory root は先に展開されるため、untracked nested repository 内の file が scan を通らず tar payload に入ることはありません。archive 作成時は permission bits を保持しつつ、前述の capability probe で対応を確認できた AppleDouble / macOS metadata、extended attributes、ACLs、file flags の suppression を要求します。作成後は tar から member path と directory type を直接読み、凍結済み path / directory list と byte-exact な NUL-delimited set として比較します。比較のための第2 extraction root に対する filesystem lookup は行いません。不一致は object や ref を書く前に exit `70` で中断します。

scanner 設定時は、凍結した payload から candidate file bytes を scan した後、残存 archive metadata channel への fail-closed な備えとして raw tar stream 全体を1回 scan します。変更された index blob も binary content を含む raw bytes のまま scanner へ流し、staged-index patch も snapshot object を書く前に scan します。

scan-hit と git failure を機械的に区別したい場合は、scanner wrapper 側で専用の非ゼロ終了コードを割り当てる想定です。

## Restore 契約

`restore` は full-copy payload を fresh な一時 staging directory へ展開し、その後で空の target へ materialize します。file bytes、symlink、permission bits、capture 済みの空 directory を保持します。検証済み macOS tar path では、extended attributes、ACLs、file flags、AppleDouble metadata は意図的に capture しません。local tar に未対応の suppression option がある場合は警告し、その metadata channel を除去したとは扱いません。残存する raw archive bytes は、scanner 設定時には引き続き scan 対象です。base tree を復元して worktree delta を適用する方式ではなく、この明示済み metadata 境界内で payload 自体が capture 時の worktree 完全コピーです。保存済み staged-index patch だけは前述のとおり target の Git index に適用します。

snapshot は信頼済みの local artifact として扱います。restore は展開前に absolute member name と `..` path component を拒否し、`--no-same-owner` を付けて target 外の一時領域へ展開します。ただし手作りの hostile ref は link などの archive 機能について platform `tar` の挙動に依存します。信頼できない repository の ref は restore しないでください。

## 検証

リポジトリルートで worktree snapshot 用スイートを実行します。

```sh
bash tests/test_wt_snapshot.sh
```
