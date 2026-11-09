#!/usr/bin/env bash
# 准备 MDCz 运行时载荷：下载官方非 Docker 发行包，按官方 pnpm lockfile 安装生产依赖。
#
# 产物：fpk/build/runtime/
#   server.js  web/  persistence/  resources/  package.json  node_modules/ ...
#
# 说明：官方 mdcz-<version>.tar.gz 不含 node_modules，安装脚本会在目标机联网安装。
# 飞牛应用包必须在安装后即可离线运行，所以这里在构建阶段用官方 lockfile 装好依赖，
# 并连同 x86_64 预编译原生模块（better-sqlite3 / sharp / impit）一起打进 fpk。
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fpk="${root}/fpk"
cache="${FPK_CACHE_DIR:-${fpk}/.cache}"
build="${fpk}/build"
runtime="${build}/runtime"
upstream_repo="${MDCZ_UPSTREAM_REPO:-ShotHeadman/mdcz}"

die() {
    echo "错误：$*" >&2
    exit 1
}

fpk_version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "${fpk}/manifest" | head -n 1 | tr -d ' \r')"
[ -n "${fpk_version}" ] || die "fpk/manifest 中没有 version 字段"

# fpk 版本允许是 0.21.0.1 这类打包修订号；上游发行包版本单独记录，避免去下载不存在的 tag。
[ -f "${fpk}/upstream-version" ] || die "缺少 fpk/upstream-version（上游发行版本号）"
upstream_version="$(head -n 1 "${fpk}/upstream-version" | tr -d ' \r')"
upstream_version="${MDCZ_UPSTREAM_VERSION:-${upstream_version}}"
[ -n "${upstream_version}" ] || die "fpk/upstream-version 为空"
tag="v${upstream_version}"

mkdir -p "${cache}" "${build}"

archive="${cache}/mdcz-${upstream_version}.tar.gz"
release_api="https://api.github.com/repos/${upstream_repo}/releases/tags/${tag}"

gh_curl_json() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" "$1"
    else
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
            -H "Accept: application/vnd.github+json" "$1"
    fi
}

download_asset() {
    _url="$1"
    _out="$2"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
            -H "Accept: application/octet-stream" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -o "${_out}" "${_url}"
    else
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
            -H "Accept: application/octet-stream" \
            -o "${_out}" "${_url}"
    fi
}

# 走 GitHub API 的资产地址下载：github.com/releases/download 的 CDN 偶发 504，
# API 资产接口会重定向到对象存储，稳定得多。
release_json="$(gh_curl_json "${release_api}")" || die "无法读取上游 release ${tag}"
release_file="$(mktemp)"
printf '%s' "${release_json}" >"${release_file}"
asset_info="$(python3 - "${release_file}" "mdcz-${upstream_version}.tar.gz" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
want = sys.argv[2]
for asset in data.get("assets", []):
    if asset.get("name") == want:
        print(asset.get("url", ""))
        print(asset.get("digest") or "")
        break
PY
)" || die "无法解析上游 release 资产"
asset_url="$(printf '%s\n' "${asset_info}" | sed -n '1p')"
asset_digest="$(printf '%s\n' "${asset_info}" | sed -n '2p')"
[ -n "${asset_url}" ] || die "${tag} 的 release 中没有 mdcz-${upstream_version}.tar.gz"

if [ ! -f "${archive}" ]; then
    echo "下载官方发行包（GitHub API 资产）：mdcz-${upstream_version}.tar.gz"
    download_asset "${asset_url}" "${archive}.part" || die "下载官方发行包失败"
    mv "${archive}.part" "${archive}"
fi

expected="${asset_digest#sha256:}"
if [ -z "${expected}" ]; then
    sums_info="$(python3 - "${release_file}" "SHA256SUMS.txt" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
want = sys.argv[2]
for asset in data.get("assets", []):
    if asset.get("name") == want:
        print(asset.get("url", ""))
        break
PY
)"
    sums_url="$(printf '%s\n' "${sums_info}" | sed -n '1p')"
    [ -n "${sums_url}" ] || die "${tag} 没有 digest，也没有 SHA256SUMS.txt"
    sums_file="$(mktemp)"
    download_asset "${sums_url}" "${sums_file}" || die "无法下载 SHA256SUMS.txt"
    expected="$(awk -v name="./mdcz-${upstream_version}.tar.gz" '$2 == name { print $1 }' "${sums_file}" | head -n 1)"
    rm -f "${sums_file}"
fi
rm -f "${release_file}"
[ -n "${expected}" ] || die "无法获取 mdcz-${upstream_version}.tar.gz 的校验值"
actual="$(sha256sum "${archive}" | awk '{ print $1 }')"
[ "${actual}" = "${expected}" ] || die "发行包校验失败：期望 ${expected}，实际 ${actual}"
echo "官方发行包校验通过：sha256 ${actual}"

extract_root="${build}/upstream"
rm -rf "${extract_root}"
mkdir -p "${extract_root}"
tar -xzf "${archive}" -C "${extract_root}"
src="${extract_root}/mdcz-${upstream_version}"
[ -f "${src}/server.js" ] || die "发行包结构异常：缺少 server.js"
[ -d "${src}/web" ] || die "发行包结构异常：缺少 web/"
[ -f "${src}/pnpm-lock.yaml" ] || die "发行包结构异常：缺少 pnpm-lock.yaml"

if command -v corepack >/dev/null 2>&1; then
    pnpm_cmd=(corepack pnpm@10.28.2)
elif command -v pnpm >/dev/null 2>&1; then
    pnpm_cmd=(pnpm)
else
    die "需要 corepack 或 pnpm 来安装生产依赖（Node.js 24 自带 corepack）"
fi

echo "安装生产依赖（官方 lockfile，hoisted 布局）"
rm -rf "${runtime}"
cp -a "${src}" "${runtime}"
(
    cd "${runtime}"
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 "${pnpm_cmd[@]}" install \
        --ignore-workspace --prod --frozen-lockfile --node-linker=hoisted
)

node_bin="$(command -v node || true)"
[ -n "${node_bin}" ] || die "构建机缺少 node"
node_major="$("${node_bin}" -p 'process.versions.node.split(".")[0]')"
[ "${node_major}" -ge 24 ] || die "构建机 Node.js 版本过低（$("${node_bin}" -v)），需要 24+"

echo "校验原生依赖可加载"
(
    cd "${runtime}"
    "${node_bin}" --input-type=module -e '
const [{ default: Database }, sharp, impit] = await Promise.all([
  import("better-sqlite3"),
  import("sharp"),
  import("impit"),
]);
if (typeof Database !== "function") throw new Error("better-sqlite3 加载异常");
if (!sharp.default || typeof sharp.default !== "function") throw new Error("sharp 加载异常");
if (!impit || typeof impit !== "object") throw new Error("impit 加载异常");
console.log(`native ok: node ${process.versions.node}, sharp ${sharp.default.versions?.sharp ?? "unknown"}`);
'
)

echo "运行时载荷已就绪：${runtime}（上游 ${upstream_version}，应用版本 ${fpk_version}）"
