/**
 * Mineflayer Bridge - communicates with Elixir via JSON over stdin/stdout.
 *
 * Protocol:
 *   Each message is a JSON object on a single line (newline-delimited JSON).
 *   Input (from Elixir):  { "action": "chat", "message": "hello" }
 *   Output (to Elixir):   { "event": "chat", "username": "Steve", "message": "hi" }
 */

const mineflayer = require('mineflayer');
const { pathfinder, Movements, goals: { GoalBlock, GoalFollow, GoalNear } } = require('mineflayer-pathfinder');
const Vec3 = require('vec3');
const readline = require('readline');

// Config from environment or argv
const host = process.env.MC_HOST || process.argv[2] || 'localhost';
const port = parseInt(process.env.MC_PORT || process.argv[3] || '25565');
const username = process.env.BOT_USERNAME || process.argv[4] || 'McFunBot';

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function log(msg) {
  process.stderr.write(`[bridge] ${msg}\n`);
}

// --- Helpers ---

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
 * Validate that coordinates are finite numbers. Returns true if valid.
 */
function validCoords(x, y, z) {
  return isFinite(x) && isFinite(y) && isFinite(z);
}

// --- Command queue for async actions ---

let actionBusy = false;
const actionQueue = [];
let activeCleanups = []; // cleanup functions for pending goal_reached listeners

const SYNC_ACTIONS = new Set([
  'chat', 'whisper', 'position', 'inventory', 'players',
  'look', 'jump', 'sneak', 'status', 'survey', 'stop', 'quit'
]);

function processCommand(cmd) {
  if (SYNC_ACTIONS.has(cmd.action)) {
    executeCommand(cmd);
  } else if (actionBusy) {
    actionQueue.push(cmd);
    send({ event: 'queued', action: cmd.action, queue_length: actionQueue.length });
  } else {
    executeAction(cmd);
  }
}

function executeAction(cmd) {
  actionBusy = true;
  executeCommand(cmd);
}

function actionDone() {
  actionBusy = false;
  if (actionQueue.length > 0) {
    const next = actionQueue.shift();
    executeAction(next);
  }
}

function clearQueue() {
  actionQueue.length = 0;
  actionBusy = false;
}

// --- Goal reached helper with cleanup ---

/**
 * Listen for goal_reached with timeout and cleanup tracking.
 * Returns a cleanup function. Calls callback() on goal reached.
 */
function onGoalReached(callback, timeoutMs = 30000) {
  let resolved = false;

  const cleanup = () => {
    if (resolved) return;
    resolved = true;
    bot.removeListener('goal_reached', handler);
    clearTimeout(timer);
    const idx = activeCleanups.indexOf(cleanup);
    if (idx !== -1) activeCleanups.splice(idx, 1);
  };

  const handler = () => {
    if (!resolved) {
      cleanup();
      callback();
    }
  };

  bot.once('goal_reached', handler);

  const timer = setTimeout(() => {
    if (!resolved) {
      cleanup();
      try { bot.pathfinder.setGoal(null); } catch (_) {}
      send({ event: 'error', message: `Pathfinding timed out after ${timeoutMs}ms` });
      actionDone();
    }
  }, timeoutMs);

  activeCleanups.push(cleanup);
  return cleanup;
}

// --- Track movement fallback timers to avoid leaks ---
let movementTimer = null;

// Cancellation flag for long-running dig_area
let digAreaCancelled = false;

// --- Reconnection state ---
let bot = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 10;
const MAX_BACKOFF_MS = 30000;
let reconnecting = false;

// --- Bot creation and event binding ---

function createBot() {
  bot = mineflayer.createBot({
    host,
    port,
    username,
    auth: 'offline',
    hideErrors: false,
  });

  bot.loadPlugin(pathfinder);

  // --- Events -> Elixir ---

  bot.once('spawn', () => {
    try {
      const mcData = require('minecraft-data')(bot.version);
      const defaultMove = new Movements(bot, mcData);
      bot.pathfinder.setMovements(defaultMove);
      log('Pathfinder loaded successfully');
    } catch (err) {
      log(`Pathfinder init failed (falling back to simple movement): ${err.message}`);
    }
  });

  bot.on('spawn', () => {
    reconnectAttempts = 0;
    reconnecting = false;
    const pos = bot.entity.position;
    const dimension = bot.game && bot.game.dimension;
    send({ event: 'spawn', position: { x: pos.x, y: pos.y, z: pos.z }, dimension });
    log('Bot spawned');
  });

  bot.on('chat', (uname, message) => {
    if (uname === bot.username) return;
    send({ event: 'chat', username: uname, message });
  });

  bot.on('whisper', (uname, message) => {
    send({ event: 'whisper', username: uname, message });
  });

  bot.on('playerJoined', (player) => {
    send({ event: 'player_joined', username: player.username });
  });

  bot.on('playerLeft', (player) => {
    send({ event: 'player_left', username: player.username });
  });

  bot.on('health', () => {
    send({ event: 'health', health: bot.health, food: bot.food });
  });

  bot.on('death', () => {
    send({ event: 'death' });
    log('Bot died — event sent, letting Elixir decide lifecycle');
  });

  bot.on('kicked', (reason) => {
    send({ event: 'kicked', reason: reason.toString() });
    log(`Kicked: ${reason}`);
    // Kicked bots may be able to rejoin — trigger reconnect
    scheduleReconnect('kicked');
  });

  bot.on('error', (err) => {
    send({ event: 'error', message: err.message });
    log(`Error: ${err.message}`);
  });

  bot.on('end', (reason) => {
    send({ event: 'disconnected', reason: reason || 'unknown' });
    log(`Disconnected: ${reason}`);
    // Clean up async state
    cleanupOnDisconnect();
    scheduleReconnect(reason);
  });
}

function cleanupOnDisconnect() {
  // Clean up active goal listeners
  for (const cleanup of [...activeCleanups]) {
    cleanup();
  }
  activeCleanups = [];
  clearQueue();
  digAreaCancelled = true;
  if (movementTimer) {
    clearTimeout(movementTimer);
    movementTimer = null;
  }
}

function scheduleReconnect(reason) {
  if (reconnecting) return;
  reconnecting = true;
  reconnectAttempts++;

  if (reconnectAttempts > MAX_RECONNECT_ATTEMPTS) {
    log(`Max reconnect attempts (${MAX_RECONNECT_ATTEMPTS}) reached, exiting`);
    send({ event: 'error', message: `Failed to reconnect after ${MAX_RECONNECT_ATTEMPTS} attempts` });
    process.exit(1);
  }

  // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s, 30s...
  const backoffMs = Math.min(1000 * Math.pow(2, reconnectAttempts - 1), MAX_BACKOFF_MS);
  log(`Reconnecting in ${backoffMs}ms (attempt ${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`);
  send({ event: 'reconnecting', attempt: reconnectAttempts, backoff_ms: backoffMs });

  setTimeout(() => {
    log(`Attempting reconnect (attempt ${reconnectAttempts})`);
    try {
      createBot();
    } catch (err) {
      log(`Reconnect failed: ${err.message}`);
      reconnecting = false;
      scheduleReconnect('reconnect_failed');
    }
  }, backoffMs);
}

// --- stdin command handling ---

const rl = readline.createInterface({ input: process.stdin });

rl.on('line', (line) => {
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch (e) {
    send({ event: 'error', message: `Invalid JSON: ${line}` });
    return;
  }

  if (!bot) {
    send({ event: 'error', message: 'Bot not connected yet' });
    return;
  }

  processCommand(cmd);
});

rl.on('close', () => {
  log('stdin closed, shutting down');
  try { if (bot) bot.quit(); } catch (_) {}
  process.exit(0);
});

// --- Command execution ---

function executeCommand(cmd) {
  switch (cmd.action) {
    case 'chat':
      bot.chat(cmd.message || '');
      send({ event: 'ack', action: 'chat' });
      break;

    case 'whisper':
      bot.whisper(cmd.target, cmd.message || '');
      send({ event: 'ack', action: 'whisper' });
      break;

    case 'move': {
      const { x, y, z } = cmd;
      if (!validCoords(x, y, z)) {
        send({ event: 'error', action: 'move', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
        actionDone();
        break;
      }
      if (bot.pathfinder && bot.pathfinder.movements) {
        bot.pathfinder.setGoal(new GoalBlock(x, y, z));
        onGoalReached(() => {
          send({ event: 'move_done', x, y, z });
          actionDone();
        }, 30000);
      } else {
        // Simple fallback: look at target and walk
        const pos = bot.entity.position;
        const dx = x - pos.x;
        const dz = z - pos.z;
        const yaw = Math.atan2(-dx, dz);
        bot.look(yaw, 0, true);
        bot.setControlState('forward', true);
        if (movementTimer) clearTimeout(movementTimer);
        movementTimer = setTimeout(() => { bot.clearControlStates(); movementTimer = null; actionDone(); }, 2000);
      }
      send({ event: 'ack', action: 'move' });
      break;
    }

    case 'look': {
      const { yaw, pitch } = cmd;
      bot.look(yaw, pitch, true);
      send({ event: 'ack', action: 'look' });
      break;
    }

    case 'jump':
      bot.setControlState('jump', true);
      setTimeout(() => bot.setControlState('jump', false), 500);
      send({ event: 'ack', action: 'jump' });
      break;

    case 'sneak':
      bot.setControlState('sneak', cmd.enabled !== false);
      send({ event: 'ack', action: 'sneak' });
      break;

    case 'attack': {
      const entity = bot.nearestEntity();
      if (entity) {
        bot.attack(entity);
        send({ event: 'ack', action: 'attack', target: entity.name || 'entity' });
      } else {
        send({ event: 'error', message: 'No entity nearby to attack' });
      }
      actionDone();
      break;
    }

    case 'inventory':
      send({
        event: 'inventory',
        items: bot.inventory.items().map(i => ({
          name: i.name,
          count: i.count,
          slot: i.slot,
        })),
      });
      break;

    case 'position':
      send({
        event: 'position',
        x: bot.entity.position.x,
        y: bot.entity.position.y,
        z: bot.entity.position.z,
        yaw: bot.entity.yaw,
        pitch: bot.entity.pitch,
        dimension: bot.game && bot.game.dimension,
      });
      break;

    case 'players':
      send({
        event: 'players',
        list: Object.values(bot.players).map(p => ({
          username: p.username,
          ping: p.ping,
          entity: p.entity ? true : false,
        })),
      });
      break;

    case 'goto': {
      let gx, gy, gz;
      if (cmd.target) {
        const player = bot.players[cmd.target];
        if (!player || !player.entity) {
          send({ event: 'error', action: 'goto', message: `Player ${cmd.target} not found or not visible` });
          actionDone();
          break;
        }
        gx = player.entity.position.x;
        gy = player.entity.position.y;
        gz = player.entity.position.z;
      } else {
        gx = cmd.x;
        gy = cmd.y;
        gz = cmd.z;
      }

      if (!cmd.target && !validCoords(gx, gy, gz)) {
        send({ event: 'error', action: 'goto', message: `Invalid coordinates: ${gx}, ${gy}, ${gz}` });
        actionDone();
        break;
      }

      if (bot.pathfinder && bot.pathfinder.movements) {
        bot.pathfinder.setGoal(new GoalNear(gx, gy, gz, 2));
        onGoalReached(() => {
          send({ event: 'goto_done', x: gx, y: gy, z: gz });
          actionDone();
        }, 30000);
      } else {
        // Simple fallback: look toward target and walk
        const pos = bot.entity.position;
        const dx = gx - pos.x;
        const dz = gz - pos.z;
        const yaw = Math.atan2(-dx, dz);
        bot.look(yaw, 0, true);
        bot.setControlState('forward', true);
        if (movementTimer) clearTimeout(movementTimer);
        movementTimer = setTimeout(() => { bot.clearControlStates(); movementTimer = null; actionDone(); }, 3000);
      }
      send({ event: 'ack', action: 'goto', target: cmd.target || `${gx},${gy},${gz}` });
      break;
    }

    case 'follow': {
      const target = bot.players[cmd.target];
      if (target && target.entity) {
        if (bot.pathfinder && bot.pathfinder.movements) {
          const dist = cmd.distance || 3;
          bot.pathfinder.setGoal(new GoalFollow(target.entity, dist), true);
        } else {
          // Simple fallback
          const pos = bot.entity.position;
          const tpos = target.entity.position;
          const dx = tpos.x - pos.x;
          const dz = tpos.z - pos.z;
          const yaw = Math.atan2(-dx, dz);
          bot.look(yaw, 0, true);
          bot.setControlState('forward', true);
          if (movementTimer) clearTimeout(movementTimer);
          movementTimer = setTimeout(() => { bot.clearControlStates(); movementTimer = null; }, 2000);
        }
        send({ event: 'ack', action: 'follow', target: cmd.target });
      } else {
        send({ event: 'error', message: `Player ${cmd.target} not found or not visible` });
      }
      // follow is continuous — don't call actionDone (stop will clear it)
      break;
    }

    case 'dig': {
      const { x, y, z } = cmd;
      if (!validCoords(x, y, z)) {
        send({ event: 'error', action: 'dig', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
        actionDone();
        break;
      }
      const block = bot.blockAt(new Vec3(x, y, z));
      if (!block || block.name === 'air') {
        send({ event: 'error', action: 'dig', message: `No block at ${x}, ${y}, ${z}` });
        actionDone();
      } else {
        withTimeout(bot.dig(block), 30000, 'dig')
          .then(() => {
            send({ event: 'ack', action: 'dig', block: block.name, x, y, z });
            send({ event: 'dig_done', block: block.name, x, y, z });
          })
          .catch((err) => {
            send({ event: 'error', action: 'dig', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'dig_looking_at': {
      const target = bot.blockAtCursor(5);
      if (!target || target.name === 'air') {
        send({ event: 'error', action: 'dig_looking_at', message: 'No block in line of sight' });
        actionDone();
      } else {
        withTimeout(bot.dig(target), 30000, 'dig_looking_at')
          .then(() => {
            send({ event: 'ack', action: 'dig_looking_at', block: target.name, x: target.position.x, y: target.position.y, z: target.position.z });
          })
          .catch((err) => {
            send({ event: 'error', action: 'dig_looking_at', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'place': {
      const { x, y, z, face } = cmd;
      if (!validCoords(x, y, z)) {
        send({ event: 'error', action: 'place', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
        actionDone();
        break;
      }
      const faceVectors = {
        top:    new Vec3(0, 1, 0),
        bottom: new Vec3(0, -1, 0),
        north:  new Vec3(0, 0, -1),
        south:  new Vec3(0, 0, 1),
        east:   new Vec3(1, 0, 0),
        west:   new Vec3(-1, 0, 0),
      };
      let faceVec;
      if (typeof face === 'string') {
        faceVec = faceVectors[face] || faceVectors.top;
      } else if (face && face.fx !== undefined) {
        faceVec = new Vec3(face.fx, face.fy, face.fz);
      } else {
        faceVec = faceVectors.top;
      }
      const refBlock = bot.blockAt(new Vec3(x, y, z));
      if (!refBlock) {
        send({ event: 'error', action: 'place', message: `No reference block at ${x}, ${y}, ${z}` });
        actionDone();
      } else {
        withTimeout(bot.placeBlock(refBlock, faceVec), 10000, 'place')
          .then(() => {
            send({ event: 'ack', action: 'place', x, y, z, face: face || 'top' });
          })
          .catch((err) => {
            send({ event: 'error', action: 'place', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'equip': {
      const { item_name, destination } = cmd;
      const dest = destination || 'hand';
      const item = bot.inventory.items().find(i => i.name === item_name);
      if (!item) {
        send({ event: 'error', action: 'equip', message: `Item '${item_name}' not in inventory` });
        actionDone();
      } else {
        withTimeout(bot.equip(item, dest), 10000, 'equip')
          .then(() => {
            send({ event: 'ack', action: 'equip', item_name, destination: dest });
          })
          .catch((err) => {
            send({ event: 'error', action: 'equip', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'craft': {
      const { item_name, count } = cmd;
      const mcData = require('minecraft-data')(bot.version);
      const itemDef = mcData.itemsByName[item_name];
      if (!itemDef) {
        send({ event: 'error', action: 'craft', message: `Unknown item: '${item_name}'` });
        actionDone();
        break;
      }
      const recipes = bot.recipesFor(itemDef.id, null, count || 1, null);
      if (!recipes || recipes.length === 0) {
        send({ event: 'error', action: 'craft', message: `No recipe for '${item_name}' (need crafting table nearby?)` });
        actionDone();
      } else {
        withTimeout(bot.craft(recipes[0], count || 1, null), 15000, 'craft')
          .then(() => {
            send({ event: 'ack', action: 'craft', item_name, count: count || 1 });
          })
          .catch((err) => {
            send({ event: 'error', action: 'craft', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'drop': {
      const held = bot.heldItem;
      if (!held) {
        send({ event: 'error', action: 'drop', message: 'Not holding any item' });
        actionDone();
      } else {
        withTimeout(bot.tossStack(held), 10000, 'drop')
          .then(() => {
            send({ event: 'ack', action: 'drop', item: held.name, count: held.count });
          })
          .catch((err) => {
            send({ event: 'error', action: 'drop', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'survey': {
      const range = cmd.range || 16;
      const mcData = require('minecraft-data')(bot.version);

      const pos = bot.entity.position;
      const cursor = bot.blockAtCursor(5);

      // Sample blocks in range using findBlocks for common interesting types
      const interestingBlocks = [];
      for (const [name, block] of Object.entries(mcData.blocksByName)) {
        if (['air', 'cave_air', 'void_air', 'water', 'lava', 'bedrock', 'stone',
             'dirt', 'grass_block', 'deepslate', 'netherrack', 'end_stone',
             'sand', 'gravel', 'sandstone', 'diorite', 'granite', 'andesite',
             'tuff', 'calcite', 'dripstone_block', 'smooth_basalt',
             'cobblestone', 'mossy_cobblestone'].includes(name)) continue;
        try {
          const found = bot.findBlocks({ matching: block.id, maxDistance: range, count: 5 });
          if (found.length > 0) {
            interestingBlocks.push({ name, count: found.length, nearest: found[0] });
          }
        } catch(_) {}
      }

      // Inventory
      const items = bot.inventory.items().map(i => ({ name: i.name, count: i.count }));

      // Nearby entities
      const entities = [];
      for (const [id, entity] of Object.entries(bot.entities)) {
        if (entity === bot.entity) continue;
        const dist = entity.position.distanceTo(pos);
        if (dist <= range) {
          entities.push({
            type: entity.type,
            name: entity.name || entity.username || entity.displayName || 'unknown',
            distance: Math.round(dist),
          });
        }
      }
      entities.sort((a, b) => a.distance - b.distance);

      send({
        event: 'survey',
        position: { x: Math.round(pos.x), y: Math.round(pos.y), z: Math.round(pos.z) },
        looking_at: cursor ? cursor.name : null,
        blocks: interestingBlocks.slice(0, 20).map(b => `${b.name}(${b.count})`),
        inventory: items.slice(0, 20),
        entities: entities.slice(0, 15),
        health: bot.health,
        food: bot.food,
      });
      break;
    }

    case 'find_and_dig': {
      const blockType = cmd.block_type;
      const mcData = require('minecraft-data')(bot.version);
      const blockDef = mcData.blocksByName[blockType];
      if (!blockDef) {
        send({ event: 'error', action: 'find_and_dig', message: `Unknown block type: ${blockType}` });
        actionDone();
        break;
      }
      const found = bot.findBlocks({ matching: blockDef.id, maxDistance: 32, count: 1 });
      if (found.length === 0) {
        send({ event: 'error', action: 'find_and_dig', message: `No ${blockType} found within 32 blocks` });
        actionDone();
        break;
      }
      const targetPos = found[0];
      const targetBlock = bot.blockAt(targetPos);
      if (!targetBlock) {
        send({ event: 'error', action: 'find_and_dig', message: `Block at ${targetPos} disappeared` });
        actionDone();
        break;
      }

      if (bot.pathfinder && bot.pathfinder.movements) {
        bot.pathfinder.setGoal(new GoalNear(targetPos.x, targetPos.y, targetPos.z, 2));
        onGoalReached(() => {
          const block = bot.blockAt(targetPos);
          if (block && block.name !== 'air') {
            withTimeout(bot.dig(block), 30000, 'find_and_dig:dig')
              .then(() => {
                send({ event: 'ack', action: 'find_and_dig', block: blockType, x: targetPos.x, y: targetPos.y, z: targetPos.z });
                send({ event: 'find_and_dig_done', block: blockType, x: targetPos.x, y: targetPos.y, z: targetPos.z });
              })
              .catch(err => {
                send({ event: 'error', action: 'find_and_dig', message: err.message });
                send({ event: 'find_and_dig_error', error: err.message });
              })
              .finally(() => actionDone());
          } else {
            send({ event: 'ack', action: 'find_and_dig', block: blockType, message: 'block already gone' });
            send({ event: 'find_and_dig_done', block: blockType, x: targetPos.x, y: targetPos.y, z: targetPos.z });
            actionDone();
          }
        }, 15000);
      } else {
        // No pathfinder — try to dig if close enough
        const dist = bot.entity.position.distanceTo(targetPos);
        if (dist <= 5) {
          withTimeout(bot.dig(targetBlock), 30000, 'find_and_dig:dig')
            .then(() => {
              send({ event: 'ack', action: 'find_and_dig', block: blockType, x: targetPos.x, y: targetPos.y, z: targetPos.z });
              send({ event: 'find_and_dig_done', block: blockType, x: targetPos.x, y: targetPos.y, z: targetPos.z });
            })
            .catch(err => {
              send({ event: 'error', action: 'find_and_dig', message: err.message });
              send({ event: 'find_and_dig_error', error: err.message });
            })
            .finally(() => actionDone());
        } else {
          send({ event: 'error', action: 'find_and_dig', message: `${blockType} found at ${targetPos} but too far (${Math.round(dist)} blocks) and no pathfinder` });
          send({ event: 'find_and_dig_error', error: `${blockType} too far and no pathfinder` });
          actionDone();
        }
      }
      break;
    }

    case 'dig_area': {
      const { x: ax, y: ay, z: az, width: aw, height: ah, depth: ad } = cmd;
      if (!validCoords(ax, ay, az)) {
        send({ event: 'error', action: 'dig_area', message: `Invalid coordinates: ${ax}, ${ay}, ${az}` });
        actionDone();
        break;
      }
      const w = Math.min(aw || 5, 20);
      const h = Math.min(ah || 3, 10);
      const d = Math.min(ad || 5, 20);

      const blocks = [];
      for (let dy = h - 1; dy >= 0; dy--) {
        for (let dx = 0; dx < w; dx++) {
          for (let dz = 0; dz < d; dz++) {
            blocks.push({ x: ax + dx, y: ay + dy, z: az + dz });
          }
        }
      }

      digAreaCancelled = false;
      send({ event: 'ack', action: 'dig_area', message: `Starting to dig ${w}x${h}x${d} area (${blocks.length} blocks)` });

      async function digNext(idx) {
        if (digAreaCancelled) {
          send({ event: 'dig_area_cancelled', blocksRemoved: idx });
          actionDone();
          return;
        }
        if (idx >= blocks.length) {
          send({ event: 'dig_area_done', blocksRemoved: blocks.length });
          actionDone();
          return;
        }
        const pos = blocks[idx];
        const block = bot.blockAt(new Vec3(pos.x, pos.y, pos.z));
        if (!block || block.name === 'air' || block.name === 'cave_air') {
          digNext(idx + 1);
          return;
        }

        // Pathfind close enough to dig
        const dist = bot.entity.position.distanceTo(new Vec3(pos.x, pos.y, pos.z));
        if (dist > 4.5 && bot.pathfinder && bot.pathfinder.movements) {
          try {
            bot.pathfinder.setGoal(new GoalNear(pos.x, pos.y, pos.z, 3));
            await new Promise((resolve) => {
              onGoalReached(() => { resolve(); }, 10000);
            });
          } catch (e) {
            log(`dig_area: pathfind error at ${pos.x},${pos.y},${pos.z}: ${e.message}`);
          }
        }

        // Dig the block
        const current = bot.blockAt(new Vec3(pos.x, pos.y, pos.z));
        if (current && current.name !== 'air' && current.name !== 'cave_air') {
          try {
            await withTimeout(bot.dig(current), 30000, 'dig_area:dig');
          } catch (e) {
            log(`dig_area: dig error at ${pos.x},${pos.y},${pos.z}: ${e.message}`);
          }
        }

        // Progress update every 10 blocks
        if ((idx + 1) % 10 === 0) {
          send({ event: 'ack', action: 'dig_area', message: `Progress: ${idx + 1}/${blocks.length} blocks` });
        }

        digNext(idx + 1);
      }

      digNext(0);
      break;
    }

    // --- New commands (mc-fun-67) ---

    case 'activate_block': {
      const { x, y, z } = cmd;
      if (!validCoords(x, y, z)) {
        send({ event: 'error', action: 'activate_block', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
        actionDone();
        break;
      }
      const block = bot.blockAt(new Vec3(x, y, z));
      if (!block) {
        send({ event: 'error', action: 'activate_block', message: `No block at ${x}, ${y}, ${z}` });
        actionDone();
      } else {
        withTimeout(bot.activateBlock(block), 10000, 'activate_block')
          .then(() => {
            send({ event: 'ack', action: 'activate_block', block: block.name, x, y, z });
          })
          .catch((err) => {
            send({ event: 'error', action: 'activate_block', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'use_item':
      try {
        bot.activateItem();
        send({ event: 'ack', action: 'use_item' });
      } catch (err) {
        send({ event: 'error', action: 'use_item', message: err.message });
      }
      actionDone();
      break;

    case 'deactivate_item':
      try {
        bot.deactivateItem();
        send({ event: 'ack', action: 'deactivate_item' });
      } catch (err) {
        send({ event: 'error', action: 'deactivate_item', message: err.message });
      }
      actionDone();
      break;

    case 'sleep': {
      const mcData = require('minecraft-data')(bot.version);
      const bed = bot.findBlock({
        matching: id => {
          const b = mcData.blocks[id];
          return b && b.name.includes('bed');
        },
        maxDistance: 4
      });
      if (!bed) {
        send({ event: 'error', action: 'sleep', message: 'No bed found within 4 blocks' });
        actionDone();
      } else {
        withTimeout(bot.sleep(bed), 10000, 'sleep')
          .then(() => {
            send({ event: 'ack', action: 'sleep' });
          })
          .catch((err) => {
            send({ event: 'error', action: 'sleep', message: err.message });
          })
          .finally(() => actionDone());
      }
      break;
    }

    case 'wake':
      try {
        bot.wake();
        send({ event: 'ack', action: 'wake' });
      } catch (err) {
        send({ event: 'error', action: 'wake', message: err.message });
      }
      actionDone();
      break;

    case 'status':
      send({
        event: 'status',
        pathfinder_moving: (bot.pathfinder && bot.pathfinder.isMoving()) || false,
        action_busy: actionBusy,
        queue_length: actionQueue.length,
        health: bot.health,
        food: bot.food,
        position: bot.entity ? { x: bot.entity.position.x, y: bot.entity.position.y, z: bot.entity.position.z } : null,
        dimension: bot.game && bot.game.dimension,
        digging: bot.targetDigBlock != null,
      });
      break;

    case 'stop':
      // Clean up all pending goal listeners
      for (const cleanup of [...activeCleanups]) {
        cleanup();
      }
      activeCleanups = [];
      try { bot.pathfinder.stop(); } catch (_) {}
      try { bot.stopDigging(); } catch (_) {}
      bot.clearControlStates();
      digAreaCancelled = true;
      clearQueue();
      send({ event: 'stopped' });
      break;

    case 'quit':
      bot.quit();
      process.exit(0);
      break;

    default:
      send({ event: 'error', message: `Unknown action: ${cmd.action}` });
      if (!SYNC_ACTIONS.has(cmd.action)) actionDone();
  }
}

// --- Bootstrap ---

log(`Connecting as ${username} to ${host}:${port}`);
createBot();
