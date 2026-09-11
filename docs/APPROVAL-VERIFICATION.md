# Approval observer verification

## Scope

Codex Desktop local IPC stream version 11. This is an internal interface, not a
stable public API. No vendor application source is distributed in this project.
Standalone Codex CLI does not publish this desktop stream.

## Evidence

- A read-only live subscription received `threadRuntimeStatus` changing to
  `active` with `waitingOnApproval`, followed by a pending
  `item/commandExecution/requestApproval` request during a real human approval.
- After approval, the request was removed and active flags returned to empty.
- An automatically reviewed operation, with the installed observer connected and
  subscribed, left physical output at `working`, command `1` throughout sampling.
- Replaying the captured approval-state shape through the installed hardware
  controller produced `attention` with both `0` and `1`; removing the request
  produced `working` with only `1`, without a tool-completion event.
- Simulated `usageLimitExceeded` and `responseStreamDisconnected` terminal states
  each produced `attention` with both `0` and `1`. Tests did not exhaust account
  credits, disable networking, or interrupt an actual user task.
- Test-owned records were removed; physical output returned to `working`, `1`,
  `simulated: false` for the current real task.

The human-approval state capture and physical replay were separate checks. A new
end-to-end human-button test after deployment remains a useful acceptance check;
the current automatic reviewer can approve the diagnostic commands without a button.

## Regression coverage

`ruby test/beacon_test.rb`: 19 runs, 103 assertions, zero failures/errors.
New tests failed before implementation. Restart/orphan and handshake regressions
were reproduced as two failing assertions, then passed after repair.

Coverage includes concurrent approvals, resolution before command completion,
automatic review with no human request, revision gaps, reconnect, stale alert
cleanup after restart, handshake timeout, fragmented IPC frames, and terminal
quota/network/permission failure latching. The transport test verifies the observer
sends no approval decision.

## Network semantics

Continuing retries remain solid. A terminal network failure recorded by Codex
flashes. Losing the local observer connection during observed work also flashes,
but that indicates loss of visibility, not proof that the internet is down.
Silent hangs without an explicit state or disconnection are not guessed from age.

The public [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server)
describes waiting flags, approval resolution, and terminal error statuses. Desktop
IPC is the separately observed transport used by this adapter.
