package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/skip2/go-qrcode"
)

type bridgeSession struct {
	ID                  string
	CreatedAt           time.Time
	WebConn             *websocket.Conn
	MobileConn          *websocket.Conn
	Authorized          bool
	PeerID              string
	Nickname            string
	KeyFingerprint      string
	SigningPublicKeyB64 string
	AgreementKeyB64     string
	mu                  sync.Mutex
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

func (s *server) routes(mux *http.ServeMux) {
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/api/session", s.handleCreateSession)
	mux.HandleFunc("/ws/web/", s.handleWebSocketWeb)
	mux.HandleFunc("/ws/mobile/", s.handleWebSocketMobile)
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
		"type":              "status",
		"session_id":        sess.ID,
		"status":            "waiting_mobile",
		"authorized":        sess.Authorized,
		"peer_id":           sess.PeerID,
		"nickname":          sess.Nickname,
		"key_fingerprint":   sess.KeyFingerprint,
		"signing_pub_key":   sess.SigningPublicKeyB64,
		"agreement_pub_key": sess.AgreementKeyB64,
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
	sess.KeyFingerprint = ""
	sess.SigningPublicKeyB64 = ""
	sess.AgreementKeyB64 = ""
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
			signingKeyB64, _ := message["signing_pub_key"].(string)
			agreementKeyB64, _ := message["agreement_pub_key"].(string)

			fingerprint, verifyErr := verifyAuthProof(sess.ID, message)
			if verifyErr != nil {
				s.writeToWeb(sess, map[string]any{
					"type":       "status",
					"session_id": sess.ID,
					"status":     "auth_rejected",
					"authorized": false,
				})
				s.writeToWeb(sess, map[string]any{
					"type":       "error",
					"session_id": sess.ID,
					"code":       "auth_proof_invalid",
					"message":    verifyErr.Error(),
				})
				continue
			}

			sess.mu.Lock()
			sess.Authorized = true
			sess.PeerID = peerID
			sess.Nickname = nickname
			sess.KeyFingerprint = fingerprint
			sess.SigningPublicKeyB64 = signingKeyB64
			sess.AgreementKeyB64 = agreementKeyB64
			sess.mu.Unlock()
			s.writeToWeb(sess, map[string]any{
				"type":              "authorized",
				"session_id":        sess.ID,
				"status":            "authorized",
				"authorized":        true,
				"peer_id":           peerID,
				"web_nickname":      nickname,
				"key_fingerprint":   fingerprint,
				"signing_pub_key":   signingKeyB64,
				"agreement_pub_key": agreementKeyB64,
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
		default:
			s.writeToWeb(sess, map[string]any{
				"type":         "mobile_message",
				"session_id":   sess.ID,
				"message_type": msgType,
				"payload":      message,
			})
		}
	}

	sess.mu.Lock()
	if sess.MobileConn == conn {
		sess.MobileConn = nil
	}
	sess.Authorized = false
	sess.KeyFingerprint = ""
	sess.SigningPublicKeyB64 = ""
	sess.AgreementKeyB64 = ""
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

func verifyAuthProof(sessionID string, message map[string]any) (string, error) {
	challenge, _ := message["auth_challenge"].(string)
	signatureB64, _ := message["auth_signature"].(string)
	signingKeyB64, _ := message["signing_pub_key"].(string)
	agreementKeyB64, _ := message["agreement_pub_key"].(string)

	if strings.TrimSpace(challenge) == "" ||
		strings.TrimSpace(signatureB64) == "" ||
		strings.TrimSpace(signingKeyB64) == "" ||
		strings.TrimSpace(agreementKeyB64) == "" {
		return "", errors.New("auth proof is incomplete")
	}
	if !strings.HasPrefix(challenge, sessionID+":") {
		return "", errors.New("challenge session mismatch")
	}

	parts := strings.Split(challenge, ":")
	if len(parts) < 3 {
		return "", errors.New("challenge format invalid")
	}
	issuedAt, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return "", errors.New("challenge timestamp invalid")
	}
	now := time.Now().Unix()
	if math.Abs(float64(now-issuedAt)) > 300 {
		return "", errors.New("challenge expired")
	}

	signingKeyRaw, err := base64.StdEncoding.DecodeString(signingKeyB64)
	if err != nil {
		return "", fmt.Errorf("signing key decode failed: %w", err)
	}
	if len(signingKeyRaw) != ed25519.PublicKeySize {
		return "", errors.New("signing key size invalid")
	}
	agreementKeyRaw, err := base64.StdEncoding.DecodeString(agreementKeyB64)
	if err != nil {
		return "", fmt.Errorf("agreement key decode failed: %w", err)
	}
	if len(agreementKeyRaw) != 32 {
		return "", errors.New("agreement key size invalid")
	}
	signatureRaw, err := base64.StdEncoding.DecodeString(signatureB64)
	if err != nil {
		return "", fmt.Errorf("signature decode failed: %w", err)
	}
	if len(signatureRaw) != ed25519.SignatureSize {
		return "", errors.New("signature size invalid")
	}

	if !ed25519.Verify(ed25519.PublicKey(signingKeyRaw), []byte(challenge), signatureRaw) {
		return "", errors.New("signature verification failed")
	}

	digest := sha256.Sum256(append(signingKeyRaw, agreementKeyRaw...))
	return hex.EncodeToString(digest[:]), nil
}

func runBridgeServer(addr string, shutdown <-chan struct{}) error {
	srv := newServer()
	mux := http.NewServeMux()
	srv.routes(mux)
	go srv.hub.cleanup(2 * time.Hour)

	httpServer := &http.Server{
		Addr:    addr,
		Handler: mux,
	}
	go func() {
		<-shutdown
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(ctx)
	}()
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func defaultListenAddress() string {
	if fromEnv := strings.TrimSpace(os.Getenv("MESH_WEB_ADDR")); fromEnv != "" {
		return fromEnv
	}
	return ":8080"
}

const indexHTML = `<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MeshWave Web</title>
  <style>
    :root { color-scheme: dark; --bg:#070b14; --glass:rgba(18,26,45,.62); --border:rgba(160,184,255,.22); --muted:#9fb0d2; --text:#ecf2ff; --ok:#3ee08a; --warn:#f3be52; --bad:#ff6f81; --accent:#5c87ff; }
    * { box-sizing: border-box; }
    body { margin: 0; background: radial-gradient(1000px 500px at 10% -10%, #334a7d 0%, transparent 50%), radial-gradient(900px 520px at 100% 0%, #2f486f 0%, transparent 56%), var(--bg); color: var(--text); font-family: -apple-system, Segoe UI, Roboto, sans-serif; min-height: 100vh; }
    .shell { display: grid; grid-template-columns: 320px 1fr; min-height: 100vh; gap: 12px; padding: 12px; }
    .glass { background: var(--glass); border: 1px solid var(--border); border-radius: 18px; backdrop-filter: blur(18px) saturate(140%); box-shadow: 0 10px 36px rgba(0,0,0,.35); }
    .sidebar { padding: 14px; display: flex; flex-direction: column; gap: 12px; }
    .brand { font-size: 24px; font-weight: 700; letter-spacing: .2px; }
    .brand-sub { color: var(--muted); font-size: 13px; }
    .status { font-weight: 600; font-size: 14px; padding: 10px 12px; border-radius: 12px; background: rgba(255,255,255,.03); }
    .ok { color: var(--ok); } .warn { color: var(--warn); } .bad { color: var(--bad); }
    .qr-wrap { display: grid; place-items: center; padding: 10px; background: rgba(255,255,255,.03); border-radius: 14px; border: 1px solid rgba(255,255,255,.08); }
    #qr { width: 245px; height: 245px; border-radius: 12px; background: #fff; }
    .btn { appearance: none; border: 0; border-radius: 12px; background: linear-gradient(135deg, #4a7bff, #6e8cff); color: #fff; font-weight: 600; padding: 10px 12px; cursor: pointer; }
    .muted { color: var(--muted); font-size: 12px; line-height: 1.38; word-break: break-word; }
    .security { margin-top: auto; padding: 12px; border-radius: 14px; background: rgba(255,255,255,.03); border: 1px solid rgba(255,255,255,.07); }
    .sec-title { font-size: 12px; text-transform: uppercase; letter-spacing: .08em; color: #9bb0d9; margin-bottom: 8px; }
    .sec-line { font-size: 12px; color: #d8e4ff; margin: 4px 0; word-break: break-all; }
    .main { display: grid; grid-template-rows: auto 1fr auto; padding: 12px; }
    .topbar { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 12px 14px; border-bottom: 1px solid rgba(255,255,255,.08); }
    .title { font-size: 17px; font-weight: 600; }
    .subtitle { font-size: 12px; color: var(--muted); }
    .dialog { padding: 16px; overflow: auto; display: grid; grid-template-columns: minmax(320px, 1fr) 360px; gap: 12px; align-content: start; }
    .panel { border-radius: 14px; border: 1px solid rgba(255,255,255,.08); background: rgba(255,255,255,.02); min-height: 220px; }
    .panel-head { padding: 10px 12px; font-size: 12px; color: #afc1e8; border-bottom: 1px solid rgba(255,255,255,.08); text-transform: uppercase; letter-spacing: .08em; }
    #messages, #events { max-height: calc(100vh - 270px); overflow: auto; padding: 10px; }
    .bubble { margin: 8px 0; padding: 10px 12px; border-radius: 12px; max-width: 94%; font-size: 13px; line-height: 1.38; background: rgba(83,116,196,.26); border: 1px solid rgba(126,154,228,.26); }
    .bubble.system { background: rgba(255,255,255,.04); border-color: rgba(255,255,255,.09); color: #d7e2ff; }
    .bubble.error { background: rgba(255,74,112,.15); border-color: rgba(255,74,112,.35); }
    .event { font-size: 12px; padding: 6px 0; border-bottom: 1px solid rgba(255,255,255,.05); color: #d4e0ff; line-height: 1.32; }
    .event:last-child { border-bottom: none; }
    .event .time { color: #8ea6d4; margin-right: 8px; }
    .composer { border-top: 1px solid rgba(255,255,255,.08); padding: 12px; display: grid; grid-template-columns: 1fr auto; gap: 8px; }
    #composer { width: 100%; border: 1px solid rgba(255,255,255,.11); background: rgba(255,255,255,.05); color: var(--text); border-radius: 12px; padding: 10px 12px; outline: none; }
    @media (max-width: 1120px) { .shell { grid-template-columns: 1fr; } .dialog { grid-template-columns: 1fr; } #messages, #events { max-height: 320px; } }
  </style>
</head>
<body>
  <div class="shell">
    <aside class="sidebar glass">
      <div>
        <div class="brand">MeshWave Web</div>
        <div class="brand-sub">Secure mesh companion • Liquid Glass UI</div>
      </div>
      <div id="status" class="status warn">Создание сессии…</div>
      <div class="qr-wrap"><img id="qr" alt="Pair QR"></div>
      <button id="newSessionBtn" class="btn" type="button">Новая сессия</button>
      <div id="meta" class="muted"></div>
      <div id="pairPayload" class="muted"></div>
      <div class="security">
        <div class="sec-title">E2EE Identity</div>
        <div class="sec-line">Fingerprint: <span id="fingerprint">—</span></div>
        <div class="sec-line">PeerID: <span id="peerID">—</span></div>
        <div class="sec-line">Bridge mode: blind relay (без plaintext)</div>
      </div>
    </aside>

    <main class="main glass">
      <div class="topbar">
        <div>
          <div class="title">Веб-сессия узла</div>
          <div class="subtitle">Стиль веб-клиента: события, безопасность, live-состояние</div>
        </div>
        <div class="subtitle" id="sessionBadge">Session: —</div>
      </div>

      <div class="dialog">
        <section class="panel">
          <div class="panel-head">Secure Stream</div>
          <div id="messages"></div>
        </section>
        <section class="panel">
          <div class="panel-head">Wire Events</div>
          <div id="events"></div>
        </section>
      </div>

      <div class="composer">
        <input id="composer" type="text" placeholder="Encrypted bridge mode: ввод отключен (read-only)" disabled>
        <button class="btn" disabled>Отправить</button>
      </div>
    </main>
  </div>

  <script>
    const statusEl = document.getElementById('status');
    const qrEl = document.getElementById('qr');
    const metaEl = document.getElementById('meta');
    const payloadEl = document.getElementById('pairPayload');
    const newSessionBtn = document.getElementById('newSessionBtn');
    const eventsEl = document.getElementById('events');
    const messagesEl = document.getElementById('messages');
    const sessionBadgeEl = document.getElementById('sessionBadge');
    const peerIDEl = document.getElementById('peerID');
    const fingerprintEl = document.getElementById('fingerprint');
    let ws = null;
    let lastStatus = '';

    function setStatus(text, cls) {
      statusEl.textContent = text;
      statusEl.className = 'status ' + (cls || '');
    }

    function wsURL(path) {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      return proto + '//' + location.host + path;
    }

    function nowTime() {
      return '[' + new Date().toLocaleTimeString() + ']';
    }

    function appendEvent(name, payload) {
      const row = document.createElement('div');
      row.className = 'event';
      const time = document.createElement('span');
      time.className = 'time';
      time.textContent = nowTime();
      row.appendChild(time);
      const text = document.createElement('span');
      text.textContent = name + (payload ? ': ' + JSON.stringify(payload) : '');
      row.appendChild(text);
      eventsEl.prepend(row);
      while (eventsEl.childElementCount > 220) {
        eventsEl.removeChild(eventsEl.lastChild);
      }
    }

    function appendMessage(text, cls) {
      const bubble = document.createElement('div');
      bubble.className = 'bubble ' + (cls || 'system');
      bubble.textContent = nowTime() + ' ' + text;
      messagesEl.prepend(bubble);
      while (messagesEl.childElementCount > 140) {
        messagesEl.removeChild(messagesEl.lastChild);
      }
    }

    function applyIdentity(msg) {
      if (msg.peer_id) {
        peerIDEl.textContent = msg.peer_id;
      }
      if (msg.key_fingerprint) {
        fingerprintEl.textContent = msg.key_fingerprint;
      }
    }

    async function createSession() {
      if (ws) {
        ws.close();
        ws = null;
      }
      eventsEl.innerHTML = '';
      messagesEl.innerHTML = '';
      lastStatus = '';
      peerIDEl.textContent = '—';
      fingerprintEl.textContent = '—';
      setStatus('Создание сессии…', 'warn');
      const resp = await fetch('/api/session', { method: 'POST' });
      if (!resp.ok) throw new Error('session create failed');
      const data = await resp.json();
      qrEl.src = data.qr_data_url;
      payloadEl.textContent = data.pair_payload;
      metaEl.textContent = 'Отсканируйте QR в iOS: Настройки → Web версия → Сканировать QR';
      sessionBadgeEl.textContent = 'Session: ' + data.session_id;
      appendEvent('session_created', { session_id: data.session_id });
      appendMessage('Сессия создана, ожидается подключение mobile узла', 'system');
      connectWebSocket(data.session_id);
    }

    function connectWebSocket(sessionID) {
      ws = new WebSocket(wsURL('/ws/web/' + encodeURIComponent(sessionID)));
      ws.onopen = () => {
        setStatus('Ожидание телефона…', 'warn');
        appendEvent('ws_open');
      };
      ws.onclose = () => {
        setStatus('Web сокет закрыт', 'bad');
        appendMessage('Соединение закрыто', 'error');
        appendEvent('ws_close');
      };
      ws.onerror = () => {
        setStatus('Ошибка web сокета', 'bad');
        appendMessage('Ошибка канала', 'error');
        appendEvent('ws_error');
      };
      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          appendEvent(msg.type || 'message', msg);
          applyIdentity(msg);

          if (msg.type === 'authorized') {
            setStatus('E2EE сессия авторизована', 'ok');
            appendMessage('Устройство подтверждено подписью Ed25519', 'system');
            return;
          }
          if (msg.type === 'error') {
            setStatus('Ошибка авторизации', 'bad');
            appendMessage(msg.message || 'Ошибка secure handshake', 'error');
            return;
          }
          if (msg.type === 'mobile_message') {
            appendMessage('Mobile payload: ' + (msg.message_type || 'unknown'), 'system');
            return;
          }
          if (msg.type === 'status') {
            if (msg.status === lastStatus && msg.status === 'mobile_online') {
              return;
            }
            lastStatus = msg.status || '';
            if (msg.status === 'mobile_connected') {
              setStatus('Телефон подключён, проверяем ключи…', 'warn');
              appendMessage('Mobile socket connected', 'system');
            } else if (msg.status === 'mobile_online') {
              setStatus('Сессия активна (телефон онлайн)', 'ok');
            } else if (msg.status === 'mobile_disconnected') {
              setStatus('Телефон отключился, сессия неактивна', 'bad');
              appendMessage('Mobile узел отключился', 'error');
            } else if (msg.status === 'auth_rejected') {
              setStatus('Auth отклонён', 'bad');
              appendMessage('Подпись/ключи не прошли валидацию', 'error');
            } else {
              setStatus('Статус: ' + msg.status, msg.authorized ? 'ok' : 'warn');
            }
          }
        } catch (_) {
          appendMessage('Ошибка разбора входящего пакета', 'error');
        }
      };
    }

    newSessionBtn.addEventListener('click', () => {
      createSession().catch(() => setStatus('Не удалось создать сессию', 'bad'));
    });
    createSession().catch(() => setStatus('Не удалось создать сессию', 'bad'));
  </script>
</body>
</html>`
