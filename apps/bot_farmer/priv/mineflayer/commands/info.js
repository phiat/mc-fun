/**
 * Information commands: inventory, position, players, status, survey.
 */

const { send } = require('../utils');
const { getQueueLength, isActionBusy } = require('../action_queue');

function inventory(bot) {
  send({
    event: 'inventory',
    items: bot.inventory.items().map(i => ({
      name: i.name,
      count: i.count,
      slot: i.slot,
    })),
  });
}

function position(bot) {
  if (!bot.entity) {
    send({ event: 'position', error: 'not_spawned' });
  } else {
    send({
      event: 'position',
      x: bot.entity.position.x,
      y: bot.entity.position.y,
      z: bot.entity.position.z,
      yaw: bot.entity.yaw,
      pitch: bot.entity.pitch,
      dimension: bot.game && bot.game.dimension,
    });
  }
}

function players(bot) {
  send({
    event: 'players',
    list: Object.values(bot.players).map(p => ({
      username: p.username,
      ping: p.ping,
      entity: p.entity ? true : false,
    })),
  });
}

function status(bot) {
  send({
    event: 'status',
    pathfinder_moving: (bot.pathfinder && bot.pathfinder.isMoving()) || false,
    action_busy: isActionBusy(),
    queue_length: getQueueLength(),
    health: bot.health,
    food: bot.food,
    position: bot.entity ? { x: bot.entity.position.x, y: bot.entity.position.y, z: bot.entity.position.z } : null,
    dimension: bot.game && bot.game.dimension,
    digging: bot.targetDigBlock != null,
  });
}

function survey(bot, cmd) {
  const range = cmd.range || 16;
  const mcData = require('minecraft-data')(bot.version);

  const pos = bot.entity.position;
  const cursor = bot.blockAtCursor(5);

  const interestingBlocks = [];
  const skipBlocks = new Set([
    'air', 'cave_air', 'void_air', 'water', 'lava', 'bedrock', 'stone',
    'dirt', 'grass_block', 'deepslate', 'netherrack', 'end_stone',
    'sand', 'gravel', 'sandstone', 'diorite', 'granite', 'andesite',
    'tuff', 'calcite', 'dripstone_block', 'smooth_basalt',
    'cobblestone', 'mossy_cobblestone'
  ]);

  for (const [name, block] of Object.entries(mcData.blocksByName)) {
    if (skipBlocks.has(name)) continue;
    try {
      const found = bot.findBlocks({ matching: block.id, maxDistance: range, count: 5 });
      if (found.length > 0) {
        interestingBlocks.push({ name, count: found.length, nearest: found[0] });
      }
    } catch (_) {}
  }

  const items = bot.inventory.items().map(i => ({ name: i.name, count: i.count }));

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
}

module.exports = { inventory, position, players, status, survey };
