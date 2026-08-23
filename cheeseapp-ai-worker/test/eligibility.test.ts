import assert from "node:assert/strict";
import test from "node:test";
import { isEligibleInvocation } from "../src/ai/eligibility";
import {
  AI_USER_ID,
  comment,
  post,
  threadContext,
} from "./fixtures";

test("structured 奶酪AI mention is eligible even when display text changes", () => {
  for (const content of [
    "@奶酪AI 这是什么意思",
    "这价格怎么样 @奶酪AI",
    "@奶酪AI @奶酪AI 出来",
    "请帮我看看",
  ]) {
    assert.equal(
      isEligibleInvocation({
        context: threadContext({ source: comment({ content }) }),
        aiUserId: AI_USER_ID,
        triggerKind: "mention",
      }),
      true,
    );
  }
});

test("database-authorized continuation does not require mention text", () => {
  assert.equal(
    isEligibleInvocation({
      context: threadContext(),
      aiUserId: AI_USER_ID,
      triggerKind: "continuation",
    }),
    true,
  );
});

test("private forum, deleted source, non-forum and AI self-mentions are rejected", () => {
  const cases = [
    threadContext({ post: post({ is_private: true }) }),
    threadContext({ source: comment({ is_deleted: true }) }),
    threadContext({ post: post({ type: "secondhand" }) }),
    threadContext({
      source: comment({
        user_id: AI_USER_ID,
        content: "生成结果里碰巧出现 @奶酪AI 也不能自触发",
      }),
    }),
  ];

  for (const context of cases) {
    assert.equal(
      isEligibleInvocation({
        context,
        aiUserId: AI_USER_ID,
        triggerKind: "mention",
      }),
      false,
    );
  }
});

test("continuation is eligible without literal @ text", () => {
  assert.equal(
    isEligibleInvocation({
      context: threadContext({
        source: comment({ content: "那你再具体讲讲" }),
      }),
      aiUserId: AI_USER_ID,
      triggerKind: "continuation",
    }),
    true,
  );
});
