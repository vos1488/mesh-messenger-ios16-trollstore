package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/skip2/go-qrcode"
)

type bridgeSession struct {
	ID         string
	CreatedAt  time.Time
	WebConn    *websocket.Conn
	MobileConn *websocket.Conn
	Authorized bool
	PeerID     string
	Nickname   string
	mu         sync.Mutex
}

type sessionHub struct {
	sessions map[string]*bridgeSession
	mu       sync.RWMutex
}

func newSessionHub() *sessionHub {
	return &sessionHub{
		sessions: make(map[string]*bridgeSession),
	}
}

func (h *sessionHub) createSession() *bridgeSession {
	id := randomID(12)
	s := &bridgeSession{
		ID:        id,
		CreatedAt: time.Now(),
	}
	h.mu.Lock()
	h.sessions[id] = s
	h.mu.Unlock()
	return s
}

func (h *sessionHub) get(id string) *bridgeSession {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.sessions[id]
}

func (h *sessionHub) cleanup(ttl time.Duration) {
	ticker := time.NewTicker(2 * time.Minute)
	for range ticker.C {
		cutoff := time.Now().Add(-ttl)
		h.mu.Lock()
		for id, s := range h.sessions {
			s.mu.Lock()
			empty := s.WebConn == nil && s.MobileConn == nil
			created := s.CreatedAt
			s.mu.Unlock()
			if empty && created.Before(cutoff) {
				delete(h.sessions, id)
			}
		}
		h.mu.Unlock()
	}
}

type server struct {
	hub      *sessionHub
	upgrader websocket.Upgrader
}

func newServer() *server {
	return &server{
		hub: newSessionHub(),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
}

func (s *server) routes() {
	http.HandleFunc("/", s.handleIndex)
	http.HandleFunc("/api/session", s.handleCreateSession)
	http.HandleFunc("/ws/web/", s.handleWebSocketWeb)
	http.HandleFunc("/ws/mobile/", s.handleWebSocketMobile)
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(indexHTML))
}

func (s *server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	session := s.hub.createSession()
	baseWS := wsBaseURL(r)
	mobileWS := baseWS + "/ws/mobile/" + session.ID
	payload := "meshweb://pair?sid=" + url.QueryEscape(session.ID) + "&ws=" + url.QueryEscape(mobileWS)

	png, err := qrcode.Encode(payload, qrcode.Medium, 320)
	if err != nil {
		http.Error(w, "failed to build QR", http.StatusInternalServerError)
		return
	}
	dataURL := "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)

	resp := map[string]any{
		"session_id":   session.ID,
		"mobile_ws":    mobileWS,
		"pair_payload": payload,
		"qr_data_url":  dataURL,
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *server) handleWebSocketWeb(w http.ResponseWriter, r *http.Request) {
	sessionID := strings.TrimPrefix(r.URL.Path, "/ws/web/")
	if sessionID == "" {
		http.Error(w, "session id required", http.StatusBadRequest)
		return
	}
	sess := s.hub.get(sessionID)
	if sess == nil {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	sess.mu.Lock()
	if sess.WebConn != nil {
		_ = sess.WebConn.Close()
	}
	sess.WebConn = conn
	initial := map[string]any{
		"type":       "status",
		"session_id": sess.ID,
		"status":     "waiting_mobile",
		"authorized": sess.Authorized,
		"peer_id":    sess.PeerID,
		"nickname":   sess.Nickname,
	}
	if sess.MobileConn != nil {
		initial["status"] = "mobile_connected"
	}
	sess.mu.Unlock()
	s.writeToWeb(sess, initial)

	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			break
		}
	}

	sess.mu.Lock()
	if sess.WebConn == conn {
		sess.WebConn = nil
	}
	sess.mu.Unlock()
	_ = conn.Close()
}

func (s *server) handleWebSocketMobile(w http.ResponseWriter, r *http.Request) {
	sessionID := strings.TrimPrefix(r.URL.Path, "/ws/mobile/")
	if sessionID == "" {
		http.Error(w, "session id required", http.StatusBadRequest)
		return
	}
	sess := s.hub.get(sessionID)
	if sess == nil {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	sess.mu.Lock()
	if sess.MobileConn != nil {
		_ = sess.MobileConn.Close()
	}
	sess.MobileConn = conn
	sess.Authorized = false
	sess.PeerID = ""
	sess.Nickname = ""
	sess.mu.Unlock()

	s.writeToWeb(sess, map[string]any{
		"type":       "status",
		"session_id": sess.ID,
		"status":     "mobile_connected",
		"authorized": false,
	})

	for {
		var message map[string]any
		if err := conn.ReadJSON(&message); err != nil {
			break
		}
		msgType, _ := message["type"].(string)
		switch strings.ToLower(msgType) {
		case "auth":
			peerID, _ := message["peer_id"].(string)
			nickname, _ := message["nickname"].(string)
			sess.mu.Lock()
			sess.Authorized = true
			sess.PeerID = peerID
			sess.Nickname = nickname
			sess.mu.Unlock()
			s.writeToWeb(sess, map[string]any{
				"type":         "authorized",
				"session_id":   sess.ID,
				"status":       "authorized",
				"authorized":   true,
				"peer_id":      peerID,
				"web_nickname": nickname,
			})
		case "heartbeat":
			s.writeToWeb(sess, map[string]any{
				"type":       "status",
				"session_id": sess.ID,
				"status":     "mobile_online",
				"authorized": true,
			})
		case "logout":
			sess.mu.Lock()
			sess.Authorized = false
			sess.mu.Unlock()
			s.writeToWeb(sess, map[string]any{
				"type":       "status",
				"session_id": sess.ID,
				"status":     "mobile_logged_out",
				"authorized": false,
			})
		}
	}

	sess.mu.Lock()
	if sess.MobileConn == conn {
		sess.MobileConn = nil
	}
	sess.Authorized = false
	sess.mu.Unlock()
	_ = conn.Close()
	s.writeToWeb(sess, map[string]any{
		"type":       "status",
		"session_id": sess.ID,
		"status":     "mobile_disconnected",
		"authorized": false,
	})
}

func (s *server) writeToWeb(sess *bridgeSession, message map[string]any) {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	if sess.WebConn == nil {
		return
	}
	_ = sess.WebConn.WriteJSON(message)
}

func wsBaseURL(r *http.Request) string {
	scheme := "ws"
	if r.TLS != nil {
		scheme = "wss"
	}
	if fwd := strings.ToLower(r.Header.Get("X-Forwarded-Proto")); fwd == "https" {
		scheme = "wss"
	}
	return scheme + "://" + r.Host
}

func randomID(bytesCount int) string {
	b := make([]byte, bytesCount)
	if _, err := rand.Read(b); err != nil {
		return time.Now().Format("20060102150405")
	}
	return hex.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func main() {
	srv := newServer()
	srv.routes()
	go srv.hub.cleanup(2 * time.Hour)

	addr := ":8080"
	log.Printf("web bridge listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}

const indexHTML = `<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MeshMessenger Web Login</title>
  <style>
    body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 24px; background: #111; color: #eee; }
    .card { max-width: 560px; margin: 0 auto; background: #1d1f24; border-radius: 12px; padding: 20px; }
    h1 { margin-top: 0; font-size: 22px; }
    #qr { width: 280px; height: 280px; border-radius: 8px; background: #fff; display: block; margin: 16px auto; }
    .muted { color: #a5a7ad; font-size: 13px; }
    .status { font-weight: 600; margin: 10px 0; }
    .ok { color: #4ade80; }
    .warn { color: #fbbf24; }
    .bad { color: #f87171; }
    button { background: #2563eb; color: #fff; border: none; border-radius: 8px; padding: 10px 14px; cursor: pointer; }
    code { font-size: 12px; word-break: break-all; color: #cbd5e1; display: block; margin-top: 8px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>MeshMessenger Web</h1>
    <div class="muted">Отсканируйте QR в iOS приложении: Настройки → Web версия → Сканировать QR.</div>
    <img id="qr" alt="Pair QR">
    <div class="status" id="status">Создание сессии…</div>
    <div id="meta" class="muted"></div>
    <button id="newSessionBtn" type="button">Новая сессия</button>
    <code id="pairPayload"></code>
  </div>
  <script>
    const statusEl = document.getElementById('status');
    const qrEl = document.getElementById('qr');
    const metaEl = document.getElementById('meta');
    const payloadEl = document.getElementById('pairPayload');
    const newSessionBtn = document.getElementById('newSessionBtn');
    let ws = null;

    function setStatus(text, cls) {
      statusEl.textContent = text;
      statusEl.className = 'status ' + (cls || '');
    }

    function wsURL(path) {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      return proto + '//' + location.host + path;
    }

    async function createSession() {
      if (ws) {
        ws.close();
        ws = null;
      }
      setStatus('Создание сессии…', 'warn');
      const resp = await fetch('/api/session', { method: 'POST' });
      if (!resp.ok) throw new Error('session create failed');
      const data = await resp.json();
      qrEl.src = data.qr_data_url;
      payloadEl.textContent = data.pair_payload;
      metaEl.textContent = 'Session: ' + data.session_id;
      connectWebSocket(data.session_id);
    }

    function connectWebSocket(sessionID) {
      ws = new WebSocket(wsURL('/ws/web/' + encodeURIComponent(sessionID)));
      ws.onopen = () => setStatus('Ожидание телефона…', 'warn');
      ws.onclose = () => setStatus('Web сокет закрыт', 'bad');
      ws.onerror = () => setStatus('Ошибка web сокета', 'bad');
      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === 'authorized') {
            setStatus('Авторизовано. peer=' + (msg.peer_id || 'unknown'), 'ok');
          } else if (msg.type === 'status') {
            if (msg.status === 'mobile_connected') {
              setStatus('Телефон подключён, ждём auth…', 'warn');
            } else if (msg.status === 'mobile_online') {
              setStatus('Сессия активна (телефон онлайн)', 'ok');
            } else if (msg.status === 'mobile_disconnected') {
              setStatus('Телефон отключился, сессия неактивна', 'bad');
            } else {
              setStatus('Статус: ' + msg.status, msg.authorized ? 'ok' : 'warn');
            }
          }
        } catch (_) {}
      };
    }

    newSessionBtn.addEventListener('click', () => {
      createSession().catch(() => setStatus('Не удалось создать сессию', 'bad'));
    });
    createSession().catch(() => setStatus('Не удалось создать сессию', 'bad'));
  </script>
</body>
</html>`
