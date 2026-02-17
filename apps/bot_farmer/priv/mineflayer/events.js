/**
 * Bot event bindings — wires mineflayer events to the Elixir JSON protocol.
 */

const { pathfinder, Movements } = require('mineflayer-pathfinder');
const { send, log } = require('./utils');

/**
 * Bind all mineflayer events to send JSON to Elixir.
 * @param {object} bot - mineflayer bot instance
 * @param {function} onDisconnect - callback for cleanup on disconnect
 * @param {function} scheduleReconnect - callback to schedule reconnection
 */
function bindEvents(bot, onDisconnect, scheduleReconnect) {
  bot.loadPlugin(pathfinder);

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
    if (uname === bot.username) return;
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
    const reasonStr = reason.toString();
    send({ event: 'kicked', reason: reasonStr });
    log(`Kicked: ${reasonStr}`);
    if (/not whitelisted|banned/i.test(reasonStr)) {
      log('Fatal kick reason — not retrying');
      process.exit(1);
    }
    scheduleReconnect('kicked');
  });

  bot.on('error', (err) => {
    send({ event: 'error', message: err.message });
    log(`Error: ${err.message}`);
  });

  bot.on('end', (reason) => {
    send({ event: 'disconnected', reason: reason || 'unknown' });
    log(`Disconnected: ${reason}`);
    onDisconnect();
    scheduleReconnect(reason);
  });
}

module.exports = { bindEvents };
