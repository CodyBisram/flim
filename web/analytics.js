/* Vercel Web Analytics, on every public page.

   Loaded as a plain (non-deferred) script BEFORE /_vercel/insights/script.js, so
   the beforeSend hook below is registered by the time the deferred insights
   script runs and sends its first pageview. Registering it after would ship one
   unredacted view per page load, which is the only one that matters.

   It lives in a file rather than inline in each page for one reason: the
   redaction rule has to hold on every page that will ever exist here, and a rule
   pasted into six <head>s is a rule the seventh page forgets.

   WHAT IS REDACTED: /i/CODE and /join/CODE carry a personal invite code in the
   path. Vercel records requestPath, so left alone every code we have ever issued
   would end up sitting in an analytics dashboard, readable by anyone with
   project access and outliving the invite itself. Both routes report as
   /i/[code] and /join/[code]: we still learn how much traffic invite links
   bring, which is the actual question, without learning which code.

   WHAT IS DELIBERATELY KEPT: the query string. utm_source and friends are how a
   campaign identifies itself, and stripping the search params would answer
   "where did they come from" with silence. Nothing on this site puts anything
   private in a query param. */
(function () {
  window.va = window.va || function () {
    (window.vaq = window.vaq || []).push(arguments);
  };

  window.va("beforeSend", function (event) {
    try {
      var url = new URL(event.url);
      url.pathname = url.pathname.replace(/^\/(i|join)\/[^/]+\/?$/, "/$1/[code]");
      return Object.assign({}, event, { url: url.toString() });
    } catch (e) {
      /* A URL we cannot parse is not a URL we can redact. Dropping the event is
         the safe direction: one missing pageview costs a number, a leaked code
         costs the invite. */
      return null;
    }
  });
})();
