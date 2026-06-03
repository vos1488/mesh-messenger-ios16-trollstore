package main

import (
	"encoding/json"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// publicServerAddr can be set via --public-addr flag to explicitly advertise
// the server's public IP in peer registry responses instead of inferring from r.Host.
var publicServerAddr string

type meshPeerRecord struct {
	PeerID       string    `json:"peer_id"`
	Nickname     string    `json:"nickname"`
	Capabilities []string  `json:"capabilities,omitempty"`
	LastSeen     time.Time `json:"last_seen"`
	SourceIP     string    `json:"source_ip,omitempty"`
}

type meshPeerRegisterRequest struct {
	PeerID       string   `json:"peer_id"`
	Nickname     string   `json:"nickname"`
	Capabilities []string `json:"capabilities"`
}

type meshPeerRegistry struct {
	mu    sync.RWMutex
	peers map[string]meshPeerRecord
}

func newMeshPeerRegistry() *meshPeerRegistry {
	return &meshPeerRegistry{
		peers: make(map[string]meshPeerRecord),
	}
}

func (r *meshPeerRegistry) upsert(req meshPeerRegisterRequest, sourceIP string) {
	peerID := strings.TrimSpace(req.PeerID)
	if peerID == "" {
		return
	}
	nickname := strings.TrimSpace(req.Nickname)
	if nickname == "" {
		nickname = "mesh-peer"
	}
	record := meshPeerRecord{
		PeerID:       peerID,
		Nickname:     nickname,
		Capabilities: normalizeCapabilities(req.Capabilities),
		LastSeen:     time.Now().UTC(),
		SourceIP:     sourceIP,
	}
	r.mu.Lock()
	r.peers[peerID] = record
	r.mu.Unlock()
}

func (r *meshPeerRegistry) list(excludePeerID string) []meshPeerRecord {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make([]meshPeerRecord, 0, len(r.peers))
	for peerID, peer := range r.peers {
		if excludePeerID != "" && peerID == excludePeerID {
			continue
		}
		result = append(result, peer)
	}
	return result
}

func (r *meshPeerRegistry) cleanup(ttl time.Duration) {
	ticker := time.NewTicker(45 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		cutoff := time.Now().UTC().Add(-ttl)
		r.mu.Lock()
		for peerID, peer := range r.peers {
			if peer.LastSeen.Before(cutoff) {
				delete(r.peers, peerID)
			}
		}
		r.mu.Unlock()
	}
}

func (s *server) handleMeshPeerRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req meshPeerRegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	req.PeerID = strings.TrimSpace(req.PeerID)
	if req.PeerID == "" {
		http.Error(w, "peer_id is required", http.StatusBadRequest)
		return
	}
	s.peerRegistry.upsert(req, requestSourceIP(r))

	response := map[string]any{
		"status":               "ok",
		"registered_peer_id":   req.PeerID,
		"known_peers":          s.peerRegistry.list(req.PeerID),
		"bootstrap_udp":        publicUDPBootstrapEndpoint(r),
		"registry_server_time": time.Now().UTC(),
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *server) handleMeshPeers(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	exclude := strings.TrimSpace(r.URL.Query().Get("exclude_peer_id"))
	response := map[string]any{
		"peers":                s.peerRegistry.list(exclude),
		"bootstrap_udp":        publicUDPBootstrapEndpoint(r),
		"registry_server_time": time.Now().UTC(),
	}
	writeJSON(w, http.StatusOK, response)
}

func requestSourceIP(r *http.Request) string {
	if forwarded := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); forwarded != "" {
		parts := strings.Split(forwarded, ",")
		if len(parts) > 0 {
			return strings.TrimSpace(parts[0])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return strings.TrimSpace(r.RemoteAddr)
}

func publicUDPBootstrapEndpoint(r *http.Request) string {
	relayPort := "58901"
	relayHost, relayRawPort, err := net.SplitHostPort(strings.TrimSpace(udpBootstrapAddr))
	if err == nil && relayRawPort != "" {
		relayPort = relayRawPort
		if relayHost != "" && relayHost != "0.0.0.0" && relayHost != "::" {
			return relayHost + ":" + relayPort
		}
	}

	// Use explicitly configured public address if available.
	if publicServerAddr != "" {
		host := publicServerAddr
		if h, _, err2 := net.SplitHostPort(host); err2 == nil {
			host = h
		}
		return net.JoinHostPort(host, relayPort)
	}

	host := strings.TrimSpace(r.Host)
	if host == "" {
		return ""
	}
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if parsedPort, err := strconv.Atoi(relayPort); err == nil && parsedPort > 0 && parsedPort <= 65535 {
		return net.JoinHostPort(host, relayPort)
	}
	return host + ":" + relayPort
}

func normalizeCapabilities(values []string) []string {
	if len(values) == 0 {
		return []string{"chat", "relay"}
	}
	seen := make(map[string]struct{})
	result := make([]string, 0, len(values))
	for _, raw := range values {
		value := strings.ToLower(strings.TrimSpace(raw))
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	if len(result) == 0 {
		return []string{"chat", "relay"}
	}
	return result
}
