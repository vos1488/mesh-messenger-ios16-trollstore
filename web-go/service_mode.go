package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kardianos/service"
)

type peerServiceProgram struct {
	addr string
	stop chan struct{}
	done chan error
}

func (p *peerServiceProgram) Start(s service.Service) error {
	if p.stop != nil {
		return nil
	}
	p.stop = make(chan struct{})
	p.done = make(chan error, 1)
	go func() {
		p.done <- runBridgeServer(p.addr, p.stop)
	}()
	return nil
}

func (p *peerServiceProgram) Stop(s service.Service) error {
	if p.stop == nil {
		return nil
	}
	close(p.stop)
	p.stop = nil
	select {
	case <-p.done:
	case <-time.After(8 * time.Second):
	}
	return nil
}

func main() {
	addr := flag.String("addr", defaultListenAddress(), "listen address for peer service")
	serviceAction := flag.String("service", "", "service action: install|uninstall|start|stop|restart")
	serviceName := flag.String("service-name", "meshwave-peer-service", "system service name")
	displayName := flag.String("service-display-name", "MeshWave Peer Service", "service display name")
	serviceDescription := flag.String("service-description", "MeshWave desktop peer bridge service", "service description")
	flag.Parse()

	program := &peerServiceProgram{addr: *addr}
	config := &service.Config{
		Name:        *serviceName,
		DisplayName: *displayName,
		Description: *serviceDescription,
		Arguments:   []string{"--addr", *addr},
	}
	svc, err := service.New(program, config)
	if err != nil {
		log.Fatal(err)
	}

	if action := *serviceAction; action != "" {
		if err := service.Control(svc, action); err != nil {
			log.Fatalf("service %s failed: %v", action, err)
		}
		fmt.Printf("service %s: ok\n", action)
		return
	}

	if service.Interactive() {
		stop := make(chan struct{})
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
		go func() {
			<-signals
			close(stop)
		}()
		log.Printf("mesh peer service listening on %s", *addr)
		if err := runBridgeServer(*addr, stop); err != nil {
			log.Fatal(err)
		}
		return
	}

	if err := svc.Run(); err != nil {
		log.Fatal(err)
	}
}
