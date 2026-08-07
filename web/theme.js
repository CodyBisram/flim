/* Shared across every page.

   Dark is the darkroom under the safelight. Light is the contact sheet on the
   light table. The control names the condition you are switching to, so the
   button says what pressing it does.

   The matching pre-paint snippet lives inline in each page's <head>, because a
   deferred file would apply the saved theme a frame too late and flash. */
(function () {
  var root = document.documentElement;
  var button = document.getElementById("themer");
  var media = window.matchMedia("(prefers-color-scheme: light)");

  var year = document.getElementById("year");
  if (year) year.textContent = new Date().getFullYear();

  if (!button) return;
  var label = button.querySelector("span");

  function current() {
    return root.getAttribute("data-theme") || (media.matches ? "light" : "dark");
  }

  function paint() {
    var next = current() === "dark" ? "light" : "dark";
    if (label) label.textContent = next === "light" ? "Lighttable" : "Safelight";
    button.setAttribute(
      "aria-label",
      next === "light"
        ? "Switch to the light table, the light theme"
        : "Switch to the safelight, the dark theme"
    );
  }

  button.addEventListener("click", function () {
    var next = current() === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    try { localStorage.setItem("flim-theme", next); } catch (e) {}
    paint();
  });

  media.addEventListener("change", paint);
  paint();
})();
