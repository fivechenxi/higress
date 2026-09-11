// Copyright 2026 alibaba
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
	total  time.Duration
	ttfb   time.Duration
	bytes  int64
	status int
	ok     bool
}

type benchMetrics struct {
	mu                       sync.Mutex
	labels                   string
	concurrency              int
	startUnix                int64
	inflight, started        int64
	completed, failed, bytes int64
	ttfb, latency            []float64
	statuses                 map[int]int64
}

var histogramBounds = []float64{0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 5, 10, 30, 60}

func metricLabels(run, target, protocol string, streaming bool) string {
	escape := func(value string) string {
		value = strings.ReplaceAll(value, `\`, `\\`)
		value = strings.ReplaceAll(value, `"`, `\"`)
		return strings.ReplaceAll(value, "\n", `\n`)
	}
	return fmt.Sprintf(`run="%s",target="%s",protocol="%s",stream="%t"`, escape(run), escape(target), escape(protocol), streaming)
}

func (m *benchMetrics) begin() {
	m.mu.Lock()
	m.inflight++
	m.started++
	m.mu.Unlock()
}

func (m *benchMetrics) finish(result sample) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.inflight--
	if result.status != 0 {
		m.statuses[result.status]++
	}
	if result.ok {
		m.completed++
		m.bytes += result.bytes
		m.ttfb = append(m.ttfb, result.ttfb.Seconds())
		m.latency = append(m.latency, result.total.Seconds())
	} else {
		m.failed++
	}
}

func (m *benchMetrics) serveHTTP(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "llm_bench_inflight{%s} %d\n", m.labels, m.inflight)
	fmt.Fprintf(w, "llm_bench_requests_started_total{%s} %d\n", m.labels, m.started)
	fmt.Fprintf(w, "llm_bench_requests_completed_total{%s} %d\n", m.labels, m.completed)
	fmt.Fprintf(w, "llm_bench_requests_failed_total{%s} %d\n", m.labels, m.failed)
	fmt.Fprintf(w, "llm_bench_response_bytes_total{%s} %d\n", m.labels, m.bytes)
	fmt.Fprintf(w, "llm_bench_configured_concurrency{%s} %d\n", m.labels, m.concurrency)
	fmt.Fprintf(w, "llm_bench_run_start_time_seconds{%s} %d\n", m.labels, m.startUnix)
	for status, count := range m.statuses {
		fmt.Fprintf(w, "llm_bench_responses_total{%s,code=\"%d\"} %d\n", m.labels, status, count)
	}
	writeHistogram(w, "llm_bench_ttfb_seconds", m.labels, m.ttfb)
	writeHistogram(w, "llm_bench_stream_latency_seconds", m.labels, m.latency)
}

func writeHistogram(w io.Writer, name, labels string, observations []float64) {
	var sum float64
	for _, value := range observations {
		sum += value
	}
	for _, bound := range histogramBounds {
		count := 0
		for _, value := range observations {
			if value <= bound {
				count++
			}
		}
		fmt.Fprintf(w, "%s_bucket{%s,le=\"%g\"} %d\n", name, labels, bound, count)
	}
	fmt.Fprintf(w, "%s_bucket{%s,le=\"+Inf\"} %d\n", name, labels, len(observations))
	fmt.Fprintf(w, "%s_sum{%s} %g\n", name, labels, sum)
	fmt.Fprintf(w, "%s_count{%s} %d\n", name, labels, len(observations))
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
				fmt.Fprintf(w, "data: {\"id\":\"chatcmpl_mock\",\"model\":\"mock-stream-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"token-%d\"}}]}\n\n", i)
			}
			flusher.Flush()
			if i+1 < chunks {
				time.Sleep(interval)
			}
		}
		if protocol == "openai" {
			fmt.Fprintf(w, "data: {\"id\":\"chatcmpl_mock\",\"model\":\"mock-stream-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":128,\"completion_tokens\":%d,\"total_tokens\":%d}}\n\n", chunks, 128+chunks)
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
	metricsAddress := fs.String("metrics-address", "", "optional Prometheus listen address, for example :9090")
	metricsFinalDelay := fs.Duration("metrics-final-delay", 20*time.Second, "keep final metrics available for scraping")
	runLabel := fs.String("run-label", "manual", "bounded test run ID")
	targetLabel := fs.String("target-label", "unknown", "bounded target label, direct or gateway")
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
	metrics := &benchMetrics{
		labels:      metricLabels(*runLabel, *targetLabel, *protocol, *streaming),
		concurrency: *concurrency,
		startUnix:   time.Now().Unix(),
		statuses:    make(map[int]int64),
	}
	var metricsServer *http.Server
	if *metricsAddress != "" {
		metricsServer = &http.Server{Addr: *metricsAddress, Handler: http.HandlerFunc(metrics.serveHTTP), ReadHeaderTimeout: 2 * time.Second}
		go func() {
			if err := metricsServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Printf("metrics server: %v", err)
			}
		}()
	}
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
				metrics.begin()
				result := oneRequest(context.Background(), client, *url, *host, payload)
				metrics.finish(result)
				results <- result
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
	if metricsServer != nil {
		time.Sleep(*metricsFinalDelay)
		_ = metricsServer.Shutdown(context.Background())
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
	readBytes, readErr := io.Copy(io.Discard, resp.Body)
	closeErr := resp.Body.Close()
	finished := time.Now()
	if firstByte.IsZero() {
		firstByte = finished
	}
	return sample{total: finished.Sub(start), ttfb: firstByte.Sub(start), bytes: readBytes, status: resp.StatusCode, ok: readErr == nil && closeErr == nil && resp.StatusCode >= 200 && resp.StatusCode < 300}
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
