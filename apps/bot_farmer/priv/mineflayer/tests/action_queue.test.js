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

function allOutputs() {
  return captured.map(c => JSON.parse(c.trim()));
}

describe('action_queue', () => {
  // Fresh require each test to reset module state
  let queue;

  beforeEach(() => {
    captureStart();
    // Clear module cache to reset state
    delete require.cache[require.resolve('../action_queue')];
    queue = require('../action_queue');
  });

  afterEach(() => captureStop());

  describe('SYNC_ACTIONS', () => {
    it('includes chat, whisper, position, inventory, players', () => {
      assert.ok(queue.SYNC_ACTIONS.has('chat'));
      assert.ok(queue.SYNC_ACTIONS.has('whisper'));
      assert.ok(queue.SYNC_ACTIONS.has('position'));
      assert.ok(queue.SYNC_ACTIONS.has('inventory'));
      assert.ok(queue.SYNC_ACTIONS.has('players'));
    });

    it('does not include async actions', () => {
      assert.ok(!queue.SYNC_ACTIONS.has('goto'));
      assert.ok(!queue.SYNC_ACTIONS.has('dig'));
      assert.ok(!queue.SYNC_ACTIONS.has('move'));
    });
  });

  describe('processCommand()', () => {
    it('executes sync commands immediately', () => {
      let executed = null;
      const executor = (cmd) => { executed = cmd; };
      queue.processCommand({ action: 'chat', message: 'hi' }, executor);
      assert.deepStrictEqual(executed, { action: 'chat', message: 'hi' });
    });

    it('executes first async command immediately', () => {
      let executed = null;
      const executor = (cmd) => { executed = cmd; };
      queue.processCommand({ action: 'goto', x: 0, y: 64, z: 0 }, executor);
      assert.deepStrictEqual(executed, { action: 'goto', x: 0, y: 64, z: 0 });
      assert.ok(queue.isActionBusy());
    });

    it('queues subsequent async commands', () => {
      let count = 0;
      const executor = () => { count++; };
      queue.processCommand({ action: 'goto', x: 0, y: 64, z: 0 }, executor);
      queue.processCommand({ action: 'dig', x: 1, y: 64, z: 1 }, executor);

      assert.strictEqual(count, 1); // only first executed
      assert.strictEqual(queue.getQueueLength(), 1);

      // Check queued event was sent
      const outputs = allOutputs();
      assert.ok(outputs.some(o => o.event === 'queued' && o.action === 'dig'));
    });

    it('allows sync commands while async is busy', () => {
      let commands = [];
      const executor = (cmd) => { commands.push(cmd.action); };
      queue.processCommand({ action: 'goto', x: 0, y: 64, z: 0 }, executor);
      queue.processCommand({ action: 'chat', message: 'hi' }, executor);

      assert.deepStrictEqual(commands, ['goto', 'chat']);
    });
  });

  describe('actionDone()', () => {
    it('advances queue when done is called', () => {
      let commands = [];
      const executor = (cmd) => { commands.push(cmd.action); };

      queue.processCommand({ action: 'goto', x: 0, y: 64, z: 0 }, executor);
      queue.processCommand({ action: 'dig', x: 1, y: 64, z: 1 }, executor);

      assert.deepStrictEqual(commands, ['goto']);

      queue.actionDone(executor);
      assert.deepStrictEqual(commands, ['goto', 'dig']);
    });

    it('sets actionBusy to false when queue is empty', () => {
      const executor = () => {};
      queue.processCommand({ action: 'goto', x: 0, y: 64, z: 0 }, executor);
      assert.ok(queue.isActionBusy());

      queue.actionDone(executor);
      assert.ok(!queue.isActionBusy());
    });
  });

  describe('clearQueue()', () => {
    it('clears all pending commands and resets busy flag', () => {
      const executor = () => {};
      queue.processCommand({ action: 'goto', x: 0, y: 64, z: 0 }, executor);
      queue.processCommand({ action: 'dig', x: 1, y: 64, z: 1 }, executor);

      queue.clearQueue();
      assert.strictEqual(queue.getQueueLength(), 0);
      assert.ok(!queue.isActionBusy());
    });
  });
});
