/**
 * Chat and whisper commands.
 */

const { send } = require('../utils');

function chat(bot, cmd) {
  bot.chat(cmd.message || '');
  send({ event: 'ack', action: 'chat' });
}

function whisper(bot, cmd) {
  bot.whisper(cmd.target, cmd.message || '');
  send({ event: 'ack', action: 'whisper' });
}

module.exports = { chat, whisper };
