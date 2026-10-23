'use strict';

const isCommand = body => typeof body === 'string' && body.trim() === '/approve';

async function canApprove(github, repo, username) {
  if (!username) return false;
  const { data } = await github.rest.repos.getCollaboratorPermissionLevel({ ...repo, username });
  return ['write', 'maintain', 'admin'].includes(data.permission);
}

async function hasApproval(github, repo, issue_number) {
  const comments = await github.paginate(github.rest.issues.listComments, {
    ...repo, issue_number, per_page: 100,
  });
  const permissions = new Map();
  for (const comment of comments) {
    if (!isCommand(comment.body) || !comment.user?.login) continue;
    const username = comment.user.login;
    if (!permissions.has(username)) {
      permissions.set(username, await canApprove(github, repo, username));
    }
    if (permissions.get(username)) return true;
  }
  return false;
}

const MISSING_SUMMARY = 'Tests are required before merge. A repository write/maintain/admin collaborator must post a standalone /approve comment. Configure Required approval as a required check, alongside the required test results.';
const UNVERIFIED_SUMMARY = 'Approval could not be verified. Merge remains blocked. Retry approval evaluation when the GitHub API is available.';
const APPROVED_SUMMARY = 'A valid /approve approval exists. The test suite must also pass before merge. Removing the last valid approval blocks merge again.';

async function publishApproval({ github, context, core, pull_number }) {
  if (context.eventName === 'workflow_dispatch') return;
  const repo = context.repo;
  const publish = async () => {
    const { data: pr } = await github.rest.pulls.get({ ...repo, pull_number });
    if (pr.state !== 'open' || pr.base.repo.full_name !== `${repo.owner}/${repo.repo}`) return;
    const head_sha = pr.head.sha;
    const external_id = `required-approval:${pull_number}:${head_sha}`;
    let approved = false;
    let summary = MISSING_SUMMARY;
    try {
      approved = await hasApproval(github, repo, pull_number);
    } catch {
      summary = UNVERIFIED_SUMMARY;
      core.notice(summary);
    }
    if (approved) summary = APPROVED_SUMMARY;
    const checks = await github.paginate(github.rest.checks.listForRef, {
      ...repo, ref: head_sha, check_name: 'Required approval', filter: 'all', per_page: 100,
    });
    // checks.create does not replace an earlier run for the same name and commit.
    const existing = checks.filter(check => check.name === 'Required approval' && check.head_sha === head_sha &&
      check.external_id === external_id && check.app?.slug === 'github-actions').sort((a, b) => b.id - a.id)[0];
    const { data: current } = await github.rest.pulls.get({ ...repo, pull_number });
    if (current.state !== 'open' || current.head.sha !== head_sha || current.head.repo?.id !== pr.head.repo?.id) return;
    const update = {
      ...repo, name: 'Required approval', external_id, status: 'completed',
      conclusion: approved ? 'success' : 'failure', completed_at: new Date().toISOString(),
      output: { title: approved ? 'Tests approved' : 'Tests not approved', summary },
    };
    if (existing) await github.rest.checks.update({ ...update, check_run_id: existing.id });
    else await github.rest.checks.create({ ...update, head_sha });
  };
  try {
    await publish();
  } catch (error) {
    // Dependabot PRs receive a read-only token here. The check then stays unreported,
    // which blocks merge without producing a failing workflow run.
    core.notice(`Required approval check was not published: ${error.message}`);
  }
}

module.exports = { isCommand, canApprove, hasApproval, publishApproval };
