#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');

const args = new Set(process.argv.slice(2));
const getArg = (name, fallback) => {
  const raw = process.argv.slice(2);
  const idx = raw.indexOf(name);
  return idx >= 0 && raw[idx + 1] ? raw[idx + 1] : fallback;
};

const timeoutMs = Math.max(1, Number(getArg('--timeout', '90'))) * 1000;
const idFilter = getArg('--id', '').trim();
const isJsonOnly = args.has('--json');
const isFailFast = args.has('--fail-fast');
const isUnsafeUnsupported = args.has('--unsafe-run-unsupported');
const includeWindows = args.has('--windows') || args.has('--all') || (!args.has('--linux') && process.platform === 'win32');
const includeLinux = args.has('--linux') || args.has('--all') || (!args.has('--windows') && process.platform !== 'win32');

function fileError(filePath, reason) {
  console.error(`[CODE RED] File/path error: ${filePath} -- Reason: ${reason}`);
}

function stripAnsi(value) {
  return String(value || '').replace(/\x1b\[[0-9;]*m/g, '');
}

function nowStamp() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function commandExists(command) {
  const probe = process.platform === 'win32'
    ? spawnSync('where.exe', [command], { stdio: 'ignore' })
    : spawnSync('command', ['-v', command], { shell: true, stdio: 'ignore' });
  return probe.status === 0;
}

function findPowerShell() {
  if (process.platform === 'win32' && commandExists('powershell.exe')) return 'powershell.exe';
  if (commandExists('pwsh')) return 'pwsh';
  if (commandExists('powershell')) return 'powershell';
  return '';
}

function discoverScripts(rootDir, runnerName, osName) {
  const absRoot = path.join(repoRoot, rootDir);
  if (!existsSync(absRoot)) {
    fileError(absRoot, `script root missing for ${osName} smoke check`);
    return [];
  }

  return readdirSync(absRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^\d+/.test(entry.name))
    .map((entry) => {
      const dir = path.join(absRoot, entry.name);
      return { os: osName, id: (entry.name.match(/^\d+/) || [''])[0], name: entry.name, dir, runner: path.join(dir, runnerName) };
    })
    .filter((item) => !idFilter || item.id === idFilter)
    .filter((item) => existsSync(item.runner))
    .sort((a, b) => Number(a.id) - Number(b.id) || a.name.localeCompare(b.name));
}

function hasCheckSupport(item) {
  try {
    const runnerText = readFileSync(item.runner, 'utf8');
    if (item.os === 'linux') {
      return /(^|[\s;])check\)/m.test(runnerText) || /verb_check\s*\(\)/.test(runnerText) || /Verbs:\s*.*check/i.test(runnerText);
    }

    const nearbyFiles = [item.runner, path.join(item.dir, 'log-messages.json')];
    const helpersDir = path.join(item.dir, 'helpers');
    if (existsSync(helpersDir)) {
      for (const helper of readdirSync(helpersDir)) {
        if (helper.endsWith('.ps1')) nearbyFiles.push(path.join(helpersDir, helper));
      }
    }
    const combined = nearbyFiles
      .filter((file) => existsSync(file))
      .map((file) => readFileSync(file, 'utf8'))
      .join('\n');
    return /['"`]check['"`]|\bcheck\b\s*\{|Command\.ToLower\(\).*check|switch\s*\([^)]*Command/i.test(combined);
  } catch (error) {
    fileError(item.runner, `could not inspect check support: ${error.message}`);
    return false;
  }
}

function runWithTimeout(command, commandArgs, cwd) {
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn(command, commandArgs, { cwd, windowsHide: true, env: { ...process.env, SMOKE_CHECK: '1' } });
    let stdout = '';
    let stderr = '';
    let isTimedOut = false;

    const timer = setTimeout(() => {
      isTimedOut = true;
      try { child.kill('SIGKILL'); } catch {}
    }, timeoutMs);

    child.stdout?.on('data', (chunk) => { stdout += chunk.toString(); });
    child.stderr?.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', (error) => {
      clearTimeout(timer);
      resolve({ exitCode: 127, stdout, stderr: `${stderr}\n${error.message}`.trim(), elapsedMs: Date.now() - started, timedOut: false });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ exitCode: isTimedOut ? 124 : (code ?? 1), stdout, stderr, elapsedMs: Date.now() - started, timedOut: isTimedOut });
    });
  });
}

function statusFor(result) {
  if (result.skipped) return 'SKIP';
  if (result.timedOut) return 'TIMEOUT';
  return result.exitCode === 0 ? 'PASS' : 'FAIL';
}

function summarizeOutput(stdout, stderr) {
  const lines = stripAnsi(`${stdout}\n${stderr}`).split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines.slice(-2).join(' | ').slice(0, 160);
}

function writeTable(rows) {
  const widths = { os: 7, id: 4, name: 36, status: 8, exit: 5, time: 8, log: 44 };
  const fit = (value, width) => {
    const text = String(value ?? '');
    return (text.length > width ? `${text.slice(0, width - 1)}…` : text).padEnd(width, ' ');
  };
  const header = `${fit('OS', widths.os)} ${fit('ID', widths.id)} ${fit('SCRIPT', widths.name)} ${fit('STATUS', widths.status)} ${fit('EXIT', widths.exit)} ${fit('TIME', widths.time)} ${fit('LOG', widths.log)}`;
  console.log(header);
  console.log('-'.repeat(header.length));
  for (const row of rows) {
    console.log(`${fit(row.os, widths.os)} ${fit(row.id, widths.id)} ${fit(row.name, widths.name)} ${fit(row.status, widths.status)} ${fit(row.exitCode, widths.exit)} ${fit(`${(row.elapsedMs / 1000).toFixed(1)}s`, widths.time)} ${fit(path.relative(repoRoot, row.logPath || ''), widths.log)}`);
  }
}

async function main() {
  const runStamp = nowStamp();
  const logDir = path.join(repoRoot, '.logs', 'smoke-check', runStamp);
  mkdirSync(logDir, { recursive: true });

  const scripts = [
    ...(includeWindows ? discoverScripts('scripts', 'run.ps1', 'windows') : []),
    ...(includeLinux ? discoverScripts('scripts-linux', 'run.sh', 'linux') : []),
  ];

  const ps = includeWindows ? findPowerShell() : '';
  const hasBash = includeLinux ? commandExists('bash') : false;
  const rows = [];

  for (const item of scripts) {
    const supportsCheck = hasCheckSupport(item);
    const logPath = path.join(logDir, `${item.os}-${item.id}-${item.name}.log`);
    let result;
    let command = '';
    let commandArgs = [];

    if (!supportsCheck && !isUnsafeUnsupported) {
      result = { skipped: true, exitCode: 'n/a', stdout: '', stderr: 'check verb not detected; skipped to avoid accidental install', elapsedMs: 0, timedOut: false };
    } else if (item.os === 'windows') {
      if (!ps) {
        result = { skipped: true, exitCode: 'n/a', stdout: '', stderr: 'PowerShell not available on this host', elapsedMs: 0, timedOut: false };
      } else {
        command = ps;
        commandArgs = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', item.runner, 'check'];
        result = await runWithTimeout(command, commandArgs, item.dir);
      }
    } else if (!hasBash) {
      result = { skipped: true, exitCode: 'n/a', stdout: '', stderr: 'bash not available on this host', elapsedMs: 0, timedOut: false };
    } else {
      command = 'bash';
      commandArgs = [item.runner, 'check'];
      result = await runWithTimeout(command, commandArgs, item.dir);
    }

    const status = statusFor(result);
    writeFileSync(logPath, [
      `Smoke check: ${item.os} ${item.id} ${item.name}`,
      `Runner: ${item.runner}`,
      `Command: ${command ? [command, ...commandArgs].join(' ') : '(not executed)'}`,
      `Status: ${status}`,
      `Exit: ${result.exitCode}`,
      `Timed out: ${result.timedOut}`,
      `Elapsed ms: ${result.elapsedMs}`,
      '',
      'STDOUT',
      '------',
      stripAnsi(result.stdout),
      '',
      'STDERR',
      '------',
      stripAnsi(result.stderr),
    ].join('\n'));

    rows.push({ ...item, status, exitCode: result.exitCode, timedOut: result.timedOut, skipped: result.skipped || false, elapsedMs: result.elapsedMs, logPath, note: summarizeOutput(result.stdout, result.stderr) });
    if (isFailFast && status === 'FAIL') break;
  }

  const reportPath = path.join(logDir, 'smoke-check-report.json');
  const summary = rows.reduce((acc, row) => ({ ...acc, [row.status.toLowerCase()]: (acc[row.status.toLowerCase()] || 0) + 1 }), { total: rows.length });
  writeFileSync(reportPath, JSON.stringify({ generatedAt: new Date().toISOString(), timeoutSeconds: timeoutMs / 1000, summary, rows }, null, 2));

  if (isJsonOnly) {
    console.log(JSON.stringify({ reportPath, summary, rows }, null, 2));
  } else {
    console.log('Smoke check report');
    console.log(`Logs: ${path.relative(repoRoot, logDir)}`);
    console.log('');
    writeTable(rows);
    console.log('');
    console.log(`Summary: total=${summary.total || 0} pass=${summary.pass || 0} fail=${summary.fail || 0} timeout=${summary.timeout || 0} skip=${summary.skip || 0}`);
    console.log(`JSON: ${path.relative(repoRoot, reportPath)}`);
  }

  const hasFailures = rows.some((row) => row.status === 'FAIL' || row.status === 'TIMEOUT');
  process.exit(hasFailures ? 1 : 0);
}

main().catch((error) => {
  fileError(path.join(repoRoot, 'tools', 'smoke-check.mjs'), error.message);
  process.exit(2);
});