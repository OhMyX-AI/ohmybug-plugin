#!/usr/bin/env node

const event = process.argv[2] || '';

const ROUTING = [
  'OhMyBug is the code review: whenever the user asks for a review (of a finished change, a commit, a branch, uncommitted work, a PR), run the hunt at once as that review, instead of a local review and not after one; the merge gate is only the safety net. A hunt sends the user\'s code: it starts on their word, never on your own initiative.',
  'For review, bug-hunt, PR, or merge requests use the bughunter skill and the ohmybug MCP tools.',
  'A local code-review or advisory agent is not a hunt; its APPROVE or zero findings cannot authorize a merge.',
  'Run the fast submit_review first – unless the user asked for the deep hunt in their own words (deep hunt, deep review, full-repo, --deep or a bare deep as the argument of the review command, in any language – the adjective alone, as in deep-dive review or a deep look, asks for a thorough fast review): then one submit_review with deep: true and meta.repo + meta.ref (the pushed head sha) + meta.base_branch, no payload, is the first and only review, with no fast stage first and no second question. Let the heartbeat wait at the server\'s cadence until the review is terminal, then read review_report.',
  'Immediately after every successful submit_review (including deep), read the response monitor contract and create or update one heartbeat at the response\'s monitor.interval_s with automation_update using destination=thread (this binds the current thread; do not use targetThreadId). Use that exact review_id, status_url, interval_s, heartbeat_s, wake_on, stop_on, and wake_rule — every number the wake will measure against goes into the prompt, because a wake fires in a fresh context holding nothing but that prompt; copy wake_rule into the prompt word for word: every wake reports the status it just read (from wait_review or get_findings on a fast hunt, from the status_url read on a deep one), and a wake with no answer prints bughunt · <mode> · poll-failed, never the previous status. The automation is the cadence and a wake is one read: inside a wake make ONE read and end — get_findings, or one wait_review with its default hold (the server caps the hold whatever timeout_s you ask for and answers timed_out:true, so a bigger timeout_s buys no extra waiting, and a timed_out answer is this wake\'s reading, running, from a healthy server, never a wake to count towards retirement); never loop either call inside the wake to cover the cadence, because a wake that loops is still holding the thread when the next one fires, and stop on done, failed or needs_files; the one exception is a payload submit (a diff sent as bytes, where the server cannot read the repo and serve the reviewers\' file requests itself) while a file request can still arrive: inside that wake call wait_review back to back, each answer a reading, and stop on done, failed or needs_files — or before the next wake is due: start another hold only if it, its round trip, and one more round trip for the handover\'s own calls would end inside heartbeat_s from this wake\'s start, so what is left before interval_s is the handover (the status line, the delete) and the next wake finds the thread free; a hold costs the server\'s cap plus the round trip and the handover\'s calls are round trips too, so a bound that subtracts the hold alone lets the last one return as the next wake fires, and one that leaves the handover to the heartbeat_s-interval_s gap shrinks it on the slow links that need it — a repo or deep submit never needs this; for a deep hunt the wake polls status_url once and reports that — that body flags a file request as awaiting_client_files/files_requested rather than in its status word, so a wake seeing either flag prints bughunt · <mode> · needs-files and serves the files first, and a failed poll falls back to one get_findings before it counts as a wake that read nothing. It must answer needs_files first, print only one compact bughunt status line, and delete itself on done or failed. Write the next sentence into the heartbeat prompt word for word, because a wake is often the only read of a finished hunt: "Besides its one bughunt status line, when this wake\'s read carries deep_offer (and, if it carries route_state, also final: true), print deep_offer.pitch word for word after that line, ask whether to start the deep hunt, and call no submit_review in this wake: the answer is the user\'s; copy this sentence into any heartbeat that replaces this one." Retire a heartbeat older than 180 minutes, or after 3 consecutive wakes that could not read a status at all (a failed wait_review, get_findings or status_url read, whichever that wake uses); on retiring, print bughunt · <mode> · watch-retired, then call get_findings once and arm a fresh heartbeat if the review is still running or waiting for files and the retirement came from unreadable wakes rather than the age cap. Never leave a heartbeat pointing at an older review id. The prompt carries facts the model can check, not only rules: compute retire_at = submit time + 180 min and write it as an ISO timestamp, the same instant into every replacement heartbeat so the cap bounds the review and not each job — if the current time is past retire_at, print bughunt · <mode> · watch-retired, delete this automation, then call get_findings once and report what it answered (still running when it is: 180 min is budget plus queue, so a queued deep hunt can be live there) — delete before the read, whatever the wake believes, because a delete that waits on a tool call is lost when that call fails. A terminal line quotes the answer it came from — on done print findings=N from that wake\'s read (wait_review, get_findings or the status_url body all carry a findings count), never the bare word; non-terminal wakes keep the enumerated lines, and no answer from a wake\'s read means the only line allowed is bughunt · <mode> · poll-failed. On done or failed delete the heartbeat in the same turn as the read; if it still exists at the next wake after a terminal read, delete it first, then report. When a get_findings next_step begins "this is the first read after done", the heartbeat outlived the hunt: delete it in that same turn and say so (the server sends it only when the hunt has been done for over ten minutes with its findings unread, so a wake that catches done within one cadence never sees it).',
  'A routed hunt carries route_state on its reads, and done on it is not the end until final: true, and neither is failed: the service continues a failed first review too. Once the reads of a review have carried route_state, it stays routed until final: true – a later read of it without route_state is not an ordinary done. While it is routed and final is not true, the rules above that stop on, or delete the heartbeat on, done or failed do not apply, nor does a next_step that begins "this is the first read after done": keep the heartbeat (retire_at still caps it). snap_running or pending, with any status, or a route_state not named here: keep the heartbeat on the same review and print bughunt · <mode> · running – except that a file request still comes first, as always. awaiting_verdicts: judge its findings with confirm_findings as usual, then keep the heartbeat on it. continued with continued_by: <id>: that review is the answer from now on, with its own findings, verdicts, billing and attestation – replace the heartbeat with one on <id> (its own monitor fields from get_findings(<id>); its status_url is the same URL with the id replaced; its own retire_at, from now), report the first review in one line at most, and take get_attestation from <id>, never from the first review. final: true: the review is the answer; when continuation_refused is present, say in one line that no fast hunt followed and why. No route_state means an ordinary hunt.',
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
const RU_DEEP = String.raw`(?:(?<!\u043d\u0435 )(?<!\u043d\u0435  )(?<!\u043d\u0435   )(?<!\u043d\u0435\t)\u0433\u043b\u0443\u0431\u043e\u043a(?:\u043e\u0435|\u0438\u0439)\s+(?:\u0440\u0435\u0432\u044c\u044e|\u0430\u0443\u0434\u0438\u0442|\u0445\u0430\u043d\u0442)|(?<!\u043d\u0435 )(?<!\u043d\u0435  )(?<!\u043d\u0435   )(?<!\u043d\u0435\t)\u043f\u043e\u043b\u043d(?:\u044b\u0439|\u043e\u0433\u043e|\u043e\u0439)\s+\u0440\u0435\u043f\u043e\u0437\u0438\u0442\u043e\u0440(?:\u0438\u0439|\u0438\u044f|\u0438\u044e|\u0438\u0438|\u0438\u0435\u043c))`
const REVIEW_REQUEST = new RegExp(`(?:\\b(?:review|reviewing|bug.?hunt|hunt\\s+bugs?|deep\\s+(?:review|hunt)|(?:lite|snap)\\s+hunt|full[- ]repo(?:sitory)?\\b|pull\\s+request|\\bpr\\b|merge)\\b|${RU_BOUNDARY_START}(?:${RU_REVIEW}|${RU_DEEP})${RU_BOUNDARY_END})`, 'iu')

const PR_REQUEST = /\bpr\b/i
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
  if (REVIEW_REQUEST.test(prompt) || PR_REQUEST.test(prompt)) {
    // The user's own words are the only thing that puts deep first (the server
    // takes deep: true from nobody else); the sentence says so only when the
    // prompt names the hunt, so a plain "review this" never reads as a deep
    // ask. The noun phrase, not the adjective, and every alternative closed on
    // BOTH sides: a hyphen is a word boundary, so \bdeep\b took "deep-dive
    // review" for the paid hour, and an open-ended full[- ]repo took "full
    // report". The slash command's own argument counts, bare or dashed.
    const deep = DEEP_REQUEST.test(prompt)
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
