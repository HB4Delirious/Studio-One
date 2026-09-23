import Foundation

/// The two pages the request server serves.
///
/// Self-contained on purpose: phones at a party are on a network whose only job
/// right now is this Mac, and a CDN round trip is a blank screen if the Wi-Fi
/// has no route out. Kept here rather than in `RequestServer` so the server
/// reads as routing rather than as markup.
enum RequestPages {

    private static let base = #"""
      :root { color-scheme: dark; --violet:#5B3BE8; --deep:#3B1FB0; --pink:#E8388F;
              --ink:#0B0A14; --panel:#161523; --dim:#6b6b85; }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      /* `[hidden]` hides through a UA rule, which any author `display` here
         outranks. Without this, setting .hidden changed nothing on screen. */
      [hidden] { display: none !important; }
      html, body { margin:0; background:var(--ink); color:#fff;
             font:16px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif; }
      input, button { font-family:inherit; }
      .pad { padding:0 18px max(22px,env(safe-area-inset-bottom)); }
      ul { list-style:none; margin:0; padding:0; }
      li { display:flex; align-items:center; gap:12px; padding:12px 2px; border-bottom:1px solid #ffffff0d; }
      .meta { min-width:0; flex:1; }
      .name { font-size:15px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .artist { font-size:13px; color:var(--dim); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .search { width:100%; padding:14px 16px; font-size:17px; border-radius:12px;
                border:1px solid #ffffff14; background:var(--panel); color:#fff; outline:none; }
      .search:focus { border-color:var(--pink); }
      button { border:0; border-radius:999px; padding:9px 16px; font-size:14px; font-weight:600;
               background:var(--pink); color:#fff; }
      button:disabled { background:#ffffff1a; color:var(--dim); }
      .ghost { background:#ffffff14; color:#fff; }
      .row { display:flex; gap:8px; flex:none; }
      .note { color:var(--dim); font-size:14px; padding:20px 4px; text-align:center; }
      #toast { position:fixed; left:50%; transform:translateX(-50%);
               bottom:max(22px,env(safe-area-inset-bottom)); background:#FFC24B; color:#1a1206;
               padding:11px 18px; border-radius:999px; font-size:14px; font-weight:600;
               opacity:0; transition:opacity .2s; pointer-events:none; max-width:88vw; z-index:9; }
      #toast.on { opacity:1; }
    """#

    private static let helpers = #"""
      var toast = document.getElementById('toast');
      function say(text) {
        toast.textContent = text; toast.className = 'on';
        setTimeout(function () { toast.className = ''; }, 2200);
      }
      var root = location.pathname.replace(/\/+$/, '');
      function api(path, body) {
        var opts = body ? { method:'POST', headers:{'Content-Type':'application/json'},
                            body: JSON.stringify(body) } : {};
        return fetch(root + path, opts).then(function (r) { return r.json(); });
      }
      function meta(t) {
        var m=document.createElement('div'); m.className='meta';
        var n=document.createElement('div'); n.className='name'; n.textContent=t.name;
        var a=document.createElement('div'); a.className='artist'; a.textContent=t.artist;
        m.appendChild(n); m.appendChild(a); return m;
      }
    """#

    // MARK: - Guest

    /// `code` is the session's own token, shown so a guest can tell one party's
    /// code from another's.
    static func guest(code: String) -> String {
        let page = #"""
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>Studio One — Request a song</title>
        <style>
        """# + base + #"""
          #join { position:fixed; inset:0; display:flex; flex-direction:column; }
          .splash { flex:1; background:linear-gradient(160deg,var(--violet),var(--deep));
                    display:flex; flex-direction:column; align-items:center; justify-content:center;
                    text-align:center; padding:28px; }
          .brand { font-size:30px; font-weight:800; letter-spacing:-.02em; }
          .puck { width:112px; height:112px; border-radius:26px; margin:26px 0 22px;
                  display:block; box-shadow:0 10px 30px #00000055; }
          .lead { font-size:17px; font-weight:600; opacity:.92; }
          .code { font:700 30px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;
                  letter-spacing:.14em; margin-top:8px; text-transform:uppercase; }
          .sheet { background:var(--ink); padding:22px 18px max(24px,env(safe-area-inset-bottom));
                   text-align:center; }
          .sheet h2 { font-size:16px; margin:0 0 16px; }
          .nickwrap { position:relative; }
          .nickwrap input { width:100%; padding:15px 44px 15px 16px; font-size:17px; border-radius:12px;
                            border:2px solid var(--pink); background:#00000055; color:#fff; outline:none; }
          .clear { position:absolute; right:6px; top:50%; transform:translateY(-50%);
                   background:none; color:var(--dim); font-size:19px; padding:8px 12px; }
          .count { text-align:right; color:var(--dim); font-size:12px; margin:6px 2px 16px; }
          #joinBtn { width:70%; padding:14px; font-size:16px; }
          .who { display:flex; align-items:center; justify-content:space-between;
                 padding:14px 0 10px; }
          .who span { color:var(--dim); font-size:13px; }
          .who button { padding:6px 12px; font-size:12px; }
          #mine { background:#ffffff10; border-radius:12px; padding:10px 14px; margin:0 0 14px;
                  font-size:14px; line-height:1.5; }
          #mine b { color:var(--pink); }
        </style></head><body>

        <div id="join">
          <div class="splash">
            <div class="brand">Studio One</div>
            <img class="puck" src="/s/__CODE__/api/icon" alt="">
            <div class="lead">You are about to join the session</div>
            <div class="code">__CODE__</div>
          </div>
          <div class="sheet">
            <h2>What is your Nickname?</h2>
            <div class="nickwrap">
              <input id="nick" maxlength="16" placeholder="Your name" autocomplete="off"
                     autocapitalize="words" enterkeyhint="go">
              <button class="clear" id="clearNick">&#10005;</button>
            </div>
            <div class="count"><span id="count">0</span> / 16</div>
            <button id="joinBtn" disabled>Join session</button>
          </div>
        </div>

        <div id="app" class="pad" hidden>
          <div class="who"><span id="whoLabel"></span><button class="ghost" id="rename">Change</button></div>
          <div id="mine" hidden></div>
          <input id="q" class="search" type="search" placeholder="Song or artist"
                 autocomplete="off" autocapitalize="off">
          <ul id="out"></ul>
          <div class="note" id="note">Type at least two letters.</div>
        </div>
        <div id="toast"></div>

        <script>
        """# + helpers + #"""
          var join=document.getElementById('join'), app=document.getElementById('app'),
              nick=document.getElementById('nick'), count=document.getElementById('count'),
              joinBtn=document.getElementById('joinBtn'), box=document.getElementById('q'),
              out=document.getElementById('out'), note=document.getElementById('note'),
              whoLabel=document.getElementById('whoLabel'), timer, me='';

          // Remembered per phone, so nobody re-types their name every song.
          // Scoped to this session's code: a different party asks again.
          var store = 'studioone.nick.__CODE__';
          function enter(name) {
            me = name;
            try { localStorage.setItem(store, name); } catch (e) {}
            whoLabel.textContent = 'Requesting as ' + name;
            join.hidden = true; app.hidden = false; box.focus();
            mine();
          }

          // Where your requests stand, from the host's real queue.
          var mineBox = document.getElementById('mine');
          function place(n) {
            if (n === 0) return 'Singing now';
            if (n === 1) return 'You\'re next';
            var s = ['th','st','nd','rd'], v = n % 100;
            return n + (s[(v - 20) % 10] || s[v] || s[0]) + ' in line';
          }
          function mine() {
            if (!me) return;
            api('/api/mine?nick=' + encodeURIComponent(me)).then(function (items) {
              mineBox.hidden = !items.length;
              mineBox.innerHTML = '';
              items.forEach(function (t) {
                var row = document.createElement('div');
                var b = document.createElement('b'); b.textContent = place(t.position);
                row.appendChild(b); row.appendChild(document.createTextNode(' · ' + t.name));
                mineBox.appendChild(row);
              });
            }).catch(function () {});
          }
          setInterval(mine, 8000);
          nick.addEventListener('input', function () {
            count.textContent = nick.value.length;
            joinBtn.disabled = nick.value.trim().length === 0;
          });
          nick.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' && !joinBtn.disabled) enter(nick.value.trim());
          });
          document.getElementById('clearNick').onclick = function () {
            nick.value = ''; count.textContent = '0'; joinBtn.disabled = true; nick.focus();
          };
          joinBtn.onclick = function () { enter(nick.value.trim()); };
          document.getElementById('rename').onclick = function () {
            join.hidden = false; app.hidden = true;
            nick.value = me; count.textContent = me.length; joinBtn.disabled = false; nick.focus();
          };

          function render(items) {
            out.innerHTML = '';
            note.style.display = items.length ? 'none' : 'block';
            if (!items.length) note.textContent = 'Nothing found in the host\'s library.';
            items.forEach(function (t) {
              var li=document.createElement('li'); li.appendChild(meta(t));
              var b=document.createElement('button'); b.textContent='Add';
              b.onclick=function(){
                b.disabled=true; b.textContent='…';
                api('/api/add', {id:t.id, nick:me}).then(function(j){
                  if (j.ok) { b.textContent='Added'; say('Added ' + j.name); setTimeout(mine, 800); }
                  else { b.disabled=false; b.textContent='Add'; say('Could not add that one'); }
                }).catch(function(){ b.disabled=false; b.textContent='Add'; say('Lost the connection'); });
              };
              li.appendChild(b); out.appendChild(li);
            });
          }
          function search() {
            var q = box.value.trim();
            if (q.length < 2) { out.innerHTML=''; note.style.display='block';
                                note.textContent='Type at least two letters.'; return; }
            note.style.display='block'; note.textContent='Searching…';
            // Numbered, so a slow answer to an earlier query can't land over
            // the answer to a later one.
            var mine = ++asked;
            api('/api/search?q=' + encodeURIComponent(q))
              .then(function (items) { if (mine === asked) render(items); })
              .catch(function(){ if (mine === asked) note.textContent='Lost the connection to the Mac.'; });
          }
          var asked = 0;
          // Every keystroke would be an Apple Event into Music; wait for a pause.
          box.addEventListener('input', function(){ clearTimeout(timer); timer=setTimeout(search, 280); });

          var saved = null;
          try { saved = localStorage.getItem(store); } catch (e) {}
          if (saved) { enter(saved); } else { nick.focus(); }
        </script></body></html>
        """#
        return page.replacingOccurrences(of: "__CODE__", with: code)
    }

    // MARK: - Remote

    static var remote: String {
        #"""
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>Studio One — Remote</title>
        <style>
        """# + base + #"""
          .deck { background:linear-gradient(165deg,var(--violet),var(--deep));
                  padding:max(18px,env(safe-area-inset-top)) 18px 22px;
                  border-radius:0 0 22px 22px; }
          .now { display:flex; align-items:center; gap:12px; }
          .thumb { width:52px; height:52px; border-radius:9px; flex:none; object-fit:cover;
                   background:#ffffff1f; }
          .now .meta .name { font-size:17px; font-weight:700; }
          .now .meta .artist { color:#ffffffb0; }
          .lbl { font-size:14px; margin:20px 0 8px; opacity:.95; }
          .slider { -webkit-appearance:none; appearance:none; width:100%; height:10px; padding:0;
                    border:0; border-radius:999px; background:#ffffff33; }
          .slider::-webkit-slider-thumb { -webkit-appearance:none; width:30px; height:30px;
                    border-radius:50%; background:#fff; box-shadow:0 2px 8px #0006; }
          /* Two steppers have to fit a 375pt phone inside 18pt padding, so the
             pieces are sized to 296pt total rather than left to overflow. */
          .steps { display:flex; justify-content:space-between; margin-top:22px; }
          .step { text-align:center; }
          .step .cap { font-size:13px; opacity:.9; margin-bottom:8px; }
          .step .line { display:flex; align-items:center; gap:9px; }
          .step .val { min-width:52px; font-size:18px; font-weight:700; }
          .step button { width:40px; height:40px; padding:0; font-size:20px; line-height:1;
                         flex:none; background:transparent; border:2px solid #ffffff8a; color:#fff; }
          .step button:disabled { border-color:#ffffff3a; color:#ffffff5a; }
          .reset { display:block; margin:16px auto 0; padding:5px 14px; font-size:12px;
                   background:#ffffff26; }
          .deckfoot { display:flex; align-items:center; justify-content:space-between;
                      margin-top:20px; }
          .deckfoot .tx { display:flex; gap:14px; }
          .deckfoot .tx button { width:46px; height:46px; padding:0; border-radius:50%;
                                 background:#ffffff26; font-size:16px; }
          .lower { padding:18px 18px max(22px,env(safe-area-inset-bottom)); }
          .head { font-size:11px; letter-spacing:.09em; color:#5a5a72; font-weight:700; margin:22px 0 2px; }
          .grab { display:flex; flex-direction:column; gap:3px; flex:none; }
          .grab button { width:38px; height:26px; padding:0; font-size:11px; line-height:1;
                         background:#ffffff14; color:#c9c9dd; border-radius:7px; }
          #results:empty { display:none; }
        </style></head><body>

        <div class="deck">
          <div class="now">
            <img class="thumb" id="art" alt="">
            <div class="meta">
              <div class="name" id="title">—</div>
              <div class="artist" id="by"></div>
            </div>
          </div>

          <div class="lbl">Volume</div>
          <input class="slider" id="vol" type="range" min="0" max="100" value="100">

          <div class="steps">
            <div class="step">
              <div class="cap">Key</div>
              <div class="line">
                <button id="keyDown">&minus;</button>
                <span class="val" id="keyVal">—</span>
                <button id="keyUp">+</button>
              </div>
            </div>
            <div class="step">
              <div class="cap">Tempo</div>
              <div class="line">
                <button id="bpmDown">&minus;</button>
                <span class="val" id="bpmVal">—</span>
                <button id="bpmUp">+</button>
              </div>
            </div>
          </div>
          <button class="reset" id="reset" hidden>Back to detected</button>

          <div class="deckfoot">
            <div class="times"><span id="pos">0:00</span> / <span id="dur">0:00</span></div>
            <div class="tx">
              <button id="prev">&#9664;&#9664;</button>
              <button id="pp">&#9654;</button>
              <button id="next">&#9654;&#9654;</button>
            </div>
          </div>
          <input class="slider" id="seek" type="range" min="0" max="1000" value="0"
                 style="height:6px;margin-top:12px">
        </div>

        <div class="lower">
          <input id="q" class="search" type="search" placeholder="Search the library"
                 autocomplete="off" autocapitalize="off">
          <ul id="results"></ul>
          <div class="note" id="snote" style="display:none"></div>
          <div class="head">UP NEXT</div>
          <ul id="queue"></ul>
          <div class="note" id="qnote">Nothing queued.</div>
        </div>
        <div id="toast"></div>

        <script>
        """# + helpers + #"""
          var art=document.getElementById('art'), titleEl=document.getElementById('title'),
              byEl=document.getElementById('by'), keyVal=document.getElementById('keyVal'),
              bpmVal=document.getElementById('bpmVal'), reset=document.getElementById('reset'),
              vol=document.getElementById('vol'), seek=document.getElementById('seek'),
              posEl=document.getElementById('pos'), durEl=document.getElementById('dur'),
              pp=document.getElementById('pp'), queue=document.getElementById('queue'),
              qnote=document.getElementById('qnote'), box=document.getElementById('q'),
              results=document.getElementById('results'), snote=document.getElementById('snote');
          var dragging=false, volDragging=false, duration=0, lastArt='', editable=false, busy=false;

          function mmss(s){ s=Math.max(0,Math.round(s||0));
            return Math.floor(s/60)+':'+('0'+(s%60)).slice(-2); }

          function paint(st) {
            titleEl.textContent = st.name || 'Nothing playing';
            byEl.textContent = st.artist || '';
            // Always shown, even when unknown: a value that disappears reads as
            // a broken feature rather than as missing data.
            keyVal.textContent = st.key ? st.key : '—';
            bpmVal.textContent = st.tempo ? st.tempo : '—';
            reset.hidden = !st.corrected;
            pp.innerHTML = st.playing ? '&#10074;&#10074;' : '&#9654;';
            duration = st.duration || 0;
            durEl.textContent = mmss(duration);
            if (!dragging) {
              posEl.textContent = mmss(st.position);
              seek.value = duration > 0 ? Math.round(st.position / duration * 1000) : 0;
            }
            if (!volDragging && typeof st.volume === 'number') vol.value = st.volume;
            if (st.artKey && st.artKey !== lastArt) {
              lastArt = st.artKey; art.src = root + '/api/artwork?k=' + encodeURIComponent(st.artKey);
            }
            editable = !!st.queueEditable;
            if (busy) return;
            queue.innerHTML = '';
            (st.queue || []).forEach(function (t, i) {
              var li=document.createElement('li'); li.appendChild(meta(t));
              if (editable) {
                var g=document.createElement('div'); g.className='grab';
                var up=document.createElement('button'); up.innerHTML='&#9650;'; up.disabled = i===0;
                up.onclick=function(){ move(i, i-1); };
                var dn=document.createElement('button'); dn.innerHTML='&#9660;';
                dn.disabled = i===(st.queue.length-1);
                dn.onclick=function(){ move(i, i+1); };
                g.appendChild(up); g.appendChild(dn); li.appendChild(g);
              }
              queue.appendChild(li);
            });
            qnote.style.display = (st.queue && st.queue.length) ? 'none' : 'block';
            qnote.textContent = editable ? 'Nothing queued.'
              : 'Playing from one of your playlists — start the requests playlist to rearrange it.';
          }
          function move(from, to) {
            busy = true;
            var rows = queue.children;
            queue.insertBefore(rows[from], to > from ? rows[to].nextSibling : rows[to]);
            api('/api/reorder', {from:from, to:to})
              .then(function(){ busy=false; setTimeout(tick, 600); })
              .catch(function(){ busy=false; say('Could not move that'); });
          }
          function tick(){ api('/api/state').then(paint).catch(function(){}); }

          pp.onclick=function(){ api('/api/command',{cmd:'playpause'}).then(tick); };
          document.getElementById('next').onclick=function(){ api('/api/command',{cmd:'next'}).then(function(){ setTimeout(tick,500); }); };
          document.getElementById('prev').onclick=function(){ api('/api/command',{cmd:'prev'}).then(function(){ setTimeout(tick,500); }); };
          document.getElementById('keyUp').onclick=function(){ api('/api/nudge',{what:'key',by:1}).then(function(){ setTimeout(tick,250); }); };
          document.getElementById('keyDown').onclick=function(){ api('/api/nudge',{what:'key',by:-1}).then(function(){ setTimeout(tick,250); }); };
          document.getElementById('bpmUp').onclick=function(){ api('/api/nudge',{what:'tempo',by:1}).then(function(){ setTimeout(tick,250); }); };
          document.getElementById('bpmDown').onclick=function(){ api('/api/nudge',{what:'tempo',by:-1}).then(function(){ setTimeout(tick,250); }); };
          reset.onclick=function(){ api('/api/nudge',{what:'reset'}).then(function(){ setTimeout(tick,250); }); };

          seek.addEventListener('input', function(){ dragging=true;
            posEl.textContent = mmss(seek.value/1000*duration); });
          // The drag flags clear whether the request worked or not: cleared
          // only on success, one dropped request froze the slider for good.
          seek.addEventListener('change', function(){
            if (!(duration > 0)) { dragging=false; return; }
            var done = function(){ dragging=false; setTimeout(tick,400); };
            api('/api/command',{cmd:'seek',to:seek.value/1000*duration})
              .then(done, function(){ done(); say('Lost the connection'); }); });
          vol.addEventListener('input', function(){ volDragging = true; });
          vol.addEventListener('change', function(){
            var done = function(){ volDragging=false; };
            api('/api/volume',{value:parseInt(vol.value,10)})
              .then(done, function(){ done(); say('Lost the connection'); }); });

          var timer;
          function render(items) {
            results.innerHTML='';
            snote.style.display = items.length ? 'none' : 'block';
            if (!items.length) snote.textContent='Nothing found in the library.';
            items.forEach(function(t){
              var li=document.createElement('li'); li.appendChild(meta(t));
              var wrap=document.createElement('div'); wrap.className='row';
              var qb=document.createElement('button'); qb.className='ghost'; qb.textContent='Queue';
              qb.onclick=function(){ qb.disabled=true;
                api('/api/add',{id:t.id}).then(function(j){ qb.textContent=j.ok?'Queued':'Failed';
                  if(j.ok) say('Queued ' + j.name); setTimeout(tick,600); })
                  .catch(function(){ qb.disabled=false; say('Lost the connection'); }); };
              var nb=document.createElement('button'); nb.textContent='Play';
              nb.onclick=function(){ nb.disabled=true;
                api('/api/play',{id:t.id}).then(function(){ say('Playing ' + t.name);
                  nb.disabled=false; setTimeout(tick,700); })
                  .catch(function(){ nb.disabled=false; say('Lost the connection'); }); };
              wrap.appendChild(qb); wrap.appendChild(nb);
              li.appendChild(wrap); results.appendChild(li);
            });
          }
          function search() {
            var q = box.value.trim();
            if (q.length < 2) { results.innerHTML=''; snote.style.display='none'; return; }
            snote.style.display='block'; snote.textContent='Searching…';
            var mine = ++asked;
            api('/api/search?q=' + encodeURIComponent(q))
              .then(function (items) { if (mine === asked) render(items); })
              .catch(function(){ if (mine === asked) snote.textContent='Lost the connection to the Mac.'; });
          }
          var asked = 0;
          box.addEventListener('input', function(){ clearTimeout(timer); timer=setTimeout(search,280); });

          tick();
          setInterval(tick, 2000);
        </script></body></html>
        """#
    }
}
