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

version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "${fpk}/manifest" | head -n 1 | tr -d ' \r')"
[ -n "${version}" ] || die "fpk/manifest 中没有 version 字段"
version="${MDCZ_VERSION:-${version}}"
tag="v${version}"

mkdir -p "${cache}" "${build}"

archive="${cache}/mdcz-${version}.tar.gz"
sums="${cache}/SHA256SUMS-${version}.txt"
if [ ! -f "${archive}" ]; then
    url="https://github.com/${upstream_repo}/releases/download/${tag}/mdcz-${version}.tar.gz"
    echo "下载官方发行包：${url}"
    curl -fsSL --retry 3 --retry-delay 3 -o "${archive}.part" "${url}"
    mv "${archive}.part" "${archive}"
fi
if [ ! -f "${sums}" ]; then
    curl -fsSL --retry 3 --retry-delay 3 -o "${sums}.part" \
        "https://github.com/${upstream_repo}/releases/download/${tag}/SHA256SUMS.txt" ||
        die "无法下载 SHA256SUMS.txt（版本 ${version}）"
    mv "${sums}.part" "${sums}"
fi

expected="$(awk -v name="./mdcz-${version}.tar.gz" '$2 == name { print $1 }' "${sums}" | head -n 1)"
[ -n "${expected}" ] || die "SHA256SUMS.txt 中没有 mdcz-${version}.tar.gz 的校验值"
actual="$(sha256sum "${archive}" | awk '{ print $1 }')"
[ "${actual}" = "${expected}" ] || die "发行包校验失败：期望 ${expected}，实际 ${actual}"
echo "官方发行包校验通过：sha256 ${actual}"

extract_root="${build}/upstream"
rm -rf "${extract_root}"
mkdir -p "${extract_root}"
tar -xzf "${archive}" -C "${extract_root}"
src="${extract_root}/mdcz-${version}"
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

echo "运行时载荷已就绪：${runtime}"
