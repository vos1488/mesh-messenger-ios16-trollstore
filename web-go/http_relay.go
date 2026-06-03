package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// relayMessage is one envelope stored in a peer's inbox.
type relayMessage struct {
	MessageID  string `json:"message_id"`
	FromPeerID string `json:"from_peer_id"`
	ToPeerID   string `json:"to_peer_id"`
	// PayloadB64 is the full TransportMessage JSON, base64-encoded.
	// The server is a blind relay and never inspects the payload.
	PayloadB64 string  `json:"payload_b64"`
	CreatedAt  float64 `json:"created_at"` // unix seconds
}

// relayInbox holds messages for one peer.
type relayInbox struct {
	messages []relayMessage
}

const (
	maxInboxSize    = 500
	inboxTTLSeconds = 10 * 60 // 10 min
)

// httpRelayQueue is the server-side store-and-forward queue.
type httpRelayQueue struct {
	mu     sync.Mutex
	inboxes map[string]*relayInbox // peerID → inbox
}

func newHTTPRelayQueue() *httpRelayQueue {
	q := &httpRelayQueue{
		inboxes: make(map[string]*relayInbox),
	}
	go q.cleanupLoop()
	return q
}

func (q *httpRelayQueue) enqueue(msg relayMessage) {
	q.mu.Lock()
	defer q.mu.Unlock()
	inbox, ok := q.inboxes[msg.ToPeerID]
	if !ok {
		inbox = &relayInbox{}
		q.inboxes[msg.ToPeerID] = inbox
	}
	// Circular-buffer: drop oldest when full.
	if len(inbox.messages) >= maxInboxSize {
		inbox.messages = inbox.messages[len(inbox.messages)-maxInboxSize+1:]
	}
	inbox.messages = append(inbox.messages, msg)
}

// fetchSince returns messages for peerID created after sinceUnix, without removing them.
func (q *httpRelayQueue) fetchSince(peerID string, sinceUnix float64) []relayMessage {
	q.mu.Lock()
	defer q.mu.Unlock()
	inbox, ok := q.inboxes[peerID]
	if !ok {
		return nil
	}
	var out []relayMessage
	for _, m := range inbox.messages {
		if m.CreatedAt > sinceUnix {
			out = append(out, m)
		}
	}
	return out
}

func (q *httpRelayQueue) cleanupLoop() {
	ticker := time.NewTicker(2 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		cutoff := float64(time.Now().Unix() - inboxTTLSeconds)
		q.mu.Lock()
		for peerID, inbox := range q.inboxes {
			var kept []relayMessage
			for _, m := range inbox.messages {
				if m.CreatedAt >= cutoff {
					kept = append(kept, m)
				}
			}
			if len(kept) == 0 {
				delete(q.inboxes, peerID)
			} else {
				inbox.messages = kept
			}
		}
		q.mu.Unlock()
	}
}

// ---------- HTTP handlers ----------

type relayServer struct {
	queue *httpRelayQueue
}

// handleRelaySend: POST /api/mesh/relay/send
// Body: relayMessage JSON
func (rs *relayServer) handleRelaySend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var msg relayMessage
	if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return
	}
	if msg.ToPeerID == "" || msg.FromPeerID == "" || msg.PayloadB64 == "" {
		http.Error(w, "missing fields", http.StatusBadRequest)
		return
	}
	if msg.MessageID == "" {
		msg.MessageID = randomID(16)
	}
	if msg.CreatedAt == 0 {
		msg.CreatedAt = float64(time.Now().UnixNano()) / 1e9
	}
	rs.queue.enqueue(msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok", "message_id": msg.MessageID})
}

// handleRelayInbox: GET /api/mesh/relay/inbox?peer_id=X&since=UNIX_TS
func (rs *relayServer) handleRelayInbox(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	peerID := r.URL.Query().Get("peer_id")
	if peerID == "" {
		http.Error(w, "missing peer_id", http.StatusBadRequest)
		return
	}
	sinceStr := r.URL.Query().Get("since")
	var sinceUnix float64
	if sinceStr != "" {
		if v, err := strconv.ParseFloat(sinceStr, 64); err == nil {
			sinceUnix = v
		}
	}

	msgs := rs.queue.fetchSince(peerID, sinceUnix)
	if msgs == nil {
		msgs = []relayMessage{}
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"peer_id":  peerID,
		"messages": msgs,
	})
}
