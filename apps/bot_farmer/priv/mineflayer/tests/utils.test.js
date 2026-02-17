const assert = require('assert');
const { describe, it, beforeEach, afterEach } = require('node:test');

// Capture stdout writes
let captured = [];
const originalWrite = process.stdout.write;

function captureStart() {
  captured = [];
  process.stdout.write = (data) => {
    captured.push(data);
    return true;
  };
}

function captureStop() {
  process.stdout.write = originalWrite;
}

function lastOutput() {
  if (captured.length === 0) return null;
  return JSON.parse(captured[captured.length - 1].trim());
}

// --- Tests ---

describe('send', () => {
  const { send } = require('../utils');

  beforeEach(() => captureStart());
  afterEach(() => captureStop());

  it('writes JSON followed by newline to stdout', () => {
    send({ event: 'test', data: 42 });
    assert.strictEqual(captured.length, 1);
    assert.strictEqual(captured[0], '{"event":"test","data":42}\n');
  });

  it('handles nested objects', () => {
    send({ event: 'pos', position: { x: 1, y: 2, z: 3 } });
    const out = lastOutput();
    assert.deepStrictEqual(out.position, { x: 1, y: 2, z: 3 });
  });
});

describe('validCoords', () => {
  const { validCoords } = require('../utils');

  it('returns true for finite numbers', () => {
    assert.strictEqual(validCoords(0, 64, 0), true);
    assert.strictEqual(validCoords(-100.5, 255, 100.5), true);
  });

  it('returns false for NaN', () => {
    assert.strictEqual(validCoords(NaN, 64, 0), false);
    assert.strictEqual(validCoords(0, NaN, 0), false);
  });

  it('returns false for Infinity', () => {
    assert.strictEqual(validCoords(Infinity, 64, 0), false);
    assert.strictEqual(validCoords(0, 64, -Infinity), false);
  });

  it('returns false for undefined/null', () => {
    assert.strictEqual(validCoords(undefined, 64, 0), false);
    assert.strictEqual(validCoords(0, null, 0), false);
  });
});

describe('withTimeout', () => {
  const { withTimeout } = require('../utils');

  it('resolves when promise resolves before timeout', async () => {
    const result = await withTimeout(
      Promise.resolve('ok'),
      1000,
      'test'
    );
    assert.strictEqual(result, 'ok');
  });

  it('rejects when promise times out', async () => {
    let slowTimer;
    const slow = new Promise(resolve => { slowTimer = setTimeout(resolve, 5000); });
    await assert.rejects(
      withTimeout(slow, 50, 'test_op'),
      { message: 'test_op timed out after 50ms' }
    );
    clearTimeout(slowTimer);
  });

  it('rejects with original error if promise rejects before timeout', async () => {
    await assert.rejects(
      withTimeout(Promise.reject(new Error('boom')), 1000, 'test'),
      { message: 'boom' }
    );
  });
});
