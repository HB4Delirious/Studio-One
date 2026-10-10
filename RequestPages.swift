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
      .level { display:inline-block; margin-left:8px; padding:0 6px; border:1px solid; border-radius:999px;
               font-size:10px; font-weight:700; line-height:16px; vertical-align:2px; }
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
      var levels = {1: ['Easy', '#3ecf6e'], 2: ['Medium', '#FFC24B'], 3: ['Hard', '#E8388F']};
      function meta(t) {
        var m=document.createElement('div'); m.className='meta';
        var n=document.createElement('div'); n.className='name'; n.textContent=t.name;
        // How hard to sing, where the Mac knows.
        if (levels[t.level]) {
          var l=document.createElement('span'); l.className='level'; l.textContent=levels[t.level][0];
          l.style.color=levels[t.level][1]; l.style.borderColor=levels[t.level][1]; n.appendChild(l);
        }
        var a=document.createElement('div'); a.className='artist'; a.textContent=t.artist;
        m.appendChild(n); m.appendChild(a); return m;
      }
    """#

    // MARK: - Recordings

    /// A singer's recording: the photo, the song, a player and a button to
    /// keep it. `base` is its address, without a trailing slash.
    static func performance(_ recording: Performances.Recording, base: String, venue: String, expires: Date?) -> String {
        let when = recording.started.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let length = Duration.seconds(recording.seconds.rounded()).formatted(.time(pattern: .minuteSecond))
        let kept = expires.map {
            "Kept on the host's Mac until \($0.formatted(.dateTime.weekday(.wide).day().month(.wide))) — save it to keep it."
        } ?? "Save it to keep it on your phone."
        let page = #"""
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>{{name}} — your recording</title>
        <style>
        {{css}}
          .top { padding:22px 0 14px; font-weight:800; font-size:15px; letter-spacing:.04em; color:var(--pink);
                 text-transform:uppercase; }
          .photo { width:100%; border-radius:18px; display:block; margin:0 0 18px; }
          h1 { font-size:26px; line-height:1.15; margin:0 0 4px; letter-spacing:-.01em; }
          .by { color:var(--dim); font-size:15px; }
          .sung { font-size:15px; margin:10px 0 18px; }
          audio { width:100%; margin:0 0 18px; }
          .save { display:block; text-align:center; padding:15px; border-radius:999px; background:var(--pink);
                  color:#fff; font-weight:700; text-decoration:none; font-size:16px; }
          .kept { color:var(--dim); font-size:13px; text-align:center; margin:14px 4px 0; }
        </style></head><body><div class="pad">
        <div class="top">{{venue}}</div>
        {{photo}}
        <h1>{{name}}</h1>
        <div class="by">{{artist}}</div>
        <div class="sung">{{sung}}</div>
        <audio controls preload="metadata" src="{{base}}/audio"></audio>
        <a class="save" href="{{base}}/audio?download=1" download="{{name}}.m4a">Save the Recording</a>
        <p class="kept">{{kept}}</p>
        </div></body></html>
        """#
        // The page's own parts first, then what came from the song and the
        // guest, escaped.
        return page
            .replacingOccurrences(of: "{{css}}", with: Self.base)
            .replacingOccurrences(of: "{{photo}}", with: recording.hasPhoto ? "<img class=\"photo\" src=\"{{base}}/photo\" alt=\"\">" : "")
            .replacingOccurrences(of: "{{base}}", with: base)
            .replacingOccurrences(of: "{{venue}}", with: html(venue.isEmpty ? "Studio One" : venue))
            .replacingOccurrences(of: "{{artist}}", with: html(recording.artist))
            .replacingOccurrences(of: "{{sung}}", with: html((recording.singer.map { "Sung by \($0) · " } ?? "") + "\(when) · \(length)"))
            .replacingOccurrences(of: "{{kept}}", with: html(kept))
            .replacingOccurrences(of: "{{name}}", with: html(recording.name))
    }

    static let recordingGone = #"""
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Recording not found</title><style>
        """# + base + #"""
        </style></head><body><div class="pad"><p class="note">This recording isn't on the host's Mac any more.</p></div></body></html>
        """#

    private static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Guest

    /// `code` is the session's own token, shown so a guest can tell one party's
    /// code from another's.
    static func guest(code: String, lyrics: Bool) -> String {
        let page = #"""
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>Studio One — Request a song</title>
        <style>
        """# + base + #"""
          #join { position:fixed; inset:0; display:flex; flex-direction:column; }
          .splash { flex:1; background:radial-gradient(130% 90% at 50% 0%, #4a2fd0 0%, #1d1640 55%, var(--ink) 100%);
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
          #mine a { color:var(--pink); font-weight:700; }
          #game { background:linear-gradient(135deg,#E8388F,var(--deep)); border-radius:14px;
                  padding:14px 16px; margin:0 0 14px; }
          #game small { display:block; font-weight:800; font-size:12px; letter-spacing:.08em; opacity:.85; }
          #game b { display:block; font-size:22px; margin:2px 0 10px; }
          #game .row { display:flex; gap:8px; }
          #game input { flex:1; padding:11px 12px; font-size:16px; border-radius:10px; border:0;
                        background:#00000055; color:#fff; outline:none; }
          #game span { display:block; font-size:13px; opacity:.8; margin-top:8px; }
          #np { display:flex; align-items:center; gap:12px; margin:0 0 14px; padding:10px;
                border-radius:16px; background:#ffffff0d; border:1px solid #ffffff14; }
          #np img { width:56px; height:56px; border-radius:10px; object-fit:cover; flex:none;
                    background:#ffffff1a; }
          #np small { display:block; color:#5EE0D0; font-weight:800; font-size:11px; letter-spacing:.06em; }
          #np b { display:block; font-size:16px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
          #np span { display:block; color:var(--dim); font-size:13px; white-space:nowrap; overflow:hidden;
                     text-overflow:ellipsis; }
          #again { margin:0 0 16px; }
          #again .h { font-size:11px; letter-spacing:.09em; color:var(--dim); font-weight:700;
                      text-transform:uppercase; margin:2px 2px 0; }
          #again .stat { color:#FFC24B; }
          .tabs { display:flex; gap:4px; background:#ffffff10; border-radius:999px; padding:4px; margin:0 0 14px; }
          .tabs button { flex:1; background:none; color:var(--dim); padding:8px; }
          .tabs button.on { background:var(--pink); color:#fff; }
          #lyr { padding:4px 0 45vh; }
          #lyr .song { font-size:18px; font-weight:700; margin:4px 0 2px; }
          #lyr .by { color:var(--dim); font-size:14px; margin-bottom:16px; }
          #lyr p { margin:0; padding:7px 0; font-size:23px; font-weight:800; line-height:1.25;
                   color:#ffffff4d; transition:color .25s, transform .25s; transform-origin:left center; }
          #lyr p.past { color:#ffffff24; }
          #lyr p.now { color:#fff; transform:scale(1.05); }
          #lyr p.p1.now { color:#FFC24B; } #lyr p.p2.now { color:#5EE0D0; } #lyr p.p3.now { color:#E8388F; }
          #lyr .none { color:var(--dim); font-size:15px; white-space:pre-wrap; }
          #brk { background:linear-gradient(135deg,var(--violet),var(--deep)); border-radius:14px;
                 padding:14px 16px; margin:0 0 14px; }
          #brk small { display:block; color:#5EE0D0; font-weight:800; font-size:12px; letter-spacing:.06em; }
          #brk b { display:block; font-size:22px; margin:2px 0; }
          #brk span { color:#ffffffb3; font-size:14px; }
        </style></head><body>

        <div id="join">
          <div class="splash">
            <div class="brand">Studio One</div>
            <img class="puck" src="/s/__CODE__/api/icon" alt="">
            <div class="lead">You are about to join the session</div>
            <div class="code">__CODE__</div>
          </div>
          <div class="sheet">
            <h2 id="ask">What's your name?</h2>
            <div class="nickwrap">
              <input id="nick" maxlength="16" placeholder="Your name" autocomplete="off"
                     autocapitalize="words" enterkeyhint="go">
              <button class="clear" id="clearNick">&#10005;</button>
            </div>
            <div class="count"><span id="count">0</span> / 16</div>
            <button id="joinBtn" disabled>Join</button>
          </div>
        </div>

        <div id="app" class="pad" hidden>
          <div class="who"><span id="whoLabel"></span><button class="ghost" id="rename">Change</button></div>
          <div id="game" hidden><small>NAME THAT TUNE</small><b id="gameQ">What's this song?</b>
            <div class="row" id="gameRow"><input id="gameIn" placeholder="Song title" autocomplete="off"
              autocapitalize="off" enterkeyhint="go"><button id="gameGo">Guess</button></div><span id="gameNote"></span></div>
          <div class="tabs" id="tabs"><button id="tabReq" class="on">Request</button><button id="tabLyr">Lyrics</button></div>
          <div id="req">
            <div id="np" hidden><img id="npArt" alt=""><div style="min-width:0"><small>NOW SINGING</small><b id="npName"></b><span id="npBy"></span></div></div>
            <div id="mine" hidden></div>
            <div id="again" hidden><div class="h">Sing one again</div><ul id="againList"></ul></div>
            <input id="q" class="search" type="search" placeholder="Song or artist"
                   autocomplete="off" autocapitalize="off">
            <ul id="out"></ul>
            <div class="note" id="note">Type at least two letters.</div>
          </div>
          <div id="lyrPane" hidden><div id="brk" hidden></div><div id="lyr"></div></div>
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
          // Scoped to this session's code, so each night asks again — with
          // the name from last time filled in, and the songs sung before.
          var store = 'studioone.nick.__CODE__', lastName = 'studioone.name';
          function enter(name) {
            me = name;
            try { localStorage.setItem(store, name); localStorage.setItem(lastName, name); } catch (e) {}
            whoLabel.textContent = 'Requesting as ' + name;
            join.hidden = true; app.hidden = false; box.focus();
            mine(); again(); playing();
          }

          // What's on now, at the top: the song, its cover and who asked.
          var np=document.getElementById('np'), npArt=document.getElementById('npArt'),
              npName=document.getElementById('npName'), npBy=document.getElementById('npBy'), npUri=null,
              npTries=0;
          function art() { npArt.src = root + '/api/art?u=' + encodeURIComponent(npUri) + '&t=' + npTries; }
          // The Mac may not have the cover yet as a song starts: try again.
          npArt.onerror = function () {
            var u = npUri;
            if (u && npTries < 5) setTimeout(function () { if (npUri === u) { npTries++; art(); } }, 3000);
          };
          // Name that tune: the question, a box to guess in, then who got it.
          var gameBox=document.getElementById('game'), gameQ=document.getElementById('gameQ'),
              gameRow=document.getElementById('gameRow'), gameIn=document.getElementById('gameIn'),
              gameGo=document.getElementById('gameGo'), gameNote=document.getElementById('gameNote');
          function showGame(g) {
            gameBox.hidden = !g;
            if (!g) return;
            gameRow.hidden = !g.open;
            if (g.open) {
              gameQ.textContent = "What's this song?";
              gameNote.textContent = g.guesses ? (g.guesses + (g.guesses === 1 ? ' guess' : ' guesses') + ' so far') : 'First right answer wins.';
            } else {
              gameQ.textContent = g.winner ? (g.winner + ' got it!') : 'Nobody got it!';
              gameNote.textContent = g.answer || '';
            }
          }
          function sendGuess() {
            var t = gameIn.value.trim();
            if (!t) return;
            gameGo.disabled = true;
            api('/api/guess', {guess: t, nick: me}).then(function (r) {
              gameGo.disabled = false;
              if (r.correct) { say('You got it!'); gameIn.value = ''; }
              else if (r.winner) { say(r.winner + ' got it first'); }
              else { say('Not it — try again!'); }
              playing();
            }).catch(function () { gameGo.disabled = false; say('Lost the connection'); });
          }
          gameGo.onclick = sendGuess;
          gameIn.addEventListener('keydown', function (e) { if (e.key === 'Enter') sendGuess(); });
          function playing() {
            api('/api/playing').then(function (j) {
              showGame(j.game);
              // No cover to give the game away.
              npArt.style.display = (j.game && j.game.open) ? 'none' : '';
              np.hidden = !j.name;
              if (!j.name) { npUri = null; return; }
              npName.textContent = j.name;
              npBy.textContent = j.singer ? (j.artist + ' · sung by ' + j.singer) : j.artist;
              if (j.uri !== npUri) {
                npUri = j.uri;
                npTries = 0;
                npArt.style.visibility = 'hidden';
                npArt.onload = function(){ npArt.style.visibility = 'visible'; };
                art();
              }
            }).catch(function () {});
          }
          setInterval(playing, 3000);

          // Songs this name has sung here before, most recent first; one tap
          // requests one again.
          var againBox = document.getElementById('again'), againList = document.getElementById('againList');
          function again() {
            againBox.hidden = true;
            if (!me) return;
            var asked = me;
            api('/api/history?nick=' + encodeURIComponent(me)).then(function (j) {
              if (asked !== me) return;
              var songs = (j && j.songs) || [];
              againList.innerHTML = '';
              againBox.hidden = !songs.length;
              if (!songs.length) return;
              whoLabel.textContent = 'Welcome back, ' + me;
              songs.forEach(function (t) {
                var li=document.createElement('li'), m=meta(t);
                var bits = [];
                if (t.times > 1) bits.push('sung ' + t.times + '×');
                if (t.tonight) bits.push('tonight');
                if (t.best) bits.push('best cheer ' + t.best);
                if (bits.length) {
                  var s=document.createElement('span'); s.className='stat'; s.textContent=' · ' + bits.join(' · ');
                  m.lastChild.appendChild(s);
                }
                li.appendChild(m); li.appendChild(addButton(t)); againList.appendChild(li);
              });
            }).catch(function () {});
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
                if (t.recording) {
                  // Theirs to play or keep.
                  var a = document.createElement('a'); a.href = root + t.recording;
                  a.textContent = '\u25CF Your recording'; row.appendChild(a);
                } else {
                  var b = document.createElement('b'); b.textContent = place(t.position); row.appendChild(b);
                }
                row.appendChild(document.createTextNode(' · ' + t.name));
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

          function addButton(t) {
            var b=document.createElement('button'); b.textContent='Add';
            b.onclick=function(){
              b.disabled=true; b.textContent='…';
              api('/api/add', {id:t.id, nick:me}).then(function(j){
                if (j.ok) { b.textContent='Added'; say('Added ' + j.name); setTimeout(mine, 800); }
                else { b.disabled=false; b.textContent='Add'; say('Could not add that one'); }
              }).catch(function(){ b.disabled=false; b.textContent='Add'; say('Lost the connection'); });
            };
            return b;
          }
          function render(items) {
            out.innerHTML = '';
            note.style.display = items.length ? 'none' : 'block';
            if (!items.length) note.textContent = 'Nothing found in the host\'s library.';
            items.forEach(function (t) {
              var li=document.createElement('li'); li.appendChild(meta(t));
              li.appendChild(addButton(t)); out.appendChild(li);
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

          // The lyrics, following the room's screen: the line being sung lit
          // in its duet part's colour and kept in view. Where the song is
          // comes from the Mac about once a second and runs on in between.
          var tabs=document.getElementById('tabs'), req=document.getElementById('req'),
              lyrPane=document.getElementById('lyrPane'), lyr=document.getElementById('lyr'),
              brk=document.getElementById('brk'), tabReq=document.getElementById('tabReq'),
              tabLyr=document.getElementById('tabLyr');
          var song={uri:null, lines:[]}, now={pos:0, playing:false, at:0}, current=-1;
          if (!__LYRICS__) tabs.hidden = true;
          function show(lyrics) {
            lyrPane.hidden = !lyrics; req.hidden = lyrics;
            tabLyr.className = lyrics ? 'on' : ''; tabReq.className = lyrics ? '' : 'on';
            if (lyrics) poll();
          }
          tabReq.onclick = function(){ show(false); };
          tabLyr.onclick = function(){ show(true); };
          function poll() {
            if (lyrPane.hidden) return;
            api('/api/now').then(function (s) {
              now = {pos: s.pos || 0, playing: !!s.playing, at: performance.now()};
              brk.hidden = !s.break;
              if (s.break) {
                brk.innerHTML = '';
                var l=document.createElement('small'); l.textContent='UP NEXT';
                var b=document.createElement('b'); b.textContent=s.break.singer || s.break.name || 'Request a song!';
                var x=document.createElement('span');
                x.textContent = s.break.singer ? (s.break.name + ' — ' + s.break.artist) : (s.break.artist || '');
                brk.appendChild(l); brk.appendChild(b); brk.appendChild(x);
              }
              // A new song, or this one's lyrics changed: found on a second
              // try, looked up again, timed by hand.
              if (s.uri !== song.uri || s.rev !== song.rev) load(s.uri, s.rev);
            }).catch(function () {});
          }
          setInterval(poll, 1000);
          function load(uri, rev) {
            song = {uri: uri, rev: rev, lines: []}; current = -1; lyr.innerHTML = '';
            if (!uri) return;
            api('/api/lyrics').then(function (j) {
              if (j.uri !== song.uri) return;
              // Still being looked up: the revision moves when they land.
              if (j.loading) return;
              var h=document.createElement('div'); h.className='song'; h.textContent=j.name||''; lyr.appendChild(h);
              var a=document.createElement('div'); a.className='by'; a.textContent=j.artist||''; lyr.appendChild(a);
              song.lines = j.lines || [];
              if (!song.lines.length) {
                var n=document.createElement('div'); n.className='none';
                n.textContent = j.plain || 'No timed lyrics for this one yet.'; lyr.appendChild(n);
              }
              // Finish the lyric: these lines show blanks until they're sung.
              song.masked = song.lines.filter(function (line) { return line.mx; });
              song.lines.forEach(function (line) {
                var p=document.createElement('p'); p.textContent=line.mx || line.x || '♪';
                if (line.p) p.className = 'p' + line.p;
                lyr.appendChild(p); line.el = p;
              });
              current = -2;
            }).catch(function () {});
          }
          function position() { return now.pos + (now.playing ? (performance.now() - now.at) / 1000 : 0); }
          function frame() {
            if (!lyrPane.hidden && song.lines.length) {
              var t = position(), i = -1;
              (song.masked || []).forEach(function (line) {
                var shown = t < line.v ? line.mx : line.x;
                if (line.el.textContent !== shown) line.el.textContent = shown;
              });
              for (var k = 0; k < song.lines.length; k++) { if (song.lines[k].t <= t) i = k; else break; }
              if (i !== current) {
                song.lines.forEach(function (line, k) {
                  line.el.classList.toggle('now', k === i); line.el.classList.toggle('past', k < i);
                });
                current = i;
                if (i >= 0) window.scrollTo({top: song.lines[i].el.offsetTop - innerHeight * 0.3, behavior: 'smooth'});
              }
            }
            requestAnimationFrame(frame);
          }
          requestAnimationFrame(frame);

          var saved = null, before = null;
          try { saved = localStorage.getItem(store); before = localStorage.getItem(lastName); } catch (e) {}
          if (saved) { enter(saved); }
          else if (before) {
            document.getElementById('ask').textContent = 'Welcome back! Is this you?';
            nick.value = before; count.textContent = before.length; joinBtn.disabled = false;
            nick.focus();
          } else { nick.focus(); }
        </script></body></html>
        """#
        return page.replacingOccurrences(of: "__CODE__", with: code)
            .replacingOccurrences(of: "__LYRICS__", with: lyrics ? "true" : "false")
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
          .deckfoot .tx button.fade { font-size:10px; letter-spacing:.06em; }
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
              <button id="fade" class="fade" aria-label="Fade out">FADE</button>
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
          document.getElementById('fade').onclick=function(){ api('/api/command',{cmd:'fade'}).then(function(){ say('Fading out'); }); };
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
