const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const dir = path.resolve(process.argv[2] || 'dist');
const marker = process.platform === 'win32' ? 'Windows' : 'macOS';
const version = require('../package.json').version;
const files = fs.readdirSync(dir)
  .filter((name) => name.includes(marker) && name.includes(version) && !name.endsWith('.blockmap'))
  .sort();
if (!files.length) throw new Error(`No ${marker} artifacts found in ${dir}`);
const lines = files.map((name) => {
  const hash = crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, name))).digest('hex');
  return `${hash}  ${name}`;
});
const output = path.join(dir, `SHA256SUMS-${marker}.txt`);
fs.writeFileSync(output, `${lines.join('\n')}\n`);
console.log(output);
