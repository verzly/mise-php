'use strict';

const { isCommand, canApprove } = require('./test-approval.cjs');

const sameHead = (pr, run, repo) => pr.head.repo?.id === run.head_repository?.id &&
  pr.head.ref === run.head_branch && pr.head.sha === run.head_sha &&
  pr.base.repo.full_name === `${repo.owner}/${repo.repo}`;

async function matchingPulls(github, repo, run) {
  if (run.event !== 'pull_request' || run.repository?.full_name !== `${repo.owner}/${repo.repo}` ||
      !run.head_repository?.owner?.login || !run.head_branch) return [];
  const pulls = await github.paginate(github.rest.pulls.list, {
    ...repo, state: 'all', head: `${run.head_repository.owner.login}:${run.head_branch}`, per_page: 100,
  });
  return pulls.filter(pr => sameHead(pr, run, repo) &&
    (!run.pull_requests?.length || run.pull_requests.some(link => link.number === pr.number &&
      link.head?.repo?.id === pr.head.repo.id && link.base?.repo?.id === pr.base.repo.id)));
}

async function rerun(github, repo, run, original) {
  const created = Date.parse(run.created_at);
  if (!Number.isFinite(created) || Date.now() - created > 30 * 24 * 60 * 60 * 1000) {
    throw new Error('A new commit is required: the original pull_request test.yml run exceeds the native 30-day rerun limit.');
  }
  // No API call may separate this head read from the privileged rerun.
  const { data: current } = await github.rest.pulls.get({ ...repo, pull_number: original.number });
  if (current.state !== 'open' || !sameHead(current, run, repo)) {
    throw new Error('PR head changed before rerun; the new commit must run its own approval check.');
  }
  await github.rest.actions.reRunWorkflow({ ...repo, run_id: run.id });
}

module.exports = async ({ github, context, core, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) }) => {
  const { payload, repo } = context;
  // Completion reconciliation publishes the separate check; it never reruns tests.
  if (context.eventName !== 'issue_comment') return;

  if (!payload.issue?.pull_request ||
      !(isCommand(payload.comment?.body) || isCommand(payload.changes?.body?.from))) return;
  const removal = payload.action === 'deleted' ||
    (isCommand(payload.changes?.body?.from) && !isCommand(payload.comment?.body));
  // The publisher handles revocation immediately, even while tests are active.
  if (removal) return;
  const actor = payload.sender?.login;
  const authorized = await canApprove(github, repo, actor);
  if (!authorized) return;
  const pull_number = payload.issue.number;
  const { data: original } = await github.rest.pulls.get({ ...repo, pull_number });
  if (original.state !== 'open') return;

  for (let attempt = 0; attempt < 19; attempt++) {
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
      ...repo, workflow_id: 'test.yml', event: 'pull_request', head_sha: original.head.sha, per_page: 100,
    });
    let selected;
    for (const run of runs.sort((a, b) => b.id - a.id)) {
      if (!sameHead(original, run, repo)) continue;
      const pulls = await matchingPulls(github, repo, run);
      if (pulls.length === 1 && pulls[0].number === pull_number) { selected = run; break; }
    }
    if (!selected) throw new Error('A new commit is required: no unambiguous matching original pull_request test.yml run exists.');
    if (selected.status === 'completed') {
      await rerun(github, repo, selected, original);
      core.info(`Requested native rerun ${selected.id}; approval reads current comments and author permissions.`);
      return;
    }
    if (attempt < 18) await sleep(10000);
  }
  throw new Error('The current-head test run is still active after 3 minutes. Retry by editing the /test comment after it completes.');
};

module.exports.resolvePullNumber = async ({ github, context }) => {
  const { payload, repo } = context;
  if (context.eventName === 'pull_request_target') return payload.pull_request.number;
  // Every PR comment evaluates current approval, even if its body is unrelated.
  // Thus a newer pending publisher can safely replace an older one for this PR.
  if (context.eventName === 'issue_comment') return payload.issue?.pull_request ? payload.issue.number : undefined;
  if (context.eventName !== 'workflow_run') return;
  const run = payload.workflow_run;
  if (run.status !== 'completed' || run.path !== '.github/workflows/test.yml' || run.event !== 'pull_request') return;
  const pulls = await matchingPulls(github, repo, run);
  if (pulls.length === 1 && pulls[0].state === 'open') return pulls[0].number;
};
