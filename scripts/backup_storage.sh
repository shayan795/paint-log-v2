#!/bin/bash
# =====================================================================
# backup_storage.sh — 投稿写真(Supabase Storage)のバックアップ
#
#   使い方:  bash scripts/backup_storage.sh
#
# ---------------------------------------------------------------------
# ★★★ 最初に必ず読むこと：このスクリプトだけでは「完全なバックアップ」に
#      ならない ★★★
#
#   このスクリプトは匿名キー(公開キー)しか持っていない。
#   そのため自動で集められるのは「公開レシピ・公開プロフィールが
#   参照している画像」だけで、次のものは **1枚も取れない**:
#     ・非公開レシピの画像
#     ・下書き(drafts)の画像
#     ・どこからも参照されていない孤児ファイル
#   つまり「成功」と出ても、それは “公開分だけは揃った” という意味でしかない。
#
#   【完全版バックアップの手順（月1回はこちらを推奨）】
#     1) Supabaseダッシュボード → SQL Editor で次を実行する:
#          select bucket_id || '/' || name
#            from storage.objects
#           where bucket_id in ('recipes','profile')
#           order by 1;
#     2) 結果(パスの一覧)をコピーして
#          scripts/storage_paths.local.txt
#        にそのまま貼り付けて保存する（1行1パス。Git管理外）。
#     3) もう一度このスクリプトを実行する。
#        → ファイルがあればそれを優先して使い、非公開・下書きも含めて漏れゼロになる。
#     ※ 非公開画像も「URLを知っていれば誰でも取得できる」公開バケットなので、
#        パス一覧さえ用意できれば匿名キーのままダウンロードできる。
# ---------------------------------------------------------------------
#
#   なぜ必要か:
#     既存の自動バックアップは pg_dump（データベースの中身）だけで、
#     利用者がアップロードした「写真」は1枚もバックアップされない。
#     写真が消えるとDBにはURLだけが残り、全レシピがリンク切れになる。
#     利用者が撮り直せない完成品の写真なので、消えたら取り返しがつかない。
#
#   以前の版はパス一覧を手作業でSQLからコピーする方式だったため、
#   実行を忘れると静かに漏れが増えた（実際に4ファイル漏れていた）。
#   この版は公開データが参照しているURLをAPIから自動収集するので、
#   最低限の分は手作業なしで確保できる。
#
#   ★失敗の扱い（重要）:
#     以前は失敗しても終了コード0（成功）で終わっていたため、
#     cron等に載せても「壊れているのに気づけない」状態だった。
#     この版は set -euo pipefail ＋ 1件でも取得失敗したら終了コード1で終わる。
#     → 呼び出し側（cron / GitHub Actions）が異常を検知できる。
# =====================================================================
set -euo pipefail

SUPABASE_URL="https://zlkbaojclitlxshpxwpr.supabase.co"
ANON_KEY="sb_publishable_ZMaz3JjPfU0q_pq7Y9QwSQ_QimbhfgX"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../backups/storage"      # 世代（YYYYMMDD）を並べる親フォルダ
STAMP="$(date +%Y%m%d)"
DEST="$ROOT/$STAMP"
LIST="$HERE/storage_paths.local.txt"
KEEP_GENERATIONS=7                   # 何世代残すか（古いものから自動削除）

# 途中でエラー終了しても一時ファイルを残さない
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

mkdir -p "$DEST"

# ---------------------------------------------------------------------
# 1) 取得対象のパス一覧を作る
# ---------------------------------------------------------------------
MODE=""
if [ -f "$LIST" ]; then
  MODE="完全版（storage_paths.local.txt を使用）"
  echo "パス一覧: $LIST を使用（完全版・非公開/下書きも含む）"
  cp "$LIST" "$TMP"
else
  MODE="公開分のみ（非公開・下書きは未取得）"
  echo "パス一覧: 公開データから自動収集（★非公開・下書きは対象外）"
  # 公開レシピの cover_url と grid 内の写真URL、プロフィール画像を集める。
  # ここは curl → python3 のパイプなので、pipefail により curl 失敗も検知できる。
  curl -sS --fail "$SUPABASE_URL/rest/v1/recipes?is_public=eq.true&select=cover_url,grid" \
       -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
  | python3 -c '
import json,sys,re
data=json.load(sys.stdin)
# APIがエラーを返すと配列ではなく辞書({"message":...})が返る。黙って0件にしないため落とす。
if not isinstance(data,list):
    sys.stderr.write("recipes APIが配列を返しませんでした: %r\n" % (data,)); sys.exit(1)
out=set()
for r in data:
    urls=[r.get("cover_url")]
    g=r.get("grid") or {}
    urls += (g.get("photos") or [])
    for e in (g.get("rows") or []):
        if isinstance(e,dict): urls.append(e.get("photo"))
    for u in urls:
        if not u: continue
        m=re.search(r"/object/public/(.+)$", u)
        if m: out.add(m.group(1))
for p in sorted(out): print(p)
' > "$TMP"
  curl -sS --fail "$SUPABASE_URL/rest/v1/profiles?select=avatar_url,header_url" \
       -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
  | python3 -c '
import json,sys,re
data=json.load(sys.stdin)
if not isinstance(data,list):
    sys.stderr.write("profiles APIが配列を返しませんでした: %r\n" % (data,)); sys.exit(1)
out=set()
for r in data:
    for u in (r.get("avatar_url"), r.get("header_url")):
        if not u: continue
        m=re.search(r"/object/public/(.+)$", u)
        if m: out.add(m.group(1))
for p in sorted(out): print(p)
' >> "$TMP"
fi

# grep -c は0件のとき終了コード1を返す。set -e で落ちないよう || true で受ける。
total=$(grep -c . "$TMP" || true)
total=${total:-0}
echo "対象: ${total} ファイル"

# 対象0件は「取れた」ではなく異常（APIの仕様変更・キー失効など）とみなす
if [ "$total" -eq 0 ]; then
  echo "エラー: 取得対象が0件でした。APIの応答かキーを確認してください。" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 2) ダウンロード（既に取得済みのファイルはスキップ）
# ---------------------------------------------------------------------
ok=0; ng=0; skip=0
FAILED=""   # 失敗したパスを覚えておき、最後にまとめて表示する
while IFS= read -r p; do
  [ -z "$p" ] && continue
  out="$DEST/$p"
  mkdir -p "$(dirname "$out")"
  if [ -f "$out" ]; then skip=$((skip+1)); continue; fi
  # curl自体がネットワークエラーで落ちても set -e で即死しないよう if で受ける
  if code=$(curl -sS -o "$out" -w '%{http_code}' "$SUPABASE_URL/storage/v1/object/public/$p"); then
    :
  else
    code="000"   # 000 = 接続すらできなかった
  fi
  if [ "$code" = "200" ]; then
    ok=$((ok+1))
  else
    ng=$((ng+1)); rm -f "$out"
    FAILED="${FAILED}  取得失敗($code): $p"$'\n'
  fi
done < "$TMP"

# ---------------------------------------------------------------------
# 3) manifest.txt を作る（何をいつ取ったかの証拠。復元時の突き合わせにも使う）
# ---------------------------------------------------------------------
MANIFEST="$DEST/manifest.txt"
{
  echo "# 塗装レシピ録 Storageバックアップ manifest"
  echo "# 作成日時: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# 取得モード: $MODE"
  echo "# 形式: <バイト数><TAB><バケット/パス>"
  # manifest.txt 自身は一覧に含めない
  find "$DEST" -type f ! -name 'manifest.txt' | sort | while IFS= read -r f; do
    size=$(wc -c < "$f" | tr -d ' ')
    printf '%s\t%s\n' "$size" "${f#"$DEST"/}"
  done
} > "$MANIFEST"
manifest_count=$(grep -vc '^#' "$MANIFEST" || true)
manifest_count=${manifest_count:-0}

# ---------------------------------------------------------------------
# 4) 古い世代を自動削除（放置すると容量を食い続けるため）
# ---------------------------------------------------------------------
removed=""
# ★今回の取得に1件でも失敗があるときは、古い世代を消さない。
#   消してしまうと「中身の欠けた最新版」だけが残り、完全だった過去のバックアップを
#   自分の手で失うことになる。バックアップで最もやってはいけない壊し方なので、
#   失敗した回は容量が増えても必ず過去分を温存する。
if [ "$ng" -gt 0 ]; then
  old_gens=""
  echo "※ 取得に ${ng} 件の失敗があったため、古い世代の自動削除は行いません（過去の完全なバックアップを守るため）"
else
  # YYYYMMDD形式のフォルダだけを対象にする（誤って別物を消さないための安全弁）
  old_gens=$(ls -1 "$ROOT" 2>/dev/null | grep -E '^[0-9]{8}$' | sort -r | tail -n +$((KEEP_GENERATIONS+1)) || true)
fi
if [ -n "$old_gens" ]; then
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    case "$g" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
        rm -rf "${ROOT:?}/$g"
        removed="${removed}$g "
        ;;
    esac
  done <<< "$old_gens"
fi

# ---------------------------------------------------------------------
# 5) 結果のまとめ（人が読んで判断できる日本語で出す）
# ---------------------------------------------------------------------
echo ""
echo "──────── バックアップ結果 ────────"
echo "取得モード : $MODE"
echo "保存先     : $DEST"
echo "新規取得   : ${ok} 件"
echo "既存スキップ: ${skip} 件（前回までに取得済み）"
echo "失敗       : ${ng} 件"
echo "一覧       : $MANIFEST（${manifest_count} 件を記録）"
du -sh "$DEST" 2>/dev/null | awk '{print "合計サイズ : " $1}' || true
if [ -n "$removed" ]; then
  echo "世代削除   : $removed（直近${KEEP_GENERATIONS}世代のみ保持）"
else
  echo "世代削除   : なし（保持は直近${KEEP_GENERATIONS}世代）"
fi

# 直近のバックアップと比較して、増減を知らせる（漏れの早期発見）
prev=$(ls -1 "$ROOT" 2>/dev/null | grep -E '^[0-9]{8}$' | sort | grep -v "^${STAMP}$" | tail -1 || true)
if [ -n "$prev" ]; then
  a=$(find "$ROOT/$prev" -type f ! -name 'manifest.txt' 2>/dev/null | wc -l | tr -d ' ')
  b=$(find "$DEST"       -type f ! -name 'manifest.txt' 2>/dev/null | wc -l | tr -d ' ')
  echo "前回($prev) $a ファイル → 今回 $b ファイル"
  if [ "$b" -lt "$a" ]; then
    echo "  ※ ファイルが減っています。削除された投稿があるか、取得漏れの可能性があります。"
  fi
fi

if [ "$MODE" != "完全版（storage_paths.local.txt を使用）" ]; then
  echo ""
  echo "⚠ これは公開分だけのバックアップです。非公開・下書きの画像は含まれていません。"
  echo "  完全版にする手順は、このスクリプト冒頭のコメントを参照してください。"
fi

# 1件でも失敗したら異常終了する（黙って成功扱いにしない）
if [ "$ng" -gt 0 ]; then
  echo ""
  echo "以下のファイルが取得できませんでした（削除済みの画像なら想定内、それ以外は要調査）:" >&2
  printf '%s' "$FAILED" >&2
  echo "★ 失敗 ${ng} 件のため異常終了します（終了コード 1）" >&2
  exit 1
fi

echo ""
echo "✅ バックアップは正常に完了しました。"
