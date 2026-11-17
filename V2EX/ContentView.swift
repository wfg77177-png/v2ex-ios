import SwiftUI
import WebKit

// MARK: - Early JS (atDocumentStart): dark + ad-hide CSS only
// Runs before first paint to kill the white flash. Reads the same
// localStorage keys the main script uses; same style element IDs so the
// main script never creates duplicates.
private let v2exEarlyJS = """
(function(){
  try{
    if (localStorage.getItem('v2ex_dark') === '1') {
      var s = document.createElement('style');
      s.id = 'v2-dark-style';
      s.textContent = 'html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
      document.documentElement.appendChild(s);
    }
    if (localStorage.getItem('v2ex_hideAds') !== '0') {
      var a = document.createElement('style');
      a.id = 'v2-ad-style';
      a.textContent = '[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
      document.documentElement.appendChild(a);
    }
  }catch(e){}
})();
"""

// MARK: - Main JS (atDocumentEnd): sign-in, nodes, dark, ads, keywords,
// images, scroll position, back to top. Re-applied from native didFinish.
// Safe features only: auto sign-in (2-step, site session cookie), node
// navigation, dark mode, hide ads, keyword filter, fullscreen images,
// remember scroll position, back to top.
// Hard rules: localStorage holds ONLY the sign-in date guard and display
// settings (dark / font / keywords). No session, token, cookie or
// credential is ever read or written by JS. Login state lives only in the
// WKWebView system cookie jar (fetch with credentials:'include'). HTML is
// parsed only with DOMParser + querySelector, never eval. No auto-reply,
// no auto-comment. No prefetch / prewarm / background preload.
private let v2exJS = """
(function(){
  function store(k,v){ try{ localStorage.setItem('v2ex_'+k, v); }catch(e){} }
  function read(k,d){ try{ var v=localStorage.getItem('v2ex_'+k); return v===null?d:v; }catch(e){ return d; } }

  function showToast(msg){
    var t=document.createElement('div');
    t.textContent=msg;
    t.style.cssText='position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:rgba(0,0,0,0.82);color:#fff;padding:10px 16px;border-radius:20px;font-size:14px;z-index:999999;pointer-events:none;';
    document.body.appendChild(t);
    setTimeout(function(){ t.remove(); }, 2600);
  }
  window.__v2Toast = showToast;

  // ---------- 1. Sign-in, 2-step, via the site's own session cookie ----------
  // Step 1: GET /mission/daily, find the redeem link with a DOM query.
  // Step 2: GET the redeem link. Day rolls on UTC, so the date guard uses
  // the UTC date (toISOString is UTC).
  // Auto sign-in is NOT run from this script: the native side calls
  // __v2AutoSignIn from webView didFinish, only after confirming the page
  // is not a Cloudflare challenge page (title "Just a moment...").
  function doSignIn(onDone){
    fetch('/mission/daily', {credentials:'include'})
      .then(function(r){ return r.text(); })
      .then(function(html){
        var doc = new DOMParser().parseFromString(html, 'text/html');
        var a = doc.querySelector('a[href*="mission/daily/redeem?once="]');
        if(!a) return null;
        return fetch(a.getAttribute('href'), {credentials:'include'});
      })
      .then(function(r){
        if(!r){ if(onDone) onDone(false); return; }
        if(r.ok){
          store('signDate', new Date().toISOString().slice(0,10));
          if(onDone) onDone(true);
        } else { if(onDone) onDone(false); }
      })
      .catch(function(){ if(onDone) onDone(false); });
  }
  window.__v2AutoSignIn = function(){
    var today = new Date().toISOString().slice(0,10);
    if (read('signDate','') === today) return;
    doSignIn(function(ok){ if(ok){ showToast('签到成功'); } });
  };
  window.__v2ManualSignIn = function(){
    doSignIn(function(ok){
      if(ok){ showToast('签到成功'); }
      else { showToast('今日已签到或未登录'); }
    });
  };

  // ---------- 2. Dark mode ----------
  window.__v2SetDark = function(on){
    store('dark', on?'1':'0');
    var id='v2-dark-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  // (applied by __v2Apply below, and again from native didFinish)

  // ---------- 3. Hide ads / promo blocks ----------
  window.__v2SetHideAds = function(on){
    store('hideAds', on?'1':'0');
    var id='v2-ad-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  // (applied by __v2Apply below, and again from native didFinish)

  // ---------- 4. Keyword filter (hide topic rows whose title contains a keyword) ----------
  window.__v2SetKeywords = function(csv){
    store('keywords', csv||'');
    applyKeywords();
  };
  function applyKeywords(){
    var csv = read('keywords','');
    var kws = csv.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
    var links = document.querySelectorAll('a.topic-link');
    links.forEach(function(a){
      var row = a.closest('.cell');
      if(!row) row = a.closest('div');
      if(!row) return;
      var txt = (a.textContent||'');
      var hit = kws.some(function(k){ return txt.indexOf(k) !== -1; });
      row.style.display = hit ? 'none' : '';
    });
  }
  window.__v2ApplyKeywords = applyKeywords;
  applyKeywords();
  new MutationObserver(function(){ applyKeywords(); }).observe(document.documentElement, {childList:true, subtree:true});

  // ---------- 5. Fullscreen image viewer ----------
  document.addEventListener('click', function(e){
    var img = e.target.closest ? e.target.closest('img') : null;
    if(!img || !img.src) return;
    if(img.closest('a')) return;
    var ov=document.createElement('div');
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,0.92);z-index:999999;display:flex;align-items:center;justify-content:center;';
    var im=document.createElement('img');
    im.src=img.src; im.style.cssText='max-width:96vw;max-height:92vh;object-fit:contain;';
    ov.appendChild(im);
    ov.addEventListener('click', function(){ ov.remove(); });
    document.body.appendChild(ov);
  }, true);

  // ---------- 6. Remember scroll position (per URL) ----------
  var saveTimer=null;
  function savePos(){
    try{ sessionStorage.setItem('v2ex_pos_'+location.pathname, String(window.scrollY)); }catch(e){}
  }
  window.addEventListener('scroll', function(){
    if(saveTimer) clearTimeout(saveTimer);
    saveTimer=setTimeout(savePos, 400);
  }, {passive:true});
  window.addEventListener('pagehide', savePos);
  function restorePos(){
    try{
      var y=parseInt(sessionStorage.getItem('v2ex_pos_'+location.pathname)||'0',10);
      if(y>200){ setTimeout(function(){ window.scrollTo(0,y); }, 350); }
    }catch(e){}
  }

  // ---------- 7. Node navigation (tap a node name in the native picker) ----------
  // Prefer /go/<node> links, fall back to any same-site link with the name.
  window.__v2GoNode = function(name){
    var links = Array.prototype.slice.call(document.querySelectorAll('a'));
    var hit = links.find(function(a){
      var t=(a.textContent||'').trim();
      var h=a.getAttribute('href')||'';
      return t===name && h.indexOf('/go/')===0;
    });
    if(!hit){
      hit = links.find(function(a){
        var t=(a.textContent||'').trim();
        var h=a.getAttribute('href')||'';
        return t===name && h.charAt(0)==='/';
      });
    }
    if(hit){ hit.click(); return true; }
    return false;
  };

  // ---------- 8. Back to top ----------
  window.__v2Top = function(){ window.scrollTo({top:0, behavior:'smooth'}); };

  // ---------- 9. Re-apply (called here and again from native didFinish) ----------
  // Safe to run repeatedly: setDark/setHideAds are idempotent (they check
  // for the existing style element), applyKeywords re-hides rows, and
  // restorePos scrolls to the same saved offset.
  window.__v2Apply = function(){
    window.__v2SetDark(read('dark','0')==='1');
    window.__v2SetHideAds(read('hideAds','1')==='1');
    applyKeywords();
    restorePos();
  };
  window.__v2Apply();
})();
"""

// MARK: - Model
final class BrowserModel: ObservableObject {
    weak var webView: WKWebView?
    @Published var isDark = false
    @Published var fontScale: CGFloat = 1.0
    @Published var hideAds = true
    @Published var keywords = ""
    @Published var canGoBack = false

    let homeURL = URL(string: "https://www.v2ex.com/")!
    let nodes = ["程序员","Claude","Apple","iDev","问与答","分享发现","酷工作","创意","好玩","交易","Linux","OpenAI"]
    // label + path, all verified live on v2ex.com
    let shortcuts: [(String, String)] = [
        ("首页", "/"),
        ("最新", "/recent"),
        ("最热", "/top"),
        ("全部节点", "/planes"),
    ]

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
    func goHome() { load(homeURL) }
    func goPath(_ path: String) {
        load(URL(string: "https://www.v2ex.com" + path)!)
    }
    func goBalance() { goPath("/balance") }
    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
    func backToTop() {
        webView?.evaluateJavaScript("window.__v2Top && window.__v2Top();", completionHandler: nil)
    }
    func goNode(_ name: String) {
        webView?.evaluateJavaScript("window.__v2GoNode && window.__v2GoNode('\(name)');") { _, _ in }
    }
    func setDark(_ on: Bool) {
        isDark = on
        UserDefaults.standard.set(on, forKey: "v2ex_dark")
        webView?.evaluateJavaScript("window.__v2SetDark && window.__v2SetDark(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setFontScale(_ s: CGFloat) {
        fontScale = s
        UserDefaults.standard.set(Double(s), forKey: "v2ex_fontScale")
        webView?.pageZoom = s
    }
    func setHideAds(_ on: Bool) {
        hideAds = on
        UserDefaults.standard.set(on, forKey: "v2ex_hideAds")
        webView?.evaluateJavaScript("window.__v2SetHideAds && window.__v2SetHideAds(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setKeywords(_ s: String) {
        keywords = s
        UserDefaults.standard.set(s, forKey: "v2ex_keywords")
        let esc = s.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.__v2SetKeywords && window.__v2SetKeywords('\(esc)');", completionHandler: nil)
    }
    func manualSignIn() {
        webView?.evaluateJavaScript("window.__v2ManualSignIn && window.__v2ManualSignIn();", completionHandler: nil)
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showNodes = false
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
                .ignoresSafeArea(edges: .top)
            BottomBar(model: model, showNodes: $showNodes, showSettings: $showSettings)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showNodes) { NodeSheet(model: model) }
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .onAppear {
            model.isDark = UserDefaults.standard.bool(forKey: "v2ex_dark")
            model.hideAds = UserDefaults.standard.object(forKey: "v2ex_hideAds") as? Bool ?? true
            model.keywords = UserDefaults.standard.string(forKey: "v2ex_keywords") ?? ""
            let fs = UserDefaults.standard.double(forKey: "v2ex_fontScale")
            if fs > 0 { model.fontScale = CGFloat(fs) }
        }
    }
}

// MARK: - WebView
// Eager root view: created on launch, loads the homepage directly.
// Default persistent WKWebsiteDataStore (cache + cookies persist). No
// prefetch / prewarm / background preload.
struct WebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Explicit persistent store: cache + cookies survive restarts, and
        // the Cloudflare cf_clearance cookie lets repeat opens skip the
        // challenge. Never clear it, never .nonPersistent(), never
        // .reloadIgnoringLocalCacheData.
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Early CSS (dark + ad-hide) before first paint; main script after
        // the document. forMainFrameOnly keeps both out of ad iframes.
        let earlyScript = WKUserScript(source: v2exEarlyJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let mainScript = WKUserScript(source: v2exJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(earlyScript)
        config.userContentController.addUserScript(mainScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // leave room so the last line is never hidden behind the bottom bar
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        if model.fontScale != 1.0 { webView.pageZoom = model.fontScale }
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
            // Re-apply display tweaks in case atDocumentEnd ran before the
            // DOM was ready.
            webView.evaluateJavaScript("window.__v2Apply && window.__v2Apply();", completionHandler: nil)
            // Auto sign-in only once the Cloudflare challenge has passed:
            // a request from the challenge page returns 403 and looks
            // automated. The challenge page title is "Just a moment...".
            webView.evaluateJavaScript("document.title") { result, _ in
                let title = result as? String ?? ""
                if !title.contains("Just a moment") {
                    webView.evaluateJavaScript("window.__v2AutoSignIn && window.__v2AutoSignIn();", completionHandler: nil)
                }
            }
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
        }
    }
}

// MARK: - Bottom bar (comfortable proportions, smooth)
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showNodes: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 2) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "节点") { showNodes = true }
            BarButton(icon: "checkmark.seal", label: "签到") { model.manualSignIn() }
            BarButton(icon: "creditcard", label: "余额") { model.goBalance() }
            BarButton(icon: model.isDark ? "moon.fill" : "moon", label: "深色") {
                model.setDark(!model.isDark)
            }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
            BarButton(icon: "gearshape", label: "设置") { showSettings = true }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

struct BarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Node picker sheet
struct NodeSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    let columns3 = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    let columns4 = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("快捷")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns4, spacing: 12) {
                        ForEach(model.shortcuts, id: \.0) { item in
                            Button {
                                model.goPath(item.1)
                                dismiss()
                            } label: {
                                Text(item.0)
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("节点")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns3, spacing: 12) {
                        ForEach(model.nodes, id: \.self) { name in
                            Button {
                                model.goNode(name)
                                dismiss()
                            } label: {
                                Text(name)
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Settings sheet
struct SettingsSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var keywordsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读") {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Stepper("", value: Binding(
                            get: { model.fontScale },
                            set: { model.setFontScale($0) }
                        ), in: 0.85...1.35, step: 0.05)
                        Text(String(format: "%.0f%%", model.fontScale * 100))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    Toggle("深色模式", isOn: Binding(
                        get: { model.isDark },
                        set: { model.setDark($0) }
                    ))
                    Toggle("隐藏广告与推广位", isOn: Binding(
                        get: { model.hideAds },
                        set: { model.setHideAds($0) }
                    ))
                }
                Section("屏蔽关键词") {
                    TextField("多个关键词用英文逗号隔开", text: $keywordsText)
                        .onChange(of: keywordsText) { model.setKeywords($0) }
                    Text("包含这些词的帖子标题会被隐藏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("刷新页面") { model.reload(); dismiss() }
                    Button("回到首页") { model.goHome(); dismiss() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { keywordsText = model.keywords }
        }
        .presentationDetents([.medium, .large])
    }
}
