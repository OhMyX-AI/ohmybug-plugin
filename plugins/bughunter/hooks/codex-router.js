#!/usr/bin/env node

const event = process.argv[2] || '';

const ROUTING = [
  'OhMyBug is the code review: whenever the user asks for a review (of a finished change, a commit, a branch, uncommitted work, a PR), run the hunt at once as that review, instead of a local review and not after one; the merge gate is only the safety net. A hunt sends the user\'s code: it starts on their word, never on your own initiative.',
  'For review, bug-hunt, PR, or merge requests use the bughunter skill and the ohmybug MCP tools.',
  'A local code-review or advisory agent is not a hunt; its APPROVE or zero findings cannot authorize a merge.',
  'Run the fast submit_review first – unless the user asked for the deep hunt in their own words (deep hunt, deep review, full-repo, --deep or a bare deep as the argument of the review command, in any language – the adjective alone, as in deep-dive review or a deep look, asks for a thorough fast review): then one submit_review with deep: true and meta.repo + meta.ref (the pushed head sha) + meta.base_branch, no payload, is the first and only review, with no fast stage first and no second question. Wait in this turn at the server\'s cadence until the review is terminal, then read review_report.',
  'Wait in the current turn for this review. Do not create a scheduled automation for a hunt. Resume the review_id returned by submit_review or already_running. Use the foreground wait procedure in the bughunter skill, including its payload file-request cadence. Follow watch.do before ordinary status handling. On move, switch to the named child and its cadence. On judge, verify and confirm the named findings once, then resume. Follow keep, done, resubmit and unavailable as specified in the server response. With an older server follow a nonfinal route_state before interpreting done or failed, and follow continued_by until final. On ordinary done, stop polling, use the findings already returned or fetch them with get_findings and confirm the verified result in this turn. Take get_attestation on the final review. Show a final deep_offer.pitch verbatim and ask before escalation.',
  'The submit answer and every poll body carry live_url: the private page where the person who started the hunt watches it in a browser – stages, findings, the sandbox-destroyed receipt, a Save as PDF button – for 6 hours after the result. Print it for the user as a plain line twice: once when the submit answer arrives, and once more beside your terminal done/failed line so they can save the report. It is a capability link: never paste it into a PR, an issue, a commit or anything shared, and never poll it yourself – status_url is your door. No live_url on the body (an older server) means no page: say nothing about one.',
  'A hunt mode the user names (lite, snap or fast: a lite hunt, --mode snap, or a bare mode as the argument of the review command) goes as submit_review\'s top-level mode; with none named send no mode: on a pushed commit the service may start with a first step (snap, or lite on accounts set to lite) and go on with a hunt in mode fast on the same commit (a route_state in the answer: follow the routed hunt rules), while uncommitted work, an uploaded diff and a change the first step cannot take (such as one over the snap size limit) get the fast hunt. "The fast submit_review", "the fast hunt" and "fast stage" in these rules mean the first stage (not deep), never mode: fast. Before the submit of a named mode say the mode and its price from get_balance modes in one line. A mode refusal (mode_unavailable, mode_needs_repo, mode_too_large, mode_with_deep) starts nothing: show it verbatim and offer what it says to send instead with one yes/no question, never a silent switch. Never send mode with deep. The status line\'s <mode> is the submit answer\'s hunt_mode (fast when absent), deep for a deep hunt.',
  'On your own initiative start deep only after the server returns deep_offer and the user explicitly agrees; never run fast and deep in parallel. A refusal of a deep-first request (repo_required, repo_too_big, commit_required, fast_running, deep_at_capacity) is shown to the user verbatim, then the fast hunt is offered with one yes/no question – never a silent downgrade to fast. A deep-first hunt follows the same foreground wait procedure.',
  'Only server review_report plus get_attestation, verified findings, and green CI can satisfy the merge gate. get_attestation is the proof; in a checkout that gates merges with ticket.sh, ./scripts/ticket.sh attest <review_id> hands it to the gate — use the recorded hook evidence when available.',
  'At the start of the session confirm the ohmybug MCP tools are present; if they are not, tell the user once, now — a session that began without them will not get them, and a restart usually does — then let the user decide and go on with what they asked.',
  'If the MCP tools are unavailable or authentication fails, report the review as blocked; do not substitute a local review.'
].join(' ');

function emit(context, hookEventName) {
  process.stdout.write(JSON.stringify({
    systemMessage: 'OHMYBUG: cloud code review',
    hookSpecificOutput: { hookEventName, additionalContext: context }
  }));
}

// The first-session offer of the setup, until the setup is done (the marker,
// written only by the skill's First-run setup) and at most 3 times (a counter
// shared with intro.sh). The questions start only on the user's word, so
// `codex exec` never waits on one.
const SETUP_OFFER = 'In your first reply add one line: OhMyBug is installed, say \'set up OhMyBug\' for three quick questions; then go on.';

function offerSetup() {
  const fs = require('fs'), path = require('path'), os = require('os');
  const dir = process.env.OMB_STATE_DIR || path.join(os.homedir(), '.ohmybug');
  if (fs.existsSync(path.join(dir, 'intro-v1'))) return false;
  const counter = path.join(dir, 'intro-v1-offers');
  let n = 0;
  try { n = parseInt(fs.readFileSync(counter, 'utf8'), 10) || 0; } catch (_) {}
  if (n >= 3) return false;
  // A counter that cannot be written would offer forever: no offer then.
  try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(counter, `${n + 1}\n`); } catch (_) { return false; }
  return true;
}

if (event === 'session') {
  // Only a new session spends an offer: a resumed, cleared or compacted one is
  // mid-task. The payload's source says which; none (an older client) counts as new.
  let raw = '', done = false;
  const go = () => {
    if (done) return;
    done = true;
    let src = '';
    try { src = String(JSON.parse(raw.replace(/^\uFEFF/, '') || '{}').source || ''); } catch (_) {}
    const fresh = src === '' || src === 'startup';
    emit(fresh && offerSetup() ? `${ROUTING} ${SETUP_OFFER}` : ROUTING, 'SessionStart');
    process.exit(0);
  };
  process.stdin.on('data', c => { raw += c; });
  process.stdin.on('end', go);
  process.stdin.on('error', go);
  setTimeout(go, 1000).unref();
}

if (event === 'subagent') {
  emit('If this subagent is asked to review or hunt bugs, follow the OhMyBug MCP lifecycle. Local advisory review is not merge evidence.', 'SubagentStart');
  process.exit(0);
}

if (event !== 'prompt' && event !== 'session') process.exit(0);

let input = '';
let finished = false;
const RU_BOUNDARY_START = String.raw`(?<![\p{L}\p{N}_])`
const RU_BOUNDARY_END = String.raw`(?![\p{L}\p{N}_])`
const RU_REVIEW = String.raw`(?:\u0431\u0430\u0433[\s-]?\u0445\u0430\u043d\u0442(?:\u0435\u0440(?:\u043e\u043c|\u0430|\u0443|\u044b|\u0435|\u043e\u0432)?|\u0430|\u043e\u043c|\u043e\u0432|\u0435|\u0443|\u044b)?|\u0440\u0435\u0432\u044c\u044e|\u043f\u0440\u043e\u0432\u0435\u0440(?:\u044c|\u044c\u0442\u0435)\s+(?:\u043a\u043e\u0434(?:\u0430|\u0443|\u043e\u043c)?|\u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u044f|\u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0439|\u0432\u0435\u0442\u043a\u0443|\u0432\u0435\u0442\u043a\u0438|\u0432\u0435\u0442\u043a\u0435|\u043a\u043e\u043c\u043c\u0438\u0442(?:\u044b|\u0430|\u043e\u0432)?|pr))`
const RU_DEEP = String.raw`(?:\u0433\u043b\u0443\u0431\u043e\u043a(?:\u043e\u0435|\u0438\u0439)\s+(?:\u0440\u0435\u0432\u044c\u044e|\u0430\u0443\u0434\u0438\u0442|\u0445\u0430\u043d\u0442)|\u043f\u043e\u043b\u043d(?:\u044b\u0439|\u043e\u0433\u043e|\u043e\u0439)\s+\u0440\u0435\u043f\u043e\u0437\u0438\u0442\u043e\u0440(?:\u0438\u0439|\u0438\u044f|\u0438\u044e|\u0438\u0438|\u0438\u0435\u043c))`
const RU_DEEP_NEGATED = new RegExp(`(?<![\\p{L}\\p{N}_])\\u043d\\u0435\\s+(?:\\u043e\\u0447\\u0435\\u043d\\u044c\\s+)?${RU_DEEP}`, 'iu')

const REVIEW_REQUEST = new RegExp(`(?:\\b(?:review|reviewing|bug.?hunt|hunt\\s+bugs?|deep\\s+(?:review|hunt)|(?:lite|snap)\\s+hunt|full[- ]repo(?:sitory)?\\b|pull\\s+request|\\bpr\\b|merge)\\b|${RU_BOUNDARY_START}(?:${RU_REVIEW}|${RU_DEEP})${RU_BOUNDARY_END})`, 'iu')
const DEEP_REQUEST = new RegExp(`(?:\\bdeep\\s+(?:hunt|review|scan|pass|mode)\\b|\\bfull[- ]repo(?:sitory)?\\b|--deep\\b|\\bbughunter:review\\s+(?:--)?deep\\b|${RU_BOUNDARY_START}${RU_DEEP}${RU_BOUNDARY_END})`, 'iu')
function finish() {
  if (finished) return;
  finished = true;
  let prompt = '';
  try { prompt = String(JSON.parse(input.replace(/^\uFEFF/, '')).prompt || ''); } catch (_) { process.exit(0); }
  // The setup ask never swallows a review ask in the same prompt: both go.
  const setup = /\bset\s*up\s+ohmybug\b|\bohmybug\s+setup\b/i.test(prompt)
    ? 'The user asks for the OhMyBug setup: run the First-run setup of the bughunter skill now, in chat, numbered, free text accepted.'
    : '';
  if (REVIEW_REQUEST.test(prompt)) {
    // The user's own words are the only thing that puts deep first (the server
    // takes deep: true from nobody else); the sentence says so only when the
    // prompt names the hunt, so a plain "review this" never reads as a deep
    // ask. The noun phrase, not the adjective, and every alternative closed on
    // BOTH sides: a hyphen is a word boundary, so \bdeep\b took "deep-dive
    // review" for the paid hour, and an open-ended full[- ]repo took "full
    // report". The slash command's own argument counts, bare or dashed.
    const deep = DEEP_REQUEST.test(prompt) && !RU_DEEP_NEGATED.test(prompt)
      ? ' The prompt names the deep hunt: if the user is asking for it, submit_review with deep: true is the first and only review – no fast stage first, no second question.'
      : '';
    emit(`${ROUTING} Route this request now; do not launch local review agents.${deep}${setup ? ` ${setup}` : ''}`, 'UserPromptSubmit');
  } else if (setup) emit(setup, 'UserPromptSubmit');
}

if (event === 'prompt') {
  process.stdin.on('data', chunk => { input += chunk; });
  process.stdin.on('end', finish);
  process.stdin.on('error', () => { finish(); process.exit(0); });
  setTimeout(() => { finish(); process.exit(0); }, 1000).unref();
}
