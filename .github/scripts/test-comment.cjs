'use strict';

const { isCommand, canApprove, hasApproval } = require('./test-approval.cjs');

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

async function approvedJob(github, repo, run) {
  const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
    ...repo, run_id: run.id, filter: 'latest', per_page: 100,
  });
  return jobs.some(job => job.name === 'check-approval' && job.conclusion === 'success');
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
  if (context.eventName === 'workflow_run') {
    const run = payload.workflow_run;
    // A failed approval rerun cannot trigger another reconciliation rerun.
    if (run.status !== 'completed' || run.path !== '.github/workflows/test.yml' || run.event !== 'pull_request') return;
    const pulls = await matchingPulls(github, repo, run);
    if (pulls.length !== 1 || pulls[0].state !== 'open') throw new Error('Cannot identify an unambiguous current-head PR for completed tests.');
    const pr = pulls[0];
    if (await hasApproval(github, repo, pr.number) || !await approvedJob(github, repo, run)) return;
    // Discard delayed completion events once a newer attempt is queued or running.
    const { data: latest } = await github.rest.actions.getWorkflowRun({ ...repo, run_id: run.id });
    if (latest.status !== 'completed' || latest.run_attempt !== run.run_attempt) return;
    await rerun(github, repo, run, pr);
    core.info('Rechecking revoked approval after tests completed.');
    return;
  }

  if (!payload.issue?.pull_request ||
      !(isCommand(payload.comment?.body) || isCommand(payload.changes?.body?.from))) return;
  const removal = payload.action === 'deleted' ||
    (isCommand(payload.changes?.body?.from) && !isCommand(payload.comment?.body));
  const actor = payload.sender?.login;
  const authorized = await canApprove(github, repo, actor);
  if (!authorized && !(removal && actor && actor === payload.comment?.user?.login)) return;
  const pull_number = payload.issue.number;
  if (removal && await hasApproval(github, repo, pull_number)) return;
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
      if (removal && !await approvedJob(github, repo, selected)) return;
      await rerun(github, repo, selected, original);
      core.info(`Requested native rerun ${selected.id}; approval reads current comments and author permissions.`);
      return;
    }
    if (attempt < 18) await sleep(10000);
  }
  if (removal) {
    core.info('Revocation will be reconciled by the trusted workflow_run completion handler.');
    return;
  }
  throw new Error('The current-head test run is still active after 3 minutes. Retry by editing the /test comment after it completes.');
};
