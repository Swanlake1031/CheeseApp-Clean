import { escapeHTML, kindDisplayLabel } from "../utils/format.js";
import { pageShell } from "../ui/shell.js";

export function renderOpenAppPage({ config, kind, postID }) {
  const canonicalURL = `https://${config.canonicalHost}/posts/${kind}/${postID}`;
  const universalOpenURL = `https://${config.canonicalHost}/open/${kind}/${postID}?launch=1`;
  const deepLinkURL = `${config.appScheme}/${kind}/${postID}`;
  const openButtonText = "繼續打開 Cheese";
  const fallbackButtonText =
    config.appDownloadURL === `https://${config.canonicalHost}/`
      ? "返回 Cheese 網頁"
      : "下載 Cheese";
  const hasWeChatOpenApp =
    Boolean(config.wechatOpenAppID) && Boolean(config.wechatJSSDKConfigURL);
  const wechatSDKScript = hasWeChatOpenApp
    ? `<script src="https://res.wx.qq.com/open/js/jweixin-1.6.0.js"></script>`
    : "";

  return pageShell({
    title: "打開 Cheese App",
    description: `正在為你打開 Cheese App 中的${kindDisplayLabel(kind)}內容。`,
    canonicalURL,
    previewImageURL: "",
    deepLinkURL,
    appName: config.siteName,
    body: `
      <div class="app-banner app-banner-compact">
        <div class="app-banner-brand">
          <div class="app-icon">🧀</div>
          <div>
            <div class="app-name">${escapeHTML(config.siteName)}</div>
            <div class="app-subtitle" id="open-page-subtitle">正在準備打開 App…</div>
          </div>
        </div>
      </div>
      <div class="card download-card open-flow-card" id="open-flow-card">
        <div class="eyebrow">Cheese App</div>
        <div class="open-state" id="open-state-chip">正在準備</div>
        <h1 id="open-page-title">正在打開 Cheese</h1>
        <p class="lead-copy" id="open-page-copy">如果你的手機已安裝 Cheese，我們會嘗試為你直接打開這篇內容。</p>
        <div class="wechat-open-tag-card is-hidden" id="wechat-open-tag-card">
          <div class="section-title">微信內快速打開</div>
          <p class="subtle wechat-open-copy">如果微信支援官方喚起能力，請優先使用下面這個按鈕。</p>
          <div class="wechat-open-tag-host" id="wechat-open-tag-host"></div>
        </div>
        <div class="download-actions">
          <a class="button full-width-button" id="open-cheese-now" href="${escapeHTML(universalOpenURL)}">${openButtonText}</a>
          <a class="secondary-button full-width-button" href="${escapeHTML(canonicalURL)}">返回貼文頁面</a>
        </div>
        <div class="wechat-help-card is-hidden" id="wechat-help-card" aria-live="polite">
          <div class="section-title">微信內打開提示</div>
          <div class="helper-steps">
            <div class="helper-step"><span class="helper-index">1</span><span>先點一次「${openButtonText}」</span></div>
            <div class="helper-step"><span class="helper-index">2</span><span>如果微信沒有彈提示，請點右上角「···」</span></div>
            <div class="helper-step"><span class="helper-index">3</span><span>選擇「在瀏覽器中打開」後再進 Cheese</span></div>
          </div>
          <button class="secondary-button full-width-button copy-link-button" id="copy-link-button" type="button">複製貼文連結</button>
        </div>
        <p class="subtle" id="open-cheese-help">
          若未成功打開，請再點一次「${openButtonText}」；
          若你正在微信內，可嘗試右上角「···」後選擇在瀏覽器中打開。
        </p>
        <div class="meta compact-meta">
          <span>內容類型</span>
          <code>${escapeHTML(kindDisplayLabel(kind))}</code>
        </div>
        <div class="download-actions">
          <a class="secondary-button full-width-button" href="${escapeHTML(config.appDownloadURL)}">${escapeHTML(fallbackButtonText)}</a>
        </div>
      </div>
      ${wechatSDKScript}
      <script>
        (() => {
          const deepLinkURL = ${JSON.stringify(deepLinkURL)};
          const canonicalURL = ${JSON.stringify(canonicalURL)};
          const universalOpenURL = ${JSON.stringify(universalOpenURL)};
          const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
          const inWeChat = /MicroMessenger/i.test(navigator.userAgent);
          const launchRequested = new URL(window.location.href).searchParams.get("launch") === "1";
          const wechatOpenAppID = ${JSON.stringify(config.wechatOpenAppID || "")};
          const wechatJSSDKConfigURL = ${JSON.stringify(config.wechatJSSDKConfigURL || "")};
          const hasWeChatOpenApp = Boolean(wechatOpenAppID && wechatJSSDKConfigURL);
          const openButton = document.getElementById("open-cheese-now");
          const copyLinkButton = document.getElementById("copy-link-button");
          const helpCard = document.getElementById("wechat-help-card");
          const openTagCard = document.getElementById("wechat-open-tag-card");
          const openTagHost = document.getElementById("wechat-open-tag-host");
          const subtitle = document.getElementById("open-page-subtitle");
          const title = document.getElementById("open-page-title");
          const copy = document.getElementById("open-page-copy");
          const stateChip = document.getElementById("open-state-chip");
          const helpText = document.getElementById("open-cheese-help");
          let openAttempted = false;
          let stillVisibleTimer = null;

          function setOpenState(state) {
            if (!stateChip || !title || !copy || !subtitle) {
              return;
            }

            document.body.dataset.openState = state;

            if (state === "opening") {
              stateChip.textContent = inWeChat ? "正在請求微信打開" : "正在打開";
              title.textContent = inWeChat ? "正在嘗試喚起 Cheese" : "正在打開 Cheese";
              copy.textContent = inWeChat
                ? "如果微信允許跳轉，稍後會直接帶你回到 Cheese App。"
                : "如果你的手機已安裝 Cheese，我們會直接為你打開這篇內容。";
              subtitle.textContent = inWeChat ? "等待微信響應…" : "正在打開 App…";
              if (openButton) {
                openButton.textContent = "正在嘗試打開…";
              }
            } else if (state === "wechat-ready") {
              stateChip.textContent = "微信官方打開已就緒";
              title.textContent = "可直接從微信打開 Cheese";
              copy.textContent = "請優先點擊上方的微信專用打開按鈕，微信更容易識別這是一次正式的 App 喚起。";
              subtitle.textContent = "等待你在微信內確認";
              if (openTagCard) {
                openTagCard.classList.remove("is-hidden");
              }
            } else if (state === "fallback") {
              stateChip.textContent = "需要你手動下一步";
              title.textContent = "還沒有成功打開 Cheese";
              copy.textContent = inWeChat
                ? "微信有時不會直接彈出打開提示，請按下方步驟繼續。"
                : "如果沒有成功打開，你可以再試一次，或回到貼文頁。";
              subtitle.textContent = inWeChat ? "微信內打開需要一步確認" : "等待你再次操作";
              if (openButton) {
                openButton.textContent = "${openButtonText}";
              }
              if (helpCard) {
                helpCard.classList.remove("is-hidden");
              }
              if (openTagCard && !hasWeChatOpenApp) {
                openTagCard.classList.add("is-hidden");
              }
            } else if (state === "opened") {
              stateChip.textContent = "已切換到 App";
              subtitle.textContent = "正在返回 Cheese…";
            }
          }

          function tryOpenApp() {
            if (stillVisibleTimer) {
              clearTimeout(stillVisibleTimer);
            }

            openAttempted = true;
            setOpenState("opening");

            if (inWeChat) {
              window.location.href = universalOpenURL;
            } else {
              const iframe = document.createElement("iframe");
              iframe.style.display = "none";
              iframe.src = deepLinkURL;
              document.body.appendChild(iframe);
              setTimeout(() => iframe.remove(), 800);

              setTimeout(() => {
                window.location.href = deepLinkURL;
              }, 40);
            }

            stillVisibleTimer = setTimeout(() => {
              if (document.visibilityState === "visible") {
                setOpenState("fallback");
              }
            }, inWeChat ? 1100 : 700);
          }

          async function initializeWeChatOpenTag() {
            if (!inWeChat || !hasWeChatOpenApp || !window.wx || !openTagCard || !openTagHost) {
              return false;
            }

            try {
              const configURL = new URL(wechatJSSDKConfigURL, window.location.origin);
              configURL.searchParams.set("url", window.location.href.split("#")[0]);
              const response = await fetch(configURL.toString(), { credentials: "omit" });
              if (!response.ok) {
                throw new Error("wechat config request failed");
              }

              const payload = await response.json();
              if (!payload || !payload.appId || !payload.timestamp || !payload.nonceStr || !payload.signature) {
                throw new Error("wechat config payload incomplete");
              }

              openTagHost.innerHTML = \`
                <wx-open-launch-app appid="\${wechatOpenAppID}" extinfo="\${canonicalURL}">
                  <script type="text/wxtag-template">
                    <style>
                      .wx-open-launch-btn {
                        width: 100%;
                        border: 0;
                        border-radius: 14px;
                        background: #1d4ed8;
                        color: #fff;
                        padding: 14px 16px;
                        font-size: 16px;
                        font-weight: 800;
                        text-align: center;
                      }
                    </style>
                    <button class="wx-open-launch-btn">在微信中打開 Cheese</button>
                  <\\/script>
                </wx-open-launch-app>
              \`;

              window.wx.config({
                debug: false,
                appId: payload.appId,
                timestamp: Number(payload.timestamp),
                nonceStr: payload.nonceStr,
                signature: payload.signature,
                jsApiList: ["updateAppMessageShareData"],
                openTagList: ["wx-open-launch-app"]
              });

              window.wx.ready(() => {
                setOpenState("wechat-ready");
              });

              window.wx.error(() => {
                setOpenState("fallback");
              });

              return true;
            } catch (error) {
              console.error("Failed to initialize WeChat open tag", error);
              setOpenState("fallback");
              return false;
            }
          }

          async function copyCanonicalLink() {
            try {
              if (navigator.clipboard?.writeText) {
                await navigator.clipboard.writeText(canonicalURL);
              } else {
                const input = document.createElement("input");
                input.value = canonicalURL;
                document.body.appendChild(input);
                input.select();
                document.execCommand("copy");
                input.remove();
              }
              if (copyLinkButton) {
                copyLinkButton.textContent = "已複製連結";
                setTimeout(() => {
                  copyLinkButton.textContent = "複製貼文連結";
                }, 1400);
              }
            } catch {
              if (helpText) {
                helpText.textContent = "複製失敗，請直接在微信右上角選擇在瀏覽器中打開。";
              }
            }
          }

          if (openButton) {
            openButton.addEventListener("click", (event) => {
              if (inWeChat) {
                setOpenState("opening");
                return;
              }
              event.preventDefault();
              tryOpenApp();
            });
          }

          if (copyLinkButton) {
            copyLinkButton.addEventListener("click", copyCanonicalLink);
          }

          document.addEventListener("visibilitychange", () => {
            if (document.visibilityState === "hidden" && openAttempted) {
              setOpenState("opened");
            }
          });

          if (isIOS && !inWeChat) {
            setTimeout(() => {
              tryOpenApp();
            }, 80);
          } else if (inWeChat) {
            if (!hasWeChatOpenApp) {
              setOpenState(launchRequested ? "fallback" : "opening");
            } else {
              initializeWeChatOpenTag().then((initialized) => {
                if (!initialized) {
                  setOpenState(launchRequested ? "fallback" : "opening");
                }
              });
            }
          }
        })();
      </script>
    `
  });
}
