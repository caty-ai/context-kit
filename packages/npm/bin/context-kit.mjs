#!/usr/bin/env node

import { constants as fsConstants } from 'node:fs';
import {
  access,
  chmod,
  copyFile,
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  rename,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PACKAGE_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const PIECE_ORDER = [
  'lg',
  'scratch-persist',
  'brief-validator',
  'safety-hooks',
  'recall',
  'wt-snapshot',
];

const PIECES = {
  lg: {
    files: ['bin/lg', 'hooks/lg-enforcer.py'],
    hooks: [
      {
        event: 'PreToolUse',
        matcher: 'Bash',
        command:
          'sh -c \'f="<CONTEXT_KIT_DIR>/hooks/lg-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 "$f"; fi\'',
      },
    ],
  },
  'scratch-persist': {
    files: ['hooks/scratch-persist.sh', 'hooks/scratch-persist.py'],
    hooks: [
      {
        event: 'PostToolUse',
        command:
          'sh -c \'f="<CONTEXT_KIT_DIR>/hooks/scratch-persist.sh"; if [ -f "$f" ]; then bash "$f"; fi\'',
      },
    ],
  },
  'brief-validator': {
    files: ['hooks/validate-subagent-brief.sh', 'hooks/validate-subagent-brief.py'],
    hooks: [
      {
        event: 'PreToolUse',
        matcher: 'Agent|Task',
        command:
          'sh -c \'f="<CONTEXT_KIT_DIR>/hooks/validate-subagent-brief.sh"; if [ -f "$f" ]; then bash "$f"; fi\'',
      },
    ],
  },
  'safety-hooks': {
    files: [
      'hooks/rm-enforcer.py',
      'hooks/private-repo-enforcer.mjs',
      'hooks/api-key-leak-detector.mjs',
    ],
    hooks: [
      {
        event: 'PreToolUse',
        matcher: 'Bash',
        command:
          'sh -c \'f="<CONTEXT_KIT_DIR>/hooks/rm-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 -B "$f"; fi\'',
      },
      {
        event: 'PreToolUse',
        matcher: 'Bash',
        command:
          'sh -c \'f="<CONTEXT_KIT_DIR>/hooks/private-repo-enforcer.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi\'',
      },
      {
        event: 'PreToolUse',
        matcher: 'Bash|Write|Edit',
        command:
          'sh -c \'f="<CONTEXT_KIT_DIR>/hooks/api-key-leak-detector.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi\'',
      },
    ],
  },
  recall: {
    files: ['bin/recall'],
    hooks: [],
  },
  'wt-snapshot': {
    files: ['bin/wt-snapshot'],
    hooks: [],
  },
};

const USAGE = `Usage:
  context-kit install [pieces...] [--all] [--apply]
  context-kit --help

Pieces:
  lg                 Large-output wrapper and enforcement hook
  scratch-persist    Persist oversized tool output for later recall
  brief-validator    Validate structured subagent briefs
  safety-hooks       Destructive-command, repo, and API-key guards
  recall             Search local context and configured memory layers
  wt-snapshot        Capture a compact git worktree snapshot

Options:
  --all              Select all six pieces
  --apply            Write files and merge settings (default: dry-run)
  --settings <path>  Override settings.json (default: $HOME/.claude/settings.json)
  --prefix <dir>     Override install root (default: $HOME/.claude/context-kit)
  -h, --help         Show this help

With no pieces, an interactive terminal shows a numbered multi-select. Dry-run
never creates directories, copies files, writes settings, or creates backups.`;

class CliError extends Error {}

function hookEntry(definition, installRoot) {
  const entry = {
    hooks: [
      {
        type: 'command',
        command: definition.command.replaceAll('<CONTEXT_KIT_DIR>', installRoot),
      },
    ],
  };
  if (definition.matcher !== undefined) {
    entry.matcher = definition.matcher;
    return { matcher: entry.matcher, hooks: entry.hooks };
  }
  return entry;
}

function parseArguments(argv) {
  if (argv.length === 0) {
    throw new CliError('Missing subcommand.');
  }
  if (argv[0] === '--help' || argv[0] === '-h') {
    return { help: true };
  }
  if (argv[0] !== 'install') {
    throw new CliError(`Unknown subcommand: ${argv[0]}`);
  }

  const result = {
    help: false,
    apply: false,
    all: false,
    pieces: [],
    settings: undefined,
    prefix: undefined,
  };

  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h') {
      result.help = true;
    } else if (argument === '--apply') {
      result.apply = true;
    } else if (argument === '--all') {
      result.all = true;
    } else if (argument === '--settings' || argument === '--prefix') {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith('--')) {
        throw new CliError(`${argument} requires a path.`);
      }
      if (argument === '--settings') {
        result.settings = value;
      } else {
        result.prefix = value;
      }
      index += 1;
    } else if (argument.startsWith('-')) {
      throw new CliError(`Unknown option: ${argument}`);
    } else if (PIECES[argument] === undefined) {
      throw new CliError(`Unknown piece: ${argument}`);
    } else {
      result.pieces.push(argument);
    }
  }

  return result;
}

async function selectInteractively() {
  const readline = createInterface({ input: process.stdin, output: process.stdout });
  try {
    console.log('Select pieces (comma-separated numbers, or a for all):');
    PIECE_ORDER.forEach((piece, index) => console.log(`  ${index + 1}. ${piece}`));
    const answer = (await readline.question('Selection: ')).trim().toLowerCase();
    if (answer === 'a') {
      return [...PIECE_ORDER];
    }
    if (answer === '') {
      throw new CliError('No pieces selected.');
    }
    const selected = [];
    for (const token of answer.split(',').map((value) => value.trim())) {
      if (!/^\d+$/.test(token)) {
        throw new CliError(`Invalid selection: ${token}`);
      }
      const piece = PIECE_ORDER[Number(token) - 1];
      if (piece === undefined) {
        throw new CliError(`Selection out of range: ${token}`);
      }
      if (!selected.includes(piece)) {
        selected.push(piece);
      }
    }
    return selected;
  } finally {
    readline.close();
  }
}

async function isDirectory(directory) {
  try {
    return (await stat(directory)).isDirectory();
  } catch (error) {
    if (error.code === 'ENOENT') {
      return false;
    }
    throw error;
  }
}

async function resolvePayloadRoot() {
  const packaged = path.join(PACKAGE_ROOT, 'kit');
  const checkout = path.resolve(PACKAGE_ROOT, '..', '..');
  for (const candidate of [packaged, checkout]) {
    if (
      (await isDirectory(path.join(candidate, 'bin'))) &&
      (await isDirectory(path.join(candidate, 'hooks')))
    ) {
      return candidate;
    }
  }
  throw new CliError(
    `Payload not found. Expected ${path.join(packaged, 'bin')} and ${path.join(packaged, 'hooks')}, ` +
      `or checkout payload under ${checkout}.`,
  );
}

async function filesEqual(first, second) {
  try {
    const [left, right] = await Promise.all([readFile(first), readFile(second)]);
    return left.equals(right);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return false;
    }
    throw error;
  }
}

async function planFiles(payloadRoot, installRoot, selectedPieces) {
  const relativeFiles = [];
  for (const piece of PIECE_ORDER) {
    if (!selectedPieces.includes(piece)) {
      continue;
    }
    for (const relativeFile of PIECES[piece].files) {
      if (!relativeFiles.includes(relativeFile)) {
        relativeFiles.push(relativeFile);
      }
    }
  }

  const plans = [];
  for (const relativeFile of relativeFiles) {
    const source = path.join(payloadRoot, relativeFile);
    const destination = path.join(installRoot, relativeFile);
    try {
      await access(source, fsConstants.R_OK);
    } catch {
      throw new CliError(`Payload file is missing or unreadable: ${source}`);
    }
    let destinationExists = true;
    try {
      await access(destination, fsConstants.F_OK);
    } catch (error) {
      if (error.code === 'ENOENT') {
        destinationExists = false;
      } else {
        throw error;
      }
    }
    const same = destinationExists && (await filesEqual(source, destination));
    plans.push({
      source,
      destination,
      status: same ? 'up to date' : destinationExists ? 'update' : 'new',
    });
  }
  return plans;
}

function skipWhitespace(text, start) {
  let index = start;
  while (index < text.length && /\s/.test(text[index])) {
    index += 1;
  }
  return index;
}

function scanStringEnd(text, start) {
  if (text[start] !== '"') {
    throw new CliError(`Internal settings scanner error at byte ${start}: expected a string.`);
  }
  let index = start + 1;
  while (index < text.length) {
    if (text[index] === '\\') {
      index += 2;
    } else if (text[index] === '"') {
      return index + 1;
    } else {
      index += 1;
    }
  }
  throw new CliError('Internal settings scanner error: unterminated string.');
}

function scanCompositeEnd(text, start) {
  const opening = text[start];
  if (opening !== '{' && opening !== '[') {
    throw new CliError(`Internal settings scanner error at byte ${start}: expected a container.`);
  }
  const stack = [opening];
  let index = start + 1;
  while (index < text.length) {
    const character = text[index];
    if (character === '"') {
      index = scanStringEnd(text, index);
      continue;
    }
    if (character === '{' || character === '[') {
      stack.push(character);
    } else if (character === '}' || character === ']') {
      const expected = character === '}' ? '{' : '[';
      if (stack.pop() !== expected) {
        throw new CliError(`Internal settings scanner error at byte ${index}: mismatched container.`);
      }
      if (stack.length === 0) {
        return index + 1;
      }
    }
    index += 1;
  }
  throw new CliError('Internal settings scanner error: unterminated container.');
}

function scanValueEnd(text, start) {
  const index = skipWhitespace(text, start);
  const character = text[index];
  if (character === '"') {
    return scanStringEnd(text, index);
  }
  if (character === '{' || character === '[') {
    return scanCompositeEnd(text, index);
  }
  let end = index;
  while (end < text.length && !/[\s,}\]]/.test(text[end])) {
    end += 1;
  }
  if (end === index) {
    throw new CliError(`Internal settings scanner error at byte ${index}: expected a value.`);
  }
  return end;
}

function scanObject(text, openIndex) {
  if (text[openIndex] !== '{') {
    throw new CliError(`Internal settings scanner error at byte ${openIndex}: expected an object.`);
  }
  const closeIndex = scanCompositeEnd(text, openIndex) - 1;
  const members = [];
  let index = skipWhitespace(text, openIndex + 1);
  while (index < closeIndex) {
    const keyStart = index;
    const keyEnd = scanStringEnd(text, keyStart);
    const key = JSON.parse(text.slice(keyStart, keyEnd));
    index = skipWhitespace(text, keyEnd);
    if (text[index] !== ':') {
      throw new CliError(`Internal settings scanner error at byte ${index}: expected a colon.`);
    }
    const valueStart = skipWhitespace(text, index + 1);
    const valueEnd = scanValueEnd(text, valueStart);
    members.push({ key, keyStart, keyEnd, valueStart, valueEnd });
    index = skipWhitespace(text, valueEnd);
    if (index === closeIndex) {
      break;
    }
    if (text[index] !== ',') {
      throw new CliError(`Internal settings scanner error at byte ${index}: expected a comma.`);
    }
    index = skipWhitespace(text, index + 1);
  }
  return { openIndex, closeIndex, members };
}

function scanArray(text, openIndex) {
  if (text[openIndex] !== '[') {
    throw new CliError(`Internal settings scanner error at byte ${openIndex}: expected an array.`);
  }
  const closeIndex = scanCompositeEnd(text, openIndex) - 1;
  const values = [];
  let index = skipWhitespace(text, openIndex + 1);
  while (index < closeIndex) {
    const valueStart = index;
    const valueEnd = scanValueEnd(text, valueStart);
    values.push({ valueStart, valueEnd });
    index = skipWhitespace(text, valueEnd);
    if (index === closeIndex) {
      break;
    }
    if (text[index] !== ',') {
      throw new CliError(`Internal settings scanner error at byte ${index}: expected a comma.`);
    }
    index = skipWhitespace(text, index + 1);
  }
  return { openIndex, closeIndex, values };
}

function findUniqueMember(object, key, label) {
  const matches = object.members.filter((member) => member.key === key);
  if (matches.length > 1) {
    throw new CliError(`Cannot safely merge settings: duplicate ${label} keys.`);
  }
  return matches[0];
}

function detectFormatting(text) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const candidates = [];
  const expression = /\r?\n([ \t]+)"/g;
  for (const match of text.matchAll(expression)) {
    candidates.push(match[1]);
  }
  candidates.sort((left, right) => left.length - right.length);
  return { eol, indent: candidates[0] || '  ' };
}

function indentBlock(value, baseIndent, indent, eol) {
  return JSON.stringify(value, null, indent).replaceAll('\n', `${eol}${baseIndent}`);
}

function insertIntoObject(text, object, property, memberIndent, closeIndent, eol) {
  if (object.members.length === 0) {
    const insertion = `${eol}${memberIndent}${property}${eol}${closeIndent}`;
    return text.slice(0, object.openIndex + 1) + insertion + text.slice(object.closeIndex);
  }

  const lastMember = object.members[object.members.length - 1];
  const trailing = text.slice(lastMember.valueEnd, object.closeIndex);
  let insertion = `,${eol}${memberIndent}${property}`;
  if (!trailing.includes('\n')) {
    insertion += `${eol}${closeIndent}`;
  }
  return text.slice(0, lastMember.valueEnd) + insertion + text.slice(lastMember.valueEnd);
}

function appendToArray(text, array, entries, entryIndent, closeIndent, indent, eol) {
  const blocks = entries.map((entry) => indentBlock(entry, entryIndent, indent, eol));
  if (array.values.length === 0) {
    const insertion = `${eol}${entryIndent}${blocks.join(
      `,${eol}${entryIndent}`,
    )}${eol}${closeIndent}`;
    return text.slice(0, array.openIndex + 1) + insertion + text.slice(array.closeIndex);
  }

  const lastValue = array.values[array.values.length - 1];
  const trailing = text.slice(lastValue.valueEnd, array.closeIndex);
  let insertion = `,${eol}${entryIndent}${blocks.join(`,${eol}${entryIndent}`)}`;
  if (!trailing.includes('\n')) {
    insertion += `${eol}${closeIndent}`;
  }
  return text.slice(0, lastValue.valueEnd) + insertion + text.slice(lastValue.valueEnd);
}

function commandSet(eventEntries) {
  const commands = new Set();
  if (!Array.isArray(eventEntries)) {
    return commands;
  }
  for (const entry of eventEntries) {
    if (!entry || typeof entry !== 'object' || !Array.isArray(entry.hooks)) {
      continue;
    }
    for (const hook of entry.hooks) {
      if (hook && typeof hook === 'object' && typeof hook.command === 'string') {
        commands.add(hook.command);
      }
    }
  }
  return commands;
}

function parseSettings(text, settingsPath) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new CliError(
      `Cannot merge ${settingsPath}: invalid JSON (JSONC comments are not supported): ${error.message}`,
    );
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new CliError(`Cannot merge ${settingsPath}: the top-level JSON value must be an object.`);
  }
  if (
    Object.hasOwn(parsed, 'hooks') &&
    (!parsed.hooks || typeof parsed.hooks !== 'object' || Array.isArray(parsed.hooks))
  ) {
    throw new CliError(`Cannot merge ${settingsPath}: "hooks" must be an object.`);
  }
  return parsed;
}

function buildPendingEntries(parsed, additionsByEvent, settingsPath) {
  const pending = new Map();
  let skipped = 0;
  for (const [event, requested] of additionsByEvent) {
    const existing = parsed.hooks?.[event];
    if (existing !== undefined && !Array.isArray(existing)) {
      throw new CliError(`Cannot merge ${settingsPath}: "hooks.${event}" must be an array.`);
    }
    const commands = commandSet(existing);
    const eventPending = [];
    for (const entry of requested) {
      const command = entry.hooks[0].command;
      if (commands.has(command)) {
        skipped += 1;
      } else {
        eventPending.push(entry);
        commands.add(command);
      }
    }
    if (eventPending.length > 0) {
      pending.set(event, eventPending);
    }
  }
  return { pending, skipped };
}

function insertHooksMember(text, root, pending, indent, eol) {
  const rootMemberIndent = indent;
  const eventIndent = indent + indent;
  const entryIndent = eventIndent + indent;
  const eventProperties = [];
  for (const [event, entries] of pending) {
    const blocks = entries.map((entry) => indentBlock(entry, entryIndent, indent, eol));
    eventProperties.push(
      `${JSON.stringify(event)}: [${eol}${entryIndent}${blocks.join(
        `,${eol}${entryIndent}`,
      )}${eol}${eventIndent}]`,
    );
  }
  const hooksProperty = `${JSON.stringify('hooks')}: {${eol}${eventIndent}${eventProperties.join(
    `,${eol}${eventIndent}`,
  )}${eol}${rootMemberIndent}}`;
  return insertIntoObject(text, root, hooksProperty, rootMemberIndent, '', eol);
}

function mergeSettingsText(originalText, before, additionsByEvent, settingsPath) {
  const { pending, skipped } = buildPendingEntries(before, additionsByEvent, settingsPath);
  const added = [...pending.values()].reduce((total, entries) => total + entries.length, 0);
  if (added === 0) {
    return { text: originalText, added, skipped, newEntries: pending };
  }

  const { eol, indent } = detectFormatting(originalText);
  const rootStart = skipWhitespace(originalText, 0);
  let text = originalText;
  let root = scanObject(text, rootStart);
  let hooksMember = findUniqueMember(root, 'hooks', 'top-level "hooks"');

  if (hooksMember === undefined) {
    text = insertHooksMember(text, root, pending, indent, eol);
    return { text, added, skipped, newEntries: pending };
  }

  for (const [event, entries] of pending) {
    root = scanObject(text, skipWhitespace(text, 0));
    hooksMember = findUniqueMember(root, 'hooks', 'top-level "hooks"');
    if (text[hooksMember.valueStart] !== '{') {
      throw new CliError(`Cannot merge ${settingsPath}: "hooks" must be an object.`);
    }
    const hooksObject = scanObject(text, hooksMember.valueStart);
    const eventMember = findUniqueMember(hooksObject, event, `"hooks.${event}"`);
    const eventIndent = indent + indent;
    const entryIndent = eventIndent + indent;

    if (eventMember === undefined) {
      const blocks = entries.map((entry) => indentBlock(entry, entryIndent, indent, eol));
      const property = `${JSON.stringify(event)}: [${eol}${entryIndent}${blocks.join(
        `,${eol}${entryIndent}`,
      )}${eol}${eventIndent}]`;
      text = insertIntoObject(
        text,
        hooksObject,
        property,
        eventIndent,
        indent,
        eol,
      );
    } else {
      if (text[eventMember.valueStart] !== '[') {
        throw new CliError(`Cannot merge ${settingsPath}: "hooks.${event}" must be an array.`);
      }
      const eventArray = scanArray(text, eventMember.valueStart);
      text = appendToArray(text, eventArray, entries, entryIndent, eventIndent, indent, eol);
    }
  }

  return { text, added, skipped, newEntries: pending };
}

function newSettingsText(additionsByEvent) {
  const hooks = {};
  for (const [event, entries] of additionsByEvent) {
    hooks[event] = entries;
  }
  return `${JSON.stringify({ hooks }, null, 2)}\n`;
}

async function resolveSettingsLocation(settingsPath) {
  let stats;
  try {
    stats = await lstat(settingsPath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return { displayPath: settingsPath, resolvedPath: settingsPath };
    }
    throw error;
  }

  if (!stats.isSymbolicLink()) {
    return { displayPath: settingsPath, resolvedPath: settingsPath };
  }

  try {
    return { displayPath: settingsPath, resolvedPath: await realpath(settingsPath) };
  } catch (error) {
    if (error.code === 'ENOENT') {
      throw new CliError(
        `Cannot merge ${settingsPath}: settings.json is a dangling symlink. Fix or remove the dangling link before installing.`,
      );
    }
    throw error;
  }
}

async function planSettings(settingsPath, additionsByEvent, displayPath = settingsPath) {
  if (additionsByEvent.size === 0) {
    return {
      exists: false,
      originalText: '',
      before: {},
      nextText: '',
      changed: false,
      added: 0,
      displayPath,
      skipped: 0,
      newEntries: new Map(),
    };
  }

  let originalBuffer;
  try {
    originalBuffer = await readFile(settingsPath);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }

  if (originalBuffer === undefined) {
    const nextText = newSettingsText(additionsByEvent);
    return {
      exists: false,
      originalText: '',
      before: {},
      nextText,
      changed: true,
      added: [...additionsByEvent.values()].reduce((sum, entries) => sum + entries.length, 0),
      displayPath,
      skipped: 0,
      newEntries: additionsByEvent,
    };
  }

  const originalText = originalBuffer.toString('utf8');
  if (!Buffer.from(originalText, 'utf8').equals(originalBuffer)) {
    throw new CliError(`Cannot merge ${displayPath}: file is not valid UTF-8.`);
  }
  const before = parseSettings(originalText, displayPath);
  const merged = mergeSettingsText(originalText, before, additionsByEvent, displayPath);
  parseSettings(merged.text, displayPath);
  return {
    exists: true,
    originalText,
    before,
    nextText: merged.text,
    changed: merged.text !== originalText,
    added: merged.added,
    displayPath,
    skipped: merged.skipped,
    newEntries: merged.newEntries,
  };
}

function splitDiffLines(text) {
  if (text === '') {
    return [];
  }
  const normalized = text.replaceAll('\r\n', '\n');
  return normalized.endsWith('\n')
    ? normalized.slice(0, -1).split('\n')
    : normalized.split('\n');
}

function unifiedDiff(before, after, label) {
  if (before === after) {
    return '';
  }
  const left = splitDiffLines(before);
  const right = splitDiffLines(after);
  const table = Array.from({ length: left.length + 1 }, () =>
    Array(right.length + 1).fill(0),
  );
  for (let leftIndex = left.length - 1; leftIndex >= 0; leftIndex -= 1) {
    for (let rightIndex = right.length - 1; rightIndex >= 0; rightIndex -= 1) {
      table[leftIndex][rightIndex] =
        left[leftIndex] === right[rightIndex]
          ? table[leftIndex + 1][rightIndex + 1] + 1
          : Math.max(table[leftIndex + 1][rightIndex], table[leftIndex][rightIndex + 1]);
    }
  }

  const output = [`--- ${label}`, `+++ ${label}`, `@@ -1,${left.length} +1,${right.length} @@`];
  let leftIndex = 0;
  let rightIndex = 0;
  while (leftIndex < left.length && rightIndex < right.length) {
    if (left[leftIndex] === right[rightIndex]) {
      output.push(` ${left[leftIndex]}`);
      leftIndex += 1;
      rightIndex += 1;
    } else if (table[leftIndex + 1][rightIndex] >= table[leftIndex][rightIndex + 1]) {
      output.push(`-${left[leftIndex]}`);
      leftIndex += 1;
    } else {
      output.push(`+${right[rightIndex]}`);
      rightIndex += 1;
    }
  }
  while (leftIndex < left.length) {
    output.push(`-${left[leftIndex]}`);
    leftIndex += 1;
  }
  while (rightIndex < right.length) {
    output.push(`+${right[rightIndex]}`);
    rightIndex += 1;
  }
  return output.join('\n');
}

function verifySettings(before, after, newEntries) {
  for (const [key, value] of Object.entries(before)) {
    if (key !== 'hooks' && !isDeepStrictEqual(after[key], value)) {
      throw new Error(`pre-existing top-level member ${JSON.stringify(key)} changed`);
    }
  }

  if (before.hooks !== undefined) {
    if (!after.hooks || typeof after.hooks !== 'object' || Array.isArray(after.hooks)) {
      throw new Error('pre-existing hooks object is missing');
    }
    for (const [event, value] of Object.entries(before.hooks)) {
      if (!newEntries.has(event)) {
        if (!isDeepStrictEqual(after.hooks[event], value)) {
          throw new Error(`pre-existing hooks.${event} value changed`);
        }
        continue;
      }
      if (!Array.isArray(value) || !Array.isArray(after.hooks[event])) {
        throw new Error(`hooks.${event} is no longer an array`);
      }
      if (after.hooks[event].length < value.length) {
        throw new Error(`pre-existing hooks.${event} entries were removed`);
      }
      for (let index = 0; index < value.length; index += 1) {
        if (!isDeepStrictEqual(after.hooks[event][index], value[index])) {
          throw new Error(`pre-existing hooks.${event}[${index}] changed`);
        }
      }
    }
  }

  for (const [event, entries] of newEntries) {
    const installedCommands = commandSet(after.hooks?.[event]);
    for (const entry of entries) {
      const command = entry.hooks[0].command;
      if (!installedCommands.has(command)) {
        throw new Error(`new hooks.${event} command is missing`);
      }
    }
  }
}

function backupTimestamp(date = new Date()) {
  const part = (value) => String(value).padStart(2, '0');
  return (
    `${date.getFullYear()}${part(date.getMonth() + 1)}${part(date.getDate())}-` +
    `${part(date.getHours())}${part(date.getMinutes())}${part(date.getSeconds())}`
  );
}

async function createBackup(settingsPath, originalText) {
  const base = `${settingsPath}.ck-backup-${backupTimestamp()}`;
  for (let suffix = 0; ; suffix += 1) {
    const backupPath = suffix === 0 ? base : `${base}-${suffix}`;
    try {
      await writeFile(backupPath, originalText, { encoding: 'utf8', flag: 'wx', mode: 0o600 });
      return backupPath;
    } catch (error) {
      if (error.code !== 'EEXIST') {
        throw error;
      }
    }
  }
}

async function atomicWrite(settingsPath, text, mode) {
  const tempPath = path.join(
    path.dirname(settingsPath),
    `.${path.basename(settingsPath)}.ck-tmp-${process.pid}-${Date.now()}-${Math.random()
      .toString(16)
      .slice(2)}`,
  );
  let handle;
  try {
    handle = await open(tempPath, 'wx', mode);
    await handle.writeFile(text, 'utf8');
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(tempPath, settingsPath);
  } catch (error) {
    if (handle !== undefined) {
      await handle.close().catch(() => {});
    }
    await unlink(tempPath).catch(() => {});
    throw error;
  }
}

async function restoreOriginal(settingsPath, plan, backupPath, mode) {
  if (!plan.exists) {
    await unlink(settingsPath).catch((error) => {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    });
    return;
  }
  if (backupPath === undefined) {
    throw new Error('no backup available for restore');
  }
  const backupText = await readFile(backupPath, 'utf8');
  await atomicWrite(settingsPath, backupText, mode);
}

async function writeSettings(settingsPath, plan) {
  if (!plan.changed) {
    return undefined;
  }
  await mkdir(path.dirname(settingsPath), { recursive: true, mode: 0o755 });
  let mode = 0o600;
  if (plan.exists) {
    mode = (await stat(settingsPath)).mode & 0o777;
  }
  const backupPath = plan.exists
    ? await createBackup(settingsPath, plan.originalText)
    : undefined;
  let renamed = false;
  try {
    await atomicWrite(settingsPath, plan.nextText, mode);
    renamed = true;
    const written = await readFile(settingsPath, 'utf8');
    const parsed = parseSettings(written, settingsPath);
    verifySettings(plan.before, parsed, plan.newEntries);
    return backupPath;
  } catch (error) {
    if (renamed) {
      try {
        await restoreOriginal(settingsPath, plan, backupPath, mode);
      } catch (restoreError) {
        throw new CliError(
          `Settings verification failed (${error.message}) and restore failed (${restoreError.message}). ` +
            `Backup retained at ${backupPath}.`,
        );
      }
    }
    throw new CliError(
      `Settings write failed${renamed ? ' verification; original restored' : ''}: ${error.message}.` +
        `${backupPath === undefined ? '' : ` Backup retained at ${backupPath}.`}`,
    );
  }
}

async function applyFiles(plans, installRoot) {
  let copied = 0;
  let upToDate = 0;
  if (!(await isDirectory(installRoot))) {
    await mkdir(installRoot, { recursive: true, mode: 0o755 });
    await chmod(installRoot, 0o755);
  }
  for (const plan of plans) {
    if (plan.status === 'up to date') {
      upToDate += 1;
      continue;
    }
    const destinationDirectory = path.dirname(plan.destination);
    if (!(await isDirectory(destinationDirectory))) {
      await mkdir(destinationDirectory, { recursive: true, mode: 0o755 });
      await chmod(destinationDirectory, 0o755);
    }
    const sourceMode = (await stat(plan.source)).mode & 0o777;
    await copyFile(plan.source, plan.destination);
    await chmod(plan.destination, sourceMode);
    copied += 1;
  }
  return { copied, upToDate };
}

function shellQuote(value) {
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(value)) {
    return value;
  }
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

function applyCommand(selectedPieces, options) {
  const argumentsList = ['npx', '@caty-ai/context-kit', 'install'];
  if (options.all) {
    argumentsList.push('--all');
  } else {
    argumentsList.push(...selectedPieces);
  }
  argumentsList.push('--apply');
  if (options.settings !== undefined) {
    argumentsList.push('--settings', path.resolve(options.settings));
  }
  if (options.prefix !== undefined) {
    argumentsList.push('--prefix', path.resolve(options.prefix));
  }
  return argumentsList.map(shellQuote).join(' ');
}

function additionsFor(selectedPieces, installRoot) {
  const additions = new Map();
  for (const piece of PIECE_ORDER) {
    if (!selectedPieces.includes(piece)) {
      continue;
    }
    for (const definition of PIECES[piece].hooks) {
      if (!additions.has(definition.event)) {
        additions.set(definition.event, []);
      }
      additions.get(definition.event).push(hookEntry(definition, installRoot));
    }
  }
  return additions;
}

function wantsPathHint(selectedPieces) {
  return selectedPieces.some((piece) => ['lg', 'recall', 'wt-snapshot'].includes(piece));
}

function validateInstallRoot(installRoot) {
  if (/["$`\\\r\n]/.test(installRoot)) {
    throw new CliError(
      `Cannot install to ${installRoot}: install roots embedded in hook commands cannot contain ", $, \`, \\, or newlines.`,
    );
  }
}

function pathHint(installRoot) {
  const defaultRoot = path.resolve(path.join(homedir(), '.claude', 'context-kit'));
  if (installRoot === defaultRoot) {
    return '$HOME/.claude/context-kit/bin';
  }
  return path.join(installRoot, 'bin');
}

async function install(options) {
  let selectedPieces = options.all
    ? [...PIECE_ORDER]
    : PIECE_ORDER.filter((piece) => options.pieces.includes(piece));
  if (selectedPieces.length === 0) {
    if (!process.stdin.isTTY) {
      throw new CliError('No pieces selected and stdin is not an interactive terminal.');
    }
    selectedPieces = await selectInteractively();
  }

  const installRoot = path.resolve(options.prefix || path.join(homedir(), '.claude', 'context-kit'));
  validateInstallRoot(installRoot);
  const settingsPath = path.resolve(options.settings || path.join(homedir(), '.claude', 'settings.json'));
  const settingsLocation = await resolveSettingsLocation(settingsPath);
  const payloadRoot = await resolvePayloadRoot();
  const filePlans = await planFiles(payloadRoot, installRoot, selectedPieces);
  const additions = additionsFor(selectedPieces, installRoot);
  const settingsPlan = await planSettings(
    settingsLocation.resolvedPath,
    additions,
    settingsLocation.displayPath,
  );

  if (!options.apply) {
    console.log('Dry run (no files will be written)');
    console.log('\nPayload files:');
    for (const plan of filePlans) {
      console.log(`  ${plan.status.padEnd(10)} ${plan.destination}`);
    }
    console.log('\nsettings.json:');
    const diff = unifiedDiff(
      settingsPlan.originalText,
      settingsPlan.nextText,
      settingsPlan.displayPath,
    );
    console.log(diff || '  no changes');
    console.log('\nApply with:');
    console.log(`  ${applyCommand(selectedPieces, options)}`);
    return;
  }

  let fileResult;
  try {
    fileResult = await applyFiles(filePlans, installRoot);
  } catch (error) {
    throw new CliError(`Payload copy failed; settings were not touched: ${error.message}`);
  }
  const backupPath = await writeSettings(settingsLocation.resolvedPath, settingsPlan);

  console.log('Context Kit install complete.');
  console.log(`Files copied: ${fileResult.copied}; up to date: ${fileResult.upToDate}`);
  console.log(`Hook entries added: ${settingsPlan.added}; skipped: ${settingsPlan.skipped}`);
  console.log(`Settings: ${settingsPlan.changed ? 'updated' : 'no changes'}`);
  console.log(
    `Backup: ${
      settingsPlan.changed
        ? settingsPlan.exists
          ? backupPath
          : 'none (new file)'
        : 'none (settings unchanged)'
    }`,
  );
  if (wantsPathHint(selectedPieces)) {
    console.log(`PATH hint: export PATH="${pathHint(installRoot)}:$PATH"`);
  }
}

export async function main(argv = process.argv.slice(2)) {
  try {
    const options = parseArguments(argv);
    if (options.help) {
      console.log(USAGE);
      return 0;
    }
    await install(options);
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`context-kit: ${message}`);
    if (error instanceof CliError) {
      console.error('');
      console.error(USAGE);
    }
    return 1;
  }
}

if (process.argv[1] !== undefined) {
  let invoked;
  try {
    invoked = await realpath(process.argv[1]);
  } catch {
    invoked = path.resolve(process.argv[1]);
  }
  if (import.meta.url === pathToFileURL(invoked).href) {
    process.exitCode = await main();
  }
}
