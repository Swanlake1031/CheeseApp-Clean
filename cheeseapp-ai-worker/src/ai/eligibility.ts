import type {
  InteractionTriggerKind,
  ThreadContext,
} from "../types";

export interface EligibilityInput {
  readonly context: ThreadContext;
  readonly aiUserId: string;
  readonly triggerKind: InteractionTriggerKind;
}

export function isEligibleInvocation(input: EligibilityInput): boolean {
  const { context, aiUserId, triggerKind } = input;
  return (
    (triggerKind === "mention" || triggerKind === "continuation") &&
    !context.source.is_deleted &&
    context.source.user_id !== aiUserId &&
    context.post.type === "forum" &&
    context.post.status === "active" &&
    !context.post.is_private
  );
}
