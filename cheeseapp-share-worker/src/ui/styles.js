export const pageStyles = `
      :root {
        color-scheme: light only;
        --page-bg: #f5f0e0;
        --card: #ffffff;
        --text: #171717;
        --muted: #6b6358;
        --accent: #111827;
        --accent-soft: #9b7a1f;
      }
      * { box-sizing: border-box; }
      html {
        min-height: 100%;
        width: 100%;
        overflow-x: clip;
        overscroll-behavior-x: none;
        background: var(--page-bg);
      }
      body {
        margin: 0;
        min-height: 100vh;
        min-height: 100dvh;
        padding: 18px 16px 40px;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        color: var(--text);
        width: 100%;
        max-width: 100vw;
        overflow-x: clip;
        overscroll-behavior-x: none;
        touch-action: pan-y pinch-zoom;
        background: var(--page-bg);
      }
      .page {
        width: 100%;
        max-width: 460px;
        margin: 0 auto;
        padding-bottom: calc(120px + env(safe-area-inset-bottom, 0px));
        overflow-x: clip;
        overscroll-behavior-x: none;
        touch-action: pan-y pinch-zoom;
      }
      img, svg, code {
        max-width: 100%;
      }
      .page > *,
      .card,
      .market-media-card,
      .app-banner,
      .market-detail-page,
      .section-surface {
        max-width: 100%;
      }
      .app-banner {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        margin-bottom: 14px;
        padding: 10px 12px;
        border-radius: 18px;
        background: #ffffff;
        border: none;
        box-shadow: none;
      }
      .app-banner-compact {
        margin-bottom: 10px;
        padding: 9px 10px;
      }
      .app-banner-brand {
        display: flex;
        align-items: center;
        gap: 10px;
        min-width: 0;
      }
      .app-icon {
        width: 36px;
        height: 36px;
        border-radius: 12px;
        display: grid;
        place-items: center;
        background: #f3d67b;
        font-size: 20px;
      }
      .app-name {
        font-size: 14px;
        font-weight: 700;
      }
      .app-subtitle {
        font-size: 12px;
        color: var(--muted);
      }
      .app-open-button {
        flex-shrink: 0;
        display: inline-block;
        text-decoration: none;
        border-radius: 999px;
        background: #1d4ed8;
        color: #fff;
        font-size: 13px;
        font-weight: 700;
        padding: 10px 14px;
      }
      .card {
        width: 100%;
        background: var(--card);
        border: none;
        border-radius: 24px;
        padding: 18px;
        box-shadow: none;
      }
      .eyebrow {
        font-size: 12px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: var(--accent-soft);
      }
      .hero-media,
      .hero-placeholder,
      .detail-media {
        width: 100%;
        margin-bottom: 20px;
        border-radius: 18px;
        overflow: hidden;
      }
      .hero-media {
        aspect-ratio: 1.6 / 1;
        background: rgba(0, 0, 0, 0.04);
      }
      .hero-media img {
        display: block;
        width: 100%;
        height: 100%;
        object-fit: cover;
      }
      .market-media-card {
        margin-bottom: 14px;
      }
      .market-detail-page {
        display: flex;
        flex-direction: column;
        gap: 14px;
      }
      .market-media {
        position: relative;
        width: 100%;
        aspect-ratio: 1 / 1;
        overflow: hidden;
        border-radius: 24px;
        background: #ffffff;
        border: none;
        box-shadow: none;
      }
      .market-media-rect {
        aspect-ratio: auto;
        height: 240px;
        border-radius: 20px;
      }
      .market-media img {
        display: block;
        width: 100%;
        height: 100%;
        object-fit: cover;
      }
      .market-media-shell {
        position: relative;
      }
      .market-media-fallback {
        display: none;
        position: absolute;
        inset: 0;
        align-items: center;
        justify-content: center;
        background: #ececec;
        color: #7b7b7b;
        font-size: 15px;
        font-weight: 700;
        letter-spacing: 0.04em;
      }
      .market-media-failed .market-media-fallback {
        display: flex;
      }
      .detail-media {
        border: none;
        background: rgba(0, 0, 0, 0.02);
      }
      .detail-media-label {
        padding: 12px 14px 0;
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        color: var(--accent-soft);
      }
      .detail-media img {
        display: block;
        width: 100%;
        aspect-ratio: 1.45 / 1;
        object-fit: cover;
        padding: 12px;
        border-radius: 22px;
      }
      .hero-placeholder {
        aspect-ratio: 1.8 / 1;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 10px;
        background: var(--page-bg);
        border: 1px solid rgba(0, 0, 0, 0.04);
      }
      .hero-icon {
        font-size: 52px;
        line-height: 1;
      }
      .hero-label {
        font-size: 14px;
        font-weight: 700;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        color: var(--accent-soft);
      }
      h1 {
        margin: 10px 0 12px;
        font-size: clamp(28px, 4vw, 40px);
        line-height: 1.08;
      }
      p {
        margin: 0 0 18px;
        color: var(--muted);
        font-size: 15px;
        line-height: 1.6;
      }
      .button {
        display: inline-block;
        min-width: 180px;
        text-align: center;
        background: var(--accent);
        color: white;
        text-decoration: none;
        border-radius: 14px;
        padding: 13px 18px;
        font-weight: 700;
      }
      .secondary-button {
        display: inline-block;
        min-width: 180px;
        text-align: center;
        background: rgba(0, 0, 0, 0.05);
        color: var(--text);
        text-decoration: none;
        border-radius: 14px;
        padding: 13px 18px;
        font-weight: 700;
      }
      .lead-copy {
        margin-bottom: 14px;
      }
      .chip-row {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        margin-bottom: 16px;
      }
      .chip {
        display: inline-flex;
        align-items: center;
        padding: 8px 10px;
        border-radius: 999px;
        background: rgba(0, 0, 0, 0.05);
        color: #3f3a33;
        font-size: 13px;
        font-weight: 600;
      }
      .detail-card,
      .section-surface {
        margin-bottom: 0;
      }
      .market-header-card h1 {
        margin-top: 0;
        margin-bottom: 10px;
        font-size: 24px;
        line-height: 1.18;
      }
      .category-pill {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 7px 12px;
        border-radius: 999px;
        background: rgba(255, 255, 255, 0.94);
        color: #9b7a1f;
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.04em;
      }
      .category-pill-overlay {
        position: absolute;
        top: 14px;
        left: 14px;
        box-shadow: 0 8px 18px rgba(0, 0, 0, 0.08);
      }
      .price-line {
        margin-bottom: 12px;
        font-size: 30px;
        line-height: 1;
        font-weight: 800;
        color: #d3a12a;
      }
      .meta-inline {
        font-size: 13px;
        color: var(--muted);
      }
      .cta-row {
        display: flex;
        align-items: center;
        gap: 10px;
      }
      .top-pill-row {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: 8px;
        margin-bottom: 10px;
      }
      .status-pill {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 7px 12px;
        border-radius: 999px;
        background: rgba(17, 24, 39, 0.92);
        color: #fff;
        font-size: 12px;
        font-weight: 700;
      }
      .subtle-pill {
        background: rgba(0, 0, 0, 0.06);
        color: var(--muted);
      }
      .subtle {
        margin-top: 14px;
        font-size: 13px;
      }
      .description-inline {
        margin-bottom: 14px;
        color: var(--muted);
        font-size: 15px;
        line-height: 1.65;
      }
      .info-stack {
        display: flex;
        flex-direction: column;
        gap: 10px;
      }
      .info-row {
        display: flex;
        align-items: flex-start;
        gap: 10px;
        color: var(--text);
        font-size: 14px;
        line-height: 1.5;
      }
      .info-icon {
        width: 18px;
        flex-shrink: 0;
        text-align: center;
      }
      .section-card {
        margin-top: 16px;
        padding: 16px;
        border-radius: 18px;
        background: rgba(0, 0, 0, 0.03);
        border: none;
      }
      .section-title {
        margin-bottom: 12px;
        font-size: 13px;
        font-weight: 800;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        color: var(--accent-soft);
      }
      .detail-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 12px;
      }
      .detail-item {
        padding: 12px;
        border-radius: 14px;
        background: #f8f6f1;
      }
      .detail-label {
        margin-bottom: 6px;
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 0.05em;
        text-transform: uppercase;
        color: var(--muted);
      }
      .detail-value {
        font-size: 15px;
        font-weight: 700;
        color: var(--text);
      }
      .body-copy {
        margin: 0;
        white-space: pre-wrap;
      }
      .description-block {
        min-height: 88px;
        padding: 14px;
        border-radius: 16px;
        background: #f8f6f1;
        color: var(--muted);
        font-size: 15px;
        line-height: 1.65;
        white-space: pre-wrap;
      }
      .seller-row {
        display: flex;
        align-items: center;
        gap: 12px;
      }
      .seller-row-compact {
        margin-bottom: 12px;
      }
      .seller-avatar {
        width: 44px;
        height: 44px;
        flex-shrink: 0;
        border-radius: 999px;
        overflow: hidden;
        background: rgba(0, 0, 0, 0.06);
      }
      .seller-avatar img,
      .seller-avatar-fallback {
        width: 100%;
        height: 100%;
      }
      .seller-avatar img {
        display: block;
        object-fit: cover;
      }
      .seller-avatar-fallback {
        display: grid;
        place-items: center;
        background: linear-gradient(180deg, #ffe59a 0%, #f1c54d 100%);
        color: #3b2f12;
        font-weight: 800;
      }
      .seller-copy {
        min-width: 0;
        flex: 1;
      }
      .seller-name {
        font-size: 15px;
        font-weight: 700;
        color: var(--text);
      }
      .seller-caption {
        margin-top: 4px;
        font-size: 12px;
        color: var(--muted);
      }
      .seller-chevron {
        flex-shrink: 0;
        color: var(--muted);
        font-size: 18px;
        line-height: 1;
      }
      .full-width-button {
        display: block;
        width: 100%;
      }
      .sticky-open-bar {
        position: fixed;
        left: 50%;
        bottom: calc(env(safe-area-inset-bottom, 0px) + 12px);
        transform: translate3d(-50%, 0, 0);
        width: min(calc(100vw - 32px), 460px);
        max-width: calc(100vw - 32px);
        z-index: 40;
        margin-top: 0;
        padding: 12px;
        border-radius: 20px;
        background: rgba(255,255,255,0.98);
        border: none;
        box-shadow: none;
        will-change: transform;
      }
      .sticky-open-button {
        display: block;
        width: 100%;
        min-width: 100%;
      }
      .download-card {
        padding: 22px 18px;
      }
      .open-flow-card {
        position: relative;
      }
      .open-state {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        margin: 10px 0 6px;
        padding: 7px 12px;
        border-radius: 999px;
        background: #f3ead0;
        color: #7d6220;
        font-size: 12px;
        font-weight: 800;
        letter-spacing: 0.03em;
      }
      body[data-open-state="opening"] .open-state {
        background: #e7efff;
        color: #1d4ed8;
      }
      body[data-open-state="wechat-ready"] .open-state {
        background: #e8f7ec;
        color: #17803d;
      }
      body[data-open-state="opened"] .open-state {
        background: #e7f7ef;
        color: #0f8f53;
      }
      .wechat-open-tag-card {
        margin-bottom: 12px;
        padding: 14px;
        border-radius: 18px;
        background: #f8f6f1;
      }
      .wechat-open-copy {
        margin: 0 0 12px;
      }
      .wechat-open-tag-host {
        width: 100%;
      }
      .wechat-open-tag-host wx-open-launch-app {
        display: block;
        width: 100%;
      }
      .wechat-help-card {
        margin-top: 14px;
        margin-bottom: 8px;
        padding: 14px;
        border-radius: 18px;
        background: #f8f6f1;
      }
      .is-hidden {
        display: none !important;
      }
      .helper-steps {
        display: flex;
        flex-direction: column;
        gap: 10px;
        margin-bottom: 12px;
      }
      .helper-step {
        display: flex;
        align-items: flex-start;
        gap: 10px;
        color: var(--text);
        font-size: 14px;
        line-height: 1.5;
      }
      .helper-index {
        width: 22px;
        height: 22px;
        flex-shrink: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        background: #efe1a9;
        color: #6e5714;
        font-size: 12px;
        font-weight: 800;
      }
      .copy-link-button {
        appearance: none;
        border: none;
        cursor: pointer;
        font: inherit;
      }
      .download-actions {
        display: flex;
        flex-direction: column;
        gap: 10px;
      }
      .open-in-app-card .subtle {
        margin-bottom: 0;
      }
      .compact-meta {
        margin-top: 16px;
      }
      .seller-link {
        display: block;
        color: inherit;
        text-decoration: none;
      }
      .progress-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        margin-bottom: 10px;
        color: var(--muted);
        font-size: 13px;
        font-weight: 700;
      }
      .progress-header strong {
        color: var(--text);
        font-size: 14px;
      }
      .progress-track {
        width: 100%;
        height: 12px;
        border-radius: 999px;
        background: #ece7db;
        overflow: hidden;
      }
      .progress-fill {
        height: 100%;
        border-radius: inherit;
        background: linear-gradient(90deg, #f0c85a 0%, #84c6a7 100%);
      }
      .forum-content-block {
        margin-top: 6px;
        min-height: 0;
        padding: 0;
        background: transparent;
        color: var(--text);
        line-height: 1.72;
      }
      .forum-header-card {
        padding-bottom: 12px;
      }
      .forum-post-card h1 {
        margin-top: 0;
        margin-bottom: 14px;
        font-size: 24px;
        line-height: 1.2;
      }
      .forum-image-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 10px;
        margin-top: 14px;
      }
      .forum-image-grid-single {
        grid-template-columns: minmax(0, 1fr);
      }
      .forum-image-card {
        width: 100%;
        aspect-ratio: 1.28 / 1;
        border-radius: 16px;
        overflow: hidden;
        background: rgba(0, 0, 0, 0.06);
      }
      .forum-image-grid-single .forum-image-card {
        aspect-ratio: 1.24 / 1;
      }
      .forum-image-card img {
        width: 100%;
        height: 100%;
        display: block;
        object-fit: cover;
      }
      .forum-stat-row {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        margin-top: 14px;
        padding-top: 14px;
        border-top: 1px solid rgba(0, 0, 0, 0.06);
      }
      .forum-stat {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 8px 10px;
        border-radius: 999px;
        background: #f8f6f1;
        color: var(--muted);
        font-size: 13px;
        font-weight: 700;
      }
      .meta {
        margin-top: 20px;
        padding-top: 16px;
        border-top: 1px solid rgba(0, 0, 0, 0.06);
        display: flex;
        flex-direction: column;
        gap: 8px;
      }
      .meta span {
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        color: var(--accent-soft);
      }
      code {
        display: inline-block;
        padding: 10px 12px;
        border-radius: 12px;
        background: rgba(0, 0, 0, 0.04);
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 12px;
        color: var(--text);
        word-break: break-all;
      }
`;
