type JSONValue =
  | string
  | number
  | boolean
  | null
  | { [key: string]: JSONValue }
  | JSONValue[];

type VerificationRequest = {
  action?: "status" | "send" | "verify" | "unlink";
  email?: string;
  code?: string;
};

type AuthUser = { id?: string };
type IssueResult = { status: string; retry_after_seconds: number };
type ConfirmResult = { status: string; remaining_attempts: number };
type UnlinkResult = { unlinked: boolean };
type VerificationRow = { email: string; verified_at: string; school_id: string };
type SchoolRow = {
  id: string;
  name: string;
  verification_domains: string[];
  badge_code: string | null;
};

const VERIFICATION_FROM = "CheeseApp Student Verification <verify@mail.cheeseapp.org>";
const encoder = new TextEncoder();

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function env(name: string): string {
  return Deno.env.get(name)?.trim() ?? "";
}

function requiredEnv(name: string): string {
  const value = env(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function jsonResponse(status: number, payload: Record<string, JSONValue>): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function normalizedEmail(raw: string | undefined): string {
  return (raw ?? "").trim().toLowerCase();
}

function maskEmail(email: string): string {
  const [local = "", domain = "mcmaster.ca"] = email.split("@", 2);
  if (local.length <= 2) return `${local.slice(0, 1)}***@${domain}`;
  return `${local.slice(0, 2)}${"*".repeat(Math.min(6, local.length - 2))}@${domain}`;
}

function projectURL(): string {
  return requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
}

function serviceRoleKey(): string {
  return requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
}

function serviceHeaders(extra: Record<string, string> = {}): HeadersInit {
  const key = serviceRoleKey();
  return {
    Authorization: `Bearer ${key}`,
    apikey: key,
    ...extra,
  };
}

async function parseResponse(response: Response): Promise<JSONValue | string | null> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text) as JSONValue;
  } catch {
    return text;
  }
}

async function authenticatedUser(req: Request): Promise<string | null> {
  const authorization = req.headers.get("authorization")?.trim() ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return null;

  const response = await fetch(`${projectURL()}/auth/v1/user`, {
    headers: {
      Authorization: authorization,
      apikey: serviceRoleKey(),
    },
  });
  if (!response.ok) return null;
  const user = (await response.json()) as AuthUser;
  return typeof user.id === "string" && user.id.length > 0 ? user.id : null;
}

async function callRPC<T>(name: string, body: Record<string, JSONValue>): Promise<T[]> {
  const response = await fetch(`${projectURL()}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders({
      "Content-Type": "application/json",
      Accept: "application/json",
    }),
    body: JSON.stringify(body),
  });
  const payload = await parseResponse(response);
  if (!response.ok) {
    throw new Error(`RPC ${name} failed with status ${response.status}`);
  }
  return Array.isArray(payload) ? payload as T[] : [];
}

async function verificationForUser(userID: string): Promise<VerificationRow | null> {
  const params = new URLSearchParams({
    select: "email,verified_at,school_id",
    user_id: `eq.${userID}`,
    limit: "1",
  });
  const response = await fetch(
    `${projectURL()}/rest/v1/mcmaster_student_verifications?${params.toString()}`,
    { headers: serviceHeaders({ Accept: "application/json" }) },
  );
  if (!response.ok) throw new Error(`Verification lookup failed with status ${response.status}`);
  const rows = await response.json() as VerificationRow[];
  return rows[0] ?? null;
}

async function selectedSchoolForUser(userID: string): Promise<SchoolRow | null> {
  const profileParams = new URLSearchParams({
    select: "school_id,profile_status",
    id: `eq.${userID}`,
    deactivated_at: "is.null",
    limit: "1",
  });
  const profileResponse = await fetch(
    `${projectURL()}/rest/v1/profiles?${profileParams.toString()}`,
    { headers: serviceHeaders({ Accept: "application/json" }) },
  );
  if (!profileResponse.ok) throw new Error(`Profile lookup failed with status ${profileResponse.status}`);
  const profiles = await profileResponse.json() as Array<{ school_id: string | null; profile_status: string }>;
  const profile = profiles[0];
  if (!profile || profile.profile_status !== "student" || !profile.school_id) return null;

  const schoolParams = new URLSearchParams({
    select: "id,name,verification_domains,badge_code",
    id: `eq.${profile.school_id}`,
    active: "eq.true",
    limit: "1",
  });
  const schoolResponse = await fetch(
    `${projectURL()}/rest/v1/schools?${schoolParams.toString()}`,
    { headers: serviceHeaders({ Accept: "application/json" }) },
  );
  if (!schoolResponse.ok) throw new Error(`School lookup failed with status ${schoolResponse.status}`);
  const schools = await schoolResponse.json() as SchoolRow[];
  const school = schools[0] ?? null;
  return school && school.verification_domains.length > 0 ? school : null;
}

async function verificationHash(userID: string, email: string, code: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(requiredEnv("MCMASTER_VERIFICATION_PEPPER")),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`${userID}:${email}:${code}`),
  );
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function generateCode(): string {
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  return String(bytes[0] % 1_000_000).padStart(6, "0");
}

function verificationEmailText(code: string, schoolName: string): string {
  return `CheeseApp ${schoolName} 学生认证验证码：${code}\n\n10 分钟内有效。如果不是你本人操作，请忽略。`;
}

async function emailIdempotencyKey(
  userID: string,
  email: string,
  codeHash: string,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(`mcmaster-verification:v1:${userID}:${email}:${codeHash}`),
  );
  const hex = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `mcmaster-verification-${hex}`;
}

async function sendVerificationEmail(
  email: string,
  code: string,
  idempotencyKey: string,
  schoolName: string,
): Promise<boolean> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${requiredEnv("RESEND_API_KEY")}`,
          "Content-Type": "application/json",
          "Idempotency-Key": idempotencyKey,
          "User-Agent": "CheeseApp-School-Verification/1.0",
        },
        signal: AbortSignal.timeout(10_000),
        body: JSON.stringify({
          from: VERIFICATION_FROM,
          to: [email],
          subject: `CheeseApp ${schoolName} 学生认证验证码`,
          text: verificationEmailText(code, schoolName),
        }),
      });
      return response.ok;
    } catch {
      if (attempt === 1) return false;
    }
  }
  return false;
}

function requestMessage(status: string, retryAfter: number): Response {
  switch (status) {
    case "cooldown":
      return jsonResponse(429, {
        error: `请等待 ${retryAfter} 秒后再重新发送。`,
        retry_after_seconds: retryAfter,
      });
    case "rate_limited":
      return jsonResponse(429, {
        error: "今天发送次数已达上限，请稍后再试。",
        retry_after_seconds: retryAfter,
      });
    case "already_verified":
      return jsonResponse(200, { verified: true, message: "该账号已完成学生认证。" });
    default:
      return jsonResponse(500, { error: "暂时无法发送验证码，请稍后再试。" });
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse(405, { error: "Method not allowed" });

  try {
    const userID = await authenticatedUser(req);
    if (!userID) return jsonResponse(401, { error: "登录状态已失效，请重新登录。" });

    let body: VerificationRequest;
    try {
      body = await req.json() as VerificationRequest;
    } catch {
      return jsonResponse(400, { error: "请求格式不正确。" });
    }

    const action = body.action ?? "status";
    const school = await selectedSchoolForUser(userID);
    if (action === "status") {
      const verification = await verificationForUser(userID);
      return jsonResponse(200, verification && school && verification.school_id === school.id
        ? {
          verified: true,
          masked_email: maskEmail(verification.email),
          verified_at: verification.verified_at,
          school_id: school.id,
          school_name: school.name,
          email_domains: school.verification_domains,
          badge_code: school.badge_code,
        }
        : {
          verified: false,
          school_id: school?.id ?? null,
          school_name: school?.name ?? null,
          email_domains: school?.verification_domains ?? [],
          badge_code: school?.badge_code ?? null,
        });
    }

    if (!school) {
      return jsonResponse(400, { error: "请先选择支持认证的学校，并将状态设为在校。" });
    }

    if (action === "unlink") {
      const [result] = await callRPC<UnlinkResult>(
        "unlink_school_student_verification",
        { p_user_id: userID },
      );
      return jsonResponse(200, {
        verified: false,
        unlinked: result?.unlinked ?? false,
        message: "学生认证已解除绑定。",
        school_id: school.id,
        school_name: school.name,
        email_domains: school.verification_domains,
        badge_code: school.badge_code,
      });
    }

    const email = normalizedEmail(body.email);
    const emailDomain = email.split("@").at(-1) ?? "";
    if (!/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/i.test(email) ||
      !school.verification_domains.includes(emailDomain)) {
      return jsonResponse(400, {
        error: `请输入有效的学校邮箱：${school.verification_domains.map((domain) => `@${domain}`).join(" / ")}`,
      });
    }

    if (action === "send") {
      const code = generateCode();
      const codeHash = await verificationHash(userID, email, code);
      const [result] = await callRPC<IssueResult>("issue_school_email_challenge", {
        p_user_id: userID,
        p_school_id: school.id,
        p_email: email,
        p_code_hash: codeHash,
      });
      if (!result || result.status !== "issued") {
        return requestMessage(result?.status ?? "error", result?.retry_after_seconds ?? 0);
      }

      const idempotencyKey = await emailIdempotencyKey(userID, email, codeHash);
      if (!await sendVerificationEmail(email, code, idempotencyKey, school.name)) {
        return jsonResponse(502, { error: "邮件服务暂时不可用，请稍后再试。" });
      }
      return jsonResponse(200, {
        sent: true,
        delivery_status: "provider_accepted",
        retry_after_seconds: result.retry_after_seconds,
        expires_in_seconds: 600,
      });
    }

    if (action === "verify") {
      const code = (body.code ?? "").trim();
      if (!/^\d{6}$/.test(code)) {
        return jsonResponse(400, { error: "请输入 6 位数字验证码。" });
      }
      const codeHash = await verificationHash(userID, email, code);
      const [result] = await callRPC<ConfirmResult>("confirm_school_email_challenge", {
        p_user_id: userID,
        p_school_id: school.id,
        p_email: email,
        p_code_hash: codeHash,
      });

      switch (result?.status) {
        case "verified":
          return jsonResponse(200, {
            verified: true,
            masked_email: maskEmail(email),
            school_id: school.id,
            school_name: school.name,
            email_domains: school.verification_domains,
            badge_code: school.badge_code,
          });
        case "invalid":
          return jsonResponse(400, {
            error: `验证码不正确，还可尝试 ${result.remaining_attempts} 次。`,
            remaining_attempts: result.remaining_attempts,
          });
        case "expired":
          return jsonResponse(400, { error: "验证码已过期，请重新发送。" });
        case "locked":
          return jsonResponse(429, { error: "错误次数过多，请重新发送验证码。" });
        case "email_in_use":
          return jsonResponse(409, { error: "该学校邮箱已绑定其他账号。" });
        default:
          return jsonResponse(400, { error: "请先发送验证码。" });
      }
    }

    return jsonResponse(400, { error: "不支持的操作。" });
  } catch {
    return jsonResponse(500, { error: "认证服务暂时不可用，请稍后再试。" });
  }
});
