import { privacyCopy } from "./legalContent.js";
import { pageShell } from "../ui/shell.js";
import { escapeHTML } from "../utils/format.js";

const CANONICAL_ORIGIN = "https://cheeseapp.org";
const SUPPORT_EMAIL = "support.cheeseteam@gmail.com";

const supportSections = [
  {
    id: "account-login",
    icon: "🔐",
    chineseTitle: "账号与登录",
    englishTitle: "Account & Login",
    chineseItems: ["登录或验证码问题", "修改个人资料", "账号安全", "删除账号"],
    englishItems: [
      "Sign-in or verification-code issues",
      "Update your profile",
      "Account security",
      "Delete your account"
    ]
  },
  {
    id: "campus-community",
    icon: "💬",
    chineseTitle: "校园社区",
    englishTitle: "Campus Community",
    chineseItems: [
      "发布、编辑或删除帖子",
      "评论与互动",
      "举报不当内容或用户"
    ],
    englishItems: [
      "Create, edit, or delete posts",
      "Comments and interactions",
      "Report inappropriate content or users"
    ]
  },
  {
    id: "marketplace",
    icon: "🛍️",
    chineseTitle: "二手市场",
    englishTitle: "Marketplace",
    chineseItems: [
      "发布或编辑商品",
      "联系卖家",
      "举报可疑或违规商品"
    ],
    englishItems: [
      "Create or edit a listing",
      "Contact a seller",
      "Report suspicious or prohibited listings"
    ],
    chineseDisclaimer:
      "CheeseApp 仅提供用户浏览刊登信息和相互沟通的平台，不直接参与交易、付款、配送或履约。",
    englishDisclaimer:
      "CheeseApp provides a platform for users to discover listings and communicate with each other. CheeseApp does not directly participate in transactions, payments, delivery, or fulfillment."
  },
  {
    id: "chat-messaging",
    icon: "✉️",
    chineseTitle: "聊天与消息",
    englishTitle: "Chat & Messaging",
    chineseItems: [
      "私聊或群聊问题",
      "消息发送异常",
      "举报骚扰或不当内容"
    ],
    englishItems: [
      "Direct or group chat issues",
      "Message delivery problems",
      "Report harassment or inappropriate content"
    ]
  },
  {
    id: "privacy-safety",
    icon: "🛡️",
    chineseTitle: "隐私与安全",
    englishTitle: "Privacy & Safety",
    chineseItems: [
      "隐私相关问题",
      "内容举报",
      "账号与数据删除请求"
    ],
    englishItems: [
      "Privacy questions",
      "Content reports",
      "Account and data deletion requests"
    ]
  }
];

export function renderLegalPage(kind, options = {}) {
  return kind === "privacy"
    ? renderPrivacyPage()
    : renderSupportPage(options);
}

function renderPrivacyPage() {
  const body = privacyCopy
    .map(
      (row) =>
        `<section class="legal-section"><p lang="en">${escapeHTML(row.english)}</p><p lang="zh-Hans">${escapeHTML(row.chinese)}</p></section>`
    )
    .join("");

  return pageShell({
    title: "Privacy Policy · 隐私政策",
    description: "CheeseApp 隐私政策与资料处理说明。",
    metaTitle: "Privacy Policy · 隐私政策 | CheeseApp",
    metaDescription:
      "CheeseApp 隐私政策与资料处理说明，涵盖帐号、社群、二手市场、聊天和安全。",
    canonicalURL: `${CANONICAL_ORIGIN}/privacy`,
    appName: "CheeseApp",
    robots: "index, follow",
    pageClass: "legal-page-shell",
    footerExtraLinks: [
      {
        href: "https://developers.cloudflare.com/workers-ai/platform/data-usage/",
        label: "Cloudflare Workers AI data use",
        external: true
      }
    ],
    body: `
      <article class="card legal-card legal-page">
        <div class="eyebrow">CheeseApp</div>
        <h1>Privacy Policy · 隐私政策</h1>
        ${body}
      </article>
    `
  });
}

function renderSupportPage({ language = "zh" } = {}) {
  const normalizedLanguage = String(language).toLowerCase() === "en" ? "en" : "zh";
  const isEnglish = normalizedLanguage === "en";
  const metaTitle = isEnglish ? "CheeseApp Support" : "奶酪帮助与支持 | CheeseApp";
  const metaDescription = isEnglish
    ? "Get help with CheeseApp account access, campus community, marketplace, chat, privacy, and safety."
    : "获取 CheeseApp 账号、校园社区、二手市场、聊天、隐私与安全方面的帮助与支持。";

  return pageShell({
    title: "奶酪帮助与支持",
    description: metaDescription,
    metaTitle,
    metaDescription,
    canonicalURL: `${CANONICAL_ORIGIN}/support`,
    appName: "CheeseApp",
    robots: "index, follow",
    lang: isEnglish ? "en" : "zh-CN",
    pageClass: "support-page-shell",
    footerTerms: true,
    body: `
      <main class="support-page" aria-labelledby="support-title">
        <section class="card support-hero">
          <div class="eyebrow">CheeseApp Support</div>
          <h1 id="support-title">
            <span lang="zh-CN">奶酪帮助与支持</span>
            <span class="support-hero-title-en" lang="en">CheeseApp Support</span>
          </h1>
          <p class="support-subtitle">遇到问题？我们会尽力帮你解决。</p>
          <p class="support-subtitle support-subtitle-en">Need help? We’re here to help.</p>
          <nav class="support-language-links" aria-label="Language / 语言">
            <a class="${isEnglish ? "" : "is-active"}" href="/support?lang=zh" lang="zh-CN"${isEnglish ? "" : ' aria-current="page"'}>中文</a>
            <a class="${isEnglish ? "is-active" : ""}" href="/support?lang=en" lang="en"${isEnglish ? ' aria-current="page"' : ""}>English</a>
          </nav>
          <div class="support-hero-actions">
            <a class="button" href="#contact">联系我们 / Contact Us</a>
          </div>
        </section>

        <div class="support-section-grid">
          ${supportSections.map(renderSupportSection).join("")}
        </div>

        <section id="contact" class="card support-contact" aria-labelledby="support-contact-title">
          <div>
            <div class="eyebrow">Contact Us · 联系我们</div>
            <h2 id="support-contact-title">联系我们</h2>
            <p class="support-contact-copy" lang="zh-CN">如果以上内容没有解决你的问题，请联系我们。</p>
            <p class="support-contact-copy" lang="en">If you still need help, contact us at:</p>
          </div>
          <a class="support-contact-email" href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>
        </section>
      </main>
    `
  });
}

function renderSupportSection(section) {
  const chineseItems = section.chineseItems
    .map((item) => `<li lang="zh-CN">${escapeHTML(item)}</li>`)
    .join("");
  const englishItems = section.englishItems
    .map((item) => `<li lang="en">${escapeHTML(item)}</li>`)
    .join("");
  const disclaimer = section.chineseDisclaimer
    ? `
        <div class="support-disclaimer">
          <p lang="zh-CN">${escapeHTML(section.chineseDisclaimer)}</p>
          <p lang="en">${escapeHTML(section.englishDisclaimer)}</p>
        </div>
      `
    : "";

  return `
    <section class="card support-section-card" aria-labelledby="support-${section.id}">
      <div class="support-section-heading">
        <span class="support-section-icon" aria-hidden="true">${section.icon}</span>
        <h2 id="support-${section.id}">
          <span lang="zh-CN">${escapeHTML(section.chineseTitle)}</span>
          <span class="support-title-en" lang="en">${escapeHTML(section.englishTitle)}</span>
        </h2>
      </div>
      <div class="support-copy-pair">
        <ul class="support-list">${chineseItems}</ul>
        <ul class="support-list support-list-en">${englishItems}</ul>
      </div>
      ${disclaimer}
    </section>
  `;
}
