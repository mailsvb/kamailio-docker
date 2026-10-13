package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
)

// Kamailio talks JSON-RPC to the jsonrpcs datagram socket and optionally uses
// the Docker Engine API for restart and container state
type Kamailio struct {
	rpcSocket    string // jsonrpcs dgram_socket of kamailio
	container    string
	dockerSocket string
	docker       *http.Client
	seq          atomic.Int64
}

func newKamailio(rpcSocket, dockerSocket, container string) *Kamailio {
	return &Kamailio{
		rpcSocket:    rpcSocket,
		container:    container,
		dockerSocket: dockerSocket,
		docker: &http.Client{
			Timeout: 60 * time.Second,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", dockerSocket)
				},
			},
		},
	}
}

type rpcResponse struct {
	Result json.RawMessage `json:"result,omitempty"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// rpc executes a kamailio RPC command and returns its result
func (k *Kamailio) rpc(method string, params []any) (json.RawMessage, error) {
	if params == nil {
		params = []any{}
	}
	id := k.seq.Add(1)
	req, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": method, "params": params, "id": id})
	if err != nil {
		return nil, err
	}
	// kamailio sends the reply to the address of the sender, so bind our own socket
	// next to the kamailio socket (shared volume)
	local := filepath.Join(filepath.Dir(k.rpcSocket), fmt.Sprintf("admin_%d_%d.sock", os.Getpid(), id))
	conn, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: local, Net: "unixgram"})
	if err != nil {
		return nil, err
	}
	defer os.Remove(local)
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	if _, err := conn.WriteToUnix(req, &net.UnixAddr{Name: k.rpcSocket, Net: "unixgram"}); err != nil {
		return nil, fmt.Errorf("kamailio not reachable: %w", err)
	}
	buf := make([]byte, 1<<20)
	n, _, err := conn.ReadFromUnix(buf)
	if err != nil {
		return nil, fmt.Errorf("no reply from kamailio: %w", err)
	}
	var resp rpcResponse
	if err := json.Unmarshal(buf[:n], &resp); err != nil {
		return nil, fmt.Errorf("invalid reply from kamailio: %w", err)
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("%s (%d)", resp.Error.Message, resp.Error.Code)
	}
	return resp.Result, nil
}

func (k *Kamailio) dockerRequest(ctx context.Context, method, path string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, "http://docker/v1.41"+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := k.docker.Do(req)
	if err != nil {
		return nil, fmt.Errorf("docker not reachable: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("docker: %s: %s", resp.Status, body)
	}
	return body, nil
}

// hasDocker reports whether the docker socket is mounted
func (k *Kamailio) hasDocker() bool {
	_, err := os.Stat(k.dockerSocket)
	return err == nil
}

// restart restarts the container via the docker API if available, otherwise
// kamailio is terminated via RPC and brought back by the container restart policy.
// It returns the method used.
func (k *Kamailio) restart(ctx context.Context) (string, error) {
	if k.hasDocker() {
		_, err := k.dockerRequest(ctx, http.MethodPost, "/containers/"+url.PathEscape(k.container)+"/restart?t=10")
		if err == nil {
			return "docker", nil
		}
		log.Printf("docker restart failed, falling back to core.kill: %v", err)
	}
	before, err := k.upSince()
	if err != nil {
		return "", err
	}
	// kamailio may exit before it replies, so a missing reply is expected
	k.rpc("core.kill", nil)
	for deadline := time.Now().Add(30 * time.Second); time.Now().Before(deadline); {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(time.Second):
		}
		if now, err := k.upSince(); err == nil && now != before {
			return "core.kill", nil
		}
	}
	return "", errors.New("kamailio did not come back within 30s, check the container logs")
}

func (k *Kamailio) upSince() (string, error) {
	res, err := k.rpc("core.uptime", nil)
	if err != nil {
		return "", err
	}
	var up struct {
		UpSince string `json:"up_since"`
	}
	err = json.Unmarshal(res, &up)
	return up.UpSince, err
}

type ContainerState struct {
	Status       string `json:"status"`
	StartedAt    string `json:"startedAt"`
	RestartCount int    `json:"restartCount"`
}

func (k *Kamailio) containerState(ctx context.Context) (*ContainerState, error) {
	body, err := k.dockerRequest(ctx, http.MethodGet, "/containers/"+url.PathEscape(k.container)+"/json")
	if err != nil {
		return nil, err
	}
	var info struct {
		RestartCount int
		State        struct {
			Status    string
			StartedAt string
		}
	}
	if err := json.Unmarshal(body, &info); err != nil {
		return nil, err
	}
	return &ContainerState{Status: info.State.Status, StartedAt: info.State.StartedAt, RestartCount: info.RestartCount}, nil
}
