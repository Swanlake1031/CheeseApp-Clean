// This file contains only browser-safe values. Copy it to config.js for local
// development, then set the production values through your Pages deploy step.
window.CHEESE_CONTENT_STUDIO_CONFIG = {
  supabaseUrl: "https://your-project.supabase.co",
  supabasePublishableKey: "your-publishable-key",
  apiBaseUrl: "http://localhost:8787",
  // This exact HTTPS URL must be present in Supabase Auth's Redirect URLs.
  oauthRedirectUrl: "https://studio.cheeseapp.org/"
};
