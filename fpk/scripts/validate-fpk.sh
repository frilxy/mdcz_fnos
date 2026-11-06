#!/usr/bin/env bash
# fpk 工程静态校验：文件齐全、JSON 合法、manifest 与入口一致、图标规格、
# 生命周期脚本语法与可执行权限、运行时载荷完整（含 x86_64 原生模块）。
#
# 用法：validate-fpk.sh [应用目录]（默认 fpk/build/fpk）
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fpk="${1:-${root}/fpk/build/fpk}"

fail() {
    echo "校验失败：$*" >&2
    exit 1
}
ok() { echo "  ✓ $*"; }

echo "== 1. 必需文件 =="
for f in \
    manifest config/privilege config/resource ICON.PNG ICON_256.PNG \
    app/ui/config app/ui/images/icon_64.png app/ui/images/icon_256.png app/supervisor.mjs \
    cmd/main cmd/install_init cmd/install_callback cmd/upgrade_init cmd/upgrade_callback \
    cmd/config_init cmd/config_callback cmd/uninstall_init cmd/uninstall_callback \
    cmd/lib/common.sh \
    wizard/install wizard/config wizard/upgrade wizard/uninstall; do
    [ -f "${fpk}/${f}" ] || fail "缺少 ${f}"
done
ok "全部必需文件存在"

echo "== 2. JSON 文件 =="
for f in config/privilege config/resource app/ui/config wizard/install wizard/config wizard/upgrade wizard/uninstall; do
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "${fpk}/${f}" ||
        fail "${f} 不是合法 JSON"
done
ok "JSON 全部可解析"

echo "== 3. manifest 与入口 =="
python3 - "${fpk}/manifest" "${fpk}/app/ui/config" <<'PY'
import json
import re
import sys

manifest_path, ui_path = sys.argv[1], sys.argv[2]
entries = {}
for line in open(manifest_path, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    entries[key.strip()] = value.strip()

required = [
    "appname", "version", "display_name", "desc", "source", "platform",
    "maintainer", "maintainer_url", "os_min_version", "desktop_uidir",
    "desktop_applaunchname", "changelog",
]
missing = [key for key in required if not entries.get(key)]
if missing:
    raise SystemExit(f"manifest 缺少字段：{', '.join(missing)}")
if entries["appname"] != "mdcz":
    raise SystemExit("manifest.appname 必须是 mdcz")
if entries["source"] != "thirdparty":
    raise SystemExit("manifest.source 必须是 thirdparty")
if entries["platform"] not in ("x86", "all"):
    raise SystemExit(f"manifest.platform 取值不合法：{entries['platform']}")
if not re.fullmatch(r"\d+\.\d+\.\d+(\.\d+)?", entries["version"]):
    raise SystemExit(f"manifest.version 格式不合法：{entries['version']}")
if entries["desktop_uidir"] != "ui":
    raise SystemExit("manifest.desktop_uidir 必须是 ui")
if entries.get("install_dep_apps") != "nodejs_v24":
    raise SystemExit("manifest.install_dep_apps 必须是 nodejs_v24")
if entries.get("disable_authorization_path") != "false":
    raise SystemExit("必须允许用户在应用设置里授权媒体目录")

ui = json.load(open(ui_path, encoding="utf-8"))
urls = ui.get(".url", {})
launch = entries["desktop_applaunchname"]
if launch not in urls:
    raise SystemExit(f"app/ui/config 中不存在入口 {launch}")
entry = urls[launch]
if entry.get("port") != "${wizard_port}":
    raise SystemExit("入口端口必须使用 ${wizard_port}，与向导字段保持一致")
if entry.get("type") not in ("iframe", "url"):
    raise SystemExit("入口 type 必须是 iframe 或 url")
if entry.get("icon") != "images/icon_{0}.png":
    raise SystemExit("入口图标必须使用 images/icon_{0}.png")
print(f"  appname={entries['appname']} version={entries['version']} 入口={launch} 端口=${{wizard_port}}")
PY
ok "manifest 字段与桌面入口一致"

echo "== 4. 图标规格 =="
python3 - "${fpk}/ICON.PNG" "${fpk}/ICON_256.PNG" <<'PY'
import struct
import sys

for path, expect in ((sys.argv[1], 64), (sys.argv[2], 256)):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} 不是 PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (expect, expect):
        raise SystemExit(f"{path} 尺寸为 {width}x{height}，期望 {expect}x{expect}")
    if len(data) > 1024 * 1024:
        raise SystemExit(f"{path} 超过 1MB")
    print(f"  {path.split('/')[-1]}: {width}x{height}")
PY
ok "图标尺寸与体积符合要求"

echo "== 5. 生命周期脚本 =="
for name in main install_init install_callback upgrade_init upgrade_callback config_init config_callback uninstall_init uninstall_callback lib/common.sh; do
    path="${fpk}/cmd/${name}"
    [ -x "${path}" ] || fail "cmd/${name} 没有可执行权限"
    head -n 1 "${path}" | grep -q '^#!' || fail "cmd/${name} 缺少 shebang"
    sh -n "${path}" || fail "cmd/${name} 语法错误"
done
node --check "${fpk}/app/supervisor.mjs" || fail "supervisor.mjs 语法错误"
if grep -rnE '(^|[^a-zA-Z])docker([^a-zA-Z]|$)' "${fpk}/cmd" >/dev/null 2>&1; then
    fail "生命周期脚本中不应出现 Docker 依赖"
fi
ok "9 个生命周期脚本 + 守护进程脚本语法正确，且不依赖 Docker"

echo "== 6. 运行时载荷 =="
for f in app/server.js app/package.json app/web/index.html app/persistence/drizzle app/resources/mapping_table; do
    [ -e "${fpk}/${f}" ] || fail "缺少 ${f}"
done
native_modules=$(find "${fpk}/app/node_modules" -name '*.node' 2>/dev/null | wc -l)
[ "${native_modules}" -ge 3 ] || fail "原生模块数量异常（${native_modules}），需要 better-sqlite3 / sharp / impit"
for module in \
    app/node_modules/better-sqlite3/build/Release/better_sqlite3.node \
    app/node_modules/impit-linux-x64-gnu/impit-node.linux-x64-gnu.node; do
    [ -f "${fpk}/${module}" ] || fail "缺少 ${module}"
    file "${fpk}/${module}" | grep -q 'x86-64' || fail "${module} 不是 x86_64 二进制"
done
if find "${fpk}/app/node_modules" -type l | grep -q .; then
    fail "node_modules 中仍有符号链接，打包后可能失效"
fi
ok "运行时文件与 x86_64 原生模块完整，无符号链接"

echo "== 7. 数据目录与端口逻辑 =="
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/var" "${tmp}/etc" "${tmp}/share"
env -i PATH="${PATH}" TRIM_APPNAME=mdcz TRIM_APPDEST="${tmp}/app" TRIM_PKGVAR="${tmp}/var" \
    TRIM_PKGETC="${tmp}/etc" TRIM_PKGTMP="${tmp}/tmp" TRIM_DATA_SHARE_PATHS="${tmp}/share" \
    MDCZ_DATA_ROOT="${tmp}/share" wizard_port=9123 \
    sh -c ". '${fpk}/cmd/lib/common.sh'; mdcz_paths; mdcz_ensure_dirs; printf 'port=%s\n' \"\$(mdcz_resolve_port)\"; printf 'root=%s\n' \"\${MDCZ_DATA_ROOT}\"; printf 'config=%s\n' \"\${MDCZ_CONFIG_DIR}\"" \
    >"${tmp}/out" 2>"${tmp}/err" || {
    cat "${tmp}/err"
    fail "共享函数库执行失败"
}

grep -qx 'port=9123' "${tmp}/out" || fail "端口解析结果不正确"
grep -qx "root=${tmp}/share" "${tmp}/out" || fail "数据目录没有使用 TRIM_DATA_SHARE_PATHS"
[ "$(cat "${tmp}/etc/web-port")" = "9123" ] || fail "端口没有持久化到 etc/web-port"
for dir in config database cache logs backups; do
    [ -d "${tmp}/share/${dir}" ] || fail "没有创建数据子目录 ${dir}"
done
[ -f "${tmp}/share/logs/lifecycle.log" ] || fail "没有创建生命周期日志"
ok "端口解析/持久化、数据目录结构正确"

echo "全部校验通过。"
