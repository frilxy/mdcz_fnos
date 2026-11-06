#!/usr/bin/env bash
# 组装并打包 fnOS 应用包。
#
#   1. 准备运行时载荷（官方发行包 + 官方 lockfile 安装的生产依赖）
#   2. 组装 fpk/build/fpk（manifest / config / cmd / wizard / app）
#   3. 静态校验，调用官方 fnpack 1.2.3 打包
#   4. 校验包内容，输出 dist/mdcz-<version>.fpk
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fpk="${root}/fpk"
build="${fpk}/build"
stage="${build}/fpk"
cache="${FPK_CACHE_DIR:-${fpk}/.cache}"
fn_pack_version="${FN_PACK_VERSION:-1.2.3}"
fn_pack_url="${FN_PACK_URL:-https://static2.fnnas.com/fnpack/fnpack-${fn_pack_version}-linux-amd64}"

die() {
    echo "错误：$*" >&2
    exit 1
}

version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "${fpk}/manifest" | head -n 1 | tr -d ' \r')"
[ -n "${version}" ] || die "fpk/manifest 中没有 version 字段"

mkdir -p "${cache}"
if [ ! -x "${cache}/fnpack-${fn_pack_version}" ]; then
    echo "下载 fnpack ${fn_pack_version}"
    curl -fsSL --retry 3 --retry-delay 3 -o "${cache}/fnpack.part" "${fn_pack_url}"
    chmod +x "${cache}/fnpack.part"
    mv "${cache}/fnpack.part" "${cache}/fnpack-${fn_pack_version}"
fi

if [ "${FPK_SKIP_RUNTIME:-0}" != "1" ] && [ ! -f "${fpk}/build/runtime/server.js" ]; then
    bash "${fpk}/scripts/prepare-runtime.sh"
fi
[ -f "${fpk}/build/runtime/server.js" ] || die "缺少运行时载荷，请先执行 fpk/scripts/prepare-runtime.sh"

echo "组装应用目录：${stage}"
rm -rf "${stage}"
mkdir -p "${stage}/app" "${stage}/cmd/lib" "${stage}/config" "${stage}/wizard"

cp "${fpk}/manifest" "${stage}/manifest"
cp "${fpk}/ICON.PNG" "${stage}/ICON.PNG"
cp "${fpk}/ICON_256.PNG" "${stage}/ICON_256.PNG"
cp "${fpk}/config/privilege" "${fpk}/config/resource" "${stage}/config/"
cp -a "${fpk}/cmd/." "${stage}/cmd/"
cp -a "${fpk}/wizard/." "${stage}/wizard/"
cp -a "${fpk}/app/ui" "${stage}/app/ui"
cp "${fpk}/app/supervisor.mjs" "${stage}/app/supervisor.mjs"

runtime="${fpk}/build/runtime"
for entry in server.js package.json web persistence resources; do
    [ -e "${runtime}/${entry}" ] || die "运行时缺少 ${entry}"
    cp -a "${runtime}/${entry}" "${stage}/app/${entry}"
done
cp -a "${runtime}/node_modules" "${stage}/app/node_modules"

# 运行期不需要 .bin 软链和类型声明，删掉可以避免符号链接在打包/解包时出错
find "${stage}/app/node_modules" -type d -name .bin -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "${stage}/app/node_modules/@types" "${stage}/app/node_modules/.modules.yaml" 2>/dev/null || true

chmod 755 "${stage}/cmd/main" "${stage}/cmd/install_init" "${stage}/cmd/install_callback" \
    "${stage}/cmd/upgrade_init" "${stage}/cmd/upgrade_callback" "${stage}/cmd/uninstall_init" \
    "${stage}/cmd/uninstall_callback" "${stage}/cmd/config_init" "${stage}/cmd/config_callback" \
    "${stage}/cmd/lib/common.sh"
chmod 644 "${stage}/app/supervisor.mjs"

bash "${fpk}/scripts/validate-fpk.sh" "${stage}"

echo "调用 fnpack 打包"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
(cd "${work}" && "${cache}/fnpack-${fn_pack_version}" build --directory "${stage}")
built="${work}/mdcz.fpk"
[ -f "${built}" ] || die "fnpack 没有生成 mdcz.fpk"

echo "校验包内容"
listing="$(tar -tzf "${built}")"
for entry in manifest config/privilege config/resource ICON.PNG ICON_256.PNG app.tgz \
    cmd/main cmd/install_init cmd/install_callback cmd/upgrade_init cmd/upgrade_callback \
    cmd/config_init cmd/config_callback cmd/uninstall_init cmd/uninstall_callback \
    cmd/lib/common.sh wizard/install wizard/config wizard/upgrade wizard/uninstall; do
    grep -qx -- "${entry}" <<<"${listing}" || die "fpk 中缺少 ${entry}"
done

packed_version="$(tar -xzOf "${built}" manifest | sed -n 's/^version[[:space:]]*=[[:space:]]*//p' | head -n 1 | tr -d ' \r')"
[ "${packed_version}" = "${version}" ] || die "包内版本 ${packed_version} 与 manifest ${version} 不一致"

app_listing="$(tar -xzOf "${built}" app.tgz | tar -tzf -)"
for entry in server.js supervisor.mjs web/index.html persistence/drizzle resources/mapping_table \
    ui/config ui/images/icon_64.png ui/images/icon_256.png \
    node_modules/better-sqlite3/build/Release/better_sqlite3.node; do
    grep -qx -- "${entry}" <<<"${app_listing}" || die "app.tgz 中缺少 ${entry}"
done

mkdir -p "${root}/dist"
out="${root}/dist/mdcz-${version}.fpk"
cp -f "${built}" "${out}"

sha="$(sha256sum "${out}" | awk '{ print $1 }')"
size="$(stat -c '%s' "${out}")"
echo "version=${version}"
echo "fpk=${out#${root}/}"
echo "sha256=${sha}"
echo "size=${size}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        printf 'version=%s\n' "${version}"
        printf 'fpk=%s\n' "${out#${root}/}"
        printf 'sha256=%s\n' "${sha}"
        printf 'size=%s\n' "${size}"
    } >>"${GITHUB_OUTPUT}"
fi
