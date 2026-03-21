package compat

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	buildOnce       sync.Once
	builtBinaryPath string
	buildBinaryErr  error
)

func daemonBinary(t *testing.T) string {
	t.Helper()

	if override := os.Getenv("CMUX_REMOTE_DAEMON_BIN"); override != "" {
		return override
	}

	buildOnce.Do(func() {
		outputDir, err := os.MkdirTemp("", "cmuxd-remote-go-*")
		if err != nil {
			buildBinaryErr = err
			return
		}
		builtBinaryPath = filepath.Join(outputDir, "cmuxd-remote-go")

		cmd := exec.Command("go", "build", "-ldflags", "-linkmode=external", "-o", builtBinaryPath, "./cmd/cmuxd-remote")
		cmd.Dir = daemonRemoteRoot()
		output, err := cmd.CombinedOutput()
		if err != nil {
			buildBinaryErr = fmt.Errorf("go build failed: %w\n%s", err, strings.TrimSpace(string(output)))
			return
		}
	})

	if buildBinaryErr != nil {
		t.Fatalf("build daemon binary: %v", buildBinaryErr)
	}
	return builtBinaryPath
}

func runJSONLFixture(t *testing.T, bin string, args ...string) []map[string]any {
	t.Helper()
	return runJSONLFixtureWithVars(t, bin, nil, args...)
}

func runJSONLFixtureWithVars(t *testing.T, bin string, initialVars map[string]string, args ...string) []map[string]any {
	t.Helper()

	if len(args) == 0 {
		t.Fatal("runJSONLFixture requires daemon args and a fixture path")
	}
	fixturePath := args[len(args)-1]
	daemonArgs := args[:len(args)-1]

	cmd := exec.Command(bin, daemonArgs...)
	cmd.Dir = daemonRemoteRoot()

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("start daemon: %v", err)
	}

	reader := bufio.NewReader(stdout)
	vars := map[string]string{}
	for key, value := range initialVars {
		vars[key] = value
	}
	var responses []map[string]any

	for _, rawLine := range readFixtureLines(t, fixturePath) {
		line := substitutePlaceholders(t, rawLine, vars)
		if _, err := io.WriteString(stdin, line+"\n"); err != nil {
			t.Fatalf("write request %q: %v", line, err)
		}

		respLine, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read response for %q: %v\nstderr:\n%s", line, err, stderr.String())
		}

		var payload map[string]any
		if err := json.Unmarshal([]byte(respLine), &payload); err != nil {
			t.Fatalf("decode response %q: %v", strings.TrimSpace(respLine), err)
		}
		captureResponseVars(payload, vars)
		responses = append(responses, payload)
	}

	if err := stdin.Close(); err != nil {
		t.Fatalf("close stdin: %v", err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("daemon exited with error: %v\nstderr:\n%s", err, stderr.String())
	}

	return responses
}

func readFixtureLines(t *testing.T, fixturePath string) []string {
	t.Helper()

	data, err := os.ReadFile(filepath.Join(compatPackageDir(), fixturePath))
	if err != nil {
		t.Fatalf("read fixture %q: %v", fixturePath, err)
	}

	var lines []string
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		lines = append(lines, trimmed)
	}
	return lines
}

func substitutePlaceholders(t *testing.T, input string, vars map[string]string) string {
	t.Helper()

	output := input
	for {
		start := strings.Index(output, "{{")
		if start == -1 {
			return output
		}
		end := strings.Index(output[start+2:], "}}")
		if end == -1 {
			t.Fatalf("unterminated placeholder in %q", input)
		}

		key := output[start+2 : start+2+end]
		value, ok := vars[key]
		if !ok {
			t.Fatalf("missing placeholder %q for fixture line %q", key, input)
		}
		output = output[:start] + value + output[start+2+end+2:]
	}
}

func captureResponseVars(payload map[string]any, vars map[string]string) {
	result, _ := payload["result"].(map[string]any)
	if result == nil {
		return
	}

	for _, key := range []string{"session_id", "attachment_id", "stream_id"} {
		if value, ok := result[key].(string); ok && value != "" {
			vars[key] = value
		}
	}
	if value, ok := result["offset"].(float64); ok {
		vars["offset"] = fmt.Sprintf("%.0f", value)
	}
}

func daemonRemoteRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(file))
}

func compatPackageDir() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(file)
}

type tlsDaemonServer struct {
	Addr         string
	ServerID     string
	TicketSecret []byte

	cmd    *exec.Cmd
	stderr *bytes.Buffer
}

func startTLSServer(t *testing.T, bin string) *tlsDaemonServer {
	t.Helper()

	tempDir := t.TempDir()
	certFile, keyFile := writeSelfSignedCert(t, tempDir)
	addr := freeTCPAddress(t)

	server := &tlsDaemonServer{
		Addr:         addr,
		ServerID:     "cmux-macmini",
		TicketSecret: []byte("compat-secret"),
		stderr:       &bytes.Buffer{},
	}
	server.cmd = exec.Command(
		bin,
		"serve",
		"--tls",
		"--listen", server.Addr,
		"--server-id", server.ServerID,
		"--ticket-secret", string(server.TicketSecret),
		"--cert-file", certFile,
		"--key-file", keyFile,
	)
	server.cmd.Dir = daemonRemoteRoot()
	server.cmd.Stderr = server.stderr

	if err := server.cmd.Start(); err != nil {
		t.Fatalf("start tls daemon: %v", err)
	}

	t.Cleanup(func() {
		if server.cmd.Process != nil {
			_ = server.cmd.Process.Kill()
		}
		_ = server.cmd.Wait()
	})

	waitForTLSServer(t, server)
	return server
}

func runDirectTLSHandshake(t *testing.T, server *tlsDaemonServer, token string) map[string]any {
	t.Helper()

	conn := dialTLSServer(t, server)
	defer conn.Close()

	return writeAndReadJSON(t, conn, map[string]any{
		"ticket": token,
	})
}

func runDirectTLSHandshakeAndRequest(
	t *testing.T,
	server *tlsDaemonServer,
	token string,
	firstReq map[string]any,
	secondReq func(map[string]any) map[string]any,
) (map[string]any, map[string]any) {
	t.Helper()

	conn := dialTLSServer(t, server)
	defer conn.Close()

	handshake := writeAndReadJSON(t, conn, map[string]any{
		"ticket": token,
	})
	if ok, _ := handshake["ok"].(bool); !ok {
		t.Fatalf("tls handshake failed: %+v", handshake)
	}

	firstResp := writeAndReadJSON(t, conn, firstReq)
	secondResp := writeAndReadJSON(t, conn, secondReq(firstResp))
	return firstResp, secondResp
}

func dialTLSServer(t *testing.T, server *tlsDaemonServer) *tls.Conn {
	t.Helper()

	conn, err := tls.Dial("tcp", server.Addr, &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true,
	})
	if err != nil {
		t.Fatalf("dial tls server %s: %v\nstderr:\n%s", server.Addr, err, server.stderr.String())
	}
	return conn
}

func writeAndReadJSON(t *testing.T, conn net.Conn, payload map[string]any) map[string]any {
	t.Helper()

	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("set conn deadline: %v", err)
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	if _, err := conn.Write(append(encoded, '\n')); err != nil {
		t.Fatalf("write payload %q: %v", string(encoded), err)
	}

	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read response: %v", err)
	}

	var response map[string]any
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		t.Fatalf("decode response %q: %v", strings.TrimSpace(line), err)
	}
	return response
}

func waitForTLSServer(t *testing.T, server *tlsDaemonServer) {
	t.Helper()

	deadline := time.Now().Add(3 * time.Second)
	for {
		conn, err := tls.Dial("tcp", server.Addr, &tls.Config{
			MinVersion:         tls.VersionTLS13,
			InsecureSkipVerify: true,
		})
		if err == nil {
			_ = conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("tls daemon did not start on %s: %v\nstderr:\n%s", server.Addr, err, server.stderr.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func freeTCPAddress(t *testing.T) string {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate tcp address: %v", err)
	}
	defer listener.Close()
	return listener.Addr().String()
}

func writeSelfSignedCert(t *testing.T, dir string) (certFile string, keyFile string) {
	t.Helper()

	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate private key: %v", err)
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: "cmuxd-remote-compat",
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, privateKey.Public(), privateKey)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}

	certFile = filepath.Join(dir, "server.crt")
	keyFile = filepath.Join(dir, "server.key")

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	privateDER, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		t.Fatalf("marshal private key: %v", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privateDER})

	if err := os.WriteFile(certFile, certPEM, 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	if err := os.WriteFile(keyFile, keyPEM, 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}

	return certFile, keyFile
}
