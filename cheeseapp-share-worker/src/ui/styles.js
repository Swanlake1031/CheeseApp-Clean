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
      .open-guidance {
        margin: 0 0 12px;
        padding: 18px;
        border-radius: 22px;
        color: #4f2c00;
        background: linear-gradient(145deg, #ffd86b 0%, #ffedb4 100%);
        box-shadow: 0 12px 28px rgba(122, 57, 0, 0.18);
      }
      .open-guidance-heading {
        display: flex;
        align-items: center;
        gap: 12px;
      }
      .open-guidance-icon {
        width: 42px;
        height: 42px;
        flex: 0 0 42px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 14px;
        color: #ffffff;
        background: #a83f00;
        font-size: 26px;
        font-weight: 900;
      }
      .open-guidance-kicker {
        margin-bottom: 2px;
        color: #8a4b00;
        font-size: 12px;
        font-weight: 900;
        letter-spacing: 0.06em;
      }
      .open-guidance-title {
        color: #2f1b00;
        font-size: 21px;
        font-weight: 900;
        line-height: 1.2;
      }
      .open-guidance p {
        margin: 14px 0 12px;
        font-size: 15px;
        font-weight: 650;
        line-height: 1.55;
      }
      .open-guidance-actions {
        margin-top: 14px;
      }
      .is-hidden {
        display: none !important;
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
      .page.support-page-shell,
      .page.legal-page-shell {
        max-width: 960px;
      }
      .support-page,
      .legal-page {
        display: flex;
        flex-direction: column;
        gap: 16px;
      }
      .support-hero {
        padding: 28px;
        background: linear-gradient(145deg, #fff7d8 0%, #ffffff 72%);
      }
      .support-hero h1 {
        margin: 10px 0 8px;
        font-size: clamp(30px, 5vw, 46px);
      }
      .support-hero .support-hero-title-en {
        display: block;
        margin-top: 6px;
        color: var(--muted);
        font-size: clamp(20px, 3vw, 28px);
        font-weight: 650;
      }
      .support-hero .support-subtitle {
        margin: 0;
        color: var(--text);
        font-size: 18px;
        font-weight: 650;
      }
      .support-hero .support-subtitle-en {
        margin-top: 4px;
        color: var(--muted);
        font-size: 15px;
        font-weight: 500;
      }
      .support-language-links {
        display: inline-flex;
        gap: 5px;
        margin-top: 18px;
        padding: 4px;
        border-radius: 999px;
        background: rgba(0, 0, 0, 0.05);
      }
      .support-language-links a {
        display: inline-flex;
        align-items: center;
        min-height: 30px;
        padding: 5px 11px;
        border-radius: 999px;
        color: var(--muted);
        font-size: 12px;
        font-weight: 750;
        text-decoration: none;
      }
      .support-language-links a:hover,
      .support-language-links a:focus-visible,
      .support-language-links a.is-active {
        background: #ffffff;
        color: var(--text);
      }
      .support-hero-actions {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        margin-top: 22px;
      }
      .support-hero-actions .button {
        min-width: 0;
      }
      .support-section-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 16px;
      }
      .support-section-card {
        min-width: 0;
        padding: 22px;
      }
      .support-section-heading {
        display: flex;
        align-items: flex-start;
        gap: 12px;
        margin-bottom: 16px;
      }
      .support-section-icon {
        display: inline-flex;
        width: 38px;
        height: 38px;
        flex: 0 0 38px;
        align-items: center;
        justify-content: center;
        border-radius: 13px;
        background: #fff2be;
        font-size: 20px;
      }
      .support-section-heading h2 {
        margin: 0;
        color: var(--text);
        font-size: 20px;
        line-height: 1.2;
      }
      .support-section-heading .support-title-en {
        display: block;
        margin-top: 5px;
        color: var(--muted);
        font-size: 14px;
        font-weight: 600;
      }
      .support-copy-pair {
        display: grid;
        gap: 12px;
      }
      .support-list {
        margin: 0;
        padding-left: 21px;
        color: var(--text);
        font-size: 15px;
        line-height: 1.6;
      }
      .support-list li + li {
        margin-top: 7px;
      }
      .support-list-en {
        color: var(--muted);
      }
      .support-disclaimer {
        margin-top: 16px;
        padding: 13px 14px;
        border-radius: 14px;
        background: #fff8df;
        color: #5d4d27;
        font-size: 14px;
        line-height: 1.6;
      }
      .support-disclaimer p {
        margin: 0;
        color: inherit;
        font-size: inherit;
      }
      .support-disclaimer p + p {
        margin-top: 8px;
        color: #746341;
      }
      .support-contact {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-end;
        justify-content: space-between;
        gap: 18px;
        padding: 24px 28px;
      }
      .support-contact h2 {
        margin: 8px 0 6px;
        font-size: 24px;
      }
      .support-contact-copy {
        max-width: 620px;
        margin: 0;
      }
      .support-contact-email {
        display: inline-flex;
        align-items: center;
        min-height: 46px;
        padding: 12px 16px;
        border-radius: 14px;
        background: var(--accent);
        color: #ffffff;
        font-size: 15px;
        font-weight: 750;
        text-decoration: none;
        white-space: nowrap;
      }
      .legal-card {
        padding: 28px;
      }
      .legal-card h1 {
        margin-top: 0;
      }
      .legal-section {
        padding: 17px 0;
        border-top: 1px solid rgba(0, 0, 0, 0.07);
      }
      .legal-section:first-of-type {
        padding-top: 0;
        border-top: 0;
      }
      .legal-section p {
        margin: 0;
      }
      .legal-section p + p {
        margin-top: 9px;
        color: var(--muted);
      }
      .site-footer {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: center;
        gap: 7px 12px;
        margin: 18px auto 0;
        padding: 4px 8px;
        color: var(--muted);
        font-size: 12px;
        line-height: 1.5;
        text-align: center;
      }
      .site-footer a,
      .site-footer-link {
        color: inherit;
        text-decoration: none;
      }
      .site-footer a:hover,
      .site-footer a:focus-visible {
        color: var(--text);
        text-decoration: underline;
      }
      .site-footer-link-disabled {
        cursor: default;
        opacity: 0.9;
      }
      .site-footer-link-disabled small {
        color: var(--accent-soft);
        font-size: 10px;
        font-weight: 700;
        letter-spacing: 0.04em;
        text-transform: uppercase;
      }
      .site-footer-separator {
        color: rgba(107, 99, 88, 0.55);
      }
      @media (max-width: 680px) {
        .page.support-page-shell,
        .page.legal-page-shell {
          max-width: 100%;
        }
        .support-hero,
        .support-contact,
        .legal-card {
          padding: 22px 18px;
        }
        .support-section-grid {
          grid-template-columns: minmax(0, 1fr);
        }
        .support-section-card {
          padding: 19px 18px;
        }
        .support-contact {
          align-items: stretch;
        }
        .support-contact-email {
          width: 100%;
          justify-content: center;
          white-space: normal;
          text-align: center;
        }
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
