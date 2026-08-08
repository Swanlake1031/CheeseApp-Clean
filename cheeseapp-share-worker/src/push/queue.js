import {
  callSupabaseRPC,
  deleteRows,
  patchRows,
  selectRows
} from "./supabase.js";
import {
  hasAPNsConfig,
  sendAPNSNotification
} from "./apns.js";

const DEFAULT_BATCH_SIZE = 25;
const MAX_RETRY_DELAY_SECONDS = 3600;

function nowISO() {
  return new Date().toISOString();
}

function retryDelaySeconds(attempts, fallbackSeconds = 60) {
  const base = Math.max(Number(fallbackSeconds) || 60, 15);
  const exponent = Math.max(Number(attempts) || 1, 1) - 1;
  return Math.min(base * (2 ** exponent), MAX_RETRY_DELAY_SECONDS);
}

async function updateJob(config, id, patch) {
  await patchRows({
    config,
    table: "push_notification_jobs",
    query: { id: `eq.${id}` },
    patch
  });
}

async function markSent(config, jobID) {
  await updateJob(config, jobID, {
    status: "sent",
    sent_at: nowISO(),
    locked_at: null,
    locked_by: null,
    last_error: null,
    updated_at: nowISO()
  });
}

async function markCanceled(config, jobID, reason) {
  await updateJob(config, jobID, {
    status: "canceled",
    locked_at: null,
    locked_by: null,
    last_error: reason || null,
    updated_at: nowISO()
  });
}

async function markFailed(config, jobID, reason) {
  await updateJob(config, jobID, {
    status: "failed",
    locked_at: null,
    locked_by: null,
    last_error: reason || null,
    updated_at: nowISO()
  });
}

async function markRetry(config, job, reason, retryAfterSeconds = null) {
  const delay = retryDelaySeconds(job.attempts, retryAfterSeconds);
  await updateJob(config, job.id, {
    status: "pending",
    available_at: new Date(Date.now() + delay * 1000).toISOString(),
    locked_at: null,
    locked_by: null,
    last_error: reason || null,
    updated_at: nowISO()
  });
}

async function activeTokensForUser(config, userID) {
  return selectRows({
    config,
    table: "user_push_tokens",
    query: {
      select: "token,platform",
      user_id: `eq.${userID}`
    }
  });
}

async function removeInvalidToken(config, token) {
  try {
    await deleteRows({
      config,
      table: "user_push_tokens",
      query: {
        token: `eq.${token}`
      }
    });
  } catch (error) {
    console.error("Failed to delete invalid push token", error);
  }
}

async function deliverJob(config, job) {
  const tokens = await activeTokensForUser(config, job.recipient_user_id);
  const validTokens = tokens.filter(
    (item) => typeof item?.token === "string" && item.token.trim()
  );

  if (!validTokens.length) {
    await markCanceled(config, job.id, "No active push tokens.");
    return;
  }

  let sent = false;
  let hasRetryableFailure = false;
  let retryAfterSeconds = null;
  let lastFailureReason = "";

  for (const tokenRow of validTokens) {
    const result = await sendAPNSNotification({
      config,
      token: tokenRow.token,
      platform: tokenRow.platform || "ios",
      title: job.title,
      body: job.body,
      payload: job.payload || {},
      threadID: job.thread_id,
      collapseKey: job.collapse_key
    });

    if (result.ok) {
      sent = true;
      continue;
    }

    lastFailureReason = result.reason || `APNs ${result.status || "error"}`;

    if (result.invalidToken) {
      await removeInvalidToken(config, tokenRow.token);
      continue;
    }

    if (result.retryable) {
      hasRetryableFailure = true;
      if (Number.isFinite(result.retryAfterSeconds)) {
        retryAfterSeconds = result.retryAfterSeconds;
      }
      continue;
    }
  }

  if (sent) {
    await markSent(config, job.id);
    return;
  }

  const remainingTokens = await activeTokensForUser(config, job.recipient_user_id);
  const stillHasTokens = remainingTokens.some(
    (item) => typeof item?.token === "string" && item.token.trim()
  );

  if (!stillHasTokens) {
    await markCanceled(config, job.id, lastFailureReason || "No valid tokens remain.");
    return;
  }

  if (hasRetryableFailure) {
    await markRetry(config, job, lastFailureReason, retryAfterSeconds);
    return;
  }

  await markFailed(config, job.id, lastFailureReason || "Permanent APNs failure.");
}

export async function processPushQueue({ config, batchSize = DEFAULT_BATCH_SIZE }) {
  if (!config.supabaseAuthKey) {
    console.warn("Skipping push queue: missing SUPABASE_SERVICE_ROLE_KEY.");
    return;
  }

  if (!hasAPNsConfig(config)) {
    console.warn("Skipping push queue: missing APNs configuration.");
    return;
  }

  const jobs = await callSupabaseRPC({
    config,
    fn: "claim_push_notification_jobs",
    body: {
      p_limit: batchSize,
      p_worker_id: `cheeseapp-share:${Date.now()}`
    }
  });

  if (!Array.isArray(jobs) || jobs.length === 0) {
    return;
  }

  for (const job of jobs) {
    try {
      await deliverJob(config, job);
    } catch (error) {
      console.error("Push job delivery failed unexpectedly", job?.id, error);
      try {
        await markRetry(config, job, error instanceof Error ? error.message : String(error));
      } catch (markError) {
        console.error("Failed to requeue push job", job?.id, markError);
      }
    }
  }
}
