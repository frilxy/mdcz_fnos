#!/usr/bin/env node
// MDCz 进程守护：以应用用户身份运行，负责拉起 server.js、崩溃后按退避重启、
// 收到停止信号时先优雅关闭子进程。pid 文件写入 pid + /proc 启动时间，避免 PID 复用误杀。
import { spawn } from "node:child_process";
import {
  createWriteStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const appDir = dirname(fileURLToPath(import.meta.url));
const pidFile = process.env.MDCZ_PID_FILE;
const childPidFile = process.env.MDCZ_CHILD_PID_FILE;
const logFile = process.env.MDCZ_LOG_FILE;

if (!pidFile || !childPidFile || !logFile) {
  console.error("supervisor: MDCZ_PID_FILE / MDCZ_CHILD_PID_FILE / MDCZ_LOG_FILE 未设置");
  process.exit(1);
}

const readStartTime = (pid) => {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    return stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19] ?? "";
  } catch {
    return "";
  }
};

const readPidFile = (file) => {
  try {
    const [pid, startTime] = readFileSync(file, "utf8").trim().split(" ");
    return { pid: Number(pid), startTime };
  } catch {
    return null;
  }
};

const writePidFile = (file, pid) => {
  writeFileSync(file, `${pid} ${readStartTime(pid)}\n`);
};

const existing = readPidFile(pidFile);
if (existing?.pid && existing.startTime === readStartTime(existing.pid) && existing.pid !== process.pid) {
  console.log(`supervisor: 已有实例在运行（pid ${existing.pid}），本次退出`);
  process.exit(0);
}

mkdirSync(dirname(pidFile), { recursive: true });
writePidFile(pidFile, process.pid);

if (existsSync(logFile) && statSync(logFile).size > 10 * 1024 * 1024) {
  try {
    renameSync(logFile, `${logFile}.1`);
  } catch {
    // 日志轮转失败不影响启动
  }
}

const log = createWriteStream(logFile, { flags: "a" });
const write = (line) => log.write(`[${new Date().toISOString()}] [supervisor] ${line}\n`);

const env = {
  ...process.env,
  PORT: process.env.PORT ?? "3838",
  MDCZ_HOST: process.env.MDCZ_HOST ?? "0.0.0.0",
  MDCZ_WEB_DIST_DIR: process.env.MDCZ_WEB_DIST_DIR ?? join(appDir, "web"),
};

let child = null;
let stopping = false;
let attempts = 0;
let restartTimer = null;
let childStartedAt = 0;

const removeChildPid = () => {
  try {
    unlinkSync(childPidFile);
  } catch {
    // 文件不存在时忽略
  }
};

const startChild = () => {
  childStartedAt = Date.now();
  child = spawn(process.execPath, [join(appDir, "server.js")], {
    cwd: appDir,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (child.pid) writePidFile(childPidFile, child.pid);
  write(`server.js 已启动（pid ${child.pid ?? "unknown"}）`);
  child.stdout.on("data", (chunk) => log.write(chunk));
  child.stderr.on("data", (chunk) => log.write(chunk));

  child.on("error", (error) => {
    write(`无法启动 server.js：${error.message}`);
  });

  child.on("exit", (code, signal) => {
    child = null;
    removeChildPid();
    const uptime = Date.now() - childStartedAt;
    write(`server.js 退出：code=${code ?? "null"} signal=${signal ?? "null"} uptime=${Math.round(uptime / 1000)}s`);
    if (stopping) {
      write("收到停止请求，supervisor 退出");
      log.end(() => process.exit(0));
      return;
    }
    if (uptime > 60_000) attempts = 0;
    const delay = Math.min(60_000, 3_000 * 2 ** Math.min(attempts, 4));
    attempts += 1;
    write(`将在 ${Math.round(delay / 1000)} 秒后重启`);
    restartTimer = setTimeout(startChild, delay);
  });
};

const shutdown = (signal) => {
  if (stopping) return;
  stopping = true;
  if (restartTimer) clearTimeout(restartTimer);
  write(`收到 ${signal}，开始停止`);
  if (!child) {
    removeChildPid();
    log.end(() => process.exit(0));
    return;
  }
  const target = child;
  target.kill("SIGTERM");
  const deadline = Date.now() + 20_000;
  const timer = setInterval(() => {
    if (!child) {
      clearInterval(timer);
      return;
    }
    if (Date.now() > deadline) {
      write("server.js 未在 20 秒内退出，发送 SIGKILL");
      clearInterval(timer);
      target.kill("SIGKILL");
    }
  }, 500);
};

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGHUP", () => write("收到 SIGHUP，忽略"));
process.on("uncaughtException", (error) => write(`uncaughtException: ${error?.stack ?? error}`));
process.on("unhandledRejection", (error) => write(`unhandledRejection: ${error?.stack ?? error}`));

write(`supervisor 启动（pid ${process.pid}）`);
startChild();
