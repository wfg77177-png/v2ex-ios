import SwiftUI
import WebKit

// MARK: - Main JS (atDocumentEnd, main frame only)
// Minimal: auth-page guard, toast, auto/manual sign-in (2-step via
// /mission/daily + redeem once token), node navigation, back to top.
// Nothing else: no dark mode, no ad hiding, no long-press preview,
// no infinite scroll, no read history, no notes/blacklist, no keyword
// highlight/filter, no code copy, no translation, no export,
// no TTS, no templates, no scroll restore, no image viewer.
// Search IS kept (in-site search via sov2ex + history).
// Login state lives only in the WKWebView system cookie jar (fetch with
// credentials:'include'). HTML is parsed only with DOMParser +
// querySelector, never eval.
private let v2exJS = """
(function(){
  if (new RegExp('^/(signin|signup|register|forgot|password|reset)').test(location.pathname)) return;
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

  // Sign-in, 2-step, via the site's own session cookie.
  // Step 1: GET /mission/daily, find the redeem link with a DOM query.
  // Step 2: GET the redeem link. Day rolls on UTC (toISOString is UTC).
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

  // Node navigation (tap a node name in the native picker).
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

  // Back to top.
  window.__v2Top = function(){ window.scrollTo({top:0, behavior:'smooth'}); };

  // Search history (localStorage).
  window.__v2GetSearchHistory = function(){
    try{ return localStorage.getItem('v2ex_searchHistory') || '[]'; }catch(e){ return '[]'; }
  };
  window.__v2AddSearchHistory = function(q){
    q = (q||'').trim();
    if(!q) return;
    var list = [];
    try{ list = JSON.parse(localStorage.getItem('v2ex_searchHistory') || '[]'); }catch(e){}
    list = list.filter(function(x){ return x !== q; });
    list.unshift(q);
    if(list.length > 10) list.length = 10;
    try{ localStorage.setItem('v2ex_searchHistory', JSON.stringify(list)); }catch(e){}
  };
  window.__v2ClearSearchHistory = function(){
    try{ localStorage.removeItem('v2ex_searchHistory'); }catch(e){}
  };
})();
"""

// MARK: - Browser model (only what the minimal UI needs)
final class BrowserModel: ObservableObject {
    weak var webView: WKWebView?

    let homeURL = URL(string: "https://www.v2ex.com/")!
    let nodes = ["程序员","Claude","Apple","iDev","问与答","分享发现","酷工作","创意","好玩","交易","Linux","OpenAI"]
    // label + path, all verified live on v2ex.com
    let shortcuts: [(String, String)] = [
        ("首页", "/"),
        ("最新", "/recent"),
        ("最热", "/top"),
        ("全部节点", "/planes"),
    ]

    // JSON-encode a Swift string into a valid JS string literal (with quotes).
    func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: data, encoding: .utf8) {
            return String(str.dropFirst().dropLast())
        }
        return "\"\""
    }

    func eval(_ js: String, completion: ((Any?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js) { result, _ in completion?(result) }
    }
    func toast(_ msg: String) {
        eval("window.__v2Toast && window.__v2Toast(\(jsString(msg)));")
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
    func goHome() { load(homeURL) }
    func goPath(_ path: String) {
        load(URL(string: "https://www.v2ex.com" + path)!)
    }
    func goBalance() { goPath("/balance") }
    func goLogin() { goPath("/signin") }
    func reload() { webView?.reload() }
    func backToTop() {
        eval("window.__v2Top && window.__v2Top();")
    }
    func goNode(_ name: String) {
        eval("window.__v2GoNode && window.__v2GoNode(\(jsString(name)));")
    }
    func manualSignIn() {
        eval("window.__v2ManualSignIn && window.__v2ManualSignIn();")
    }

    // MARK: - Search (sov2ex is the de-facto V2EX full-text search,
    // used by V2er; V2EX's own /search redirects to /go/search)
    func search(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        eval("window.__v2AddSearchHistory && window.__v2AddSearchHistory(\(jsString(query)));")
        if let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            load(URL(string: "https://www.sov2ex.com/?q=" + enc)!)
        }
    }
    func getSearchHistory(completion: @escaping ([String]) -> Void) {
        eval("window.__v2GetSearchHistory && window.__v2GetSearchHistory();") { result in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                completion([])
                return
            }
            completion(arr)
        }
    }
    func clearSearchHistory() {
        eval("window.__v2ClearSearchHistory && window.__v2ClearSearchHistory();")
    }
}

// MARK: - Content view
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showNodes = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
            BottomBar(model: model, showNodes: $showNodes)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showNodes) { NodeSheet(model: model) }
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
        // Single script at document end, main frame only (keeps it out of
        // ad iframes). No atDocumentStart script: nothing to paint early.
        let mainScript = WKUserScript(source: v2exJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(mainScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // leave room so the last line is never hidden behind the bottom bar
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
        // Links that open in a new window (target="_blank", e.g. search results
        // and second-level pages) would otherwise do nothing: WKWebView has no
        // second web view to hand them to. Load them in this same web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Auto sign-in only once the Cloudflare challenge has passed:
            // a request from the challenge page returns 403 and looks
            // automated. The challenge page title is "Just a moment...".
            // Never auto sign-in on auth pages (it disturbs the login
            // form's CSRF token).
            webView.evaluateJavaScript("document.title") { result, _ in
                let title = result as? String ?? ""
                let path = webView.url?.path ?? ""
                let isAuthPage = ["/signin", "/signup", "/register", "/forgot", "/password", "/reset"].contains { path == $0 || path.hasPrefix($0 + "/") }
                if !title.contains("Just a moment") && !isAuthPage {
                    webView.evaluateJavaScript("window.__v2AutoSignIn && window.__v2AutoSignIn();", completionHandler: nil)
                }
            }
        }
    }
}

// MARK: - Bottom bar (6 buttons only)
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showNodes: Bool

    var body: some View {
        HStack(spacing: 2) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "节点") { showNodes = true }
            BarButton(icon: "checkmark.seal", label: "签到") { model.manualSignIn() }
            BarButton(icon: "creditcard", label: "余额") { model.goBalance() }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
            BarButton(icon: "person.crop.circle", label: "登录") { model.goLogin() }
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

// MARK: - Node picker sheet (shortcuts + 12 nodes, no search)
struct NodeSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchHistory: [String] = []

    let columns3 = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    let columns4 = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("搜索")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("搜索 V2EX…", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { doSearch() }
                        Button("搜索") { doSearch() }
                            .buttonStyle(.borderedProminent)
                    }
                    if !searchHistory.isEmpty {
                        LazyVGrid(columns: columns4, spacing: 8) {
                            ForEach(searchHistory, id: \.self) { q in
                                Button {
                                    model.search(q)
                                    dismiss()
                                } label: {
                                    Text(q)
                                        .font(.system(size: 14))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button("清空搜索记录", role: .destructive) {
                            model.clearSearchHistory()
                            searchHistory = []
                        }
                        .font(.system(size: 13))
                    }
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
            .onAppear {
                model.getSearchHistory { searchHistory = $0 }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func doSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        model.search(q)
        dismiss()
    }
}
