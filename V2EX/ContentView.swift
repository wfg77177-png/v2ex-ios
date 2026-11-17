import SwiftUI
import WebKit
import Photos
import AVFoundation

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

// MARK: - Main JS (atDocumentEnd)
// Sections 1-9: the original safe features (sign-in, dark, ads, keyword
// filter, fullscreen images, scroll position, node navigation, back to
// top). Sections 10-19: v2 safe additions, all read-only or user-triggered
// only. No auto-reply, no auto-comment, no auto lottery entry.
// Hard rules: localStorage holds ONLY the sign-in date guard, display
// settings, read history, blocked users, user notes, highlight keywords,
// search history, translation config. No session, token, cookie or
// credential is ever read or written by JS (a user-entered BYOK translation
// key lives in localStorage on the device only, never in repo code).
// Login state lives only in the WKWebView system cookie jar (fetch with
// credentials:'include'). HTML is parsed only with DOMParser +
// querySelector, never eval.
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

  function copyText(t){
    if(navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(t).catch(function(){ fallbackCopy(t); });
    } else { fallbackCopy(t); }
  }
  function fallbackCopy(t){
    var ta = document.createElement('textarea');
    ta.value = t;
    ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try{ document.execCommand('copy'); }catch(e){}
    ta.remove();
  }

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

  // ---------- 4. Keyword filter (hide topic rows whose title contains a
  // keyword) + user blacklist (hide rows by blocked authors). One place
  // decides list-row visibility so the two rules never fight. ----------
  function blockedUsers(){
    return read('blockedUsers','').split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
  }
  function blockedSet(){
    var s = {};
    blockedUsers().forEach(function(u){ s[u]=true; });
    return s;
  }
  function rowAuthor(row){
    var a = row.querySelector('a[href^="/member/"]');
    return a ? (a.textContent||'').trim() : '';
  }
  window.__v2SetKeywords = function(csv){
    store('keywords', csv||'');
    applyKeywords();
  };
  function applyKeywords(){
    var csv = read('keywords','');
    var kws = csv.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
    var bset = blockedSet();
    var links = document.querySelectorAll('a.topic-link');
    links.forEach(function(a){
      var row = a.closest('.cell');
      if(!row) row = a.closest('div');
      if(!row) return;
      var txt = (a.textContent||'');
      var hit = kws.some(function(k){ return txt.indexOf(k) !== -1; });
      row.style.display = (hit || bset[rowAuthor(row)]) ? 'none' : '';
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

  // ---------- 9. Re-apply (called on load and again from native didFinish) ----------
  // Safe to run repeatedly: setDark/setHideAds are idempotent (they check
  // for the existing style element), and every apply function below is
  // idempotent (data attributes / existing-element checks).
  window.__v2Apply = function(){
    window.__v2SetDark(read('dark','0')==='1');
    window.__v2SetHideAds(read('hideAds','1')==='1');
    reapplyNew();
    restorePos();
  };

  // ================= v2 additions =================

  // ---------- 10. Read history: clicked topics dim on list pages ----------
  function readSet(){
    try{ return JSON.parse(localStorage.getItem('v2ex_read') || '[]'); }catch(e){ return []; }
  }
  function markRead(id){
    if(!id) return;
    var list = readSet().filter(function(x){ return x !== id; });
    list.unshift(id);
    if(list.length > 500) list.length = 500;
    try{ localStorage.setItem('v2ex_read', JSON.stringify(list)); }catch(e){}
  }
  function topicIdOfLink(a){
    var id = (a.getAttribute('id')||'').replace('topic-link-','');
    if(id) return id;
    var m = (a.getAttribute('href')||'').match(/\\/t\\/(\\d+)/);
    return m ? m[1] : '';
  }
  document.addEventListener('click', function(e){
    var a = e.target.closest ? e.target.closest('a.topic-link') : null;
    if(!a) return;
    // A long-press preview just opened: swallow the click that follows it.
    if(window.__v2PreviewBlock){ e.preventDefault(); e.stopPropagation(); window.__v2PreviewBlock = false; return; }
    markRead(topicIdOfLink(a));
  }, true);
  function applyReadMarks(){
    var list = readSet();
    if(!list.length) return;
    var set = {};
    list.forEach(function(id){ set[id] = true; });
    document.querySelectorAll('a.topic-link').forEach(function(a){
      var row = a.closest('.cell');
      if(!row) return;
      row.style.opacity = set[topicIdOfLink(a)] ? '0.55' : '';
    });
  }
  window.__v2ClearRead = function(){
    try{ localStorage.removeItem('v2ex_read'); }catch(e){}
    document.querySelectorAll('a.topic-link').forEach(function(a){
      var row = a.closest('.cell'); if(row) row.style.opacity = '';
    });
    showToast('已清空已读记录');
  };

  // ---------- 11. User blacklist (reply cells) + user notes ----------
  window.__v2SetBlockedUsers = function(csv){ store('blockedUsers', csv||''); applyKeywords(); applyReplyVisibility(); };
  window.__v2GetBlockedUsers = function(){ return read('blockedUsers',''); };
  function userNotes(){
    try{ return JSON.parse(localStorage.getItem('v2ex_userNotes') || '{}'); }catch(e){ return {}; }
  }
  window.__v2SetUserNotes = function(json){
    try{ localStorage.setItem('v2ex_userNotes', json); }catch(e){}
    clearUserNotes(); applyUserNotes();
  };
  window.__v2GetUserNotes = function(){
    try{ return localStorage.getItem('v2ex_userNotes') || '{}'; }catch(e){ return '{}'; }
  };
  function clearUserNotes(){
    document.querySelectorAll('.v2-note').forEach(function(s){ s.remove(); });
    document.querySelectorAll('[data-v2-noted]').forEach(function(a){ delete a.dataset.v2Noted; });
  }
  function applyUserNotes(){
    var notes = userNotes();
    var links = document.querySelectorAll('div.cell[id^="r_"] strong a[href^="/member/"], .header small.gray a[href^="/member/"], .cell.item a[href^="/member/"]');
    links.forEach(function(a){
      if(a.dataset.v2Noted) return;
      var name = (a.textContent||'').trim();
      if(!name || !notes[name]) return;
      a.dataset.v2Noted = '1';
      var s = document.createElement('span');
      s.className = 'v2-note';
      s.textContent = ' ' + notes[name];
      s.style.cssText = 'color:#b45309;background:#fef3c7;border-radius:6px;padding:1px 6px;font-size:11px;margin-left:4px;';
      a.insertAdjacentElement('afterend', s);
    });
  }
  // One place decides reply-cell visibility: blacklist OR only-OP.
  var onlyOPOn = false;
  function opName(){
    var a = document.querySelector('.header small.gray a[href^="/member/"]');
    if(a) return (a.textContent||'').trim();
    var b = document.querySelector('.header a[href^="/member/"]');
    return b ? (b.textContent||'').trim() : '';
  }
  function applyReplyVisibility(){
    var bset = blockedSet();
    var op = opName();
    document.querySelectorAll('div.cell[id^="r_"]').forEach(function(cell){
      var a = cell.querySelector('strong a[href^="/member/"]');
      var name = a ? (a.textContent||'').trim() : '';
      var hide = !!bset[name] || (onlyOPOn && op && name !== op);
      cell.style.display = hide ? 'none' : '';
    });
  }
  window.__v2SetOnlyOP = function(on){
    onlyOPOn = !!on;
    applyReplyVisibility();
  };

  // ---------- 12. Keyword highlight (separate from the hide filter) ----------
  window.__v2SetHighlightKeywords = function(csv){
    store('hlKeywords', csv||'');
    clearHighlights(); applyHighlights();
  };
  function hlList(){
    return read('hlKeywords','').split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
  }
  function clearHighlights(){
    document.querySelectorAll('.v2-hl').forEach(function(sp){
      var parent = sp.parentNode;
      if(!parent) return;
      parent.replaceChild(document.createTextNode(sp.textContent), sp);
      parent.normalize();
    });
  }
  function highlightNode(node, kws){
    var text = node.nodeValue;
    var lower = text.toLowerCase();
    var firstIdx = -1, firstKw = '';
    kws.forEach(function(k){
      var i = lower.indexOf(k.toLowerCase());
      if(i !== -1 && (firstIdx === -1 || i < firstIdx)){ firstIdx = i; firstKw = k; }
    });
    if(firstIdx === -1) return null;
    var before = document.createTextNode(text.slice(0, firstIdx));
    var sp = document.createElement('span');
    sp.className = 'v2-hl';
    sp.style.cssText = 'background:#fde68a;color:#78350f;border-radius:3px;padding:0 2px;';
    sp.textContent = text.slice(firstIdx, firstIdx + firstKw.length);
    var after = document.createTextNode(text.slice(firstIdx + firstKw.length));
    var parent = node.parentNode;
    if(!parent) return null;
    parent.insertBefore(before, node);
    parent.insertBefore(sp, node);
    parent.insertBefore(after, node);
    parent.removeChild(node);
    return after;
  }
  function highlightTextNodes(root, kws){
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(node){
        if(!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        var p = node.parentNode;
        if(p && p.nodeType === 1 && p.closest && p.closest('.v2-hl')) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var nodes = [];
    while(walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(function(node){
      var cur = node;
      var guard = 0;
      while(cur && guard++ < 20){ cur = highlightNode(cur, kws); }
    });
  }
  function applyHighlights(){
    var kws = hlList();
    if(!kws.length) return;
    document.querySelectorAll('a.topic-link, .cell.item a[href^="/member/"]').forEach(function(a){
      highlightTextNodes(a, kws);
    });
  }

  // ---------- 13. Infinite scroll (next page via link[rel="next"]) ----------
  var v2LoadingNext = false;
  window.__v2SetInfiniteScroll = function(on){ store('infinite', on?'1':'0'); };
  function nextPageURL(){
    var link = document.querySelector('link[rel="next"]');
    if(link && link.getAttribute('href')) return new URL(link.getAttribute('href'), location.href).href;
    return null;
  }
  function isTopicPage(){ return /^\\/t\\/\\d+/.test(location.pathname); }
  function isListPage(){
    var p = location.pathname;
    return p === '/' || p === '/recent' || p === '/top' || p === '/planes' || p.indexOf('/go/') === 0 || p.indexOf('/member/') === 0;
  }
  function showLoadingRow(show, done){
    var el = document.getElementById('v2-loading-row');
    if(show){
      if(!el){
        el = document.createElement('div');
        el.id = 'v2-loading-row';
        el.style.cssText = 'text-align:center;color:#888;padding:16px;font-size:14px;';
        document.body.appendChild(el);
      }
      el.textContent = '正在加载…';
      el.style.display = '';
    } else if(el){
      if(done){ el.textContent = '没有更多了'; }
      else { el.remove(); }
    }
  }
  function loadNextPage(){
    if(v2LoadingNext) return;
    if(read('infinite','1') !== '1') return;
    var url = nextPageURL();
    if(!url) return;
    v2LoadingNext = true;
    showLoadingRow(true);
    fetch(url, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
      var doc = new DOMParser().parseFromString(html, 'text/html');
      var nextLink = doc.querySelector('link[rel="next"]');
      var curNext = document.querySelector('link[rel="next"]');
      if(nextLink && curNext){ curNext.setAttribute('href', nextLink.getAttribute('href')); }
      else if(curNext && !nextLink){ curNext.remove(); }
      var added = 0;
      if(isTopicPage()){
        var cells = doc.querySelectorAll('div.cell[id^="r_"]');
        var all = document.querySelectorAll('div.cell[id^="r_"]');
        var parent = all.length ? all[all.length-1].parentNode : document.querySelector('.box.reply-threads');
        cells.forEach(function(c){ if(parent){ parent.appendChild(document.importNode(c, true)); added++; } });
      } else if(isListPage()){
        var rows = doc.querySelectorAll('.cell.item');
        var allRows = document.querySelectorAll('.cell.item');
        var parent2 = allRows.length ? allRows[allRows.length-1].parentNode : null;
        rows.forEach(function(r){ if(parent2){ parent2.appendChild(document.importNode(r, true)); added++; } });
      }
      showLoadingRow(false);
      v2LoadingNext = false;
      if(added > 0){
        reapplyNew();
        if(!nextPageURL()) showLoadingRow(false, true);
      } else {
        showLoadingRow(false, true);
      }
    }).catch(function(){ showLoadingRow(false); v2LoadingNext = false; });
  }
  var scrollTimer = null;
  window.addEventListener('scroll', function(){
    if(scrollTimer) return;
    scrollTimer = setTimeout(function(){
      scrollTimer = null;
      if(window.innerHeight + window.scrollY > document.documentElement.scrollHeight - 1200){
        loadNextPage();
      }
    }, 200);
  }, {passive:true});

  // ---------- 14. Only OP is in section 11 (applyReplyVisibility).
  // Long-text folding + topic preview (long-press). ----------
  function applyFolding(){
    document.querySelectorAll('.topic_content, .reply_content').forEach(function(el){
      if(el.dataset.v2Folded) return;
      el.dataset.v2Folded = '1';
      if((el.textContent||'').length < 900) return;
      el.style.maxHeight = '240px';
      el.style.overflow = 'hidden';
      var btn = document.createElement('button');
      btn.textContent = '展开全文';
      btn.style.cssText = 'display:block;margin:8px 0 0;padding:6px 14px;border:1px solid #ccc;border-radius:16px;background:#fff;color:#333;font-size:13px;';
      btn.addEventListener('click', function(){
        el.style.maxHeight = '';
        el.style.overflow = '';
        btn.remove();
      });
      el.insertAdjacentElement('afterend', btn);
    });
  }
  var previewTimer = null;
  var previewEl = null;
  document.addEventListener('touchstart', function(e){
    var a = e.target.closest ? e.target.closest('a.topic-link') : null;
    if(!a) return;
    var href = a.getAttribute('href') || '';
    previewTimer = setTimeout(function(){ showPreview(href); }, 600);
    function cancel(){
      if(previewTimer){ clearTimeout(previewTimer); previewTimer = null; }
      document.removeEventListener('touchend', cancel);
      document.removeEventListener('touchmove', cancel);
    }
    document.addEventListener('touchend', cancel);
    document.addEventListener('touchmove', cancel);
  }, {passive:true});
  function closePreview(){
    if(previewEl){ previewEl.remove(); previewEl = null; }
    window.__v2PreviewBlock = false;
  }
  function showPreview(href){
    // Block the click that follows this long-press right away; the fetch
    // below is async and would otherwise be too late.
    window.__v2PreviewBlock = true;
    var url = href.split('#')[0];
    var full = new URL(url, location.href).href;
    fetch(full, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
      var doc = new DOMParser().parseFromString(html, 'text/html');
      var title = (doc.querySelector('h1')||{}).textContent || '';
      var body = doc.querySelector('.topic_content');
      var text = body ? (body.textContent||'').trim().slice(0, 400) : '';
      closePreview();
      window.__v2PreviewBlock = true;
      var ov = document.createElement('div');
      ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.45);z-index:999998;display:flex;align-items:center;justify-content:center;padding:20px;';
      var card = document.createElement('div');
      card.style.cssText = 'background:#fff;color:#111;border-radius:16px;padding:18px;max-width:520px;width:100%;max-height:70vh;overflow:auto;';
      var h = document.createElement('div');
      h.style.cssText = 'font-size:16px;font-weight:600;margin-bottom:10px;';
      h.textContent = title;
      var p = document.createElement('div');
      p.style.cssText = 'font-size:14px;line-height:1.6;color:#333;white-space:pre-wrap;';
      p.textContent = text || '（无正文）';
      var row = document.createElement('div');
      row.style.cssText = 'display:flex;gap:10px;margin-top:14px;';
      var openBtn = document.createElement('button');
      openBtn.textContent = '打开帖子';
      openBtn.style.cssText = 'flex:1;padding:10px;border-radius:12px;background:#2563eb;color:#fff;font-size:15px;border:0;';
      openBtn.addEventListener('click', function(){ closePreview(); location.href = full; });
      var closeBtn = document.createElement('button');
      closeBtn.textContent = '关闭';
      closeBtn.style.cssText = 'flex:1;padding:10px;border-radius:12px;background:#eee;color:#333;font-size:15px;border:0;';
      closeBtn.addEventListener('click', closePreview);
      row.appendChild(openBtn); row.appendChild(closeBtn);
      card.appendChild(h); card.appendChild(p); card.appendChild(row);
      ov.appendChild(card);
      ov.addEventListener('click', function(e){ if(e.target === ov) closePreview(); });
      document.body.appendChild(ov);
      previewEl = ov;
    }).catch(function(){ window.__v2PreviewBlock = false; });
  }

  // ---------- 15. Code block copy + basic highlight ----------
  var codeKeywords = ['function','return','if','else','for','while','do','switch','case','break','continue','class','extends','import','from','export','const','let','var','new','this','try','catch','finally','throw','async','await','def','print','public','private','static','void','int','string','bool','true','false','null','None','lambda','in','is','not','and','or','with','as','pass','elif','foreach','using','namespace','struct','enum','interface','implements','super','self','nil','func','guard','where','protocol'];
  function highlightCode(code){
    var kw = {};
    codeKeywords.forEach(function(k){ kw[k]=true; });
    function esc(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
    var out = '';
    var i = 0;
    while(i < code.length){
      var ch = code[i];
      if(ch === '/' && code[i+1] === '/'){
        var j = code.indexOf('\\n', i);
        if(j === -1) j = code.length;
        out += '<span style="color:#888">' + esc(code.slice(i,j)) + '</span>';
        i = j; continue;
      }
      if(ch === '"' || ch === "'" || ch === '`'){
        var q = ch; var k = i+1;
        while(k < code.length && code[k] !== q){ if(code[k] === '\\\\') k++; k++; }
        if(k < code.length) k++;
        out += '<span style="color:#0a7a42">' + esc(code.slice(i,k)) + '</span>';
        i = k; continue;
      }
      if(/[A-Za-z_$]/.test(ch)){
        var m = i;
        while(m < code.length && /[A-Za-z0-9_$]/.test(code[m])) m++;
        var w = code.slice(i,m);
        if(kw[w]) out += '<span style="color:#7c3aed;font-weight:600">' + esc(w) + '</span>';
        else out += esc(w);
        i = m; continue;
      }
      if(/[0-9]/.test(ch)){
        var n = i;
        while(n < code.length && /[0-9.]/.test(code[n])) n++;
        out += '<span style="color:#b45309">' + esc(code.slice(i,n)) + '</span>';
        i = n; continue;
      }
      out += esc(ch); i++;
    }
    return out;
  }
  function applyCodeBlocks(){
    document.querySelectorAll('.topic_content pre, .reply_content pre').forEach(function(pre){
      if(pre.dataset.v2Code) return;
      pre.dataset.v2Code = '1';
      var code = pre.textContent || '';
      var codeEl = pre.querySelector('code') || pre;
      codeEl.innerHTML = highlightCode(code);
      var btn = document.createElement('button');
      btn.textContent = '复制代码';
      btn.style.cssText = 'display:inline-block;margin:0 0 6px;padding:4px 10px;border:1px solid #ccc;border-radius:12px;background:#f5f5f5;color:#333;font-size:12px;';
      btn.addEventListener('click', function(){
        copyText(code);
        showToast('代码已复制');
      });
      pre.insertAdjacentElement('beforebegin', btn);
    });
  }

  // ---------- 16. Export helpers (called from native, user-triggered) ----------
  function htmlToMd(el){
    var out = '';
    function walk(node){
      if(node.nodeType === 3){ out += node.nodeValue; return; }
      if(node.nodeType !== 1) return;
      var tag = node.tagName;
      if(tag === 'A'){
        var href = node.getAttribute('href') || '';
        out += '[' + (node.textContent||'') + '](' + href + ')';
        return;
      }
      if(tag === 'IMG'){
        var src = node.getAttribute('src') || '';
        out += '![' + (node.getAttribute('alt')||'') + '](' + src + ')';
        return;
      }
      if(tag === 'BR'){ out += '\\n'; return; }
      if(tag === 'PRE'){ out += '\\n```\\n' + (node.textContent||'') + '\\n```\\n'; return; }
      if(tag === 'CODE'){ out += '`' + (node.textContent||'') + '`'; return; }
      if(tag === 'STRONG' || tag === 'B'){ out += '**' + (node.textContent||'') + '**'; return; }
      if(tag === 'EM' || tag === 'I'){ out += '*' + (node.textContent||'') + '*'; return; }
      if(tag === 'BLOCKQUOTE'){
        var t2 = node.textContent || '';
        t2.split('\\n').forEach(function(line){ out += '> ' + line + '\\n'; });
        return;
      }
      if(tag === 'LI'){ out += '- '; Array.prototype.forEach.call(node.childNodes, walk); out += '\\n'; return; }
      if(/^H[1-6]$/.test(tag)){
        var n = parseInt(tag[1], 10);
        out += '\\n' + '#'.repeat(n) + ' ' + (node.textContent||'') + '\\n';
        return;
      }
      Array.prototype.forEach.call(node.childNodes, walk);
      if(tag === 'P' || tag === 'DIV'){ out += '\\n\\n'; }
    }
    Array.prototype.forEach.call(el.childNodes, walk);
    return out.replace(/\\n{3,}/g, '\\n\\n').trim();
  }
  window.__v2ExportMarkdown = function(){
    var title = (document.querySelector('h1')||{}).textContent || document.title;
    var md = '# ' + (title||'').trim() + '\\n\\n' + location.href + '\\n';
    var op = document.querySelector('.topic_content');
    if(op){ md += '\\n## ' + (opName() || '楼主') + '\\n\\n' + htmlToMd(op) + '\\n'; }
    var cells = document.querySelectorAll('div.cell[id^="r_"]');
    var count = 0;
    cells.forEach(function(cell){
      if(count >= 200) return;
      var a = cell.querySelector('strong a[href^="/member/"]');
      var name = a ? (a.textContent||'').trim() : '';
      var rc = cell.querySelector('.reply_content');
      if(!rc) return;
      md += '\\n---\\n\\n**' + name + '**: ' + htmlToMd(rc) + '\\n';
      count++;
    });
    return md;
  };
  window.__v2GetReadableText = function(){
    var parts = [];
    var title = (document.querySelector('h1')||{}).textContent || '';
    if(title) parts.push(title);
    var op = document.querySelector('.topic_content');
    if(op) parts.push((op.textContent||'').trim());
    document.querySelectorAll('div.cell[id^="r_"] .reply_content').forEach(function(rc){
      parts.push((rc.textContent||'').trim());
    });
    var text = parts.filter(function(s){ return s.length>0; }).join('\\n');
    return text.slice(0, 15000);
  };
  window.__v2CollectImages = function(){
    var urls = [];
    var seen = {};
    document.querySelectorAll('.topic_content img, .reply_content img, img.embedded_image').forEach(function(img){
      var src = img.getAttribute('src') || img.src || '';
      if(!src) return;
      if(src.indexOf('data:') === 0) return;
      var abs = img.src || src;
      if(seen[abs]) return;
      seen[abs] = true;
      urls.push(abs);
    });
    return JSON.stringify(urls.slice(0, 50));
  };
  window.__v2InsertTemplate = function(text){
    var ta = document.querySelector('textarea#reply_content') || document.querySelector('textarea[name="content"]') || document.querySelector('.box form textarea') || document.querySelector('textarea');
    if(!ta){ showToast('当前页面没有回复框（可能需要登录）'); return false; }
    var cur = ta.value || '';
    var pos = ta.selectionStart != null ? ta.selectionStart : cur.length;
    ta.value = cur.slice(0, pos) + text + cur.slice(pos);
    ta.dispatchEvent(new Event('input', {bubbles:true}));
    ta.focus();
    ta.scrollIntoView({block:'center', behavior:'smooth'});
    return true;
  };

  // ---------- 17. Search history (localStorage) ----------
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

  // ---------- 18. Bilingual translation (user-triggered only) ----------
  // Default: free MyMemory (no key). Optional BYOK: OpenAI-compatible
  // /chat/completions (key + base URL + model in Settings, stored on-device
  // in localStorage only, never in repo code).
  window.__v2GetTrConfig = function(){
    return JSON.stringify({key: read('trKey',''), base: read('trBase','https://openrouter.ai/api/v1'), model: read('trModel','deepseek/deepseek-chat')});
  };
  window.__v2SetTrConfig = function(key, base, model){
    store('trKey', key||'');
    store('trBase', base||'https://openrouter.ai/api/v1');
    store('trModel', model||'deepseek/deepseek-chat');
  };
  function trLangOf(text){ return /[\\u4e00-\\u9fff]/.test(text) ? 'zh' : 'en'; }
  function trBytes(s){ return encodeURIComponent(s).replace(/%[0-9A-F]{2}/g, 'x').length; }
  function trSplit(text, maxBytes){
    var sentences = text.match(/[^。！？!?\\n]+[。！？!?]?/g) || [text];
    var chunks = [];
    var cur = '';
    sentences.forEach(function(s){
      if(trBytes(cur + s) > maxBytes && cur){ chunks.push(cur); cur = s; }
      else { cur += s; }
    });
    if(cur) chunks.push(cur);
    return chunks.length ? chunks : [text];
  }
  function trMyMemory(text, from, to){
    var url = 'https://api.mymemory.translated.net/get?q=' + encodeURIComponent(text) + '&langpair=' + from + '|' + to;
    return fetch(url).then(function(r){ return r.json(); }).then(function(j){
      if(j.responseStatus === 200 && j.responseData && j.responseData.translatedText){
        var t = j.responseData.translatedText;
        if(t.indexOf('QUERY LENGTH LIMIT') !== -1 || t.indexOf('INVALID') !== -1) throw new Error(t);
        return t;
      }
      throw new Error('MyMemory ' + (j.responseStatus || 'error'));
    });
  }
  function trBYOK(text, from, to){
    var cfg = JSON.parse(window.__v2GetTrConfig());
    var target = to === 'zh-CN' ? 'Chinese' : 'English';
    var base = (cfg.base || 'https://openrouter.ai/api/v1').replace(/\\/+$/, '');
    return fetch(base + '/chat/completions', {
      method: 'POST',
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + cfg.key},
      body: JSON.stringify({model: cfg.model, messages: [{role: 'user', content: 'Translate the following text to ' + target + '. Return only the translation, no explanation.\\n\\n' + text}], temperature: 0.3})
    }).then(function(r){ return r.json(); }).then(function(j){
      if(j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) return j.choices[0].message.content.trim();
      throw new Error((j.error && j.error.message) || 'BYOK error');
    });
  }
  function trOne(text, from, to){
    if(read('trKey','')) return trBYOK(text, from, to);
    return trMyMemory(text, from, to);
  }
  function trTranslate(text, onProgress){
    var lang = trLangOf(text);
    var from = lang === 'zh' ? 'zh-CN' : 'en';
    var to = lang === 'zh' ? 'en' : 'zh-CN';
    var useBYOK = !!read('trKey','');
    var maxBytes = useBYOK ? 6000 : 450;
    var chunks = trSplit(text, maxBytes);
    var out = [];
    var i = 0;
    function next(){
      if(i >= chunks.length) return Promise.resolve(out.join('\\n'));
      if(onProgress) onProgress(i + 1, chunks.length);
      return trOne(chunks[i], from, to).then(function(t){
        out.push(t); i++; return next();
      }).catch(function(){
        out.push(chunks[i]); i++; return next();
      });
    }
    return next();
  }
  function trShowPanel(title, build){
    var old = document.getElementById('v2-tr-panel');
    if(old) old.remove();
    var ov = document.createElement('div');
    ov.id = 'v2-tr-panel';
    ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.45);z-index:999998;display:flex;align-items:flex-end;justify-content:center;';
    var card = document.createElement('div');
    card.style.cssText = 'background:#fff;color:#111;border-radius:18px 18px 0 0;padding:16px;width:100%;max-height:82vh;overflow:auto;';
    var h = document.createElement('div');
    h.style.cssText = 'font-size:16px;font-weight:600;margin-bottom:10px;display:flex;justify-content:space-between;align-items:center;';
    var ht = document.createElement('span'); ht.textContent = title;
    var x = document.createElement('button');
    x.textContent = '关闭';
    x.style.cssText = 'padding:6px 12px;border-radius:12px;background:#eee;border:0;font-size:14px;';
    x.addEventListener('click', function(){ ov.remove(); });
    h.appendChild(ht); h.appendChild(x);
    card.appendChild(h);
    var body = document.createElement('div');
    card.appendChild(body);
    ov.appendChild(card);
    ov.addEventListener('click', function(e){ if(e.target === ov) ov.remove(); });
    document.body.appendChild(ov);
    build(body, ov);
    return {ov: ov, body: body};
  }
  window.__v2TranslateSelection = function(){
    var sel = (window.getSelection() || '').toString().trim();
    if(sel.length < 2){ showToast('请先选中一段文字再翻译'); return; }
    trShowPanel('翻译', function(body){
      var st = document.createElement('div');
      st.style.cssText = 'color:#666;font-size:14px;';
      st.textContent = '翻译中…';
      body.appendChild(st);
      trTranslate(sel, function(i, n){ st.textContent = '翻译中 ' + i + '/' + n + '…'; }).then(function(t){
        body.innerHTML = '';
        var o = document.createElement('div');
        o.style.cssText = 'font-size:13px;color:#666;white-space:pre-wrap;margin-bottom:10px;';
        o.textContent = sel;
        var d = document.createElement('div');
        d.style.cssText = 'font-size:15px;line-height:1.7;white-space:pre-wrap;color:#2563eb;';
        d.textContent = t;
        var cp = document.createElement('button');
        cp.textContent = '复制译文';
        cp.style.cssText = 'margin-top:12px;padding:8px 16px;border-radius:12px;background:#2563eb;color:#fff;border:0;font-size:14px;';
        cp.addEventListener('click', function(){ copyText(t); showToast('译文已复制'); });
        body.appendChild(o); body.appendChild(d); body.appendChild(cp);
      }).catch(function(){ st.textContent = '翻译失败，请检查网络或翻译设置'; });
    });
  };
  window.__v2TranslatePage = function(){
    var useBYOK = !!read('trKey','');
    var cap = useBYOK ? 8000 : 2500;
    var blocks = [];
    var title = (document.querySelector('h1')||{}).textContent || '';
    if(title) blocks.push({label: '标题', text: title});
    var op = document.querySelector('.topic_content');
    if(op){
      var t = (op.textContent||'').trim();
      if(t) blocks.push({label: opName() || '楼主', text: t});
    }
    document.querySelectorAll('div.cell[id^="r_"]').forEach(function(cell){
      var a = cell.querySelector('strong a[href^="/member/"]');
      var name = a ? (a.textContent||'').trim() : '';
      var rc = cell.querySelector('.reply_content');
      if(!rc) return;
      var t2 = (rc.textContent||'').trim();
      if(t2) blocks.push({label: name, text: t2});
    });
    var total = 0; var capped = false;
    var kept = [];
    blocks.forEach(function(b){
      if(total + b.text.length > cap){ capped = true; return; }
      total += b.text.length; kept.push(b);
    });
    if(!kept.length){ showToast('本页没有可翻译的正文'); return; }
    trShowPanel('本页翻译', function(body){
      var st = document.createElement('div');
      st.style.cssText = 'color:#666;font-size:14px;';
      st.textContent = '翻译中 0/' + kept.length + '…';
      if(capped) st.textContent += '（免费接口限额，只翻前 ' + cap + ' 字）';
      body.appendChild(st);
      var done = 0;
      function nextBlock(){
        if(done >= kept.length){ st.remove(); return; }
        var b = kept[done];
        st.textContent = '翻译中 ' + (done + 1) + '/' + kept.length + '…';
        trTranslate(b.text, null).then(function(t){
          var wrap = document.createElement('div');
          wrap.style.cssText = 'margin-bottom:14px;border-bottom:1px solid #eee;padding-bottom:10px;';
          var lb = document.createElement('div');
          lb.style.cssText = 'font-size:13px;font-weight:600;color:#333;margin-bottom:4px;';
          lb.textContent = b.label;
          var orig = document.createElement('div');
          orig.style.cssText = 'font-size:13px;color:#888;white-space:pre-wrap;margin-bottom:4px;';
          orig.textContent = b.text;
          var tr = document.createElement('div');
          tr.style.cssText = 'font-size:15px;line-height:1.7;white-space:pre-wrap;color:#2563eb;';
          tr.textContent = t;
          wrap.appendChild(lb); wrap.appendChild(orig); wrap.appendChild(tr);
          body.appendChild(wrap);
          done++;
          nextBlock();
        }).catch(function(){
          done++; nextBlock();
        });
      }
      nextBlock();
    });
  };

  // ---------- 19. Re-apply all v2 features (idempotent) ----------
  function reapplyNew(){
    applyKeywords();
    applyHighlights();
    applyReadMarks();
    applyReplyVisibility();
    applyUserNotes();
    applyFolding();
    applyCodeBlocks();
  }
  var reapplyTimer = null;
  function scheduleReapply(){
    if(reapplyTimer) return;
    reapplyTimer = setTimeout(function(){ reapplyTimer = null; reapplyNew(); }, 300);
  }
  new MutationObserver(function(){ scheduleReapply(); }).observe(document.documentElement, {childList:true, subtree:true});

  // First run (native didFinish calls __v2Apply again).
  window.__v2Apply();
})();
"""

// MARK: - Quick reply template group (native-managed, UserDefaults JSON)
struct TemplateGroup: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var items: [String]
}

// MARK: - Model
final class BrowserModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    weak var webView: WKWebView?
    @Published var isDark = false
    @Published var fontScale: CGFloat = 1.0
    @Published var hideAds = true
    @Published var keywords = ""
    @Published var canGoBack = false
    // v2
    @Published var isTopicPage = false
    @Published var onlyOP = false
    @Published var isSpeaking = false
    @Published var infiniteScroll = true
    @Published var highlightKeywords = ""
    @Published var templates: [TemplateGroup] = []
    @Published var currentTitle = ""
    var lastTopicId = ""
    private let synthesizer = AVSpeechSynthesizer()

    let homeURL = URL(string: "https://www.v2ex.com/")!
    let nodes = ["程序员","Claude","Apple","iDev","问与答","分享发现","酷工作","创意","好玩","交易","Linux","OpenAI"]
    // label + path, all verified live on v2ex.com
    let shortcuts: [(String, String)] = [
        ("首页", "/"),
        ("最新", "/recent"),
        ("最热", "/top"),
        ("全部节点", "/planes"),
    ]

    override init() {
        super.init()
        synthesizer.delegate = self
        loadTemplates()
    }

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
    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
    func backToTop() {
        eval("window.__v2Top && window.__v2Top();")
    }
    func goNode(_ name: String) {
        eval("window.__v2GoNode && window.__v2GoNode(\(jsString(name)));")
    }
    func setDark(_ on: Bool) {
        isDark = on
        UserDefaults.standard.set(on, forKey: "v2ex_dark")
        eval("window.__v2SetDark && window.__v2SetDark(\(on ? "true" : "false"));")
    }
    func setFontScale(_ s: CGFloat) {
        fontScale = s
        UserDefaults.standard.set(Double(s), forKey: "v2ex_fontScale")
        webView?.pageZoom = s
    }
    func setHideAds(_ on: Bool) {
        hideAds = on
        UserDefaults.standard.set(on, forKey: "v2ex_hideAds")
        eval("window.__v2SetHideAds && window.__v2SetHideAds(\(on ? "true" : "false"));")
    }
    func setKeywords(_ s: String) {
        keywords = s
        UserDefaults.standard.set(s, forKey: "v2ex_keywords")
        eval("window.__v2SetKeywords && window.__v2SetKeywords(\(jsString(s)));")
    }
    func manualSignIn() {
        eval("window.__v2ManualSignIn && window.__v2ManualSignIn();")
    }

    // MARK: v2 — page tracking (called from the Coordinator on didFinish)
    func notePageChange(url: URL?, title: String) {
        currentTitle = title
        guard let url = url else { isTopicPage = false; return }
        let parts = url.path.split(separator: "/")
        let isTopic = parts.count >= 2 && parts[0] == "t"
        isTopicPage = isTopic
        if isTopic {
            let tid = String(parts[1])
            if tid != lastTopicId {
                lastTopicId = tid
                if onlyOP { onlyOP = false }
            }
        } else {
            lastTopicId = ""
            if onlyOP { onlyOP = false }
        }
    }

    // MARK: v2 — infinite scroll
    func setInfiniteScroll(_ on: Bool) {
        infiniteScroll = on
        UserDefaults.standard.set(on, forKey: "v2ex_infinite")
        eval("window.__v2SetInfiniteScroll && window.__v2SetInfiniteScroll(\(on ? "true" : "false"));")
    }

    // MARK: v2 — highlight keywords
    func setHighlightKeywords(_ s: String) {
        highlightKeywords = s
        UserDefaults.standard.set(s, forKey: "v2ex_hlKeywords")
        eval("window.__v2SetHighlightKeywords && window.__v2SetHighlightKeywords(\(jsString(s)));")
    }

    // MARK: v2 — only OP
    func setOnlyOP(_ on: Bool) {
        onlyOP = on
        eval("window.__v2SetOnlyOP && window.__v2SetOnlyOP(\(on ? "true" : "false"));")
    }

    // MARK: v2 — read history
    func clearReadHistory() {
        eval("window.__v2ClearRead && window.__v2ClearRead();")
    }

    // MARK: v2 — blacklist + user notes (localStorage, via JS bridge)
    func setBlockedUsers(_ csv: String) {
        eval("window.__v2SetBlockedUsers && window.__v2SetBlockedUsers(\(jsString(csv)));")
    }
    func getBlockedUsers(completion: @escaping (String) -> Void) {
        eval("window.__v2GetBlockedUsers && window.__v2GetBlockedUsers();") { result in
            completion(result as? String ?? "")
        }
    }
    func setUserNotes(json: String) {
        eval("window.__v2SetUserNotes && window.__v2SetUserNotes(\(jsString(json)));")
    }
    func getUserNotes(completion: @escaping ([(String, String)]) -> Void) {
        eval("window.__v2GetUserNotes && window.__v2GetUserNotes();") { result in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                completion([])
                return
            }
            completion(dict.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 })
        }
    }

    // MARK: v2 — search (sov2ex is the de-facto V2EX full-text search,
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

    // MARK: v2 — translation config (BYOK, on-device only)
    func getTrConfig(completion: @escaping (String, String, String) -> Void) {
        eval("window.__v2GetTrConfig && window.__v2GetTrConfig();") { result in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                completion("", "https://openrouter.ai/api/v1", "deepseek/deepseek-chat")
                return
            }
            completion(dict["key"] ?? "", dict["base"] ?? "https://openrouter.ai/api/v1", dict["model"] ?? "deepseek/deepseek-chat")
        }
    }
    func setTrConfig(key: String, base: String, model: String) {
        eval("window.__v2SetTrConfig && window.__v2SetTrConfig(\(jsString(key)), \(jsString(base)), \(jsString(model)));")
    }
    func translateSelection() {
        eval("window.__v2TranslateSelection && window.__v2TranslateSelection();")
    }
    func translatePage() {
        eval("window.__v2TranslatePage && window.__v2TranslatePage();")
    }

    // MARK: v2 — quick reply templates (UserDefaults JSON)
    func loadTemplates() {
        if let data = UserDefaults.standard.data(forKey: "v2ex_templates"),
           let groups = try? JSONDecoder().decode([TemplateGroup].self, from: data),
           !groups.isEmpty {
            templates = groups
            return
        }
        templates = [
            TemplateGroup(name: "常用", items: ["感谢分享！", "mark 一下", "学习了", "同问"]),
        ]
        saveTemplates()
    }
    func saveTemplates() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: "v2ex_templates")
        }
    }
    func insertTemplate(_ text: String) {
        // Inserts into the reply box only. Submitting is always manual:
        // the user taps the site's own reply button.
        eval("window.__v2InsertTemplate && window.__v2InsertTemplate(\(jsString(text)));")
    }

    // MARK: v2 — export Markdown / PDF / share
    func presentShare(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let root = window.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 120, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
    func exportMarkdown() {
        eval("window.__v2ExportMarkdown && window.__v2ExportMarkdown();") { [weak self] result in
            guard let self = self, let md = result as? String, !md.isEmpty else {
                self?.toast("当前页面没有可导出的帖子")
                return
            }
            let tid = self.lastTopicId.isEmpty ? "page" : self.lastTopicId
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2ex-\(tid).md")
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                self.presentShare(items: [url])
            } catch {
                self.toast("导出失败")
            }
        }
    }
    func exportPDF() {
        guard let webView = webView else { return }
        webView.createPDF { [weak self] result in
            switch result {
            case .success(let data):
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2ex-page.pdf")
                do {
                    try data.write(to: url)
                    self?.presentShare(items: [url])
                } catch {
                    self?.toast("保存 PDF 失败")
                }
            case .failure:
                self?.toast("生成 PDF 失败")
            }
        }
    }
    func shareCurrentPage() {
        guard let url = webView?.url else { return }
        var items: [Any] = [url]
        if !currentTitle.isEmpty { items.insert(currentTitle, at: 0) }
        presentShare(items: items)
    }

    // MARK: v2 — save page images to Photos
    func savePageImages() {
        eval("window.__v2CollectImages && window.__v2CollectImages();") { [weak self] result in
            guard let self = self,
                  let s = result as? String,
                  let data = s.data(using: .utf8),
                  let urls = try? JSONSerialization.jsonObject(with: data) as? [String],
                  !urls.isEmpty else {
                self?.toast("本页没有可保存的图片")
                return
            }
            self.saveImages(urls: urls)
        }
    }
    private func saveImages(urls: [String]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.toast("需要相册添加权限才能保存图片") }
                return
            }
            let group = DispatchGroup()
            var saved = 0
            let lock = NSLock()
            for urlStr in urls {
                guard let url = URL(string: urlStr) else { continue }
                group.enter()
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data = data, UIImage(data: data) != nil else {
                        group.leave()
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                    }) { ok, _ in
                        if ok {
                            lock.lock(); saved += 1; lock.unlock()
                        }
                        group.leave()
                    }
                }.resume()
            }
            group.notify(queue: .main) {
                self?.toast(saved > 0 ? "已保存 \(saved) 张图片到相册" : "图片保存失败")
            }
        }
    }

    // MARK: v2 — text to speech
    func toggleSpeak() {
        if isSpeaking {
            stopSpeaking()
            return
        }
        eval("window.__v2GetReadableText && window.__v2GetReadableText();") { [weak self] result in
            guard let self = self, let text = result as? String, !text.isEmpty else {
                self?.toast("本页没有可朗读的正文")
                return
            }
            self.speak(text: text)
        }
    }
    private func speak(text: String) {
        stopSpeaking()
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return }
        isSpeaking = true
        for p in paragraphs.prefix(60) {
            let u = AVSpeechUtterance(string: p)
            u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            u.rate = 0.52
            synthesizer.speak(u)
        }
    }
    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            if let self = self, !self.synthesizer.isSpeaking { self.isSpeaking = false }
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.isSpeaking = false }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showNodes = false
    @State private var showSettings = false
    @State private var showMore = false
    @State private var showTemplates = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
                .ignoresSafeArea(edges: .top)
            // Topic-page "更多" menu: keeps the bottom bar clean (7 buttons).
            if model.isTopicPage {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { showMore = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 52, height: 52)
                                .background(.ultraThinMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        .padding(.bottom, 96)
                    }
                }
            }
            BottomBar(model: model, showNodes: $showNodes, showSettings: $showSettings)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showNodes) { NodeSheet(model: model) }
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .sheet(isPresented: $showTemplates) { TemplatePickerSheet(model: model) }
        .confirmationDialog("帖子工具", isPresented: $showMore, titleVisibility: .visible) {
            Button(model.onlyOP ? "取消只看楼主" : "只看楼主") { model.setOnlyOP(!model.onlyOP) }
            Button("插入回复模板") { showTemplates = true }
            Button("导出 Markdown") { model.exportMarkdown() }
            Button("转 PDF") { model.exportPDF() }
            Button("保存本页图片") { model.savePageImages() }
            Button(model.isSpeaking ? "停止朗读" : "朗读本页") { model.toggleSpeak() }
            Button("翻译选中文字") { model.translateSelection() }
            Button("翻译本页") { model.translatePage() }
            Button("分享") { model.shareCurrentPage() }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            model.isDark = UserDefaults.standard.bool(forKey: "v2ex_dark")
            model.hideAds = UserDefaults.standard.object(forKey: "v2ex_hideAds") as? Bool ?? true
            model.keywords = UserDefaults.standard.string(forKey: "v2ex_keywords") ?? ""
            model.highlightKeywords = UserDefaults.standard.string(forKey: "v2ex_hlKeywords") ?? ""
            model.infiniteScroll = UserDefaults.standard.object(forKey: "v2ex_infinite") as? Bool ?? true
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
            model.notePageChange(url: webView.url, title: webView.title ?? "")
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

// MARK: - Node picker sheet (with search)
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

// MARK: - Template picker sheet (insert only; submit stays manual)
struct TemplatePickerSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.templates) { group in
                    Section(group.name) {
                        ForEach(group.items, id: \.self) { item in
                            Button {
                                model.insertTemplate(item)
                                dismiss()
                            } label: {
                                Text(item)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("插入回复模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Settings sheet
struct SettingsSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var keywordsText = ""
    @State private var highlightText = ""
    @State private var blockedText = ""
    @State private var userNotes: [(String, String)] = []
    @State private var newNoteUser = ""
    @State private var newNoteText = ""
    @State private var trKey = ""
    @State private var trBase = "https://openrouter.ai/api/v1"
    @State private var trModel = "deepseek/deepseek-chat"
    @State private var newGroupName = ""
    @State private var newItemText: [UUID: String] = [:]

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
                    Toggle("无缝翻页（滑到底自动接下一页）", isOn: Binding(
                        get: { model.infiniteScroll },
                        set: { model.setInfiniteScroll($0) }
                    ))
                }
                Section("屏蔽关键词") {
                    TextField("多个关键词用英文逗号隔开", text: $keywordsText)
                        .onChange(of: keywordsText) { model.setKeywords($0) }
                    Text("包含这些词的帖子标题会被隐藏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("高亮关键词") {
                    TextField("多个关键词用英文逗号隔开", text: $highlightText)
                        .onChange(of: highlightText) { model.setHighlightKeywords($0) }
                    Text("标题和用户名里命中这些词的会标黄，和屏蔽分开两组。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("复制高亮词（导出）") {
                        UIPasteboard.general.string = highlightText
                        model.toast("高亮词已复制")
                    }
                }
                Section("黑名单用户") {
                    TextField("多个用户名用英文逗号隔开", text: $blockedText)
                        .onChange(of: blockedText) { model.setBlockedUsers($0) }
                    Text("这些人发的帖子和回复会被隐藏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("用户备注") {
                    ForEach(userNotes, id: \.0) { pair in
                        HStack {
                            Text(pair.0).fontWeight(.medium)
                            Text(pair.1).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                userNotes.removeAll { $0.0 == pair.0 }
                                saveUserNotes()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("用户名", text: $newNoteUser)
                        TextField("备注", text: $newNoteText)
                        Button("添加") {
                            let u = newNoteUser.trimmingCharacters(in: .whitespaces)
                            let n = newNoteText.trimmingCharacters(in: .whitespaces)
                            guard !u.isEmpty, !n.isEmpty else { return }
                            userNotes.removeAll { $0.0 == u }
                            userNotes.append((u, n))
                            userNotes.sort { $0.0 < $1.0 }
                            newNoteUser = ""; newNoteText = ""
                            saveUserNotes()
                        }
                    }
                    Text("备注会显示在用户名旁边。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("快捷回复模板") {
                    Text("点一下插进回复框，提交由你自己点，绝不自动提交。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(model.templates) { group in
                        Section(group.name) {
                            ForEach(group.items, id: \.self) { item in
                                Text(item).lineLimit(2)
                            }
                            .onDelete { offsets in
                                if let idx = model.templates.firstIndex(where: { $0.id == group.id }) {
                                    model.templates[idx].items.remove(atOffsets: offsets)
                                    model.saveTemplates()
                                }
                            }
                            HStack {
                                TextField("新模板", text: Binding(
                                    get: { newItemText[group.id] ?? "" },
                                    set: { newItemText[group.id] = $0 }
                                ))
                                Button("添加") {
                                    let t = (newItemText[group.id] ?? "").trimmingCharacters(in: .whitespaces)
                                    guard !t.isEmpty else { return }
                                    if let idx = model.templates.firstIndex(where: { $0.id == group.id }) {
                                        model.templates[idx].items.append(t)
                                        model.saveTemplates()
                                    }
                                    newItemText[group.id] = ""
                                }
                            }
                            Button("删除分组", role: .destructive) {
                                model.templates.removeAll { $0.id == group.id }
                                model.saveTemplates()
                            }
                        }
                    }
                    HStack {
                        TextField("新分组名", text: $newGroupName)
                        Button("添加分组") {
                            let n = newGroupName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            model.templates.append(TemplateGroup(name: n, items: []))
                            model.saveTemplates()
                            newGroupName = ""
                        }
                    }
                }
                Section("翻译设置") {
                    SecureField("BYOK Key（可选，留空用免费接口）", text: $trKey)
                        .onChange(of: trKey) { saveTrConfig() }
                    TextField("Base URL", text: $trBase)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: trBase) { saveTrConfig() }
                    TextField("模型", text: $trModel)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: trModel) { saveTrConfig() }
                    Text("默认免费 MyMemory 接口（无需 key，每日限额）；填了 Key 后走你自己的 OpenAI 兼容接口。Key 只存在本机，不进代码仓库。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("已读记录") {
                    Button("清空已读记录", role: .destructive) { model.clearReadHistory() }
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
            .onAppear {
                keywordsText = model.keywords
                highlightText = model.highlightKeywords
                model.getBlockedUsers { blockedText = $0 }
                model.getUserNotes { userNotes = $0 }
                model.getTrConfig { key, base, m in
                    trKey = key; trBase = base; trModel = m
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveUserNotes() {
        let dict = Dictionary(uniqueKeysWithValues: userNotes)
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let json = String(data: data, encoding: .utf8) {
            model.setUserNotes(json: json)
        }
    }
    private func saveTrConfig() {
        model.setTrConfig(key: trKey, base: trBase, model: trModel)
    }
}
