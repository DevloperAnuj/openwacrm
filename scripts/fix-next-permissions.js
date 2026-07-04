// One-off maintenance script for hosts where the .next build output was
// uploaded via a control-panel file manager (e.g. cPanel) rather than
// produced by `next build` on the server itself. Zip extraction through
// some file managers leaves files with permissions too restrictive for
// the Node process to read (EACCES), so this normalizes them to the
// standard safe defaults for a deployed app: 755 for directories, 644
// for files. Run once after uploading/extracting .next; not part of the
// normal build or start flow.
const fs = require('fs');
const path = require('path');

function fixPermissions(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      fs.chmodSync(full, 0o755);
      fixPermissions(full);
    } else {
      fs.chmodSync(full, 0o644);
    }
  }
}

const target = path.join(__dirname, '..', '.next');
fixPermissions(target);
console.log(`Fixed permissions under ${target}`);
