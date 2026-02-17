/**
 * Mineflayer Bridge - communicates with Elixir via JSON over stdin/stdout.
 *
 * Protocol:
 *   Each message is a JSON object on a single line (newline-delimited JSON).
 *   Input (from Elixir):  { "action": "chat", "message": "hello" }
 *   Output (to Elixir):   { "event": "chat", "username": "Steve", "message": "hi" }
 *
 * Modules:
 *   utils.js        — send(), log(), withTimeout(), validCoords()
 *   action_queue.js — command queueing, sync/async routing, goal_reached helpers
 *   events.js       — mineflayer event → Elixir JSON bindings
 *   commands/        — command handlers by domain (chat, movement, combat, info, world, inventory)
 */

const mineflayer = require('mineflayer');
const readline = require('readline');

const { send, log } = require('./utils');
const { processCommand, actionDone, clearQueue, cleanupAllGoals, SYNC_ACTIONS } = require('./action_queue');
const { bindEvents } = require('./events');
const { cleanupMovement, setDigAreaCancelled } = require('./commands/movement');

// Command handlers
const chatCmds = require('./commands/chat');
const moveCmds = require('./commands/movement');
const combatCmds = require('./commands/combat');
const infoCmds = require('./commands/info');
const worldCmds = require('./commands/world');
const invCmds = require('./commands/inventory');

// Config from environment or argv
const host = process.env.MC_HOST || process.argv[2] || 'localhost';
const port = parseInt(process.env.MC_PORT || process.argv[3] || '25565');
const username = process.env.BOT_USERNAME || process.argv[4] || 'McFunBot';

// --- Reconnection state ---
let bot = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 10;
const MAX_BACKOFF_MS = 30000;
let reconnecting = false;

// --- Command dispatch ---

// Wrap actionDone to pass executeCommand for queue advancement
function done() {
  actionDone(executeCommand);
}

function executeCommand(cmd) {
  switch (cmd.action) {
    // Chat
    case 'chat':           chatCmds.chat(bot, cmd); break;
    case 'whisper':        chatCmds.whisper(bot, cmd); break;

    // Movement
    case 'move':           moveCmds.move(bot, cmd, done); break;
    case 'goto':           moveCmds.goto(bot, cmd, done); break;
    case 'follow':         moveCmds.follow(bot, cmd); break;
    case 'look':           moveCmds.look(bot, cmd); break;
    case 'jump':           moveCmds.jump(bot); break;
    case 'sneak':          moveCmds.sneak(bot, cmd); break;
    case 'stop':           moveCmds.stop(bot); break;

    // Combat
    case 'attack':         combatCmds.attack(bot, cmd, done); break;

    // Info (sync — no done() needed)
    case 'inventory':      infoCmds.inventory(bot); break;
    case 'position':       infoCmds.position(bot); break;
    case 'players':        infoCmds.players(bot); break;
    case 'status':         infoCmds.status(bot); break;
    case 'survey':         infoCmds.survey(bot, cmd); break;

    // World interaction
    case 'dig':            worldCmds.dig(bot, cmd, done); break;
    case 'dig_looking_at': worldCmds.digLookingAt(bot, cmd, done); break;
    case 'dig_area':       worldCmds.digArea(bot, cmd, done); break;
    case 'find_and_dig':   worldCmds.findAndDig(bot, cmd, done); break;
    case 'place':          worldCmds.place(bot, cmd, done); break;
    case 'activate_block': worldCmds.activateBlock(bot, cmd, done); break;

    // Inventory management
    case 'equip':          invCmds.equip(bot, cmd, done); break;
    case 'craft':          invCmds.craft(bot, cmd, done); break;
    case 'drop':           invCmds.drop(bot, cmd, done); break;
    case 'drop_item':      invCmds.dropItem(bot, cmd, done); break;
    case 'drop_all':       invCmds.dropAll(bot, cmd, done); break;
    case 'use_item':       invCmds.useItem(bot, cmd, done); break;
    case 'deactivate_item': invCmds.deactivateItem(bot, cmd, done); break;
    case 'sleep':          invCmds.sleep(bot, cmd, done); break;
    case 'wake':           invCmds.wake(bot, cmd, done); break;

    // Quit
    case 'quit':
      bot.quit();
      process.exit(0);
      break;

    default:
      send({ event: 'error', message: `Unknown action: ${cmd.action}` });
      if (!SYNC_ACTIONS.has(cmd.action)) done();
  }
}

// --- Bot lifecycle ---

function cleanupOnDisconnect() {
  cleanupAllGoals();
  clearQueue();
  setDigAreaCancelled(true);
  cleanupMovement();
}

function scheduleReconnect(reason) {
  if (reconnecting) return;
  reconnecting = true;
  reconnectAttempts++;

  if (reconnectAttempts > MAX_RECONNECT_ATTEMPTS) {
    log(`Max reconnect attempts (${MAX_RECONNECT_ATTEMPTS}) reached, exiting`);
    send({ event: 'error', message: `Failed to reconnect after ${MAX_RECONNECT_ATTEMPTS} attempts` });
    process.exit(1);
  }

  const backoffMs = Math.min(1000 * Math.pow(2, reconnectAttempts - 1), MAX_BACKOFF_MS);
  log(`Reconnecting in ${backoffMs}ms (attempt ${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`);
  send({ event: 'reconnecting', attempt: reconnectAttempts, backoff_ms: backoffMs });

  setTimeout(() => {
    log(`Attempting reconnect (attempt ${reconnectAttempts})`);
    try {
      createBot();
    } catch (err) {
      log(`Reconnect failed: ${err.message}`);
      reconnecting = false;
      scheduleReconnect('reconnect_failed');
    }
  }, backoffMs);
}

function createBot() {
  bot = mineflayer.createBot({
    host,
    port,
    username,
    auth: 'offline',
    hideErrors: false,
  });

  bot.on('spawn', () => {
    reconnectAttempts = 0;
    reconnecting = false;
  });

  bindEvents(bot, cleanupOnDisconnect, scheduleReconnect);
}

// --- stdin command handling ---

const rl = readline.createInterface({ input: process.stdin });

rl.on('line', (line) => {
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch (e) {
    send({ event: 'error', message: `Invalid JSON: ${line}` });
    return;
  }

  if (!bot) {
    send({ event: 'error', message: 'Bot not connected yet' });
    return;
  }

  processCommand(cmd, executeCommand);
});

rl.on('close', () => {
  log('stdin closed, shutting down');
  try { if (bot) bot.quit(); } catch (_) {}
  process.exit(0);
});

// --- Bootstrap ---

log(`Connecting as ${username} to ${host}:${port}`);
createBot();
