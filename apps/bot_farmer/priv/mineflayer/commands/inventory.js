/**
 * Inventory commands: equip, craft, drop, drop_item, drop_all, use_item, deactivate_item, sleep, wake.
 */

const { send, withTimeout } = require('../utils');

function equip(bot, cmd, done) {
  const { item_name, destination } = cmd;
  const dest = destination || 'hand';
  const item = bot.inventory.items().find(i => i.name === item_name);
  if (!item) {
    send({ event: 'error', action: 'equip', message: `Item '${item_name}' not in inventory` });
    done();
  } else {
    withTimeout(bot.equip(item, dest), 10000, 'equip')
      .then(() => {
        send({ event: 'ack', action: 'equip', item_name, destination: dest });
      })
      .catch((err) => {
        send({ event: 'error', action: 'equip', message: err.message });
      })
      .finally(() => done());
  }
}

function craft(bot, cmd, done) {
  const { item_name, count } = cmd;
  const mcData = require('minecraft-data')(bot.version);
  const itemDef = mcData.itemsByName[item_name];
  if (!itemDef) {
    send({ event: 'error', action: 'craft', message: `Unknown item: '${item_name}'` });
    done();
    return;
  }
  const recipes = bot.recipesFor(itemDef.id, null, count || 1, null);
  if (!recipes || recipes.length === 0) {
    send({ event: 'error', action: 'craft', message: `No recipe for '${item_name}' (need crafting table nearby?)` });
    done();
  } else {
    withTimeout(bot.craft(recipes[0], count || 1, null), 15000, 'craft')
      .then(() => {
        send({ event: 'ack', action: 'craft', item_name, count: count || 1 });
      })
      .catch((err) => {
        send({ event: 'error', action: 'craft', message: err.message });
      })
      .finally(() => done());
  }
}

function drop(bot, cmd, done) {
  const held = bot.heldItem;
  if (!held) {
    send({ event: 'error', action: 'drop', message: 'Not holding any item' });
    done();
  } else {
    withTimeout(bot.tossStack(held), 10000, 'drop')
      .then(() => {
        send({ event: 'ack', action: 'drop', item: held.name, count: held.count });
      })
      .catch((err) => {
        send({ event: 'error', action: 'drop', message: err.message });
      })
      .finally(() => done());
  }
}

function dropItem(bot, cmd, done) {
  const { item_name, count } = cmd;
  const item = bot.inventory.items().find(i => i.name === item_name);
  if (!item) {
    send({ event: 'error', action: 'drop_item', message: `Item '${item_name}' not in inventory` });
    done();
  } else {
    const toDrop = count ? Math.min(count, item.count) : item.count;
    withTimeout(bot.toss(item.type, null, toDrop), 10000, 'drop_item')
      .then(() => {
        send({ event: 'ack', action: 'drop_item', item_name, count: toDrop });
      })
      .catch((err) => {
        send({ event: 'error', action: 'drop_item', message: err.message });
      })
      .finally(() => done());
  }
}

function dropAll(bot, cmd, done) {
  const items = bot.inventory.items();
  if (items.length === 0) {
    send({ event: 'ack', action: 'drop_all', count: 0 });
    done();
  } else {
    let dropped = 0;
    const dropNext = () => {
      const remaining = bot.inventory.items();
      if (remaining.length === 0) {
        send({ event: 'ack', action: 'drop_all', count: dropped });
        done();
        return;
      }
      const item = remaining[0];
      bot.tossStack(item)
        .then(() => { dropped++; dropNext(); })
        .catch(() => { dropped++; dropNext(); });
    };
    dropNext();
  }
}

function useItem(bot, cmd, done) {
  try {
    bot.activateItem();
    send({ event: 'ack', action: 'use_item' });
  } catch (err) {
    send({ event: 'error', action: 'use_item', message: err.message });
  }
  done();
}

function deactivateItem(bot, cmd, done) {
  try {
    bot.deactivateItem();
    send({ event: 'ack', action: 'deactivate_item' });
  } catch (err) {
    send({ event: 'error', action: 'deactivate_item', message: err.message });
  }
  done();
}

function sleep(bot, cmd, done) {
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
    done();
  } else {
    withTimeout(bot.sleep(bed), 10000, 'sleep')
      .then(() => {
        send({ event: 'ack', action: 'sleep' });
      })
      .catch((err) => {
        send({ event: 'error', action: 'sleep', message: err.message });
      })
      .finally(() => done());
  }
}

function wake(bot, cmd, done) {
  try {
    bot.wake();
    send({ event: 'ack', action: 'wake' });
  } catch (err) {
    send({ event: 'error', action: 'wake', message: err.message });
  }
  done();
}

module.exports = { equip, craft, drop, dropItem, dropAll, useItem, deactivateItem, sleep, wake };
