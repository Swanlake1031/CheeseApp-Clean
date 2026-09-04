import type { RecommendationConfig } from "../config";
import { SupabaseRepository, SupabaseRequestError } from "../supabase";
import type { PostEmbeddingJob } from "../types";
import {
  EmbeddingProviderError,
  GeminiEmbeddingProvider,
} from "./embeddingProvider";

export class RecommendationProcessor {
  private readonly repository: SupabaseRepository;
  private readonly provider: GeminiEmbeddingProvider;

  constructor(private readonly config: RecommendationConfig) {
    this.repository = new SupabaseRepository(
      config.supabaseUrl,
      config.supabaseServiceRoleKey,
    );
    this.provider = new GeminiEmbeddingProvider(config.geminiApiKey);
  }

  async runScheduledBatch(): Promise<void> {
    const [backfilled, signalsBackfilled, metricsRefreshed] = await Promise.all([
      this.repository.backfillForumEmbeddingJobs(100),
      this.repository.backfillRecommendationSignalState(250),
      this.repository.refreshRecommendationMetrics(false),
    ]);
    const jobs = await this.repository.claimPostEmbeddingJobs(8);
    for (let offset = 0; offset < jobs.length; offset += 2) {
      await Promise.all(jobs.slice(offset, offset + 2).map((job) => this.process(job)));
    }

    let shadowSessions = 0;
    if (this.config.shadowEnabled) {
      const users = await this.repository.listRecommendationShadowUsers(8);
      const results = await Promise.all(
        users.map((userId) => this.repository.createRecommendationShadowSession(userId)),
      );
      shadowSessions = results.filter(Boolean).length;
    }
    console.log(JSON.stringify({
      event: "recommendation_schedule_completed",
      algorithm_version: this.config.algorithmVersion,
      embedding_version: this.config.embeddingVersion,
      backfilled,
      signals_backfilled: signalsBackfilled,
      metrics_refreshed: metricsRefreshed,
      jobs_claimed: jobs.length,
      shadow_sessions: shadowSessions,
    }));
  }

  private async process(job: PostEmbeddingJob): Promise<void> {
    const startedAt = Date.now();
    try {
      if (
        job.model !== this.config.embeddingModel ||
        job.embedding_version !== this.config.embeddingVersion ||
        job.input_format_version !== this.config.inputFormatVersion
      ) {
        await this.repository.failPostEmbeddingJob(
          job.job_id,
          "version_mismatch",
          false,
        );
        return;
      }
      const embedding = await this.provider.embed(job.embedding_input);
      const committed = await this.repository.completePostEmbeddingJob(
        job.job_id,
        job.input_hash,
        embedding.values,
        embedding.norm,
      );
      console.log(JSON.stringify({
        event: committed
          ? "post_embedding_completed"
          : "post_embedding_stale_rejected",
        post_id: job.post_id,
        job_id: job.job_id,
        attempt: job.attempt,
        embedding_version: job.embedding_version,
        model: job.model,
        provider_norm: embedding.providerNorm,
        stored_norm: embedding.norm,
        provider_latency_ms: embedding.latencyMs,
        total_latency_ms: Math.max(0, Date.now() - startedAt),
      }));
    } catch (error: unknown) {
      const category =
        error instanceof EmbeddingProviderError
          ? error.category
          : error instanceof SupabaseRequestError
            ? error.category
            : "embedding_processing_error";
      const retryable =
        error instanceof EmbeddingProviderError
          ? error.retryable
          : error instanceof SupabaseRequestError
            ? error.status === 429 || error.status >= 500
            : true;
      try {
        await this.repository.failPostEmbeddingJob(job.job_id, category, retryable);
      } catch {
        // The scheduled invocation will reclaim an abandoned processing lease.
      }
      console.error(JSON.stringify({
        event: "post_embedding_failed",
        post_id: job.post_id,
        job_id: job.job_id,
        attempt: job.attempt,
        category,
        retryable,
        latency_ms: Math.max(0, Date.now() - startedAt),
      }));
    }
  }
}
