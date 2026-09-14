// Keeps the extension's bundled watcher scripts in sync with the
// standalone scripts at the repo root, so there is one source of truth
// for the VPN-detection and suspend/resume logic.
const fs = require('fs');
const path = require('path');

const repoRoot = path.join(__dirname, '..', '..');
const targetDir = path.join(__dirname, '..', 'scripts');

fs.mkdirSync(targetDir, { recursive: true });

for (const name of ['code-watch.sh', 'code-watch.ps1']) {
  fs.copyFileSync(path.join(repoRoot, name), path.join(targetDir, name));
}

console.log('Copied watcher scripts into vscode-extension/scripts/');
