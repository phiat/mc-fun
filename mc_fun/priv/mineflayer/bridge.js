/**
 * Mineflayer Bridge - communicates with Elixir via JSON over stdin/stdout.
 *
 * Protocol:
 *   Each message is a JSON object on a single line (newline-delimited JSON).
 *   Input (from Elixir):  { "action": "chat", "message": "hello" }
 *   Output (to Elixir):   { "event": "chat", "username": "Steve", "message": "hi" }
 */

const mineflayer = require('mineflayer');
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

log(`Connecting as ${username} to ${host}:${port}`);

const bot = mineflayer.createBot({
  host,
  port,
  username,
  auth: 'offline',
  hideErrors: false,
});

// --- Events -> Elixir ---

bot.on('spawn', () => {
  const pos = bot.entity.position;
  send({ event: 'spawn', position: { x: pos.x, y: pos.y, z: pos.z } });
  log('Bot spawned');
});

bot.on('chat', (username, message) => {
  if (username === bot.username) return; // ignore self
  send({ event: 'chat', username, message });
});

bot.on('whisper', (username, message) => {
  send({ event: 'whisper', username, message });
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
  log('Bot died, disconnecting');
  setTimeout(() => {
    try { bot.quit(); } catch (_) {}
    process.exit(0);
  }, 1000);
});

bot.on('kicked', (reason) => {
  send({ event: 'kicked', reason: reason.toString() });
  log(`Kicked: ${reason}`);
});

bot.on('error', (err) => {
  send({ event: 'error', message: err.message });
  log(`Error: ${err.message}`);
});

bot.on('end', (reason) => {
  send({ event: 'end', reason });
  log(`Disconnected: ${reason}`);
  process.exit(0);
});

// --- Commands from Elixir -> Bot ---

const rl = readline.createInterface({ input: process.stdin });

rl.on('line', (line) => {
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch (e) {
    send({ event: 'error', message: `Invalid JSON: ${line}` });
    return;
  }

  handleCommand(cmd);
});

rl.on('close', () => {
  log('stdin closed, shutting down');
  try { bot.quit(); } catch (_) {}
  process.exit(0);
});

function handleCommand(cmd) {
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
      const goal = new (require('mineflayer-pathfinder').goals.GoalBlock)(x, y, z);
      // Only use pathfinder if loaded
      if (bot.pathfinder) {
        bot.pathfinder.setGoal(goal);
      } else {
        // Simple movement: look at target and walk
        bot.lookAt(bot.entity.position.offset(x - bot.entity.position.x, 0, z - bot.entity.position.z));
        bot.setControlState('forward', true);
        setTimeout(() => bot.clearControlStates(), 2000);
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
      const { x, y, z } = cmd;
      if (bot.pathfinder) {
        const { goals } = require('mineflayer-pathfinder');
        bot.pathfinder.setGoal(new goals.GoalBlock(x, y, z));
      } else {
        // Simple fallback: look toward target and walk
        const pos = bot.entity.position;
        const dx = x - pos.x;
        const dz = z - pos.z;
        const yaw = Math.atan2(-dx, dz);
        bot.look(yaw, 0, true);
        bot.setControlState('forward', true);
        setTimeout(() => bot.clearControlStates(), 3000);
      }
      send({ event: 'ack', action: 'goto' });
      break;
    }

    case 'follow': {
      const target = bot.players[cmd.target];
      if (target && target.entity) {
        if (bot.pathfinder) {
          const { goals } = require('mineflayer-pathfinder');
          const dist = cmd.distance || 3;
          bot.pathfinder.setGoal(new goals.GoalFollow(target.entity, dist), true);
        } else {
          // Simple fallback
          const pos = bot.entity.position;
          const tpos = target.entity.position;
          const dx = tpos.x - pos.x;
          const dz = tpos.z - pos.z;
          const yaw = Math.atan2(-dx, dz);
          bot.look(yaw, 0, true);
          bot.setControlState('forward', true);
          setTimeout(() => bot.clearControlStates(), 2000);
        }
        send({ event: 'ack', action: 'follow', target: cmd.target });
      } else {
        send({ event: 'error', message: `Player ${cmd.target} not found or not visible` });
      }
      break;
    }

    case 'quit':
      bot.quit();
      process.exit(0);
      break;

    default:
      send({ event: 'error', message: `Unknown action: ${cmd.action}` });
  }
}
