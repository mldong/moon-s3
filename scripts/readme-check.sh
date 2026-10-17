#!/usr/bin/env bash
# 把每个 README 的「最小用法」代码块逐字抽出来，灌进一个指向本仓源码的独立工程，真编译真跑。
#
# 判的是"文档写的形状就是用户抄了能跑的东西"。本仓还没发布到注册表，所以只有 source 一档：
# 临时 workspace 的 members 指向仓内各模块，pin 也从各模块 moon.mod 现读，不写死版本号。
# 等发布之后再补 registry 一档（判"用户今天照 README 敲能不能装到"）。
#
# 通过 = 零警告 + failed: 0。警告不许豁免：抽出来的代码是真代码，报警告就是真问题。
set -euo pipefail
: "${MOON_HOME:?需要先 export MOON_HOME}"
cd "$(dirname "$0")/.."
REPO=$(pwd -W 2>/dev/null || pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moonfs-readme-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

MODULES=(.)
CHECK="$WORK/readme_check"
mkdir -p "$CHECK"

{
  echo 'members = ['
  for m in "${MODULES[@]}"; do echo "  \"$REPO\","; done
  echo '  "./readme_check",'
  echo ']'
} > "$WORK/moon.work"

VERSION=$(sed -nE 's/^version = "([^"]+)".*/\1/p' moon.mod | head -1)
ASYNC=$(sed -nE 's/.*"moonbitlang\/async@([^"]+)".*/\1/p' moon.mod | head -1)
# HTTP 传输端口的 pin 从"需要它的那个模块"现读，别从 core 取（core 不引 http 包）
HUTOOL=$(sed -nE 's/.*"mldong\/moon-hutool@([^"]+)".*/\1/p' moon.mod | head -1)
{
  echo 'name = "mldong/readme_check"'
  echo 'version = "0.0.0"'
  echo 'preferred_target = "wasm"'
  echo 'import {'
  for pkg in mldong/moon-s3; do
    echo "  \"$pkg@$VERSION\","
  done
  echo "  \"moonbitlang/async@$ASYNC\","
  echo "  \"mldong/moon-hutool@$HUTOOL\","
  echo '}'
} > "$CHECK/moon.mod"

python - "$REPO" "$CHECK" <<'PY'
import io, os, re, sys

repo, check = sys.argv[1], sys.argv[2]
files = ["README.md"]
# alias -> 包路径；抽出来的代码里出现过 @alias. 才引，多引一个包对包本身就是 unused_package。
ALIASES = [
    ("model", "mldong/moon-file-storage/model"),
    ("platform", "mldong/moon-file-storage/platform"),
    ("storage", "mldong/moon-file-storage/storage"),
    ("transport", "mldong/moon-hutool/http"),
    ("sdk", "mldong/moon-s3/s3"),
    ("sigv4", "mldong/moon-s3/sigv4"),
    ("kodo", "mldong/moon-kodo/kodo"),
    ("kodoauth", "mldong/moon-kodo/auth"),
    ("kodoconfig", "mldong/moon-kodo/config"),
    ("qiniu", "mldong/moon-file-storage-qiniu/qiniu"),
    ("ftp", "mldong/moon-file-storage-ftp/ftp"),
    ("s3", "mldong/moon-file-storage-s3/s3"),
    ("local", "mldong/moon-file-storage-local/local"),
    ("record", "mldong/moon-file-storage-recorder-file/file"),
]
RUNTIME = [
    ("fs", "moonbitlang/async/fs"),
    ("io", "moonbitlang/async/io"),
    ("utf8", "moonbitlang/core/encoding/utf8"),
]

blocks = []
for rel in files:
    path = os.path.join(repo, rel)
    if not os.path.exists(path):
        continue
    src = io.open(path, encoding="utf-8").read()
    found = re.search(r"## 最小用法\s+```moonbit\n(.*?)\n```", src, re.S)
    if not found:
        print("skip (no 最小用法 block): %s" % rel)
        continue
    code = found.group(1)
    if "async test" not in code and "test \"" not in code:
        raise SystemExit("README block without a test: %s" % rel)
    name = re.sub(r"[^a-z0-9]+", "_", rel.replace("/README.md", "").replace(".md", ""))
    io.open(os.path.join(check, "readme_%s_test.mbt" % name), "w",
            encoding="utf-8", newline="\n").write(code + "\n")
    blocks.append((rel, code))
if not blocks:
    raise SystemExit("一个 README 代码块都没抽到，这条门禁等于没跑")

allcode = "\n".join(c for _, c in blocks)
entries = []
for alias, pkg in ALIASES + RUNTIME:
    if ("@" + alias + ".") in allcode:
        entries.append('  "%s" @%s,' % (pkg, alias))
# async 运行时只在抽出来的代码真用得上时才引：某仓的文档块可能是纯同步的（例如只算签名与 URL），
# 无条件引就是 unused_package 警告，零警告口径下会把那条仓的门禁永久钉红。
if any(tok in allcode for tok in ("async test", "await ", "@async.")):
    entries.append('  "moonbitlang/async",')
Q = chr(34)
text = (
    "import {" + "\n" + "\n".join(entries) + "\n"
    + "} for " + Q + "test" + Q + "\n\n"
    + "supported_targets = " + Q + "wasm+native" + Q + "\n"
)
io.open(os.path.join(check, "moon.pkg"), "w", encoding="utf-8", newline="\n").write(text)
print("extracted %d block(s), imports %d" % (len(blocks), len(entries)))
PY

cd "$WORK"
log=$(moon test --target wasm -j 1 ./readme_check 2>&1) || true
printf '%s\n' "$log" | tail -5
if printf '%s' "$log" | grep -q "Warning"; then
  printf '%s\n' "$log" | grep -B2 -A 8 "Warning" | head -40
  echo "README CHECK FAIL: 抽出来的代码有警告（零警告口径下这是错误）" >&2
  exit 1
fi
if printf '%s' "$log" | grep -q "failed: 0"; then
  echo "README CHECK PASS（零警告，真编译真跑）"
else
  echo "README CHECK FAIL" >&2
  exit 1
fi
