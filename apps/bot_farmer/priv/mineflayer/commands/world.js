/**
 * World interaction commands: dig, dig_looking_at, dig_area, find_and_dig, place, activate_block.
 */

const Vec3 = require('vec3');
const { goals: { GoalNear } } = require('mineflayer-pathfinder');
const { send, log, withTimeout, validCoords } = require('../utils');
const { onGoalReached } = require('../action_queue');
const { getDigAreaCancelled, setDigAreaCancelled } = require('./movement');

function dig(bot, cmd, done) {
  const { x, y, z } = cmd;
  if (!validCoords(x, y, z)) {
    send({ event: 'error', action: 'dig', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
    done();
    return;
  }
  const block = bot.blockAt(new Vec3(x, y, z));
  if (!block || block.name === 'air') {
    send({ event: 'error', action: 'dig', message: `No block at ${x}, ${y}, ${z}` });
    done();
  } else {
    withTimeout(bot.dig(block), 30000, 'dig')
      .then(() => {
        send({ event: 'ack', action: 'dig', block: block.name, x, y, z });
        send({ event: 'dig_done', block: block.name, x, y, z });
      })
      .catch((err) => {
        send({ event: 'error', action: 'dig', message: err.message });
      })
      .finally(() => done());
  }
}

function digLookingAt(bot, cmd, done) {
  const target = bot.blockAtCursor(5);
  if (!target || target.name === 'air') {
    send({ event: 'error', action: 'dig_looking_at', message: 'No block in line of sight' });
    done();
  } else {
    withTimeout(bot.dig(target), 30000, 'dig_looking_at')
      .then(() => {
        send({ event: 'ack', action: 'dig_looking_at', block: target.name, x: target.position.x, y: target.position.y, z: target.position.z });
      })
      .catch((err) => {
        send({ event: 'error', action: 'dig_looking_at', message: err.message });
      })
      .finally(() => done());
  }
}

function place(bot, cmd, done) {
  const { x, y, z, face } = cmd;
  if (!validCoords(x, y, z)) {
    send({ event: 'error', action: 'place', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
    done();
    return;
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
    done();
  } else {
    withTimeout(bot.placeBlock(refBlock, faceVec), 10000, 'place')
      .then(() => {
        send({ event: 'ack', action: 'place', x, y, z, face: face || 'top' });
      })
      .catch((err) => {
        send({ event: 'error', action: 'place', message: err.message });
      })
      .finally(() => done());
  }
}

function findAndDig(bot, cmd, done) {
  const blockType = cmd.block_type;
  const mcData = require('minecraft-data')(bot.version);
  const blockDef = mcData.blocksByName[blockType];
  if (!blockDef) {
    send({ event: 'error', action: 'find_and_dig', message: `Unknown block type: ${blockType}` });
    done();
    return;
  }
  const found = bot.findBlocks({ matching: blockDef.id, maxDistance: 32, count: 1 });
  if (found.length === 0) {
    send({ event: 'error', action: 'find_and_dig', message: `No ${blockType} found within 32 blocks` });
    done();
    return;
  }
  const targetPos = found[0];
  const targetBlock = bot.blockAt(targetPos);
  if (!targetBlock) {
    send({ event: 'error', action: 'find_and_dig', message: `Block at ${targetPos} disappeared` });
    done();
    return;
  }

  function digTarget() {
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
        .finally(() => done());
    } else {
      send({ event: 'ack', action: 'find_and_dig', block: blockType, message: 'block already gone' });
      send({ event: 'find_and_dig_done', block: blockType, x: targetPos.x, y: targetPos.y, z: targetPos.z });
      done();
    }
  }

  if (bot.pathfinder && bot.pathfinder.movements) {
    bot.pathfinder.setGoal(new GoalNear(targetPos.x, targetPos.y, targetPos.z, 2));
    onGoalReached(bot, digTarget, 15000, done);
  } else {
    const dist = bot.entity.position.distanceTo(targetPos);
    if (dist <= 5) {
      digTarget();
    } else {
      send({ event: 'error', action: 'find_and_dig', message: `${blockType} found at ${targetPos} but too far (${Math.round(dist)} blocks) and no pathfinder` });
      send({ event: 'find_and_dig_error', error: `${blockType} too far and no pathfinder` });
      done();
    }
  }
}

function digArea(bot, cmd, done) {
  const { x: ax, y: ay, z: az, width: aw, height: ah, depth: ad } = cmd;
  if (!validCoords(ax, ay, az)) {
    send({ event: 'error', action: 'dig_area', message: `Invalid coordinates: ${ax}, ${ay}, ${az}` });
    done();
    return;
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

  setDigAreaCancelled(false);
  send({ event: 'ack', action: 'dig_area', message: `Starting to dig ${w}x${h}x${d} area (${blocks.length} blocks)` });

  async function digNext(idx) {
    if (getDigAreaCancelled()) {
      send({ event: 'dig_area_cancelled', blocksRemoved: idx });
      done();
      return;
    }
    if (idx >= blocks.length) {
      send({ event: 'dig_area_done', blocksRemoved: blocks.length });
      done();
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
          onGoalReached(bot, () => { resolve(); }, 10000, resolve);
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
}

function activateBlock(bot, cmd, done) {
  const { x, y, z } = cmd;
  if (!validCoords(x, y, z)) {
    send({ event: 'error', action: 'activate_block', message: `Invalid coordinates: ${x}, ${y}, ${z}` });
    done();
    return;
  }
  const block = bot.blockAt(new Vec3(x, y, z));
  if (!block) {
    send({ event: 'error', action: 'activate_block', message: `No block at ${x}, ${y}, ${z}` });
    done();
  } else {
    withTimeout(bot.activateBlock(block), 10000, 'activate_block')
      .then(() => {
        send({ event: 'ack', action: 'activate_block', block: block.name, x, y, z });
      })
      .catch((err) => {
        send({ event: 'error', action: 'activate_block', message: err.message });
      })
      .finally(() => done());
  }
}

module.exports = { dig, digLookingAt, place, findAndDig, digArea, activateBlock };
