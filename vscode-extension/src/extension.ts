import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import { spawn } from 'child_process';

const REFRESH_SECONDS = 2;
const STALE_AFTER_MS = REFRESH_SECONDS * 1000 * 4;

let statusBarItem: vscode.StatusBarItem;
let sidebarProvider: CodeWatchStatusProvider;
let sidebarView: vscode.TreeView<vscode.TreeItem>;
let pollHandle: ReturnType<typeof setInterval> | undefined;
let statusFile: string;
let cmdFile: string;

class CodeWatchStatusProvider implements vscode.TreeDataProvider<vscode.TreeItem> {
  private readonly emitter = new vscode.EventEmitter<void>();
  readonly onDidChangeTreeData = this.emitter.event;

  refresh(): void {
    this.emitter.fire();
  }

  getTreeItem(element: vscode.TreeItem): vscode.TreeItem {
    return element;
  }

  getChildren(): vscode.TreeItem[] {
    const status = readStatus();

    if (!status) {
      const starting = new vscode.TreeItem('Starting…');
      starting.iconPath = new vscode.ThemeIcon('sync~spin');
      return [starting];
    }

    const paused = status.STATE === 'paused';
    const connected = status.VPN === 'connected';

    const headline = new vscode.TreeItem(
      paused ? 'VS Code: PAUSED' : connected ? 'VS Code: Protected' : 'VS Code: VPN down',
    );
    headline.iconPath = new vscode.ThemeIcon('circle-large-filled', paused || !connected ? RED : GREEN);
    headline.command = { command: 'codeWatch.resumeNow', title: 'Resume Now' };
    headline.tooltip = paused
      ? 'VS Code is frozen because the VPN is disconnected.\nClick to resume manually once you are back on VPN.'
      : connected
        ? 'VPN connected. VS Code runs normally.'
        : 'VPN disconnected. VS Code will be paused automatically.';

    const vpnRow = new vscode.TreeItem('VPN');
    vpnRow.description = connected ? (status.DETAIL || 'connected') : 'disconnected';
    vpnRow.iconPath = new vscode.ThemeIcon(connected ? 'shield' : 'warning');

    const ifaceRow = new vscode.TreeItem('Tunnel Interface');
    ifaceRow.description = status.IFACE || '—';
    ifaceRow.iconPath = new vscode.ThemeIcon('plug');

    const ipRow = new vscode.TreeItem('Public IP');
    ipRow.description = status.IP || 'checking…';
    ipRow.tooltip = 'The externally-visible IP address — what a leak would actually expose. Refreshed roughly every 30s.';
    ipRow.iconPath = new vscode.ThemeIcon('globe');

    const processRow = new vscode.TreeItem('Frozen processes');
    processRow.description = paused ? (status.PIDS || '0') : '0';
    processRow.iconPath = new vscode.ThemeIcon(paused ? 'debug-pause' : 'debug-start');

    const updatedRow = new vscode.TreeItem('Last check');
    updatedRow.description = formatLocalTime(status.UPDATED);
    updatedRow.iconPath = new vscode.ThemeIcon('clock');

    const rows = [headline, vpnRow, ifaceRow, ipRow, processRow, updatedRow];

    if (paused && status.PAUSED_AT) {
      const pausedAtMs = Number(status.PAUSED_AT) * 1000;
      if (!Number.isNaN(pausedAtMs) && pausedAtMs > 0) {
        const elapsedRow = new vscode.TreeItem('Frozen for');
        elapsedRow.description = `${Math.max(0, Math.round((Date.now() - pausedAtMs) / 1000))}s (as of last check)`;
        elapsedRow.tooltip = 'This number only advances on each poll — it cannot tick live while VS Code itself is frozen.';
        elapsedRow.iconPath = new vscode.ThemeIcon('watch');
        rows.push(elapsedRow);
      }
    }

    return rows;
  }
}

function formatLocalTime(iso?: string): string {
  if (!iso) { return '—'; }
  const parsed = new Date(iso);
  return Number.isNaN(parsed.getTime()) ? '—' : parsed.toLocaleTimeString();
}

function scriptPathsFor(extensionPath: string): { command: string; args: string[]; env?: NodeJS.ProcessEnv } | undefined {
  const appName = vscode.workspace.getConfiguration('codeWatch').get<string>('appProcessName', '').trim();

  if (process.platform === 'darwin') {
    const script = path.join(extensionPath, 'scripts', 'code-watch.sh');
    const env = appName ? { ...process.env, CODE_WATCH_APP_NAME: appName } : process.env;
    return { command: '/bin/bash', args: [script, '--daemon', statusFile], env };
  }

  if (process.platform === 'win32') {
    const script = path.join(extensionPath, 'scripts', 'code-watch.ps1');
    return {
      command: 'powershell.exe',
      args: [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', script,
        '-Daemon',
        '-StatusFile', statusFile,
        '-AppProcessName', appName || 'Code',
      ],
    };
  }

  return undefined;
}

function readStatus(): Record<string, string> | undefined {
  try {
    const raw = fs.readFileSync(statusFile, 'utf8');
    const status: Record<string, string> = {};
    for (const line of raw.split('\n')) {
      const idx = line.indexOf('=');
      if (idx === -1) { continue; }
      status[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
    }
    return status;
  } catch {
    return undefined;
  }
}

function isDaemonAlive(): boolean {
  const status = readStatus();
  if (!status?.UPDATED) { return false; }
  const updated = Date.parse(status.UPDATED);
  return !Number.isNaN(updated) && Date.now() - updated < STALE_AFTER_MS;
}

function writeCommand(cmd: 'pause' | 'resume' | 'stop'): void {
  fs.writeFileSync(cmdFile, cmd, 'utf8');
}

function startWatcher(extensionPath: string): void {
  if (isDaemonAlive()) {
    updateStatusBar();
    return;
  }

  const target = scriptPathsFor(extensionPath);
  if (!target) {
    statusBarItem.text = '$(warning) Code Watch: unsupported OS';
    statusBarItem.show();
    return;
  }

  const child = spawn(target.command, target.args, {
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
    env: target.env,
  });
  child.unref();
}

const GREEN = new vscode.ThemeColor('terminal.ansiGreen');
const RED = new vscode.ThemeColor('terminal.ansiRed');

// VS Code's own UI (this extension included) is frozen along with
// everything else while paused, so there is no way to show a live
// countdown during the freeze — the best we can do is remember when it
// started and report the total once the extension host is running again.
let localPauseStartedAt: number | undefined;

function updateStatusBar(): void {
  const status = readStatus();
  if (!status) {
    statusBarItem.text = '$(sync~spin) Code Watch: starting…';
    statusBarItem.color = undefined;
    statusBarItem.backgroundColor = undefined;
    statusBarItem.show();
    return;
  }

  const paused = status.STATE === 'paused';
  const connected = status.VPN === 'connected';

  if (paused && localPauseStartedAt === undefined) {
    localPauseStartedAt = Date.now();
  } else if (!paused && localPauseStartedAt !== undefined) {
    const elapsedSec = Math.round((Date.now() - localPauseStartedAt) / 1000);
    localPauseStartedAt = undefined;
    vscode.window.showInformationMessage(`Code Watch: VS Code was frozen for ${elapsedSec}s while the VPN was disconnected.`);
  }

  if (paused) {
    statusBarItem.text = `$(debug-pause) Code Watch: PAUSED (${status.PIDS ?? '?'} procs)`;
    statusBarItem.color = RED;
    statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
    statusBarItem.tooltip = 'VS Code is frozen because the VPN is disconnected.\nClick to resume manually once you are back on VPN.';
  } else if (!connected) {
    statusBarItem.text = '$(shield) Code Watch: VPN down, armed';
    statusBarItem.color = RED;
    statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    statusBarItem.tooltip = 'VPN disconnected. VS Code will be paused automatically.';
  } else {
    statusBarItem.text = `$(shield) Code Watch: ${status.DETAIL ?? 'connected'}`;
    statusBarItem.color = GREEN;
    statusBarItem.backgroundColor = undefined;
    statusBarItem.tooltip = 'VPN connected. VS Code runs normally.';
  }
  statusBarItem.show();
  sidebarProvider?.refresh();

  if (sidebarView) {
    sidebarView.badge = paused
      ? { value: Number(status.PIDS) || 1, tooltip: 'VS Code is paused — VPN disconnected' }
      : undefined;
  }
}

export function activate(context: vscode.ExtensionContext): void {
  const storageDir = context.globalStorageUri.fsPath;
  fs.mkdirSync(storageDir, { recursive: true });
  statusFile = path.join(storageDir, 'code-watch.status');
  cmdFile = `${statusFile}.cmd`;

  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1_000_000);
  statusBarItem.command = 'codeWatch.resumeNow';
  context.subscriptions.push(statusBarItem);

  sidebarProvider = new CodeWatchStatusProvider();
  sidebarView = vscode.window.createTreeView('codeWatch.statusView', { treeDataProvider: sidebarProvider });
  context.subscriptions.push(sidebarView);

  context.subscriptions.push(
    vscode.commands.registerCommand('codeWatch.start', () => startWatcher(context.extensionPath)),
    vscode.commands.registerCommand('codeWatch.stop', () => writeCommand('stop')),
    vscode.commands.registerCommand('codeWatch.pauseNow', () => writeCommand('pause')),
    vscode.commands.registerCommand('codeWatch.resumeNow', () => writeCommand('resume')),
  );

  pollHandle = setInterval(updateStatusBar, REFRESH_SECONDS * 1000);
  context.subscriptions.push({ dispose: () => pollHandle && clearInterval(pollHandle) });

  const autoStart = vscode.workspace.getConfiguration('codeWatch').get<boolean>('autoStart', true);
  if (autoStart) {
    startWatcher(context.extensionPath);
  }
  updateStatusBar();
}

export function deactivate(): void {
  // Intentionally leave the detached watcher daemon running: it must
  // keep monitoring the VPN even while VS Code itself is closed or
  // paused. Use the "Code Watch: Stop Monitoring" command to end it
  // explicitly (e.g. before uninstalling).
}
