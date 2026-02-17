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

function lastOutput() {
  if (captured.length === 0) return null;
  return JSON.parse(captured[captured.length - 1].trim());
}

// --- Mock bot ---

function mockBot(overrides = {}) {
  return {
    username: 'TestBot',
    health: 20,
    food: 20,
    entity: {
      position: { x: 100, y: 64, z: 200, distanceTo: () => 3 },
      yaw: 0,
      pitch: 0,
    },
    game: { dimension: 'minecraft:overworld' },
    heldItem: null,
    targetDigBlock: null,
    players: {},
    entities: {},
    inventory: {
      items: () => overrides.items || [],
    },
    chat: () => {},
    whisper: () => {},
    look: () => {},
    setControlState: () => {},
    clearControlStates: () => {},
    blockAt: () => overrides.block || null,
    blockAtCursor: () => overrides.cursor || null,
    nearestEntity: () => overrides.nearestEntity || null,
    findBlocks: () => [],
    findBlock: () => null,
    pathfinder: {
      movements: true,
      setGoal: () => {},
      stop: () => {},
      isMoving: () => false,
    },
    attack: () => {},
    dig: () => Promise.resolve(),
    placeBlock: () => Promise.resolve(),
    equip: () => Promise.resolve(),
    craft: () => Promise.resolve(),
    recipesFor: () => [],
    tossStack: () => Promise.resolve(),
    toss: () => Promise.resolve(),
    activateBlock: () => Promise.resolve(),
    activateItem: () => {},
    deactivateItem: () => {},
    sleep: () => Promise.resolve(),
    wake: () => {},
    stopDigging: () => {},
    removeListener: () => {},
    once: () => {},
    ...overrides,
  };
}

// --- Tests ---

describe('commands/chat', () => {
  const chatCmds = require('../commands/chat');

  beforeEach(() => captureStart());
  afterEach(() => captureStop());

  it('chat sends ack', () => {
    let chatted = null;
    const bot = mockBot({ chat: (msg) => { chatted = msg; } });
    chatCmds.chat(bot, { message: 'hello world' });
    assert.strictEqual(chatted, 'hello world');
    assert.deepStrictEqual(lastOutput(), { event: 'ack', action: 'chat' });
  });

  it('whisper sends ack', () => {
    let whispered = null;
    const bot = mockBot({ whisper: (target, msg) => { whispered = { target, msg }; } });
    chatCmds.whisper(bot, { target: 'Steve', message: 'psst' });
    assert.deepStrictEqual(whispered, { target: 'Steve', msg: 'psst' });
    assert.deepStrictEqual(lastOutput(), { event: 'ack', action: 'whisper' });
  });
});

describe('commands/combat', () => {
  const combatCmds = require('../commands/combat');

  beforeEach(() => captureStart());
  afterEach(() => captureStop());

  it('attack hits nearest entity', () => {
    let attacked = false;
    const entity = { name: 'zombie' };
    const bot = mockBot({
      nearestEntity: () => entity,
      attack: () => { attacked = true; },
    });
    let doneCount = 0;
    combatCmds.attack(bot, {}, () => { doneCount++; });
    assert.ok(attacked);
    assert.strictEqual(doneCount, 1);
    assert.deepStrictEqual(lastOutput(), { event: 'ack', action: 'attack', target: 'zombie' });
  });

  it('attack errors when no entity nearby', () => {
    const bot = mockBot({ nearestEntity: () => null });
    let doneCount = 0;
    combatCmds.attack(bot, {}, () => { doneCount++; });
    assert.strictEqual(doneCount, 1);
    assert.deepStrictEqual(lastOutput(), { event: 'error', message: 'No entity nearby to attack' });
  });
});

describe('commands/info', () => {
  const infoCmds = require('../commands/info');

  beforeEach(() => captureStart());
  afterEach(() => captureStop());

  it('position sends coordinates', () => {
    const bot = mockBot();
    infoCmds.position(bot);
    const out = lastOutput();
    assert.strictEqual(out.event, 'position');
    assert.strictEqual(out.x, 100);
    assert.strictEqual(out.y, 64);
    assert.strictEqual(out.z, 200);
  });

  it('position handles not spawned', () => {
    const bot = mockBot({ entity: null });
    infoCmds.position(bot);
    assert.deepStrictEqual(lastOutput(), { event: 'position', error: 'not_spawned' });
  });

  it('inventory sends items', () => {
    const items = [{ name: 'diamond', count: 3, slot: 0 }];
    const bot = mockBot({ items });
    infoCmds.inventory(bot);
    const out = lastOutput();
    assert.strictEqual(out.event, 'inventory');
    assert.deepStrictEqual(out.items, [{ name: 'diamond', count: 3, slot: 0 }]);
  });

  it('players sends player list', () => {
    const bot = mockBot({
      players: {
        Steve: { username: 'Steve', ping: 42, entity: {} },
        Alex: { username: 'Alex', ping: 100, entity: null },
      },
    });
    infoCmds.players(bot);
    const out = lastOutput();
    assert.strictEqual(out.event, 'players');
    assert.strictEqual(out.list.length, 2);
    const steve = out.list.find(p => p.username === 'Steve');
    assert.strictEqual(steve.entity, true);
    const alex = out.list.find(p => p.username === 'Alex');
    assert.strictEqual(alex.entity, false);
  });
});

describe('commands/movement', () => {
  beforeEach(() => captureStart());
  afterEach(() => captureStop());

  it('look sends ack', () => {
    // Fresh require to avoid state leaks
    delete require.cache[require.resolve('../commands/movement')];
    delete require.cache[require.resolve('../action_queue')];
    const moveCmds = require('../commands/movement');
    const bot = mockBot();
    moveCmds.look(bot, { yaw: 1.5, pitch: -0.5 });
    assert.deepStrictEqual(lastOutput(), { event: 'ack', action: 'look' });
  });

  it('jump sends ack', () => {
    delete require.cache[require.resolve('../commands/movement')];
    delete require.cache[require.resolve('../action_queue')];
    const moveCmds = require('../commands/movement');
    const bot = mockBot();
    moveCmds.jump(bot);
    assert.deepStrictEqual(lastOutput(), { event: 'ack', action: 'jump' });
  });

  it('stop sends stopped event', () => {
    delete require.cache[require.resolve('../commands/movement')];
    delete require.cache[require.resolve('../action_queue')];
    const moveCmds = require('../commands/movement');
    const bot = mockBot();
    moveCmds.stop(bot);
    assert.deepStrictEqual(lastOutput(), { event: 'stopped' });
  });
});
