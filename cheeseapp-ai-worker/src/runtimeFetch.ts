/**
 * Cloudflare's runtime fetch relies on its original global `this` binding.
 * Passing the bare function into a class and later calling it as a property
 * changes that binding and throws "Illegal invocation" in production.
 */
export const runtimeFetch: typeof fetch = globalThis.fetch.bind(globalThis);
