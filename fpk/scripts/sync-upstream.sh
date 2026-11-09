#!/usr/bin/env bash
# 检查上游 MDCz 最新正式版；有更新时同步版本号、重新构建并跑生命周期模拟。
#
# 用法：
#   sync-upstream.sh                 检查最新版，有更新就构建
#   sync-upstream.sh --check-only    只检查，不修改/构建
#   sync-upstream.sh --target 0.22.0 指定上游版本（可带 v 前缀）
#
# 输出（同时写入 $GITHUB_OUTPUT）：
#   changed=true|false
#   version=<上游版本>
#   tag=v<上游版本>
#   fpk=dist/mdcz-<版本>.fpk
#   sha256=...
#   size=...
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fpk="${root}/fpk"
upstream_repo="${MDCZ_UPSTREAM_REPO:-ShotHeadman/mdcz}"
check_only=0
target="${TARGET_VERSION:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
    --check-only) check_only=1 ;;
    --target)
        target="${2:-}"
        shift
        ;;
    *)
        echo "未知参数：$1" >&2
        exit 2
        ;;
    esac
    shift
done
target="${target#v}"

die() {
    echo "错误：$*" >&2
    exit 1
}

gh_curl() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" "$@"
    else
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
            -H "Accept: application/vnd.github+json" "$@"
    fi
}

emit() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
    fi
    printf '%s=%s\n' "$1" "$2"
}

is_newer() {
    [ "$1" != "$2" ] || return 1
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1)" = "$1" ]
}

[ -f "${fpk}/upstream-version" ] || die "缺少 fpk/upstream-version"
current="$(head -n 1 "${fpk}/upstream-version" | tr -d ' \r')"
[ -n "${current}" ] || die "fpk/upstream-version 为空"

if [ -z "${target}" ]; then
    api="https://api.github.com/repos/${upstream_repo}/releases/latest"
    tag="$(gh_curl "${api}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name") or "")')" ||
        die "无法读取上游最新 release（${upstream_repo}）"
    target="${tag#v}"
fi

case "${target}" in
[0-9]*.[0-9]*.[0-9]*) ;;
*) die "上游版本格式不合法：${target}" ;;
esac

if ! is_newer "${target}" "${current}"; then
    echo "上游最新 v${target}，当前已同步 v${current}，无需更新"
    emit changed false
    emit version "${current}"
    exit 0
fi

# 用 GitHub API 检查发行包是否已上传，避免直连 releases CDN 时的 5xx
release_url="https://api.github.com/repos/${upstream_repo}/releases/tags/v${target}"
asset_names="$(gh_curl "${release_url}" | python3 -c 'import json,sys; print("\n".join(a.get("name","") for a in json.load(sys.stdin).get("assets",[])))')" ||
    die "无法读取 v${target} 的 release 信息"
grep -qx "mdcz-${target}.tar.gz" <<<"${asset_names}" ||
    die "v${target} 的发行包尚未就绪（release 中没有 mdcz-${target}.tar.gz）"
grep -qx "SHA256SUMS.txt" <<<"${asset_names}" ||
    die "v${target} 的发行包尚未就绪（release 中没有 SHA256SUMS.txt）"

echo "发现上游新版本：v${current} -> v${target}"
if [ "${check_only}" -eq 1 ]; then
    emit changed true
    emit version "${target}"
    emit tag "v${target}"
    exit 0
fi

printf '%s\n' "${target}" >"${fpk}/upstream-version"
python3 - "${fpk}/manifest" "${target}" <<'PY'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

def set_key(text, key, value):
    pattern = re.compile(rf"^({re.escape(key)}\s*)=\s*.*$", re.MULTILINE)
    if not pattern.search(text):
        raise SystemExit(f"manifest 中缺少字段 {key}")
    return pattern.sub(lambda match: f"{match.group(1)}= {value}", text, count=1)

text = set_key(text, "version", version)
text = set_key(
    text,
    "changelog",
    f"同步上游 MDCz v{version}：使用官方非 Docker 发行包，Node.js 24 原生运行；保留 fnOS 生命周期、自动 trimacl ACL 修复与升级备份。",
)
open(path, "w", encoding="utf-8").write(text)
print(f"manifest: version={version}")
PY

bash "${fpk}/scripts/prepare-runtime.sh"
bash "${fpk}/scripts/build-fpk.sh"
bash "${fpk}/scripts/simulate-lifecycle.sh"

fpk_path="dist/mdcz-${target}.fpk"
[ -f "${root}/${fpk_path}" ] || die "构建产物不存在：${fpk_path}"
sha="$(sha256sum "${root}/${fpk_path}" | awk '{ print $1 }')"
size="$(stat -c '%s' "${root}/${fpk_path}")"

emit changed true
emit version "${target}"
emit tag "v${target}"
emit fpk "${fpk_path}"
emit sha256 "${sha}"
emit size "${size}"
echo "同步完成：${fpk_path}（${size} 字节，sha256 ${sha}）"
