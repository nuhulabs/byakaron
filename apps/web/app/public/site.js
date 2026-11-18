// Shared by the landing and download pages. Loaded synchronously at the top
// of the page so the platform-specific parts show without a flash.
//
// 1. Tags <html data-os="..."> with the visitor's platform; CSS picks the
//    matching hero button and card from it.
// 2. Selects the matching tab in the terminal install box.
// 3. Download links use GitHub's /releases/latest/download/<file>, which
//    skips prereleases. While a repo has only prereleases (internal, alpha,
//    beta builds), the links are pointed at its newest release instead, as
//    install.sh does.
(function () {
  var ua = navigator.userAgent || "";
  var hint = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  var os = "web";
  if (/android/i.test(ua)) os = "android";
  else if (/iphone|ipad|ipod/i.test(ua) || (/mac/i.test(hint) && navigator.maxTouchPoints > 1)) os = "ios";
  else if (/cros/i.test(ua)) os = "web";
  else if (/win/i.test(hint) || /windows/i.test(ua)) os = "windows";
  else if (/mac/i.test(hint) || /mac os x/i.test(ua)) os = "macos";
  else if (/linux|x11/i.test(hint) || /linux|x11/i.test(ua)) os = "linux";
  document.documentElement.setAttribute("data-os", os);

  var LATEST = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/releases\/latest(\/download\/.+)?$/;

  function cached(key) {
    try { return sessionStorage.getItem(key); } catch (e) { return null; }
  }
  function remember(key, value) {
    try { sessionStorage.setItem(key, value); } catch (e) {}
  }

  // The tag to use instead of latest/: "" when latest/ works, null on error.
  function newestTag(repo) {
    var key = "byakaron-tag:" + repo;
    var hit = cached(key);
    if (hit !== null) return Promise.resolve(hit);
    var api = "https://api.github.com/repos/" + repo + "/releases";
    return fetch(api + "/latest").then(function (r) {
      if (r.ok) return "";
      return fetch(api + "?per_page=1").then(function (r2) {
        return r2.ok ? r2.json() : [];
      }).then(function (list) {
        return list.length ? list[0].tag_name : "";
      });
    }).then(function (tag) {
      remember(key, tag);
      return tag;
    }, function () { return null; });
  }

  function retarget() {
    var byRepo = {};
    var links = document.querySelectorAll('a[href^="https://github.com/"]');
    for (var i = 0; i < links.length; i++) {
      var m = links[i].getAttribute("href").match(LATEST);
      if (!m) continue;
      (byRepo[m[1]] = byRepo[m[1]] || []).push({ el: links[i], file: m[2] || "" });
    }
    Object.keys(byRepo).forEach(function (repo) {
      newestTag(repo).then(function (tag) {
        if (!tag) return;
        byRepo[repo].forEach(function (l) {
          var base = "https://github.com/" + repo + "/releases/";
          l.el.setAttribute("href", l.file
            ? base + "download/" + tag + l.file.replace(/^\/download/, "")
            : base + "tag/" + tag);
        });
      });
    });
  }

  function selectTab() {
    var tab = document.getElementById("lp-term-" + os);
    if (tab) tab.checked = true;
  }

  function ready() {
    selectTab();
    retarget();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ready);
  else ready();
})();
