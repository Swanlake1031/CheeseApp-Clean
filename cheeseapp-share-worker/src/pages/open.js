import { escapeHTML } from "../utils/format.js";

export function renderOpenGuidance({ deepLinkURL }) {
  return `
    <section class="wechat-intercept-alert" role="alert">
      <div class="wechat-alert-heading">
        <span class="wechat-alert-icon">!</span>
        <div>
          <div class="wechat-alert-kicker">如果你正在使用微信</div>
          <div class="wechat-alert-title">请点击右上角「···」</div>
        </div>
      </div>
      <p>选择「在浏览器中打开」，然后再打开 Cheese。</p>
      <div class="wechat-browser-instruction">
        <strong>···</strong>
        <span>在浏览器中打开</span>
      </div>
      <div class="download-actions wechat-open-actions">
        <a class="button full-width-button" href="${escapeHTML(deepLinkURL)}">打开 Cheese</a>
      </div>
    </section>
  `;
}
