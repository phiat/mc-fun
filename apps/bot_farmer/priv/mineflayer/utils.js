/**
 * Shared utilities for the mineflayer bridge.
 */

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function log(msg) {
  process.stderr.write(`[bridge] ${msg}\n`);
}

/**
 * Race a promise against a timeout. Rejects with a descriptive error on timeout.
 */
function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/**
 * Validate that coordinates are finite numbers (not null/undefined/NaN/Infinity).
 */
function validCoords(x, y, z) {
  return typeof x === 'number' && typeof y === 'number' && typeof z === 'number' &&
    isFinite(x) && isFinite(y) && isFinite(z);
}

module.exports = { send, log, withTimeout, validCoords };
