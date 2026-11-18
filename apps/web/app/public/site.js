// Shared by the landing and download pages. Loaded synchronously at the top
// of the page so the platform-specific parts show without a flash.
//
// 1. Tags <html data-os="..."> with the visitor's platform; CSS picks the
//    matching hero button and card from it.
// 2. Selects the matching tab in the terminal install box.
//
// Download links stay on GitHub's /releases/latest/download/<file>: the
// release marked latest on Byakaron-Assets.
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

  function selectTab() {
    var tab = document.getElementById("lp-term-" + os);
    if (tab) tab.checked = true;
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", selectTab);
  else selectTab();
})();
