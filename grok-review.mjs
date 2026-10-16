#!/usr/bin/env node
// Grok backend for /crossreview. Sends a diff to xAI's Responses API as plain
// text. Grok gets no tools and no file access, so it cannot write anything:
// the read-only guarantee holds by construction rather than by a sandbox flag
// (xAI's own CLI has no sandbox on Windows).
// Exit codes follow the codex-run.sh contract. See DESIGN.md.
import { readFileSync, writeFileSync } from 'node:fs';

const EXIT = { NO_LOGIN: 11, TIMEOUT: 12, FAIL: 13, NO_OUTPUT: 14, USAGE: 64 };
const ENDPOINT = 'https://api.x.ai/v1/responses';

function die(msg, code) {
  process.stderr.write(`cross-model: ${msg}\n`);
  process.exit(code);
}

const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 2) {
  const flag = argv[i];
  if (!['--diff', '--out', '--timeout'].includes(flag)) die(`unknown option: ${flag}`, EXIT.USAGE);
  if (i + 1 >= argv.length) die(`${flag} requires a value`, EXIT.USAGE);
  args[flag.slice(2)] = argv[i + 1];
}
if (!args.diff || !args.out) die('--diff and --out are required', EXIT.USAGE);
const secs = Number(args.timeout ?? 600);
if (!Number.isInteger(secs) || secs <= 0) die(`--timeout must be a positive integer, got: ${args.timeout}`, EXIT.USAGE);

const key = process.env.XAI_API_KEY;
if (!key) die('XAI_API_KEY is not set (create a key at console.x.ai)', EXIT.NO_LOGIN);

const model = process.env.CROSS_MODEL_GROK_MODEL || 'grok-4.7';
const maxBytes = Number(process.env.CROSS_MODEL_GROK_MAX_BYTES || 200000);
const priceIn = Number(process.env.CROSS_MODEL_GROK_PRICE_IN || 2);
const priceOut = Number(process.env.CROSS_MODEL_GROK_PRICE_OUT || 6);

let diff;
try {
  diff = readFileSync(args.diff, 'utf8');
} catch {
  die(`diff file not found: ${args.diff}`, EXIT.USAGE);
}
if (!diff.trim()) die('diff is empty; nothing to send', EXIT.USAGE);
const bytes = Buffer.byteLength(diff);
// Grok bills per token, unlike Codex on a ChatGPT plan, so an accidental
// whole-repo diff must not turn into a surprise bill.
if (bytes > maxBytes) {
  die(`diff is ${bytes} bytes, over the ${maxBytes}-byte cap (raise CROSS_MODEL_GROK_MAX_BYTES to allow it)`, EXIT.FAIL);
}

const instructions = `You are reviewing a code change: a unified diff with surrounding context lines.
You cannot open files or run anything. Judge only what the diff shows, and say so when a finding depends on code outside it.

Report only real defects. Each finding must state the concrete input or state that triggers it and the wrong result it produces. A finding without a concrete failure path is an opinion: omit it. Style preferences are not findings.

Output, exactly, one block per finding, most severe first:

- [P1|P2|P3] <title> — <path>:<startline>-<endline>
  <The triggering input or state, and the wrong result it produces.>

P1 = breaks correctness, security, or data integrity now; P2 = will break under realistic use; P3 = real but contained.
Use paths exactly as they appear in the diff headers, and line numbers from the new version of the file.

If nothing meets that bar, write "No findings" and list the files you examined.`;

const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), secs * 1000);

let res;
try {
  res = await fetch(ENDPOINT, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, instructions, input: `Review this diff:\n\n${diff}`, max_output_tokens: 16000 }),
    signal: controller.signal,
  });
} catch (err) {
  if (err.name === 'AbortError') die(`grok timed out after ${secs}s`, EXIT.TIMEOUT);
  die(`could not reach ${ENDPOINT}: ${err.message}`, EXIT.FAIL);
}

let bodyText;
try {
  bodyText = await res.text();
} catch (err) {
  if (err.name === 'AbortError') die(`grok timed out after ${secs}s`, EXIT.TIMEOUT);
  die(`could not read the response: ${err.message}`, EXIT.FAIL);
} finally {
  clearTimeout(timer);
}

if (res.status === 401 || res.status === 403) {
  die(`xAI rejected the API key (HTTP ${res.status})`, EXIT.NO_LOGIN);
}
if (!res.ok) die(`xAI returned HTTP ${res.status}: ${bodyText.slice(0, 500)}`, EXIT.FAIL);

let data;
try {
  data = JSON.parse(bodyText);
} catch {
  die(`xAI returned a response that is not JSON: ${bodyText.slice(0, 200)}`, EXIT.FAIL);
}

const text = (data.output ?? [])
  .filter((item) => item.type === 'message')
  .flatMap((item) => item.content ?? [])
  .filter((part) => part.type === 'output_text')
  .map((part) => part.text)
  .join('\n')
  .trim();

const usage = data.usage ?? {};
const inTok = usage.input_tokens ?? 0;
const outTok = usage.output_tokens ?? 0;
const cost = (inTok * priceIn + outTok * priceOut) / 1e6;
process.stderr.write(
  `grok usage: model ${model}, ${inTok} input + ${outTok} output tokens, ` +
    `about $${cost.toFixed(4)} at $${priceIn}/$${priceOut} per 1M tokens\n`,
);

if (!text) die('grok produced no output', EXIT.NO_OUTPUT);
writeFileSync(args.out, `${text}\n`);
