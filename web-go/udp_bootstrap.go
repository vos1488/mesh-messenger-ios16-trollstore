package main

import (
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"
)

var udpBootstrapEnabled = true
var udpBootstrapAddr = ":58901"

type udpRelayMessage struct {
	SenderPeerID   string `json:"senderPeerID"`
	ReceiverPeerID string `json:"receiverPeerID"`
}

type udpPeerEndpoint struct {
	addr     *net.UDPAddr
	lastSeen time.Time
}

func startUDPBootstrapRelay(listenAddr string, shutdown <-chan struct{}) error {
	if listenAddr == "" {
		return errors.New("udp relay listen address is empty")
	}
	conn, err := net.ListenPacket("udp", listenAddr)
	if err != nil {
		return err
	}

	udpConn, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return errors.New("udp listener type assertion failed")
	}

	var (
		mu    sync.Mutex
		peers = make(map[string]udpPeerEndpoint)
	)

	go func() {
		<-shutdown
		_ = udpConn.Close()
	}()

	go func() {
		buffer := make([]byte, 64*1024)
		for {
			_ = udpConn.SetReadDeadline(time.Now().Add(3 * time.Second))
			n, srcAddrRaw, err := udpConn.ReadFromUDP(buffer)
			if err != nil {
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					continue
				}
				return
			}
			if n <= 0 {
				continue
			}

			payload := append([]byte(nil), buffer[:n]...)
			var msg udpRelayMessage
			_ = json.Unmarshal(payload, &msg)
			now := time.Now()

			mu.Lock()
			if msg.SenderPeerID != "" {
				peers[msg.SenderPeerID] = udpPeerEndpoint{addr: srcAddrRaw, lastSeen: now}
			}
			for peerID, endpoint := range peers {
				if now.Sub(endpoint.lastSeen) > 4*time.Minute {
					delete(peers, peerID)
				}
			}

			targets := make([]*net.UDPAddr, 0, len(peers))
			if msg.ReceiverPeerID != "" && msg.ReceiverPeerID != "*" {
				if endpoint, ok := peers[msg.ReceiverPeerID]; ok {
					targets = append(targets, endpoint.addr)
				}
			} else {
				for peerID, endpoint := range peers {
					if msg.SenderPeerID != "" && peerID == msg.SenderPeerID {
						continue
					}
					targets = append(targets, endpoint.addr)
				}
			}

			if len(targets) == 0 {
				for peerID, endpoint := range peers {
					if msg.SenderPeerID != "" && peerID == msg.SenderPeerID {
						continue
					}
					targets = append(targets, endpoint.addr)
				}
			}
			mu.Unlock()

			for _, target := range targets {
				if target == nil {
					continue
				}
				_, _ = udpConn.WriteToUDP(payload, target)
			}
		}
	}()

	return nil
}
