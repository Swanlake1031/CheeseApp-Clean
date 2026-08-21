export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      url.pathname = url.pathname.slice("/api".length);
      const init = { method: request.method, headers: new Headers(request.headers) };
      if (request.method !== "GET" && request.method !== "HEAD") init.body = request.body;
      return env.CONTENT_STUDIO_API.fetch(new Request(url.toString(), init));
    }
    return env.ASSETS.fetch(request);
  }
};
