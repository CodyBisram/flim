/* Shared across every page.

   The app's two desks: Slate (dark) and Paper (light). The control names the
   desk you are switching to, so the button says what pressing it does.

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
    if (label) label.textContent = next === "light" ? "Paper" : "Slate";
    button.setAttribute(
      "aria-label",
      next === "light"
        ? "Switch to Paper, the light desk"
        : "Switch to Slate, the dark desk"
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
