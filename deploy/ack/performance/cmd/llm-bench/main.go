// llm-bench provides a deterministic streaming LLM mock and a small load
// generator. It intentionally uses only the Go standard library so that the
// same pinned binary can run on a developer machine and inside ACK.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptrace"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type sample struct {
	total time.Duration
	ttfb  time.Duration
	ok    bool
}

type summary struct {
	URL         string             `json:"url"`
	Protocol    string             `json:"protocol"`
	Streaming   bool               `json:"streaming"`
	Concurrency int                `json:"concurrency"`
	DurationSec float64            `json:"duration_seconds"`
	Requests    int                `json:"requests"`
	Successes   int                `json:"successes"`
	Errors      int                `json:"errors"`
	RPS         float64            `json:"rps"`
	LatencyMS   map[string]float64 `json:"latency_ms"`
	TTFBMS      map[string]float64 `json:"ttfb_ms"`
}

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: llm-bench server|load [flags]")
	}
	switch os.Args[1] {
	case "server":
		runServer(os.Args[2:])
	case "load":
		runLoad(os.Args[2:])
	case "routes":
		runRoutes(os.Args[2:])
	case "probe":
		runProbe(os.Args[2:])
	default:
		log.Fatalf("unknown command %q", os.Args[1])
	}
}

func runProbe(args []string) {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	url := fs.String("url", "http://127.0.0.1/ready", "target URL")
	host := fs.String("host", "", "optional HTTP Host header")
	timeout := fs.Duration("timeout", 30*time.Second, "overall timeout")
	interval := fs.Duration("interval", 10*time.Millisecond, "delay between attempts")
	_ = fs.Parse(args)
	started := time.Now()
	deadline := started.Add(*timeout)
	client := &http.Client{Timeout: 2 * time.Second}
	attempts := 0
	for time.Now().Before(deadline) {
		attempts++
		req, err := http.NewRequest(http.MethodGet, *url, nil)
		if err == nil {
			if *host != "" {
				req.Host = *host
			}
			resp, requestErr := client.Do(req)
			if requestErr == nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
						"convergence_ms": float64(time.Since(started).Microseconds()) / 1000,
						"attempts":       attempts,
					})
					return
				}
			}
		}
		time.Sleep(*interval)
	}
	log.Fatalf("route did not converge within %s after %d attempts", *timeout, attempts)
}

func runRoutes(args []string) {
	fs := flag.NewFlagSet("routes", flag.ExitOnError)
	count := fs.Int("count", 100, "number of host rules in one Ingress")
	namespace := fs.String("namespace", "higress-performance", "target namespace")
	_ = fs.Parse(args)
	rules := make([]any, 0, *count)
	for i := 0; i < *count; i++ {
		rules = append(rules, map[string]any{
			"host": fmt.Sprintf("route-%05d.llm-perf.internal", i),
			"http": map[string]any{"paths": []any{map[string]any{
				"path": "/", "pathType": "Prefix",
				"backend": map[string]any{"service": map[string]any{
					"name": "llm-mock", "port": map[string]any{"number": 8080},
				}},
			}}},
		})
	}
	ingress := map[string]any{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "Ingress",
		"metadata": map[string]any{
			"name":      "controller-scale",
			"namespace": *namespace,
			"labels": map[string]string{
				"performance.higress.io/route-set": "controller-scale",
			},
		},
		"spec": map[string]any{"ingressClassName": "higress", "rules": rules},
	}
	if err := json.NewEncoder(os.Stdout).Encode(ingress); err != nil {
		log.Fatal(err)
	}
}

func runServer(args []string) {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	address := fs.String("address", ":8080", "listen address")
	ttft := fs.Duration("ttft", 300*time.Millisecond, "stream time to first token")
	chunks := fs.Int("chunks", 32, "SSE chunks per stream")
	interval := fs.Duration("chunk-interval", 30*time.Millisecond, "delay between SSE chunks")
	backendDelay := fs.Duration("backend-delay", 50*time.Millisecond, "non-stream response delay")
	payloadBytes := fs.Int("response-bytes", 2048, "approximate non-stream response bytes")
	_ = fs.Parse(args)

	mux := http.NewServeMux()
	mux.HandleFunc("/ready", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/v1/chat/completions", mockHandler("openai", *ttft, *chunks, *interval, *backendDelay, *payloadBytes))
	mux.HandleFunc("/v1/messages", mockHandler("anthropic", *ttft, *chunks, *interval, *backendDelay, *payloadBytes))
	server := &http.Server{Addr: *address, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("listening on %s", *address)
	log.Fatal(server.ListenAndServe())
}

func mockHandler(protocol string, ttft time.Duration, chunks int, interval, backendDelay time.Duration, payloadBytes int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		streaming := bytes.Contains(body, []byte(`"stream":true`))
		if !streaming {
			time.Sleep(backendDelay)
			w.Header().Set("Content-Type", "application/json")
			text := strings.Repeat("x", max(1, payloadBytes-256))
			if protocol == "anthropic" {
				_ = json.NewEncoder(w).Encode(map[string]any{"id": "msg_mock", "type": "message", "content": []map[string]string{{"type": "text", "text": text}}})
			} else {
				_ = json.NewEncoder(w).Encode(map[string]any{"id": "chatcmpl_mock", "choices": []map[string]any{{"index": 0, "message": map[string]string{"role": "assistant", "content": text}}}})
			}
			return
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		time.Sleep(ttft)
		for i := 0; i < chunks; i++ {
			if protocol == "anthropic" {
				fmt.Fprintf(w, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"token-%d\"}}\n\n", i)
			} else {
				fmt.Fprintf(w, "data: {\"id\":\"chatcmpl_mock\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"token-%d\"}}]}\n\n", i)
			}
			flusher.Flush()
			if i+1 < chunks {
				time.Sleep(interval)
			}
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
		flusher.Flush()
	}
}

func runLoad(args []string) {
	fs := flag.NewFlagSet("load", flag.ExitOnError)
	url := fs.String("url", "http://127.0.0.1:8080/v1/chat/completions", "target URL")
	host := fs.String("host", "", "optional HTTP Host header")
	protocol := fs.String("protocol", "openai", "openai or anthropic")
	streaming := fs.Bool("stream", false, "request an SSE stream")
	concurrency := fs.Int("concurrency", 10, "number of closed-loop workers")
	duration := fs.Duration("duration", 30*time.Second, "measurement duration")
	timeout := fs.Duration("timeout", 30*time.Second, "per-request timeout")
	promptBytes := fs.Int("prompt-bytes", 1024, "approximate prompt size")
	_ = fs.Parse(args)
	if *concurrency < 1 || (*protocol != "openai" && *protocol != "anthropic") {
		log.Fatal("concurrency must be positive and protocol must be openai or anthropic")
	}

	prompt := strings.Repeat("p", max(1, *promptBytes))
	var payload []byte
	if *protocol == "anthropic" {
		payload, _ = json.Marshal(map[string]any{"model": "mock", "max_tokens": 512, "stream": *streaming, "messages": []map[string]string{{"role": "user", "content": prompt}}})
	} else {
		payload, _ = json.Marshal(map[string]any{"model": "mock", "stream": *streaming, "messages": []map[string]string{{"role": "user", "content": prompt}}})
	}

	transport := &http.Transport{
		MaxIdleConns:        *concurrency * 2,
		MaxIdleConnsPerHost: *concurrency,
		MaxConnsPerHost:     *concurrency,
		IdleConnTimeout:     90 * time.Second,
	}
	client := &http.Client{Transport: transport, Timeout: *timeout}
	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()
	results := make(chan sample, *concurrency*4)
	var workers sync.WaitGroup
	started := time.Now()
	for i := 0; i < *concurrency; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for ctx.Err() == nil {
				// Do not cancel an in-flight stream at the measurement boundary.
				// Let it complete, then stop that worker before the next request.
				results <- oneRequest(context.Background(), client, *url, *host, payload)
			}
		}()
	}
	go func() { workers.Wait(); close(results) }()

	var totals, ttfbs []time.Duration
	successes, errors := 0, 0
	for result := range results {
		if result.ok {
			successes++
			totals = append(totals, result.total)
			ttfbs = append(ttfbs, result.ttfb)
		} else {
			errors++
		}
	}
	elapsed := time.Since(started)
	out := summary{
		URL: *url, Protocol: *protocol, Streaming: *streaming, Concurrency: *concurrency,
		DurationSec: elapsed.Seconds(), Requests: successes + errors, Successes: successes,
		Errors: errors, RPS: float64(successes) / elapsed.Seconds(),
		LatencyMS: percentiles(totals), TTFBMS: percentiles(ttfbs),
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(out); err != nil {
		log.Fatal(err)
	}
}

func oneRequest(parent context.Context, client *http.Client, url, host string, payload []byte) sample {
	start := time.Now()
	var firstByte time.Time
	trace := &httptrace.ClientTrace{GotFirstResponseByte: func() { firstByte = time.Now() }}
	ctx, cancel := context.WithCancel(httptrace.WithClientTrace(parent, trace))
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return sample{}
	}
	req.Header.Set("Content-Type", "application/json")
	if host != "" {
		req.Host = host
	}
	resp, err := client.Do(req)
	if err != nil {
		return sample{}
	}
	_, readErr := io.Copy(io.Discard, resp.Body)
	closeErr := resp.Body.Close()
	finished := time.Now()
	if firstByte.IsZero() {
		firstByte = finished
	}
	return sample{total: finished.Sub(start), ttfb: firstByte.Sub(start), ok: readErr == nil && closeErr == nil && resp.StatusCode >= 200 && resp.StatusCode < 300}
}

func percentiles(values []time.Duration) map[string]float64 {
	result := map[string]float64{"p50": 0, "p95": 0, "p99": 0, "max": 0}
	if len(values) == 0 {
		return result
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	for label, quantile := range map[string]float64{"p50": .50, "p95": .95, "p99": .99, "max": 1} {
		index := int(float64(len(values)-1) * quantile)
		result[label] = float64(values[index].Microseconds()) / 1000
	}
	return result
}
