/**
 * Movement commands: move, goto, follow, look, jump, sneak, stop.
 */

const { goals: { GoalBlock, GoalFollow, GoalNear } } = require('mineflayer-pathfinder');
const { send, validCoords } = require('../utils');
const { onGoalReached, cleanupAllGoals, clearQueue } = require('../action_queue');

// Track fallback movement timer
let movementTimer = null;

// Cancellation flag for dig_area (shared with world commands)
let digAreaCancelled = false;

function setDigAreaCancelled(val) { digAreaCancelled = val; }
function getDigAreaCancelled() { return digAreaCancelled; }

function move(bot, cmd, done) {
  const { x, y, z } = cmd;
  if (!validCoords(x, y, z)) {
    send({ event: 'error', action: 'move', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
    done();
    return;
  }
  if (bot.pathfinder && bot.pathfinder.movements) {
    bot.pathfinder.setGoal(new GoalBlock(x, y, z));
    onGoalReached(bot, () => {
      send({ event: 'move_done', x, y, z });
      done();
    }, 30000, done);
  } else {
    const pos = bot.entity.position;
    const dx = x - pos.x;
    const dz = z - pos.z;
    const yaw = Math.atan2(-dx, dz);
    bot.look(yaw, 0, true);
    bot.setControlState('forward', true);
    if (movementTimer) clearTimeout(movementTimer);
    movementTimer = setTimeout(() => { bot.clearControlStates(); movementTimer = null; done(); }, 2000);
  }
  send({ event: 'ack', action: 'move' });
}

function goto_(bot, cmd, done) {
  let gx, gy, gz;
  if (cmd.target) {
    const player = bot.players[cmd.target];
    if (!player || !player.entity) {
      send({ event: 'error', action: 'goto', message: `Player ${cmd.target} not found or not visible` });
      done();
      return;
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
    done();
    return;
  }

  if (bot.pathfinder && bot.pathfinder.movements) {
    bot.pathfinder.setGoal(new GoalNear(gx, gy, gz, 2));
    onGoalReached(bot, () => {
      send({ event: 'goto_done', x: gx, y: gy, z: gz });
      done();
    }, 30000, done);
  } else {
    const pos = bot.entity.position;
    const dx = gx - pos.x;
    const dz = gz - pos.z;
    const yaw = Math.atan2(-dx, dz);
    bot.look(yaw, 0, true);
    bot.setControlState('forward', true);
    if (movementTimer) clearTimeout(movementTimer);
    movementTimer = setTimeout(() => { bot.clearControlStates(); movementTimer = null; done(); }, 3000);
  }
  send({ event: 'ack', action: 'goto', target: cmd.target || `${gx},${gy},${gz}` });
}

function follow(bot, cmd) {
  const target = bot.players[cmd.target];
  if (target && target.entity) {
    if (bot.pathfinder && bot.pathfinder.movements) {
      const dist = cmd.distance || 3;
      bot.pathfinder.setGoal(new GoalFollow(target.entity, dist), true);
    } else {
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
}

function look(bot, cmd) {
  bot.look(cmd.yaw, cmd.pitch, true);
  send({ event: 'ack', action: 'look' });
}

function jump(bot) {
  bot.setControlState('jump', true);
  setTimeout(() => bot.setControlState('jump', false), 500);
  send({ event: 'ack', action: 'jump' });
}

function sneak(bot, cmd) {
  bot.setControlState('sneak', cmd.enabled !== false);
  send({ event: 'ack', action: 'sneak' });
}

function stop(bot) {
  cleanupAllGoals();
  try { bot.pathfinder.stop(); } catch (_) {}
  try { bot.stopDigging(); } catch (_) {}
  bot.clearControlStates();
  digAreaCancelled = true;
  clearQueue();
  send({ event: 'stopped' });
}

function cleanupMovement() {
  if (movementTimer) {
    clearTimeout(movementTimer);
    movementTimer = null;
  }
  digAreaCancelled = true;
}

module.exports = {
  move, goto: goto_, follow, look, jump, sneak, stop,
  cleanupMovement, setDigAreaCancelled, getDigAreaCancelled,
};
