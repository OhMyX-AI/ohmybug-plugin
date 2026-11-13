#!/usr/bin/env node

const event = process.argv[2] || '';

const ROUTING = [
  'OhMyBug is the code review: whenever the user asks for a review (of a finished change, a commit, a branch, uncommitted work, a PR), run the hunt at once as that review, instead of a local review and not after one; the merge gate is only the safety net. A hunt sends the user\'s code: it starts on their word, never on your own initiative.',
  'For review, bug-hunt, PR, or merge requests use the bughunter skill and the ohmybug MCP tools.',
  'A local code-review or advisory agent is not a hunt; its APPROVE or zero findings cannot authorize a merge.',
  'Run the fast submit_review first – unless the user asked for the deep hunt in their own words (deep hunt, deep review, full-repo, --deep or a bare deep as the argument of the review command, in any language – the adjective alone, as in deep-dive review or a deep look, asks for a thorough fast review): then one submit_review with deep: true and meta.repo + meta.ref (the pushed head sha) + meta.base_branch, no payload, is the first and only review, with no fast stage first and no second question. Let the heartbeat wait at the server\'s cadence until the review is terminal, then read review_report.',
  `Immediately after every successful submit_review (including deep), create or update one heartbeat at the response's monitor.interval_s with automation_update using destination=thread (this binds the current thread; do not use targetThreadId), never leaving one on an older review id. Its prompt is the bughunter skill's wake prompt: each wake runs the watch helper once – sh '${require('path').join(__dirname, '..', 'skills', 'bughunter', 'watch-once.sh')}' <review_id> '<status_url>' <start> <mode>, start being the submit time in epoch seconds – prints its first line and does what its last word says (keep, files, judge, move, done, failed, resubmit, read, retire); the helper, not the prompt, decides the route, the age cap, the failure window and the line. A routed hunt is followed through those words: its first review's done is not the result, and after move the review it names is the hunt and its attestation.`,
  'The submit answer and every poll body carry live_url: the private page where the person who started the hunt watches it in a browser – stages, findings, the sandbox-destroyed receipt, a Save as PDF button – for 6 hours after the result. Print it for the user as a plain line twice: once when the submit answer arrives, and once more beside your terminal done/failed line so they can save the report. It is a capability link: never paste it into a PR, an issue, a commit or anything shared, and never poll it yourself – status_url is your door. No live_url on the body (an older server) means no page: say nothing about one.',
  'A hunt mode the user names (lite, snap or fast: a lite hunt, --mode snap, or a bare mode as the argument of the review command) goes as submit_review\'s top-level mode; with none named send no mode: on a pushed commit the service may start with a first step (snap, or lite on accounts set to lite) and go on with a hunt in mode fast on the same commit (a route_state in the answer: follow the routed hunt rules), while uncommitted work, an uploaded diff and a change the first step cannot take (such as one over the snap size limit) get the fast hunt. "The fast submit_review", "the fast hunt" and "fast stage" in these rules mean the first stage (not deep), never mode: fast. Before the submit of a named mode say the mode and its price from get_balance modes in one line. A mode refusal (mode_unavailable, mode_needs_repo, mode_too_large, mode_with_deep) starts nothing: show it verbatim and offer what it says to send instead with one yes/no question, never a silent switch. Never send mode with deep. The heartbeat\'s <mode> is the submit answer\'s hunt_mode (fast when absent), deep for a deep hunt.',
  'On your own initiative start deep only after the server returns deep_offer and the user explicitly agrees; never run fast and deep in parallel. A refusal of a deep-first request (repo_required, repo_too_big, commit_required, fast_running, deep_at_capacity) is shown to the user verbatim, then the fast hunt is offered with one yes/no question – never a silent downgrade to fast. A deep-first hunt arms the same heartbeat as an escalation, from its own response\'s monitor, and its compact line reads bughunt · deep · running.',
  'Only server review_report plus get_attestation, verified findings, and green CI can satisfy the merge gate. get_attestation is the proof; in a checkout that gates merges with ticket.sh, ./scripts/ticket.sh attest <review_id> hands it to the gate — Codex has no hook that records a hunt locally, so without that step the gate sees no record and refuses.',
  'At the start of the session confirm the ohmybug MCP tools are present; if they are not, tell the user once, now — a session that began without them will not get them, and a restart usually does — then let the user decide and go on with what they asked.',
  'If the MCP tools are unavailable or authentication fails, report the review as blocked; do not substitute a local review.'
].join(' ');

function emit(context, hookEventName) {
  process.stdout.write(JSON.stringify({
    systemMessage: 'OHMYBUG: cloud code review',
    hookSpecificOutput: { hookEventName, additionalContext: context }
  }));
}

// Once per machine, the first Codex session after install: what to say to try it.
// Codex has no slash commands, so the welcome names phrases, and asks the assistant
// to pass them on, since a systemMessage alone is small print.
const WELCOME = 'OhMyBug is installed: a cloud bug hunt for your code, from $4 only when a real bug is found (the first is free). No pull request needed. Ask Codex: "Run the OhMyBug cloud hunt on my code" (your branch, uncommitted changes, recent commits, or a folder with no git), "Run an OhMyBug scan of this repository" (a GitHub repository, everything changed in the last 30 days, up to 150 minutes), or "Show my OhMyBug balance and record". Nothing starts until you ask.';

function firstSession() {
  const fs = require('fs'), path = require('path'), os = require('os');
  const dir = process.env.OMB_STATE_DIR || path.join(os.homedir(), '.ohmybug');
  const mark = path.join(dir, 'codex-welcome-v1');
  try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(mark, '', { flag: 'wx' }); return true; } catch (_) { return false; }
}

if (event === 'session') {
  if (firstSession()) {
    process.stdout.write(JSON.stringify({
      systemMessage: WELCOME,
      hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: `${ROUTING} ${WELCOME} (For the assistant: in your first reply this session, tell the user in two or three plain lines that OhMyBug is installed, and offer once to hunt their current branch or uncommitted changes now, before you answer what they asked. A hunt sends their code: start it only if they say yes.)` }
    }));
  } else emit(ROUTING, 'SessionStart');
  process.exit(0);
}

if (event === 'subagent') {
  emit('If this subagent is asked to review or hunt bugs, follow the OhMyBug MCP lifecycle. Local advisory review is not merge evidence.', 'SubagentStart');
  process.exit(0);
}

if (event !== 'prompt') process.exit(0);

let input = '';
let finished = false;
function finish() {
  if (finished) return;
  finished = true;
  let prompt = '';
  try { prompt = String(JSON.parse(input.replace(/^\uFEFF/, '')).prompt || ''); } catch (_) { process.exit(0); }
  if (/\b(?:review|reviewing|bug.?hunt|hunt\s+bugs?|deep\s+(?:review|hunt)|(?:lite|snap)\s+hunt|full[- ]repo(?:sitory)?\b|pull\s+request|\bpr\b|merge)\b/i.test(prompt)) {
    // The user's own words are the only thing that puts deep first (the server
    // takes deep: true from nobody else); the sentence says so only when the
    // prompt names the hunt, so a plain "review this" never reads as a deep
    // ask. The noun phrase, not the adjective, and every alternative closed on
    // BOTH sides: a hyphen is a word boundary, so \bdeep\b took "deep-dive
    // review" for the paid hour, and an open-ended full[- ]repo took "full
    // report". The slash command's own argument counts, bare or dashed.
    const deep = /\bdeep\s+(?:hunt|review|scan|pass|mode)\b|\bfull[- ]repo(?:sitory)?\b|--deep\b|\bbughunter:review\s+(?:--)?deep\b/i.test(prompt)
      ? ' The prompt names the deep hunt: if the user is asking for it, submit_review with deep: true is the first and only review – no fast stage first, no second question.'
      : '';
    emit(`${ROUTING} Route this request now; do not launch local review agents.${deep}`, 'UserPromptSubmit');
  }
}

process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', finish);
process.stdin.on('error', () => { finish(); process.exit(0); });
setTimeout(() => { finish(); process.exit(0); }, 1000).unref();
