'use strict';

const isCommand = body => typeof body === 'string' && body.trim() === '/test';

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

module.exports = { isCommand, canApprove, hasApproval };
