/**
 * Combat commands: attack.
 */

const { send } = require('../utils');

function attack(bot, cmd, done) {
  const entity = bot.nearestEntity();
  if (entity) {
    bot.attack(entity);
    send({ event: 'ack', action: 'attack', target: entity.name || 'entity' });
  } else {
    send({ event: 'error', message: 'No entity nearby to attack' });
  }
  done();
}

module.exports = { attack };
