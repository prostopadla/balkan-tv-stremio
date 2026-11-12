/*
 * Balkan setup for Lampa: does the same job as the Stremio/Kodi setup.
 *  - torrents come from Torrentio (Serbian/Croatian releases first), TorrentsDB and Peerflix
 *    instead of Russian trackers (jac.red stays as a fallback, or can be added back in settings);
 *  - subtitles: Serbian first, extra srp/hrv/bos/eng subtitles from OpenSubtitles are added to the player;
 *  - audio: Serbian/Croatian/Bosnian track is picked automatically when the release has one;
 *  - IPTV: Balkan + English playlist (same as Kodi).
 * Install: Settings -> Extensions -> Add plugin -> https://prostopadla.github.io/balkan-tv-stremio/lampa/balkan.js
 */
(function () {
  'use strict';

  if (window.balkan_plugin_ready) return;
  window.balkan_plugin_ready = true;

  var VERSION = 1;
  var PLAYLIST = 'https://prostopadla.github.io/balkan-tv-stremio/kodi.m3u';
  var SOURCES = [
    {
      name: 'Torrentio',
      url: 'https://torrentio.strem.fun/providers=yts,eztv,rarbg,1337x,ext,thepiratebay,kickasstorrents,torrentgalaxy,uindex,knaben,magnetdl|language=serbian,croatian|qualityfilter=brremux,dolbyvision,threed,scr,cam,unknown'
    },
    {
      name: 'TorrentsDB',
      url: 'https://torrentsdb.com/eyJwcm92aWRlcnMiOlsieXRzIiwiZXp0diIsIjEzMzd4IiwidG9ycmVudGNzdiIsIm55YWEiLCJsaW1ldG9ycmVudCIsInJhcmdiIiwia25hYmVuIiwidGhlcGlyYXRlYmF5Iiwia2lja2Fzc3RvcnJlbnRzIiwiYW5pbWV0b3NobyIsInRva3lvdG9zaG8iLCJleHRyZW1seW10b3JyZW50cyJdLCJsYW5ndWFnZSI6WyJzZXJiaWFuIiwiY3JvYXRpYW4iXSwicXVhbGl0eWZpbHRlciI6WyJicnJlbXV4IiwiZG9sYnl2aXNpb24iLCJzY3IiLCJjYW0iLCJ1bmtub3duIl19'
    },
    {
      name: 'Peerflix',
      url: 'https://addon.peerflix.mov/language=en%7Cqualityfilter=brremux,threed,scr,cam'
    }
  ];
  var SUBS_URL = 'https://opensubtitles-v3.strem.io';
  // OpenSubtitles (ISO 639-2) -> Lampa code and label, in order of preference
  var SUB_LANGS = [
    { os: 'srp', code: 'sr', label: 'Српски' },
    { os: 'scc', code: 'sr', label: 'Српски' },
    { os: 'hrv', code: 'hr', label: 'Hrvatski' },
    { os: 'bos', code: 'bs', label: 'Bosanski' },
    { os: 'eng', code: 'en', label: 'English' }
  ];
  var AUDIO_PREF = /^(sr|srp|scc|hr|hrv|bs|bos|sh)\b/i;
  var FLAGS = [
    ['🇷🇸', 'SRB'], // RS
    ['🇭🇷', 'HRV'], // HR
    ['🇧🇦', 'BIH'], // BA
    ['🇲🇪', 'MNE']  // ME
  ];

  var last_movie = null; // card the torrent list was opened for (used for subtitles)

  function log() {
    var a = ['Balkan'].concat([].slice.call(arguments));
    console.log.apply(console, a);
  }

  /* ---------------- one-time settings ---------------- */

  function setup(force) {
    var S = Lampa.Storage;
    if (!force && S.get('balkan_setup', 0) >= VERSION) return;

    S.set('subtitles_start', true);
    S.set('subtitles_lang', 'sr');
    S.set('parser_use', true);

    var list = S.get('iptv_playlist_custom', '[]');
    if (!Array.isArray(list)) list = [];
    var others = list.filter(function (p) {
      return p && p.url && p.url.indexOf('iptv-org.github.io') < 0 && p.url !== PLAYLIST;
    });
    others.unshift({ id: 'balkan_tv', custom: true, url: PLAYLIST, name: 'Balkan + English TV' });
    S.set('iptv_playlist_custom', others);

    S.set('balkan_setup', VERSION);
    log('settings applied');
    if (force) Lampa.Noty.show('Балканские настройки применены');
  }

  /* ---------------- torrents ---------------- */

  function request(url, ok, fail) {
    var net = new Lampa.Reguest();
    net.timeout(20000);
    net.silent(url, ok, fail || function () { ok(null); });
  }

  function imdbFor(movie, done) {
    var id = movie.imdb_id || (movie.external_ids && movie.external_ids.imdb_id);
    if (id) return done(id);
    if (!movie.id) return done(null);
    var type = movie.original_name || movie.number_of_seasons ? 'tv' : 'movie';
    request(Lampa.TMDB.api(type + '/' + movie.id + '/external_ids?api_key=' + Lampa.TMDB.key()), function (json) {
      done(json && json.imdb_id || null);
    }, function () { done(null); });
  }

  function parseSize(str) {
    var m = /([\d.,]+)\s*(TB|GB|MB|KB)/i.exec(str || '');
    if (!m) return 0;
    var mult = { tb: 1099511627776, gb: 1073741824, mb: 1048576, kb: 1024 }[m[2].toLowerCase()];
    return Math.round(parseFloat(m[1].replace(',', '.')) * mult);
  }

  function toResult(stream, source) {
    if (!stream || !stream.infoHash) return null;
    var lines = (stream.title || '').split('\n');
    var info = lines.filter(function (l) { return l.indexOf('👤') >= 0; })[0] || ''; // line with seeders
    var seeds = parseInt((/👤\s*(\d+)/.exec(info) || [])[1] || '0');
    var size = parseSize(info);
    var tracker = (/(?:⚙️|🌐)\s*(.+)$/.exec(info) || [])[1] || source;
    var name = lines[0] || stream.behaviorHints && stream.behaviorHints.filename || stream.infoHash;
    var file = lines[1] && lines[1] !== info && lines[1].indexOf('👤') < 0 ? lines[1] : '';

    var langs = [];
    FLAGS.forEach(function (f) { if ((stream.title || '').indexOf(f[0]) >= 0) langs.push(f[1]); });
    if (/multi audio/i.test(stream.title || '')) langs.push('MULTI');
    var quality = (stream.name || '').split('\n').slice(1).join(' ');

    var title = (langs.length ? '[' + langs.join(' ') + '] ' : '') + name;
    if (file && file.indexOf(name) < 0 && /S\d\dE\d\d/i.test(file)) title += ' / ' + file.split('/').pop();
    if (quality) title += ' [' + quality + ']';

    var trackers = (stream.sources || []).filter(function (s) { return s.indexOf('tracker:') === 0; })
      .slice(0, 15).map(function (s) { return '&tr=' + encodeURIComponent(s.slice(8)); }).join('');
    var magnet = 'magnet:?xt=urn:btih:' + stream.infoHash.toLowerCase() + '&dn=' + encodeURIComponent(name) + trackers;

    return {
      Title: title,
      Tracker: source + (tracker && tracker !== source ? ' / ' + tracker.trim() : ''),
      Size: size,
      size: Lampa.Utils.bytesToSize(size),
      PublishDate: '',
      PublisTime: 0,
      Seeders: seeds,
      Peers: 0,
      MagnetUri: magnet,
      hash: Lampa.Utils.hash(stream.infoHash.toLowerCase()),
      viewed: false,
      checked_at: Date.now(),
      source_rank: 0,
      balkan_lang: langs.length ? 1 : 0
    };
  }

  function stremioSearch(movie, done) {
    imdbFor(movie, function (imdb) {
      if (!imdb) return done([]);
      var serial = !!(movie.original_name || movie.number_of_seasons);
      var ids = [];
      if (serial) {
        var seasons = Math.min(movie.number_of_seasons || 1, 12);
        for (var s = 1; s <= seasons; s++) ids.push('series/' + imdb + ':' + s + ':1');
      } else ids.push('movie/' + imdb);

      var calls = [];
      SOURCES.forEach(function (src) {
        ids.forEach(function (id) { calls.push({ src: src, url: src.url + '/stream/' + id + '.json' }); });
      });

      var pending = calls.length;
      var seen = {};
      var out = [];
      calls.forEach(function (c) {
        request(c.url, function (json) {
          (json && json.streams || []).forEach(function (st) {
            var r = toResult(st, c.src.name);
            if (r && !seen[r.MagnetUri.slice(20, 60)]) {
              seen[r.MagnetUri.slice(20, 60)] = true;
              out.push(r);
            }
          });
          if (--pending === 0) {
            // Balkan-language releases first, then by seeders
            out.sort(function (a, b) { return (b.balkan_lang - a.balkan_lang) || (b.Seeders - a.Seeders); });
            log('stremio sources:', out.length, 'results for', imdb);
            done(out);
          }
        });
      });
    });
  }

  function hookParser() {
    var original = Lampa.Parser.get;
    Lampa.Parser.get = function (params, oncomplite, onerror) {
      var movie = params && params.movie;
      if (!movie || params.from_search || params.clarification) return original.apply(this, arguments);
      last_movie = movie;
      var with_ru = Lampa.Storage.field('balkan_ru_trackers');

      stremioSearch(movie, function (results) {
        if (!with_ru && results.length) return oncomplite({ Results: results });
        // Russian trackers requested, or nothing found: ask jac.red too
        original.call(Lampa.Parser, params, function (json) {
          var ru = json && json.Results || [];
          oncomplite({ Results: results.concat(ru) });
        }, function (e) {
          if (results.length) oncomplite({ Results: results });else onerror(e);
        });
      });
    };
  }

  /* ---------------- subtitles ---------------- */

  function fetchSubs(element, done) {
    if (!last_movie) return done([]);
    imdbFor(last_movie, function (imdb) {
      if (!imdb) return done([]);
      var serial = !!(last_movie.original_name || last_movie.number_of_seasons);
      var id;
      if (serial) {
        if (!element.season || !element.episode) return done([]);
        id = 'series/' + imdb + ':' + element.season + ':' + element.episode;
      } else id = 'movie/' + imdb;

      request(SUBS_URL + '/subtitles/' + id + '.json', function (json) {
        var subs = json && json.subtitles || [];
        var out = [];
        SUB_LANGS.forEach(function (l) {
          subs.filter(function (s) { return s.lang === l.os; }).slice(0, 3).forEach(function (s, i) {
            out.push({ label: l.label + ' ' + (i + 1) + ' (OpenSubtitles)', url: s.url, language: l.code, lang: l.code });
          });
        });
        done(out);
      });
    });
  }

  function hookPlayer() {
    var original = Lampa.Player.play;
    Lampa.Player.play = function (element) {
      var self = this;
      var args = arguments;
      var is_torrent = element && typeof element.url == 'string' && /\/stream\b|:8090/.test(element.url) && !element.iptv;
      if (!is_torrent || element.balkan_subs) return original.apply(self, args);

      var finished = false;
      var timer = setTimeout(go, 6000); // never hold the player for long
      fetchSubs(element, function (subs) {
        if (finished) return;
        if (subs.length) {
          // put Serbian/Croatian ones ahead of whatever is inside the torrent
          var mine = (element.subtitles || []).filter(function (s) { return s; });
          element.subtitles = subs.concat(mine);
          (element.playlist || []).forEach(function (p) {
            if (p.url === element.url) p.subtitles = element.subtitles;
          });
        }
        go();
      });

      function go() {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        element.balkan_subs = true;
        original.apply(self, args);
      }
    };
  }

  function hookAudio() {
    if (!Lampa.PlayerVideo || !Lampa.PlayerVideo.listener) return;
    Lampa.PlayerVideo.listener.follow('tracks', function (e) {
      var tracks = e.tracks || [];
      var current = tracks.filter(function (t) { return t.selected || t.enabled === true; })[0];
      if (current && AUDIO_PREF.test(current.language || current.lang || '')) return;
      var pick = tracks.filter(function (t) { return AUDIO_PREF.test(t.language || t.lang || ''); })[0];
      if (!pick) return;
      try {
        tracks.forEach(function (t) { t.selected = false; });
        pick.enabled = true;
        pick.selected = true;
        log('audio track switched to', pick.language || pick.lang);
      } catch (err) {}
    });
  }

  /* ---------------- settings page ---------------- */

  function addSettings() {
    if (!Lampa.SettingsApi) return;
    Lampa.SettingsApi.addComponent({
      component: 'balkan',
      name: 'Балканы',
      icon: '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="4" width="20" height="5" fill="#c6363c"/><rect x="2" y="9" width="20" height="5" fill="#0c4076"/><rect x="2" y="14" width="20" height="5" fill="#ffffff"/></svg>'
    });
    Lampa.SettingsApi.addParam({
      component: 'balkan',
      param: { name: 'balkan_ru_trackers', type: 'trigger', 'default': false },
      field: {
        name: 'Русские трекеры тоже',
        description: 'Кроме Torrentio / TorrentsDB / Peerflix искать ещё через jac.red (раздачи с русской озвучкой)'
      }
    });
    Lampa.SettingsApi.addParam({
      component: 'balkan',
      param: { name: 'balkan_reapply', type: 'button' },
      field: {
        name: 'Применить настройки заново',
        description: 'Сербские субтитры по умолчанию и плейлист Balkan + English TV'
      },
      onChange: function () { setup(true); }
    });
  }

  function start() {
    try { setup(false); } catch (e) { log('setup error', e); }
    try { hookParser(); } catch (e) { log('parser hook error', e); }
    try { hookPlayer(); } catch (e) { log('player hook error', e); }
    try { hookAudio(); } catch (e) { log('audio hook error', e); }
    try { addSettings(); } catch (e) { log('settings error', e); }
    log('ready');
  }

  if (window.appready) start();
  else Lampa.Listener.follow('app', function (e) { if (e.type == 'ready') start(); });
})();
