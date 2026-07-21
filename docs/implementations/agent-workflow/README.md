# Agent workflow commands

## Save invocation decision

`save` is an actionable handoff command, not a rigid whole-message grammar. It is invoked case-insensitively when the user directs the agent to save, including:

- `save`;
- `save: <context>`;
- `save and merge`;
- `save, push, and merge`;
- `please save then merge`.

Discussion is not invocation. A message that quotes `save`, asks what the command means, or proposes wording for the rule does not run the handoff unless it also directs the agent to perform it.

## Combined commands

When `save` appears with other actionable commands, the requested order is binding. For example, `save and merge` means:

1. finish the in-scope repository work;
2. run the complete save handoff against the actual pre-merge state;
3. perform the separately authorized merge;
4. report both outcomes truthfully.

The combined message authorizes its named actions; the save protocol never implies an unnamed commit, push, merge, deploy, deletion, or external mutation.

## Reasoning and consequences

The previous exact-message rule rejected clear commands such as `save and merge`, forcing unnecessary follow-up turns. Matching actionable intent keeps the safety boundary—discussion still does nothing—while allowing ordinary command combinations.

Save output remains a point-in-time handoff. If a later action in the same message changes repository or runtime state, the handoff records the pre-action state required by the user's ordering and the final response records the post-action result.
