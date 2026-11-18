// Tags <html data-os="…"> with the visitor's platform so the landing page's
// CSS can pick the matching download or store link. Loaded synchronously at
// the top of the page to avoid a flash of the default (web) button.
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
})();
