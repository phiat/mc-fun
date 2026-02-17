/**
 * Command queue for async bot actions.
 *
 * Sync actions (chat, whisper, etc.) execute immediately.
 * Async actions (goto, dig, etc.) are queued so only one runs at a time.
 */

const { send, log } = require('./utils');

const SYNC_ACTIONS = new Set([
  'chat', 'whisper', 'position', 'inventory', 'players',
  'look', 'jump', 'sneak', 'status', 'survey', 'stop', 'quit'
]);

let actionBusy = false;
const actionQueue = [];
let activeCleanups = []; // cleanup functions for pending goal_reached listeners

function processCommand(cmd, executeCommand) {
  if (SYNC_ACTIONS.has(cmd.action)) {
    executeCommand(cmd);
  } else if (actionBusy) {
    actionQueue.push(cmd);
    send({ event: 'queued', action: cmd.action, queue_length: actionQueue.length });
  } else {
    actionBusy = true;
    executeCommand(cmd);
  }
}

function actionDone(executeCommand) {
  actionBusy = false;
  if (actionQueue.length > 0) {
    const next = actionQueue.shift();
    actionBusy = true;
    executeCommand(next);
  }
}

function clearQueue() {
  actionQueue.length = 0;
  actionBusy = false;
}

function getQueueLength() {
  return actionQueue.length;
}

function isActionBusy() {
  return actionBusy;
}

/**
 * Listen for goal_reached with timeout and cleanup tracking.
 */
function onGoalReached(bot, callback, timeoutMs = 30000, onTimeout) {
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
      if (onTimeout) onTimeout();
    }
  }, timeoutMs);

  activeCleanups.push(cleanup);
  return cleanup;
}

function cleanupAllGoals() {
  for (const cleanup of [...activeCleanups]) {
    cleanup();
  }
  activeCleanups = [];
}

module.exports = {
  SYNC_ACTIONS,
  processCommand,
  actionDone,
  clearQueue,
  getQueueLength,
  isActionBusy,
  onGoalReached,
  cleanupAllGoals,
};
