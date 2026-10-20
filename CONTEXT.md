# Attention Return

AwaitCue models how a selected target returns to a person’s attention only after the target is ready and the person is appropriate to interrupt.

## Language

**Hook**:
A future attention request bound to one Target, with either a Condition or a Minimum Wait.
_Avoid_: Reminder, alarm, task

**Target**:
The selected app window or specific Chromium tab and its selected region.
_Avoid_: Page or window when used without the binding semantics

**Condition Hook**:
A Hook that becomes Satisfied after observation confirms the user-approved Condition.
_Avoid_: Automation rule, event Hook

**Delay Hook**:
A Hook that becomes Satisfied after its Minimum Wait has elapsed; the time is not a notification deadline.
_Avoid_: Timer, countdown, alarm

**Condition**:
The user’s natural-language description of when the Target deserves attention again.
_Avoid_: Prompt, trigger rule

**Minimum Wait**:
The duration before a Delay Hook, or a snoozed Hook, may become Satisfied.
_Avoid_: Due time, deadline

**Satisfied**:
The Condition is confirmed or the Minimum Wait has elapsed, but the person has not necessarily been notified.
_Avoid_: Triggered, notified, completed

**Appropriate to Interrupt**:
Current screen context, input activity, and user preferences indicate that returning attention will not obviously disrupt focused work.
_Avoid_: Idle, inactive

**Target Unavailable**:
The bound tab or window can no longer be observed or reopened reliably and will not be replaced automatically.
_Avoid_: Condition failed, Hook failed

**Snooze**:
After notification, the same Hook enters a new Minimum Wait and then waits again for an appropriate interruption moment.
_Avoid_: Fixed-time alarm snooze
