#!/usr/bin/env bash
# 在普通 Linux 用户下模拟飞牛应用中心的完整生命周期：
#   安装 -> 启动 -> 健康检查 -> 崩溃自愈 -> 停止 -> 改端口 -> 升级 -> 卸载（保留/删除）
#
# 这不是真实 fnOS 安装（没有应用中心、共享目录 ACL、桌面入口），但会使用与安装后
# 完全相同的目录结构、TRIM_* 环境变量和生命周期脚本，可以验证脚本本身是否正确。
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fpk="${root}/fpk"
sim="${fpk}/build/sim"
version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "${fpk}/manifest" | head -n 1 | tr -d ' \r')"
pkg="${root}/dist/mdcz-${version}.fpk"
port1="${SIM_PORT_1:-3941}"
port2="${SIM_PORT_2:-3942}"
port3="${SIM_PORT_3:-3943}"

[ -f "${pkg}" ] || {
    echo "找不到 ${pkg}，请先执行 fpk/scripts/build-fpk.sh" >&2
    exit 1
}

fail() {
    echo "失败：$*" >&2
    echo "--- 服务日志（最后 60 行）---" >&2
    tail -n 60 "${sim}/@appshare/mdcz/logs/mdcz.log" 2>/dev/null >&2 || true
    echo "--- 生命周期日志（最后 60 行）---" >&2
    tail -n 60 "${sim}/@appshare/mdcz/logs/lifecycle.log" 2>/dev/null >&2 || true
    exit 1
}

pass() { echo "  ✓ $*"; }

node_dir="$(dirname "$(command -v node)")"
node_dir="$(cd "${node_dir}" && pwd)"

app_env() {
    env -i \
        PATH="${node_dir}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="${sim}/home" \
        TRIM_APPNAME=mdcz \
        TRIM_APPDEST="${sim}/apps/mdcz/target" \
        TRIM_PKGVAR="${sim}/apps/mdcz/var" \
        TRIM_PKGETC="${sim}/apps/mdcz/etc" \
        TRIM_PKGTMP="${sim}/apps/mdcz/tmp" \
        TRIM_PKGHOME="${sim}/apps/mdcz/home" \
        TRIM_APPDEST_VOL="${sim}" \
        TRIM_DATA_SHARE_PATHS="${sim}/@appshare/mdcz" \
        TRIM_UID="$(id -u)" \
        TRIM_GID="$(id -g)" \
        TRIM_USERNAME="$(id -un)" \
        TRIM_GROUPNAME="$(id -gn)" \
        TRIM_APPVER="${version}" \
        TRIM_TEMP_LOGFILE="${sim}/temp.log" \
        "$@"
}

lifecycle() {
    local script="$1"
    shift
    app_env sh "${sim}/apps/mdcz/cmd/${script}" "$@"
}

health() {
    curl -fsS --max-time 3 "http://127.0.0.1:$1/health" 2>/dev/null | grep -q '"status":"ok"'
}

wait_health() {
    local port="$1" deadline=$((SECONDS + 40))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        health "${port}" && return 0
        sleep 1
    done
    return 1
}

port_free() {
    ! ss -ltn 2>/dev/null | awk '{ print $4 }' | grep -qE "[:.]$1\$"
}

cleanup() {
    lifecycle main stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== 准备模拟安装目录 =="
rm -rf "${sim}"
mkdir -p "${sim}/apps/mdcz/target" "${sim}/@appshare/mdcz"
tar -xzf "${pkg}" -C "${sim}/apps/mdcz"
tar -xzf "${sim}/apps/mdcz/app.tgz" -C "${sim}/apps/mdcz/target"
rm -f "${sim}/apps/mdcz/app.tgz"
pass "已解包 ${pkg##*/}"

echo "== 1. install_init =="
lifecycle install_init >"${sim}/install_init.log" 2>&1 || fail "install_init 失败"
pass "安装前检查通过"

echo "== 2. install_callback =="
app_env wizard_port="${port1}" sh "${sim}/apps/mdcz/cmd/install_callback" >"${sim}/install_callback.log" 2>&1 || fail "install_callback 失败"
for d in config database cache logs backups; do
    [ -d "${sim}/@appshare/mdcz/${d}" ] || fail "缺少数据目录 ${d}"
done
pass "数据目录初始化完成"
[ "$(cat "${sim}/apps/mdcz/etc/web-port")" = "${port1}" ] || fail "默认端口未写入 etc/web-port"
pass "默认端口落盘：${port1}"

echo "== 3. 启动与健康检查 =="
lifecycle main start >"${sim}/start.log" 2>&1 || fail "启动失败"
wait_health "${port1}" || fail "端口 ${port1} 健康检查失败"
grep -q 'MDCz WebUI' <(curl -fsS "http://127.0.0.1:${port1}/") || fail "WebUI 首页内容异常"
[ -f "${sim}/apps/mdcz/var/mdcz.pid" ] || fail "缺少 supervisor pid 文件"
[ -f "${sim}/apps/mdcz/var/mdcz-server.pid" ] || fail "缺少 server pid 文件"
[ -f "${sim}/@appshare/mdcz/database/mdcz.sqlite" ] || fail "SQLite 数据库未创建"
pass "服务启动、WebUI 可访问、数据库已初始化"

lifecycle main status >/dev/null 2>&1 || fail "status 未返回运行中"
pass "status 返回运行中"

echo "== 4. 崩溃自愈 =="
child="$(awk '{ print $1 }' "${sim}/apps/mdcz/var/mdcz-server.pid")"
kill -9 "${child}"
wait_health "${port1}" 20 || fail "子进程崩溃后没有自动恢复"
new_child="$(awk '{ print $1 }' "${sim}/apps/mdcz/var/mdcz-server.pid")"
[ "${new_child}" != "${child}" ] || fail "supervisor 没有拉起新的 server 进程"
pass "server 被 SIGKILL 后自动重启（pid ${child} -> ${new_child}）"

echo "== 5. 停止 =="
lifecycle main stop >"${sim}/stop.log" 2>&1 || fail "停止失败"
lifecycle main status >/dev/null 2>&1 && fail "停止后 status 仍返回运行中"
port_free "${port1}" || fail "停止后端口 ${port1} 仍被占用"
pass "服务已停止、端口已释放"

echo "== 6. 运行中修改端口 =="
lifecycle main start >/dev/null 2>&1 || fail "重启失败"
app_env wizard_port="${port2}" sh "${sim}/apps/mdcz/cmd/config_callback" >"${sim}/config.log" 2>&1 ||
    fail "config_callback 失败"
wait_health "${port2}" || fail "修改端口后 ${port2} 未就绪"
port_free "${port1}" || fail "修改端口后旧端口仍被占用"
[ "$(cat "${sim}/apps/mdcz/etc/web-port")" = "${port2}" ] || fail "新端口未持久化"
pass "配置变更触发重启，端口 ${port1} -> ${port2}"

echo "== 7. 升级（保留数据 + 自动备份） =="
echo "upgrade-marker" >"${sim}/@appshare/mdcz/config/sim-marker.txt"
app_env TRIM_OLD_APPVER=0.20.0 sh "${sim}/apps/mdcz/cmd/upgrade_init" >"${sim}/upgrade_init.log" 2>&1 ||
    fail "upgrade_init 失败"
[ -f "${sim}/@appshare/mdcz/config/sim-marker.txt" ] || fail "升级后配置丢失"
ls "${sim}/@appshare/mdcz/backups"/pre-upgrade-*.tar.gz >/dev/null 2>&1 || fail "升级前没有生成备份"
app_env TRIM_OLD_APPVER=0.20.0 sh "${sim}/apps/mdcz/cmd/upgrade_callback" >"${sim}/upgrade_callback.log" 2>&1 ||
    fail "upgrade_callback 失败"
wait_health "${port2}" || fail "升级后服务未启动"
grep -q 'upgrade-marker' "${sim}/@appshare/mdcz/config/sim-marker.txt" || fail "升级后配置内容丢失"
pass "升级保留配置/数据库并生成备份，服务自动恢复"

echo "== 8. 卸载（默认保留数据） =="
lifecycle uninstall_init >/dev/null 2>&1 || fail "uninstall_init 失败"
lifecycle uninstall_callback >/dev/null 2>&1 || fail "uninstall_callback 失败"
[ -f "${sim}/@appshare/mdcz/database/mdcz.sqlite" ] || fail "卸载后数据库被意外删除"
pass "默认卸载保留数据目录"

echo "== 9. 卸载（选择删除数据） =="
app_env wizard_remove_data=true sh "${sim}/apps/mdcz/cmd/uninstall_callback" >"${sim}/uninstall.log" 2>&1 ||
    fail "删除数据的 uninstall_callback 失败"
[ ! -d "${sim}/@appshare/mdcz/config" ] || fail "选择删除后配置目录仍存在"
pass "选择删除后数据目录已清空"

echo "== 10. 端口被占用时的报错 =="
mkdir -p "${sim}/apps/mdcz/etc" "${sim}/@appshare/mdcz/logs"
python3 - "${port3}" <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.listen(1)
time.sleep(30)
PY
blocker=$!
sleep 1
if app_env wizard_port="${port3}" sh "${sim}/apps/mdcz/cmd/main" start >"${sim}/conflict.log" 2>&1; then
    kill "${blocker}" 2>/dev/null || true
    fail "端口被占用时启动却返回成功"
fi
kill "${blocker}" 2>/dev/null || true
grep -q "已被其他进程占用" "${sim}/temp.log" || fail "端口冲突没有写入用户可见错误"
pass "端口冲突时拒绝启动并给出明确提示"

echo "== 11. 残留进程检查 =="
if ps -eo args | grep -F "${sim}/apps/mdcz" | grep -v grep >/dev/null; then
    fail "测试结束后仍有残留进程"
fi
pass "没有残留进程"

echo
echo "全部生命周期模拟测试通过。"
