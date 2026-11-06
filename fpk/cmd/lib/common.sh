#!/bin/sh
# MDCz fnOS 应用包 —— 生命周期脚本共享函数库。
#
# 由 cmd/ 下的脚本以 `. cmd/lib/common.sh` 方式引入；所有函数都按 POSIX sh 编写。
# 目录、端口和运行身份全部来自飞牛运行环境（TRIM_* 变量），不硬编码应用路径。

MDCZ_SCRIPT_TAG="${MDCZ_SCRIPT_TAG:-mdcz}"
MDCZ_DEFAULT_PORT=3838
MDCZ_APPNAME="${TRIM_APPNAME:-mdcz}"
MDCZ_APPDEST="${TRIM_APPDEST:-/var/apps/${MDCZ_APPNAME}}"
MDCZ_APP_ROOT="${MDCZ_APP_ROOT:-$(dirname "${MDCZ_APPDEST%/}")}"
MDCZ_PKGVAR="${TRIM_PKGVAR:-${MDCZ_APP_ROOT}/var}"
MDCZ_PKGETC="${TRIM_PKGETC:-${MDCZ_APP_ROOT}/etc}"
MDCZ_PKGTMP="${TRIM_PKGTMP:-${MDCZ_APP_ROOT}/tmp}"
MDCZ_CMD_DIR="${MDCZ_CMD_DIR:-${MDCZ_APPDEST%/}/../cmd}"

MDCZ_PID_FILE="${MDCZ_PKGVAR}/mdcz.pid"
MDCZ_CHILD_PID_FILE="${MDCZ_PKGVAR}/mdcz-server.pid"
MDCZ_STOP_FILE="${MDCZ_PKGVAR}/mdcz.stopping"

mdcz_log() {
    _mdcz_line="$(printf '[%s] [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "${MDCZ_SCRIPT_TAG}" "$*")"
    printf '%s\n' "${_mdcz_line}" >&2
    if [ -n "${MDCZ_LIFECYCLE_LOG:-}" ] && [ -d "$(dirname "${MDCZ_LIFECYCLE_LOG}")" ]; then
        printf '%s\n' "${_mdcz_line}" >>"${MDCZ_LIFECYCLE_LOG}" 2>/dev/null || true
    fi
}

mdcz_user_error() {
    mdcz_log "ERROR: $*"
    if [ -n "${TRIM_TEMP_LOGFILE:-}" ]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${TRIM_TEMP_LOGFILE}" 2>/dev/null || true
    fi
}

mdcz_fail() {
    mdcz_user_error "$*"
    exit 1
}

# ---------------------------------------------------------------- 目录

mdcz_data_root() {
    if [ -n "${MDCZ_DATA_ROOT:-}" ]; then
        printf '%s' "${MDCZ_DATA_ROOT}"
        return 0
    fi
    if [ -n "${TRIM_DATA_SHARE_PATHS:-}" ]; then
        printf '%s' "${TRIM_DATA_SHARE_PATHS%%:*}"
        return 0
    fi
    for _candidate in "${MDCZ_APP_ROOT}/shares/${MDCZ_APPNAME}" "${MDCZ_APP_ROOT}/share/${MDCZ_APPNAME}"; do
        if [ -d "${_candidate}" ]; then
            printf '%s' "${_candidate}"
            return 0
        fi
    done
    printf '%s' "${MDCZ_PKGVAR}/data"
}

mdcz_paths() {
    MDCZ_DATA_ROOT="$(mdcz_data_root)"
    MDCZ_CONFIG_DIR="${MDCZ_DATA_ROOT}/config"
    MDCZ_DATA_DIR="${MDCZ_DATA_ROOT}/database"
    MDCZ_CACHE_DIR="${MDCZ_DATA_ROOT}/cache"
    MDCZ_LOG_DIR="${MDCZ_DATA_ROOT}/logs"
    MDCZ_BACKUP_DIR="${MDCZ_DATA_ROOT}/backups"
    MDCZ_SERVER_LOG="${MDCZ_LOG_DIR}/mdcz.log"
    MDCZ_LIFECYCLE_LOG="${MDCZ_LOG_DIR}/lifecycle.log"
}

mdcz_ensure_dirs() {
    mdcz_paths
    for _dir in "${MDCZ_CONFIG_DIR}" "${MDCZ_DATA_DIR}" "${MDCZ_CACHE_DIR}" "${MDCZ_CACHE_DIR}/tmp" \
        "${MDCZ_CACHE_DIR}/home" "${MDCZ_LOG_DIR}" "${MDCZ_BACKUP_DIR}" "${MDCZ_PKGVAR}" "${MDCZ_PKGTMP}"; do
        mkdir -p "${_dir}" 2>/dev/null || mdcz_fail "无法创建目录 ${_dir}，请检查应用目录权限"
    done
    : >>"${MDCZ_LIFECYCLE_LOG}" 2>/dev/null || true
    if [ "$(id -u 2>/dev/null)" = "0" ] && [ -n "${TRIM_UID:-}" ] && [ -n "${TRIM_GID:-}" ]; then
        for _dir in "${MDCZ_CONFIG_DIR}" "${MDCZ_DATA_DIR}" "${MDCZ_CACHE_DIR}" "${MDCZ_LOG_DIR}" "${MDCZ_BACKUP_DIR}"; do
            chown "${TRIM_UID}:${TRIM_GID}" "${_dir}" 2>/dev/null || true
        done
    fi
}

# ---------------------------------------------------------------- Node.js

mdcz_node_bin() {
    _node_candidates=""
    if command -v node >/dev/null 2>&1; then
        _node_candidates="$(command -v node)"
    fi
    for _candidate in $(ls -d /var/apps/nodejs_v*/target/bin/node 2>/dev/null | sort -Vr); do
        _node_candidates="${_node_candidates} ${_candidate}"
    done
    for _candidate in ${_node_candidates}; do
        [ -x "${_candidate}" ] || continue
        _major="$("${_candidate}" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
        case "${_major}" in
        '' | *[!0-9]*) continue ;;
        esac
        if [ "${_major}" -ge 24 ]; then
            printf '%s' "${_candidate}"
            return 0
        fi
    done
    return 1
}

mdcz_require_node() {
    MDCZ_NODE="$(mdcz_node_bin)" || mdcz_fail "未找到 Node.js 24 或更高版本。请先在应用中心安装 Node.js 24（应用名 nodejs_v24）后重试。"
    MDCZ_NODE_VERSION="$("${MDCZ_NODE}" -p 'process.versions.node' 2>/dev/null || echo unknown)"
    mdcz_log "Node.js: ${MDCZ_NODE} (v${MDCZ_NODE_VERSION})"
}

# ---------------------------------------------------------------- 端口

mdcz_valid_port() {
    case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

mdcz_port_state_file() {
    if [ -n "${MDCZ_PKGETC:-}" ]; then
        printf '%s/web-port' "${MDCZ_PKGETC}"
    fi
}

# 解析访问端口：wizard_port（表单提交） > etc/web-port（上次保存） > 3838
mdcz_resolve_port() {
    _state_file="$(mdcz_port_state_file)"
    _port=""
    if mdcz_valid_port "${wizard_port:-}"; then
        _port="${wizard_port}"
    elif [ -n "${_state_file}" ] && [ -r "${_state_file}" ]; then
        _saved="$(head -n 1 "${_state_file}" 2>/dev/null | tr -d ' \t\r\n')"
        if mdcz_valid_port "${_saved}"; then
            _port="${_saved}"
        fi
    fi
    if [ -z "${_port}" ]; then
        _port="${MDCZ_DEFAULT_PORT}"
    fi
    if [ -n "${_state_file}" ]; then
        mkdir -p "${MDCZ_PKGETC}" 2>/dev/null || true
        printf '%s\n' "${_port}" >"${_state_file}" 2>/dev/null || true
    fi
    printf '%s' "${_port}"
}

mdcz_port_in_use() {
    _port="$1"
    case "${_port}" in '' | *[!0-9]*) return 1 ;; esac
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{ print $4 }' | grep -qE "[:.]${_port}\$" && return 0
        return 1
    fi
    if [ -r /proc/net/tcp ]; then
        _hex="$(printf '%04X' "${_port}")"
        awk -v want="${_hex}" '
            NR > 1 && $4 == "0A" {
                split($2, parts, ":")
                if (toupper(parts[2]) == want) { found = 1 }
            }
            END { exit found ? 0 : 1 }
        ' /proc/net/tcp && return 0
    fi
    return 1
}

# ---------------------------------------------------------------- 进程

mdcz_proc_matches() {
    _pid="$1"
    _marker="$2"
    [ -d "/proc/${_pid}" ] || return 1
    tr '\0' ' ' <"/proc/${_pid}/cmdline" 2>/dev/null | grep -qF "${_marker}"
}

# 读取 pid 文件并校验进程身份与启动时间，避免 PID 复用误杀
mdcz_pid_from_file() {
    _file="$1"
    _marker="$2"
    [ -r "${_file}" ] || return 1
    read -r _pid _starttime _rest <"${_file}" 2>/dev/null || return 1
    case "${_pid}" in '' | *[!0-9]*) return 1 ;; esac
    [ -d "/proc/${_pid}" ] || return 1
    _current_start="$(awk '{ print $22 }' "/proc/${_pid}/stat" 2>/dev/null)"
    [ -n "${_starttime}" ] && [ "${_current_start}" = "${_starttime}" ] || return 1
    mdcz_proc_matches "${_pid}" "${_marker}" || return 1
    printf '%s' "${_pid}"
}

mdcz_status() {
    _pid="$(mdcz_pid_from_file "${MDCZ_PID_FILE}" "supervisor.mjs")" || return 3
    [ -n "${_pid}" ] || return 3
    return 0
}

mdcz_health() {
    _port="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 3 "http://127.0.0.1:${_port}/health" 2>/dev/null | grep -q '"status":"ok"' && return 0
        return 1
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 3 -O - "http://127.0.0.1:${_port}/health" 2>/dev/null | grep -q '"status":"ok"' && return 0
        return 1
    fi
    return 1
}

mdcz_child_pid() {
    mdcz_pid_from_file "${MDCZ_CHILD_PID_FILE}" "server.js"
}

mdcz_stop() {
    mdcz_paths
    _pid="$(mdcz_pid_from_file "${MDCZ_PID_FILE}" "supervisor.mjs")" || _pid=""
    _child="$(mdcz_child_pid)" || _child=""
    if [ -z "${_pid}" ] && [ -z "${_child}" ]; then
        rm -f "${MDCZ_PID_FILE}" "${MDCZ_CHILD_PID_FILE}" 2>/dev/null || true
        mdcz_log "服务未在运行"
        return 0
    fi
    if [ -n "${_pid}" ]; then
        touch "${MDCZ_STOP_FILE}" 2>/dev/null || true
        mdcz_log "正在停止 MDCz（supervisor pid ${_pid}）"
        kill -TERM "${_pid}" 2>/dev/null || true
        _waited=0
        while [ "${_waited}" -lt 30 ] && [ -d "/proc/${_pid}" ]; do
            sleep 1
            _waited=$((_waited + 1))
        done
        if [ -d "/proc/${_pid}" ]; then
            mdcz_log "supervisor 未在 30 秒内退出，发送 SIGKILL"
            kill -KILL "${_pid}" 2>/dev/null || true
        fi
    fi
    _child="$(mdcz_child_pid)" || _child=""
    if [ -n "${_child}" ]; then
        mdcz_log "清理残留的 server 进程 ${_child}"
        kill -TERM "${_child}" 2>/dev/null || true
        _waited=0
        while [ "${_waited}" -lt 10 ] && [ -d "/proc/${_child}" ]; do
            sleep 1
            _waited=$((_waited + 1))
        done
        [ -d "/proc/${_child}" ] && kill -KILL "${_child}" 2>/dev/null || true
    fi
    rm -f "${MDCZ_PID_FILE}" "${MDCZ_CHILD_PID_FILE}" "${MDCZ_STOP_FILE}" 2>/dev/null || true
    mdcz_log "MDCz 已停止"
    return 0
}

mdcz_export_env() {
    _port="$1"
    export PORT="${_port}"
    export MDCZ_HOST="0.0.0.0"
    export MDCZ_CONFIG_DIR="${MDCZ_CONFIG_DIR}"
    export MDCZ_DATA_DIR="${MDCZ_DATA_DIR}"
    export MDCZ_WEB_DIST_DIR="${MDCZ_APPDEST}/web"
    export MDCZ_SERVER_BUILD="fnos-${TRIM_APPVER:-unknown}"
    export MDCZ_WEB_BUILD="fnos-${TRIM_APPVER:-unknown}"
    export XDG_CACHE_HOME="${MDCZ_CACHE_DIR}"
    export TMPDIR="${MDCZ_CACHE_DIR}/tmp"
    export HOME="${MDCZ_CACHE_DIR}/home"
    export NODE_ENV="production"
    export MDCZ_PID_FILE="${MDCZ_PID_FILE}"
    export MDCZ_CHILD_PID_FILE="${MDCZ_CHILD_PID_FILE}"
    export MDCZ_LOG_FILE="${MDCZ_SERVER_LOG}"
    export MDCZ_LOG_DIR="${MDCZ_LOG_DIR}"
}


# ---------------------------------------------------------------- 媒体目录 ACL

# 飞牛 1.2.x 的 trimacl 存在非 root 写入判定缺陷：应用用户创建的目录/文件 ACL 正常，
# 但再次打开写入会 EACCES。官方规避方案是给目录补 owner 的 RWX 继承 ACE。
# 生命周期脚本以 root 运行（config/privilege: run-as=root），Web 服务仍用 mdcz 用户。
mdcz_fix_media_acl() {
    [ "$(id -u 2>/dev/null)" = "0" ] || return 0
    [ -n "${TRIM_DATA_ACCESSIBLE_PATHS:-}" ] || return 0
    if [ -x /usr/trim/bin/trimacl ]; then
        _trimacl=/usr/trim/bin/trimacl
    else
        _trimacl="$(command -v trimacl 2>/dev/null || true)"
    fi
    [ -n "${_trimacl}" ] || return 0

    mdcz_paths
    _marker="${MDCZ_PKGETC}/acl-owner-fix-v1"
    _first=0
    [ -f "${_marker}" ] || _first=1

    _rest="${TRIM_DATA_ACCESSIBLE_PATHS}"
    while [ -n "${_rest}" ]; do
        case "${_rest}" in
        *:*) _path="${_rest%%:*}" ; _rest="${_rest#*:}" ;;
        *) _path="${_rest}" ; _rest="" ;;
        esac
        [ -n "${_path}" ] || continue
        case "${_path}" in
        /vol/* | /vol[0-9]*) ;;
        *) continue ;;
        esac
        [ -d "${_path}" ] || continue
        if "${_trimacl}" -m a:o:RWX:sdf "${_path}" 2>/dev/null; then
            mdcz_log "已确保媒体目录 ACL：${_path}"
        else
            mdcz_log "警告：无法为 ${_path} 补 owner ACL，刮削写入可能失败"
        fi
        if [ "${_first}" -eq 1 ]; then
            # 修复前已存在的影片目录不会自动继承新 ACE，首次启动补一遍
            if [ -n "${TRIM_UID:-}" ]; then
                find "${_path}" -maxdepth 3 -type d -user "${TRIM_UID}" \
                    -exec "${_trimacl}" -m a:o:RWX:sdf {} \; 2>/dev/null || true
            fi
        fi
    done

    if [ "${_first}" -eq 1 ]; then
        mkdir -p "${MDCZ_PKGETC}" 2>/dev/null || true
        printf '%s\n' "$(date '+%F %T')" >"${_marker}" 2>/dev/null || true
        mdcz_log "媒体目录 ACL 首次修复完成"
    fi
}

mdcz_start() {
    mdcz_paths
    mdcz_fix_media_acl
    if mdcz_status; then
        mdcz_log "MDCz 已在运行（pid $(mdcz_pid_from_file "${MDCZ_PID_FILE}" supervisor.mjs)）"
        return 0
    fi
    rm -f "${MDCZ_PID_FILE}" "${MDCZ_CHILD_PID_FILE}" 2>/dev/null || true
    mdcz_ensure_dirs
    mdcz_require_node
    _port="$(mdcz_resolve_port)"
    if mdcz_port_in_use "${_port}"; then
        mdcz_fail "端口 ${_port} 已被其他进程占用，MDCz 无法启动。请在「应用设置」里换一个空闲端口，或停止占用该端口的应用。"
    fi
    if [ ! -f "${MDCZ_APPDEST}/server.js" ]; then
        mdcz_fail "应用文件不完整：缺少 ${MDCZ_APPDEST}/server.js，请重新安装 MDCz。"
    fi
    cd "${MDCZ_APPDEST}" 2>/dev/null || mdcz_fail "无法进入应用目录 ${MDCZ_APPDEST}"

    mdcz_export_env "${_port}"
    export PATH="$(dirname "${MDCZ_NODE}"):${PATH}"
    mdcz_log "启动 MDCz：端口 ${_port}，数据目录 ${MDCZ_DATA_ROOT}"

    if [ "$(id -u 2>/dev/null)" = "0" ] && [ -n "${TRIM_USERNAME:-}" ] && [ "${TRIM_USERNAME}" != "root" ]; then
        setsid runuser -u "${TRIM_USERNAME}" -- "${MDCZ_NODE}" "${MDCZ_APPDEST}/supervisor.mjs" \
            >>"${MDCZ_SERVER_LOG}" 2>&1 &
    else
        setsid "${MDCZ_NODE}" "${MDCZ_APPDEST}/supervisor.mjs" >>"${MDCZ_SERVER_LOG}" 2>&1 &
    fi

    _waited=0
    while [ "${_waited}" -lt 45 ]; do
        if mdcz_status && mdcz_health "${_port}"; then
            mdcz_log "MDCz 已就绪：http://<NAS 地址>:${_port}/"
            return 0
        fi
        sleep 1
        _waited=$((_waited + 1))
    done

    mdcz_user_error "MDCz 启动失败：45 秒内没有通过健康检查（端口 ${_port}）。最近日志："
    tail -n 40 "${MDCZ_SERVER_LOG}" 2>/dev/null | while IFS= read -r _line; do
        printf '%s\n' "${_mdcz_line}" >&2
        [ -n "${TRIM_TEMP_LOGFILE:-}" ] && printf '%s\n' "${_line}" >>"${TRIM_TEMP_LOGFILE}" 2>/dev/null
    done
    mdcz_stop >/dev/null 2>&1 || true
    return 1
}
