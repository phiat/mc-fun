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

function terrainScan(bot) {
  const mcData = require('minecraft-data')(bot.version)
  const Vec3 = require('vec3')
  const columns = bot.world.getColumns()
  const airIds = new Set()

  // Collect air-type state IDs for fast skip
  for (const name of ['air', 'cave_air', 'void_air']) {
    const b = mcData.blocksByName[name]
    if (b) airIds.add(b.defaultState)
  }

  const blocks = []
  const cursor = new Vec3(0, 0, 0)

  for (const { chunkX, chunkZ, column } of columns) {
    const cx = parseInt(chunkX) * 16
    const cz = parseInt(chunkZ) * 16
    const colMinY = column.minY != null ? column.minY : -64
    const sections = column.sections

    // Find highest populated section to avoid scanning empty air above
    let topSectionIdx = sections ? sections.length - 1 : 23
    if (sections) {
      while (topSectionIdx >= 0 && !sections[topSectionIdx]) topSectionIdx--
      if (topSectionIdx < 0) continue  // entirely empty column
    }
    const startY = colMinY + (topSectionIdx + 1) * 16 - 1

    for (let bx = 0; bx < 16; bx++) {
      cursor.x = bx
      for (let bz = 0; bz < 16; bz++) {
        cursor.z = bz
        for (let by = startY; by >= colMinY; by--) {
          // Skip entire empty sections
          if (sections) {
            const secIdx = (by - colMinY) >> 4
            if (!sections[secIdx]) {
              // Jump to bottom of this section
              by = colMinY + secIdx * 16
              continue
            }
          }
          cursor.y = by
          const stateId = column.getBlockStateId(cursor)
          if (stateId && !airIds.has(stateId)) {
            const blockInfo = mcData.blocksByStateId[stateId]
            blocks.push([cx + bx, cz + bz, by, blockInfo ? blockInfo.name : 'unknown'])
            break
          }
        }
      }
    }
  }

  const pos = bot.entity ? bot.entity.position : { x: 0, y: 0, z: 0 }
  send({
    event: 'terrain_scan',
    center: { x: Math.round(pos.x), z: Math.round(pos.z) },
    blocks: blocks,
    chunk_count: columns.length
  })
}

module.exports = { inventory, position, players, status, survey, terrainScan };
