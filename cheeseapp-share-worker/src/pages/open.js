import { escapeHTML } from "../utils/format.js";

export function renderOpenGuidance({ deepLinkURL }) {
  return `
    <section class="open-guidance" role="status">
      <div class="open-guidance-heading">
        <span class="open-guidance-icon">↗</span>
        <div>
          <div class="open-guidance-kicker">Cheese</div>
          <div class="open-guidance-title">在 App 中继续</div>
        </div>
      </div>
      <p>如果 Cheese 没有自动打开，请使用下方按钮继续。</p>
      <div class="download-actions open-guidance-actions">
        <a class="button full-width-button" href="${escapeHTML(deepLinkURL)}">打开 Cheese</a>
      </div>
    </section>
  `;
}
