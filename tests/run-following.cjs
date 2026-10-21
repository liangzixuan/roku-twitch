const { spawnSync } = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const result = spawnSync(path.join(root, 'node_modules/.bin/brs'), [
  '--root', 'tests/roku', 'roku/components/Following.brs', 'tests/roku/following.brs'
], { cwd: root, encoding: 'utf8' });
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error) throw result.error;
if (result.status !== 0 || result.stderr || !/PASS:\s+\d+\s+Following checks/.test(result.stdout)) {
  process.exit(1);
}
